"""Embeddings-based semantic router.

Instead of matching keywords, this routes a question by *meaning*: a small set of
labeled example questions ("prototypes") is embedded once, the incoming question
is embedded at request time, and the question is assigned to the label with the
highest cosine similarity. This is robust to paraphrase ("is the T screwed up?"
still routes to transit) and needs no hand-maintained keyword lists.

It uses the Gemini embedding API (same key/base URL as the answer model). If no
key is configured, the caller falls back to the deterministic keyword router, so
the app still runs offline. The rule-based router and this one share the gold-set
eval harness, so the precision/recall difference is measured, not assumed.
"""

from __future__ import annotations

import math
import os

import httpx

from .router import _extract_location
from .schemas import RouteRequest, RouteResponse

# Labeled example questions. The label maps to a (category, sources) routing in
# LABEL_ROUTING below. A few short, varied examples per label is enough for
# nearest-prototype classification.
PROTOTYPES: dict[str, tuple[str, ...]] = {
    "weather": (
        "Will it rain tomorrow?",
        "How cold is it outside right now?",
        "Do I need an umbrella today?",
        "What's the forecast for this weekend?",
        "Is it going to snow tonight?",
    ),
    "transit_arrival": (
        "When is the next train?",
        "How long until the next bus?",
        "What time does the next Red Line arrive?",
        "Next departure from South Station?",
    ),
    "transit_alert": (
        "Is the Green Line delayed?",
        "Are there any MBTA service alerts?",
        "Is the subway running normally today?",
        "Why is the Orange Line not running?",
    ),
    "civic": (
        "There's a pothole that hasn't been fixed.",
        "Why does trash keep piling up on my street?",
        "The streetlight has been broken for weeks.",
        "How do I report illegal dumping?",
    ),
    "housing": (
        "My landlord won't fix the heat.",
        "Where do I apply for affordable housing?",
        "How do I report a housing code violation?",
    ),
    "public_safety": (
        "Is there a power outage near me?",
        "Which roads are closed after the water main break?",
        "Is there a gas leak reported downtown?",
    ),
    "events": (
        "Is there a community meeting this week?",
        "Any campus events this weekend?",
        "When is the next town hall?",
    ),
    "local_news": (
        "Why is the city ignoring these repeated problems?",
        "Who is accountable for this ongoing issue?",
        "Why hasn't anyone investigated this?",
    ),
    "out_of_scope": (
        "What's the best pizza in Boston?",
        "Tell me a joke.",
        "What movie should I watch tonight?",
        "Write my essay for me.",
    ),
    "small_talk": (
        "Hi there",
        "Thank you so much",
        "Good morning",
    ),
}

LABEL_ROUTING: dict[str, tuple[str, tuple[str, ...]]] = {
    "weather": ("weather", ("nws",)),
    "transit_arrival": ("transit", ("mbta_predictions",)),
    "transit_alert": ("transit", ("mbta_alerts",)),
    "civic": ("civic_services", ("boston_311", "local_news")),
    "housing": ("housing", ("boston_311", "local_news")),
    "public_safety": ("public_safety", ("local_news", "boston_311")),
    "events": ("events", ("university_events", "local_news")),
    "local_news": ("local_news", ("local_news",)),
    "out_of_scope": ("other", ()),
    "small_talk": ("other", ()),
}

# Categories whose answer is location-specific; if no location is known we ask.
_REQUIRES_LOCATION = {"weather", "civic_services", "housing", "public_safety", "local_news"}

# Module-level cache so prototype vectors are embedded once per process, not per
# request. Keyed by model so switching models re-embeds.
_PROTOTYPE_CACHE: dict[str, list[tuple[str, list[float]]]] = {}


class EmbeddingRouter:
    def __init__(self) -> None:
        self.api_key = os.getenv("GEMINI_API_KEY", "").strip()
        self.model = os.getenv("GEMINI_EMBED_MODEL", "text-embedding-004").strip()
        self.base_url = os.getenv(
            "GEMINI_BASE_URL",
            "https://generativelanguage.googleapis.com/v1beta",
        ).rstrip("/")
        # Below this top similarity the match is too weak to trust; treat as
        # out of scope rather than forcing a civic category.
        self.min_similarity = float(os.getenv("EMBED_MIN_SIMILARITY", "0.60"))

    @property
    def is_configured(self) -> bool:
        return bool(self.api_key)

    async def route(self, request: RouteRequest) -> RouteResponse | None:
        """Semantic route, or None if embeddings are unavailable/failed."""
        if not self.is_configured:
            return None
        try:
            prototypes = await self._prototype_vectors()
            query = (await self._embed([request.question]))[0]
        except (httpx.HTTPError, KeyError, IndexError, ValueError, TypeError):
            return None

        best_label, best_score = _nearest_label(query, prototypes)
        location = _extract_location(request.question) or request.location

        if best_score < self.min_similarity or best_label == "out_of_scope":
            return RouteResponse(
                category="other",
                sources=[],
                location=location,
                out_of_scope=best_label == "out_of_scope",
                confidence=round(best_score, 3),
                method="embeddings",
            )
        if best_label == "small_talk":
            return RouteResponse(
                category="other",
                sources=[],
                location=location,
                confidence=round(best_score, 3),
                method="embeddings",
            )

        category, sources = LABEL_ROUTING[best_label]
        if category in _REQUIRES_LOCATION and not location:
            return RouteResponse(
                category=category,
                sources=list(sources),
                needs_clarification=True,
                clarification_question="Which city and state are you asking about?",
                confidence=round(best_score, 3),
                method="embeddings",
            )
        return RouteResponse(
            category=category,
            sources=list(sources),
            location=location,
            confidence=round(best_score, 3),
            method="embeddings",
        )

    async def _prototype_vectors(self) -> list[tuple[str, list[float]]]:
        cached = _PROTOTYPE_CACHE.get(self.model)
        if cached is not None:
            return cached
        labels: list[str] = []
        texts: list[str] = []
        for label, examples in PROTOTYPES.items():
            for example in examples:
                labels.append(label)
                texts.append(example)
        vectors = await self._embed(texts)
        prototypes = list(zip(labels, vectors))
        _PROTOTYPE_CACHE[self.model] = prototypes
        return prototypes

    async def _embed(self, texts: list[str]) -> list[list[float]]:
        url = f"{self.base_url}/models/{self.model}:batchEmbedContents"
        payload = {
            "requests": [
                {
                    "model": f"models/{self.model}",
                    "content": {"parts": [{"text": text}]},
                }
                for text in texts
            ]
        }
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.post(
                url,
                headers={
                    "Content-Type": "application/json",
                    "x-goog-api-key": self.api_key,
                },
                json=payload,
            )
        response.raise_for_status()
        data = response.json()
        return [item["values"] for item in data["embeddings"]]


def _nearest_label(
    query: list[float],
    prototypes: list[tuple[str, list[float]]],
) -> tuple[str, float]:
    """Return the label of the most cosine-similar prototype and that score."""
    best_label = "out_of_scope"
    best_score = -1.0
    for label, vector in prototypes:
        score = _cosine(query, vector)
        if score > best_score:
            best_score = score
            best_label = label
    return best_label, best_score


def _cosine(a: list[float], b: list[float]) -> float:
    dot = 0.0
    norm_a = 0.0
    norm_b = 0.0
    for x, y in zip(a, b):
        dot += x * y
        norm_a += x * x
        norm_b += y * y
    if norm_a == 0.0 or norm_b == 0.0:
        return 0.0
    return dot / (math.sqrt(norm_a) * math.sqrt(norm_b))
