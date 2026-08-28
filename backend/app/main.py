from fastapi import Depends, FastAPI

from .auth import (
    AuthenticatedUser,
    auth_is_configured,
    authorize_chat_request,
    authorize_routing_request,
)
from .gemini import GeminiService, GeminiServiceError
from .router import local_route, should_use_gemini
from .schemas import AskRequest, AskResponse, RouteRequest, RouteResponse


app = FastAPI(
    title="AI Hyperlocal News Companion API",
    version="0.1.0",
    description="Grounded LLM answers for the Local Companion iOS application.",
)


@app.get("/")
async def root() -> dict[str, str]:
    return {"message": "AI Hyperlocal News Companion API"}


@app.get("/health")
async def health() -> dict[str, str | bool]:
    service = GeminiService()
    return {
        "status": "ok",
        "provider": "gemini",
        "model": service.model,
        "model_configured": service.is_configured,
        "authentication_configured": auth_is_configured(),
    }


@app.post("/ask", response_model=AskResponse)
async def ask(
    request: AskRequest,
    _user: AuthenticatedUser = Depends(authorize_chat_request),
) -> AskResponse:
    try:
        return await GeminiService().answer(request)
    except GeminiServiceError as error:
        provider_message = str(error)
        if "HTTP 429" in provider_message:
            message = (
                "The AI request limit has been reached, so I can’t safely "
                "evaluate this question right now. Please try again after "
                "the Gemini quota resets."
            )
        elif "not configured" in provider_message:
            message = (
                "The AI service is not configured right now. This is a system "
                "problem, not a missing community answer."
            )
        else:
            message = (
                "I couldn’t reach the AI service right now. This is a system "
                "problem, so I will not record your question as an information gap."
            )

        return AskResponse(
            answer=message,
            status="abstained",
            outcome="system_miss",
            category="other",
            confidence=0,
            citations=[],
            evidence_checked=[item.title for item in request.evidence],
            save_for_journalist=False,
        )


@app.post("/route", response_model=RouteResponse)
async def route_question(
    request: RouteRequest,
    _user: AuthenticatedUser = Depends(authorize_routing_request),
) -> RouteResponse:
    route = local_route(request)
    if should_use_gemini(route):
        return await GeminiService().route(request, route)
    return route
