import re
from dataclasses import dataclass

from .schemas import ModelRoute, RouteRequest, RouteResponse


ALLOWED_SOURCES = {
    "nws",
    "mbta_alerts",
    "mbta_predictions",
    "boston_311",
    "local_news",
    "university_events",
}


@dataclass(frozen=True)
class SourceProfile:
    category: str
    sources: tuple[str, ...]
    phrases: tuple[str, ...]


SOURCE_PROFILES = (
    SourceProfile(
        "weather",
        ("nws",),
        (
            "weather", "forecast", "rain", "snow", "temperature", "wind",
            "umbrella", "heat index", "air outside", "cloudy", "sunny",
            "storm", "precipitation", "how hot", "how cold",
        ),
    ),
    SourceProfile(
        "transit",
        ("mbta_predictions",),
        (
            "next train", "next bus", "arrival", "departure", "when does",
            "when is", "platform", "schedule", "how long until", "commuter rail",
        ),
    ),
    SourceProfile(
        "transit",
        ("mbta_alerts",),
        (
            "mbta", "green line", "red line", "orange line", "blue line",
            "silver line", "train delay", "bus delay", "service alert",
            "station closed", "transit disruption", "subway",
        ),
    ),
    SourceProfile(
        "civic_services",
        ("boston_311", "local_news"),
        (
            "311", "pothole", "streetlight", "trash pickup", "illegal dumping",
            "flooding complaint", "storm drain", "catch basin", "road damage",
            "unresolved complaint", "public works", "sidewalk", "rodent",
        ),
    ),
    SourceProfile(
        "housing",
        ("boston_311", "local_news"),
        (
            "housing", "tenant", "landlord", "rent", "eviction", "inspection",
            "building code", "housing application", "shelter", "affordable housing",
        ),
    ),
    SourceProfile(
        "public_safety",
        ("local_news", "boston_311"),
        (
            "power outage", "road closed", "street closed", "fire", "police",
            "public safety", "emergency", "hazard", "water main", "gas leak",
        ),
    ),
    SourceProfile(
        "events",
        ("university_events", "local_news"),
        (
            "university event", "campus event", "community meeting", "town hall",
            "public hearing", "festival", "academic calendar", "classes start",
        ),
    ),
    SourceProfile(
        "local_news",
        ("local_news",),
        (
            "why are residents", "why is the city", "officials", "investigation",
            "accountability", "repeated", "increasing", "unresolved", "this month",
            "neighborhood problem", "community concern", "local news",
        ),
    ),
)


OUT_OF_SCOPE_PATTERNS = (
    r"\bbest (?:pizza|restaurant|bar|coffee|food|movie|song|singer)\b",
    r"\bwrite (?:my|an?) (?:essay|assignment|homework)\b",
    r"\btell me a joke\b",
    r"\bshopping recommendation\b",
)
SMALL_TALK_PATTERN = re.compile(
    r"^\s*(?:hi|hello|hey|good morning|good afternoon|good evening|good night|thanks|thank you)[!.?\s]*$",
    re.IGNORECASE,
)
KNOWN_LOCATIONS = {
    "boston": "Boston, MA",
    "cambridge": "Cambridge, MA",
    "somerville": "Somerville, MA",
    "brookline": "Brookline, MA",
    "newton": "Newton, MA",
    "quincy": "Quincy, MA",
    "san francisco": "San Francisco, CA",
    "new york": "New York, NY",
    "washington dc": "Washington, DC",
}
TOKEN_SYNONYMS = {
    "showers": "rain",
    "raining": "rain",
    "rainy": "rain",
    "breezy": "wind",
    "windy": "wind",
    "hot": "temperature",
    "cold": "temperature",
    "subway": "mbta",
    "tram": "mbta",
    "t": "mbta",
    "trains": "train",
    "buses": "bus",
    "late": "delay",
    "delayed": "delay",
    "delays": "delay",
    "outages": "outage",
    "complaints": "complaint",
}


