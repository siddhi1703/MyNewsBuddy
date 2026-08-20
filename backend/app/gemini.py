import json
import os
import re
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
3. Use status "abstained" only for a sufficiently specific, public-interest local
   question that trusted sources do not answer. This is a potential journalism
   information gap, so do not use it merely because a question is ambiguous.
4. If the message is only a greeting, farewell, or thanks, respond warmly with
   status "conversational". Do not describe friendly small talk as an
   information gap or as out of scope.
5. If the question is unrelated to local community information, use
   status "out_of_scope". Restaurant rankings, personal preferences, shopping,
   and entertainment recommendations are out of scope even when they mention a
   local city. Do not treat them as journalism information gaps.
6. If a potentially valid local question is missing an essential detail such as
   the institution, agency, neighborhood, route, or event, use status
   "needs_clarification" and ask one concise follow-up question. Do not save an
   ambiguous question as a journalism gap. Example: for "When do fall classes
   start in Boston?", ask which school or university.
7. First classify the user's intent using meaning and context, not keyword matching.
   Examples: "best pizza in Boston" is out_of_scope; "why did inspectors close
   this restaurant?" may be a public-interest gap; "when do classes start in
   Boston?" needs_clarification; recurring power failures may be a true gap.
8. Use status "source_unavailable" for a routine factual or service question that
   is likely answered by an existing official source which was not supplied, such
   as a university calendar, tuition page, 311 case, or government form. That is
   a source-coverage/system gap, not a journalism information gap, so do not save
   it for journalists. By contrast, an unexplained recurring pattern, public harm,
   or accountability question may be a true information gap.
9. Use CONVERSATION HISTORY to resolve follow-up references and short answers to
   clarification questions. If the user has already named the institution, place,
   route, or event, do not ask for that same detail again. History can establish
   conversational context, but it is not factual evidence and must never be cited.
10. Never invent a URL, source, statistic, event, cause, date, location, or citation.
11. Do not copy source wording at length. Synthesize the facts conversationally.
12. For forecasts beyond the dates present in the evidence, abstain rather than
   treating the current forecast as a future forecast.
13. Keep the answer useful and generally under 120 words.
14. Return JSON only, matching the required response schema.
15. If MBTA evidence reports zero matching active alerts, say only that no active
    official alert was found. Do not claim that all service is operating normally.
16. When MBTA prediction evidence is supplied, answer with the published stop,
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
            "enum": [
                "answered",
                "abstained",
                "out_of_scope",
                "conversational",
                "needs_clarification",
                "source_unavailable",
            ],
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
        if guarded_response := _research_quality_guardrail(request):
            return guarded_response

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


def _research_quality_guardrail(request: AskRequest) -> AskResponse | None:
    """Keep predictable source limits out of the journalism-gap dataset.

    Gemini still performs semantic intent classification and writes grounded
    answers. These narrow deterministic checks enforce research policy for two
    routine cases that must never be mislabeled as community reporting leads.
    """
    question = request.question.strip()
    normalized = question.lower()

    weather_terms = ("weather", "forecast", "rain", "snow", "temperature")
    horizon_match = re.search(
        r"\b(?:after|in|next|for)\s+(\d{1,3})\s*(day|days|week|weeks|month|months)\b",
        normalized,
    )
    if horizon_match and any(term in normalized for term in weather_terms):
        amount = int(horizon_match.group(1))
        unit = horizon_match.group(2)
        days = amount * (7 if unit.startswith("week") else 30 if unit.startswith("month") else 1)
        if days > 7:
            return AskResponse(
                answer=(
                    "The National Weather Service forecast connected to this app "
                    "covers about seven days, so I can’t give you a trustworthy "
                    f"{amount}-{unit.rstrip('s')} forecast. This is a forecast "
                    "limit, not a missing community answer."
                ),
                status="source_unavailable",
                outcome="system_miss",
                category="weather",
                confidence=1,
                citations=[],
                evidence_checked=[item.title for item in request.evidence],
                save_for_journalist=False,
            )

    routine_calendar = (
        re.search(r"\bwhen\b", normalized)
        and re.search(r"\b(class|classes|semester|term|college|school|university)\b", normalized)
        and re.search(r"\b(start|starts|begin|begins|open|opens)\b", normalized)
        and not re.search(r"\bwhy\b|\bcancel|\bclosed\b|\bdelay|\bproblem\b|\bimpact\b", normalized)
    )
    if routine_calendar:
        return AskResponse(
            answer=(
                "That date should come from the specific school or university’s "
                "official academic calendar. That source is not connected yet, "
                "so I won’t guess or label this as a journalism gap."
            ),
            status="source_unavailable",
            outcome="system_miss",
            category="events",
            confidence=1,
            citations=[],
            evidence_checked=[item.title for item in request.evidence],
            save_for_journalist=False,
        )

    return None


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
    elif status in {"out_of_scope", "conversational", "needs_clarification"}:
        outcome = "out_of_scope"
    elif status == "source_unavailable":
        outcome = "system_miss"
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
