import json
import os
from datetime import datetime, timezone

import httpx

from .schemas import AskRequest, AskResponse, Citation, ModelAnswer


SYSTEM_PROMPT = """
You are the AI Hyperlocal News Companion for a journalism research project.

Your job is to answer community questions in a warm, natural, concise voice while
remaining strictly grounded in the TRUSTED EVIDENCE supplied with the request.

Rules:
1. Never use model memory as evidence for weather, transit, civic services, news,
   events, public safety, housing, or other local facts.
2. Use status "answered" only when the supplied evidence directly supports the
   answer. Every answered response must cite at least one supplied source_id.
3. If the question is local and the evidence is missing or insufficient, use
   status "abstained" and explain kindly that you do not have a trusted answer yet.
4. If the message is only a greeting, farewell, or thanks, respond warmly with
   status "conversational". Do not describe friendly small talk as an
   information gap or as out of scope.
5. If the question is unrelated to local community information, use
   status "out_of_scope". Restaurant rankings, personal preferences, shopping,
   and entertainment recommendations are out of scope even when they mention a
   local city. Do not treat them as journalism information gaps.
6. Never invent a URL, source, statistic, event, cause, date, location, or citation.
7. Do not copy source wording at length. Synthesize the facts conversationally.
8. For forecasts beyond the dates present in the evidence, abstain rather than
   treating the current forecast as a future forecast.
9. Keep the answer useful and generally under 120 words.
10. CONVERSATION HISTORY provides language context for follow-up questions, but it
   is not trusted factual evidence. Never cite it or use it to support a local fact.
11. Return JSON only, matching the required response schema.
12. If MBTA evidence reports zero matching active alerts, say only that no active
    official alert was found. Do not claim that all service is operating normally.
13. When MBTA prediction evidence is supplied, answer with the published stop,
    platform direction, route, and upcoming time. If both directions are present,
    clearly list both. Never infer which platform reaches a requested destination
    unless the supplied evidence explicitly establishes that direction.
""".strip()


RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "answer": {"type": "string"},
        "status": {
            "type": "string",
            "enum": ["answered", "abstained", "out_of_scope", "conversational"],
        },
        "category": {
            "type": "string",
            "enum": [
                "weather",
                "transit",
                "housing",
                "public_safety",
                "local_news",
                "events",
                "other",
            ],
        },
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "citation_source_ids": {
            "type": "array",
            "items": {"type": "string"},
            "maxItems": 10,
        },
    },
    "required": [
        "answer",
        "status",
        "category",
        "confidence",
        "citation_source_ids",
    ],
    "additionalProperties": False,
}


class GeminiServiceError(RuntimeError):
    pass


class GeminiService:
    def __init__(self) -> None:
        self.api_key = os.getenv("GEMINI_API_KEY", "").strip()
        self.model = os.getenv("GEMINI_MODEL", "gemini-3.5-flash-lite").strip()
        self.base_url = os.getenv(
            "GEMINI_BASE_URL",
            "https://generativelanguage.googleapis.com/v1beta",
        ).rstrip("/")

    @property
    def is_configured(self) -> bool:
        return bool(self.api_key)

    async def answer(self, request: AskRequest) -> AskResponse:
        out_of_scope = _obvious_out_of_scope_response(request)
        if out_of_scope is not None:
            return out_of_scope

        if not self.is_configured:
            raise GeminiServiceError(
                "GEMINI_API_KEY is not configured on the backend."
            )

        evidence_payload = [
            {
                "source_id": item.source_id,
                "title": item.title,
                "url": str(item.url),
                "retrieved_at": item.retrieved_at,
                "text": item.text,
            }
            for item in request.evidence
        ]
        user_payload = {
            "current_time_utc": datetime.now(timezone.utc).isoformat(),
            "question": request.question,
            "location_context": request.location,
            "conversation_history": [
                {"role": item.role, "content": item.content}
                for item in request.history[-20:]
            ],
            "trusted_evidence": evidence_payload,
        }

        payload = {
            "systemInstruction": {"parts": [{"text": SYSTEM_PROMPT}]},
            "contents": [
                {
                    "role": "user",
                    "parts": [{"text": json.dumps(user_payload, ensure_ascii=False)}],
                }
            ],
            "generationConfig": {
                "responseMimeType": "application/json",
                "responseJsonSchema": RESPONSE_SCHEMA,
                # Thinking-capable Gemini models can use part of this allowance
                # before emitting the small JSON object we need. A limit of 1,000
                # occasionally produced a candidate with no text at all.
                "maxOutputTokens": 3_000,
                "temperature": 0.2,
            },
        }

        url = f"{self.base_url}/models/{self.model}:generateContent"
        last_error: GeminiServiceError | None = None

        # Gemini can occasionally return an empty/truncated candidate even though
        # the HTTP request succeeded. Retry that transient provider failure once;
        # never retry validation/authentication HTTP errors blindly.
        for attempt in range(2):
            try:
                async with httpx.AsyncClient(timeout=30) as client:
                    response = await client.post(
                        url,
                        headers={
                            "Content-Type": "application/json",
                            "x-goog-api-key": self.api_key,
                        },
                        json=payload,
                    )
            except httpx.HTTPError as error:
                last_error = GeminiServiceError("Could not reach Gemini.")
                if attempt == 0:
                    continue
                raise last_error from error

            if response.status_code >= 400:
                detail = _provider_error_message(response)
                error = GeminiServiceError(
                    f"Gemini returned HTTP {response.status_code}: {detail}"
                )
                if attempt == 0 and response.status_code in {500, 502, 503, 504}:
                    last_error = error
                    continue
                raise error

            try:
                model_answer = _parse_model_answer(response.json())
                return _grounded_response(model_answer, request)
            except (KeyError, IndexError, TypeError, ValueError) as error:
                last_error = GeminiServiceError(
                    "Gemini did not return a complete answer. Please try again."
                )
                if attempt == 0:
                    continue
                raise last_error from error

        raise last_error or GeminiServiceError("Could not reach Gemini.")