def local_route(request: RouteRequest) -> RouteResponse:
    question = request.question.strip()
    normalized = _normalize(question)
    location = _extract_location(question) or request.location

    if SMALL_TALK_PATTERN.fullmatch(question):
        return RouteResponse(
            category="other",
            sources=[],
            location=location,
            out_of_scope=False,
            confidence=1,
            method="rules",
        )

    if any(re.search(pattern, normalized) for pattern in OUT_OF_SCOPE_PATTERNS):
        return RouteResponse(
            category="other",
            sources=[],
            location=location,
            out_of_scope=True,
            confidence=0.99,
            method="rules",
        )

    scored = sorted(
        ((_profile_score(normalized, profile), profile) for profile in SOURCE_PROFILES),
        key=lambda item: item[0],
        reverse=True,
    )
    best_score, best_profile = scored[0]

    if best_score <= 0:
        return RouteResponse(
            category="other",
            sources=[],
            location=location,
            confidence=0.2,
            method="local_nlp",
        )

    selected_profiles = [
        profile
        for score, profile in scored
        if score >= 2 and score >= best_score - 1.5
    ] or [best_profile]
    sources = list(
        dict.fromkeys(
            source
            for profile in selected_profiles
            for source in profile.sources
        )
    )
    category = best_profile.category
    confidence = min(0.96, 0.48 + best_score * 0.09)
    if best_score >= 1.5:
        confidence = max(confidence, 0.78)

    if category == "transit":
        arrival_intent = bool(
            re.search(
                r"\b(next|arrive|arrival|departure|depart|schedule|how long until|when is|when does)\b",
                normalized,
            )
        )
        disruption_intent = bool(
            re.search(
                r"\b(delay|service alert|disruption|not running|closed|closure|problem)\b",
                normalized,
            )
        )
        sources = []
        if arrival_intent:
            sources.append("mbta_predictions")
        if disruption_intent:
            sources.append("mbta_alerts")
        if not sources:
            sources.append("mbta_alerts")

    broad_transit = bool(
        re.search(r"\b(public transport|public transportation|nearby transit|nearest station)\b", normalized)
    )
    requires_location = category in {
        "weather", "civic_services", "housing", "public_safety", "local_news"
    } or broad_transit
    institution_missing = (
        "university_events" in sources
        and re.search(r"\b(class|classes|semester|term|tuition|college|university)\b", normalized)
        and not re.search(
            r"\b(northeastern|harvard|mit|boston university|boston college|umass)\b",
            normalized,
        )
    )

    if institution_missing:
        return RouteResponse(
            category=category,
            sources=sources,
            location=location,
            needs_clarification=True,
            clarification_question="Which school or university are you asking about?",
            confidence=0.95,
            method="rules",
        )

    if requires_location and not location:
        return RouteResponse(
            category=category,
            sources=sources,
            needs_clarification=True,
            clarification_question="Which city and state are you asking about?",
            confidence=max(confidence, 0.85),
            method="rules",
        )

    return RouteResponse(
        category=category,
        sources=sources,
        location=location,
        confidence=confidence,
        method="local_nlp",
    )


def should_use_gemini(route: RouteResponse) -> bool:
    return (
        route.method == "local_nlp"
        and not route.needs_clarification
        and not route.out_of_scope
        and route.confidence < 0.72
    )


def validated_model_route(model_route: ModelRoute, fallback: RouteResponse) -> RouteResponse:
    sources = [
        source for source in dict.fromkeys(model_route.sources) if source in ALLOWED_SOURCES
    ]
    needs_clarification = model_route.needs_clarification
    clarification = model_route.clarification_question
    if needs_clarification and not clarification:
        clarification = "Could you share the city, agency, route, or institution you mean?"

    # A local public-interest question with no selected trusted source is not a
    # true gap. Ask for clarification or let the answering layer mark it as a
    # system/source-coverage miss.
    if not model_route.out_of_scope and not needs_clarification and not sources:
        needs_clarification = True
        clarification = "Could you be more specific about the local place or service involved?"

    return RouteResponse(
        category=model_route.category,
        sources=sources,
        location=model_route.location or fallback.location,
        needs_clarification=needs_clarification,
        clarification_question=clarification,
        out_of_scope=model_route.out_of_scope,
        confidence=model_route.confidence,
        method="gemini",
    )


def _normalize(value: str) -> str:
    words = re.findall(r"[a-z0-9]+", value.lower())
    return " ".join(TOKEN_SYNONYMS.get(word, word) for word in words)


def _profile_score(normalized: str, profile: SourceProfile) -> float:
    question_tokens = set(normalized.split())
    score = 0.0
    for phrase in profile.phrases:
        normalized_phrase = _normalize(phrase)
        phrase_tokens = set(normalized_phrase.split())
        if normalized_phrase in normalized:
            score += 2.5 if len(phrase_tokens) > 1 else 1.5
        else:
            overlap = len(question_tokens & phrase_tokens)
            if overlap:
                score += overlap / max(len(phrase_tokens), 1)
    return score


def _extract_location(question: str) -> str | None:
    city_state = re.search(
        r"\b([A-Z][A-Za-z.'-]*(?:\s+[A-Z][A-Za-z.'-]*){0,3}),\s*([A-Z]{2})\b",
        question,
    )
    if city_state:
        return f"{city_state.group(1)}, {city_state.group(2)}"

    normalized = _normalize(question)
    for name, display_name in KNOWN_LOCATIONS.items():
        if re.search(rf"\b{re.escape(name)}\b", normalized):
            return display_name
    return None
