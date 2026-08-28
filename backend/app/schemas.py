from typing import Literal

from pydantic import BaseModel, Field, HttpUrl


AnswerStatus = Literal[
    "answered",
    "abstained",
    "out_of_scope",
    "conversational",
    "needs_clarification",
    "source_unavailable",
]
AnswerOutcome = Literal["answered", "true_gap", "out_of_scope", "system_miss"]
RetrievalStatus = Literal["succeeded", "failed", "not_connected"]
RoutingMethod = Literal["rules", "local_nlp", "gemini"]
QuestionCategory = Literal[
    "weather",
    "transit",
    "civic_services",
    "housing",
    "public_safety",
    "local_news",
    "events",
    "other",
]


class ChatHistoryItem(BaseModel):
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=8_000)


class EvidenceItem(BaseModel):
    source_id: str = Field(min_length=1, max_length=80)
    title: str = Field(min_length=1, max_length=200)
    url: HttpUrl
    text: str = Field(min_length=1, max_length=20_000)
    retrieved_at: str | None = Field(default=None, max_length=100)


class RetrievalAttempt(BaseModel):
    source_id: str = Field(min_length=1, max_length=80)
    status: RetrievalStatus
    evidence_count: int = Field(default=0, ge=0, le=1_000)
    detail: str | None = Field(default=None, max_length=500)


class AskRequest(BaseModel):
    question: str = Field(min_length=1, max_length=2_000)
    location: str | None = Field(default=None, max_length=200)
    evidence: list[EvidenceItem] = Field(default_factory=list, max_length=20)
    history: list[ChatHistoryItem] = Field(default_factory=list, max_length=20)
    required_sources: list[str] = Field(default_factory=list, max_length=10)
    retrieval_attempts: list[RetrievalAttempt] = Field(default_factory=list, max_length=20)
    routing_method: RoutingMethod | None = None


class RouteRequest(BaseModel):
    question: str = Field(min_length=1, max_length=2_000)
    location: str | None = Field(default=None, max_length=200)
    history: list[ChatHistoryItem] = Field(default_factory=list, max_length=20)


class RouteResponse(BaseModel):
    category: QuestionCategory
    sources: list[str] = Field(default_factory=list, max_length=10)
    location: str | None = Field(default=None, max_length=200)
    needs_clarification: bool = False
    clarification_question: str | None = Field(default=None, max_length=500)
    out_of_scope: bool = False
    confidence: float = Field(ge=0, le=1)
    method: RoutingMethod


class Citation(BaseModel):
    title: str
    url: HttpUrl


class AskResponse(BaseModel):
    answer: str
    status: AnswerStatus
    outcome: AnswerOutcome
    category: QuestionCategory
    confidence: float = Field(ge=0, le=1)
    citations: list[Citation] = Field(default_factory=list)
    evidence_checked: list[str] = Field(default_factory=list)
    save_for_journalist: bool = False


class ModelAnswer(BaseModel):
    answer: str = Field(min_length=1, max_length=4_000)
    status: AnswerStatus
    category: QuestionCategory
    confidence: float = Field(ge=0, le=1)
    citation_source_ids: list[str] = Field(default_factory=list, max_length=10)


class ModelRoute(BaseModel):
    category: QuestionCategory
    sources: list[str] = Field(default_factory=list, max_length=10)
    location: str | None = Field(default=None, max_length=200)
    needs_clarification: bool = False
    clarification_question: str | None = Field(default=None, max_length=500)
    out_of_scope: bool = False
    confidence: float = Field(ge=0, le=1)