def _obvious_out_of_scope_response(request: AskRequest) -> AskResponse | None:
    """Keep clear consumer recommendations out of the journalism-gap dataset.

    The LLM still classifies nuanced civic questions. This narrow deterministic
    guard covers the explicit non-news examples in the research taxonomy and
    prevents model variation from creating false journalist leads.
    """
    question = " ".join(request.question.lower().split())
    recommendation_markers = (
        "best ",
        "recommend ",
        "recommendation",
        "top-rated",
        "top rated",
        "favorite ",
        "favourite ",
        "where should i eat",
        "where should i shop",
    )
    consumer_topics = (
        "pizza",
        "restaurant",
        "food",
        "coffee",
        "cafe",
        "bar ",
        "shopping",
        "store",
        "hotel",
        "movie",
        "entertainment",
        "date night",
    )
    if not (
        any(marker in question for marker in recommendation_markers)
        and any(topic in question for topic in consumer_topics)
    ):
        return None

    return AskResponse(
        answer=(
            "That’s a personal recommendation rather than a civic information "
            "question, so I won’t record it as a journalism gap. I can help with "
            "local services, public agencies, transportation, housing, safety, "
            "weather, and other community issues."
        ),
        status="out_of_scope",
        outcome="out_of_scope",
        category="other",
        confidence=1,
        citations=[],
        evidence_checked=[item.title for item in request.evidence],
        save_for_journalist=False,
    )


def _parse_model_answer(provider_response: object) -> ModelAnswer:
    """Extract structured JSON from all Gemini text parts.

    Structured-output responses normally contain one plain JSON text part, but
    some model versions split text across parts or wrap it in a Markdown fence.
    Accepting those harmless variations prevents a valid answer from appearing
    in the app as an "invalid response" error.
    """
    if not isinstance(provider_response, dict):
        raise ValueError("Provider response is not an object.")

    candidates = provider_response.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        raise ValueError("Provider response has no candidates.")

    content = candidates[0].get("content")
    if not isinstance(content, dict):
        raise ValueError("Provider candidate has no content.")

    parts = content.get("parts")
    if not isinstance(parts, list):
        raise ValueError("Provider candidate has no parts.")

    text = "".join(
        part.get("text", "")
        for part in parts
        if isinstance(part, dict) and isinstance(part.get("text"), str)
    ).strip()
    if text.startswith("```"):
        lines = text.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip() == "```":
            lines = lines[:-1]
        text = "\n".join(lines).strip()

    if not text:
        raise ValueError("Provider candidate contains no text.")
    return ModelAnswer.model_validate_json(text)


def _grounded_response(model_answer: ModelAnswer, request: AskRequest) -> AskResponse:
    evidence_by_id = {item.source_id: item for item in request.evidence}
    valid_ids = list(
        dict.fromkeys(
            source_id
            for source_id in model_answer.citation_source_ids
            if source_id in evidence_by_id
        )
    )

    status = model_answer.status
    answer = model_answer.answer.strip()
    confidence = model_answer.confidence

    # This backend—not the model—enforces the central research rule: an answer
    # without trusted evidence and at least one valid citation cannot be published.
    if status == "answered" and (not request.evidence or not valid_ids):
        status = "abstained"
        answer = (
            "I’m sorry—I don’t have enough trusted evidence to answer that yet, "
            "and I don’t want to guess. I can save this as an information gap for "
            "journalist review."
        )
        confidence = 0
        valid_ids = []

    if status != "answered":
        valid_ids = []

    if status == "answered":
        outcome = "answered"
    elif status in {"out_of_scope", "conversational"}:
        outcome = "out_of_scope"
    else:
        outcome = "true_gap"

    citations = [
        Citation(title=evidence_by_id[source_id].title, url=evidence_by_id[source_id].url)
        for source_id in valid_ids
    ]
    return AskResponse(
        answer=answer,
        status=status,
        outcome=outcome,
        category=model_answer.category,
        confidence=confidence,
        citations=citations,
        evidence_checked=[item.title for item in request.evidence],
        save_for_journalist=outcome == "true_gap",
    )


def _provider_error_message(response: httpx.Response) -> str:
    try:
        payload = response.json()
        message = payload.get("error", {}).get("message")
        if isinstance(message, str) and message:
            return message[:400]
    except ValueError:
        pass
    return "Provider request failed."
