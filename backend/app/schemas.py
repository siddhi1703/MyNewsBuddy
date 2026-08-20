from typing import Literal

from pydantic import BaseModel, Field, HttpUrl


AnswerStatus = Literal["answered", "abstained", "out_of_scope"]
AnswerOutcome = Literal["answered", "true_gap", "out_of_scope", "system_miss"]
QuestionCategory = Literal[
    "weather",
    "transit",
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


class AskRequest(BaseModel):
    question: str = Field(min_length=1, max_length=2_000)
    location: str | None = Field(default=None, max_length=200)
    evidence: list[EvidenceItem] = Field(default_factory=list, max_length=20)
    history: list[ChatHistoryItem] = Field(default_factory=list, max_length=20)


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
