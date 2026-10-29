"""Retrieval-relevance metrics for source routing.

The router returns a *set* of trusted sources per question, so precision and
recall are computed over sets:

    precision = |predicted ∩ expected| / |predicted|
    recall    = |predicted ∩ expected| / |expected|
    f1        = harmonic mean of precision and recall

Precision answers "of the sources we chose to query, how many were right?"
(low precision => wasted/irrelevant retrieval). Recall answers "of the sources
that should have been queried, how many did we pick?" (low recall => missing
evidence). These are the same definitions used in the interview discussion,
applied to source selection rather than document ranking.

We report two aggregates:
- macro: average of per-question scores (every question counts equally)
- micro: pooled TP/FP/FN across all questions (every source decision counts
  equally; dominated by questions with more expected sources)
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Counts:
    tp: int = 0
    fp: int = 0
    fn: int = 0

    def __add__(self, other: "Counts") -> "Counts":
        return Counts(self.tp + other.tp, self.fp + other.fp, self.fn + other.fn)

    @property
    def precision(self) -> float:
        denom = self.tp + self.fp
        return self.tp / denom if denom else 1.0

    @property
    def recall(self) -> float:
        denom = self.tp + self.fn
        return self.tp / denom if denom else 1.0

    @property
    def f1(self) -> float:
        p, r = self.precision, self.recall
        return 2 * p * r / (p + r) if (p + r) else 0.0


def counts_for(predicted: set[str], expected: set[str]) -> Counts:
    """True/false positives and false negatives for one question's sources."""
    tp = len(predicted & expected)
    return Counts(tp=tp, fp=len(predicted - expected), fn=len(expected - predicted))


@dataclass(frozen=True)
class RetrievalReport:
    n: int
    macro_precision: float
    macro_recall: float
    macro_f1: float
    micro: Counts
    exact_match: float  # fraction of questions where predicted == expected

    @property
    def micro_precision(self) -> float:
        return self.micro.precision

    @property
    def micro_recall(self) -> float:
        return self.micro.recall

    @property
    def micro_f1(self) -> float:
        return self.micro.f1


def aggregate(pairs: list[tuple[set[str], set[str]]]) -> RetrievalReport:
    """Aggregate (predicted, expected) source sets into a retrieval report."""
    if not pairs:
        return RetrievalReport(0, 1.0, 1.0, 1.0, Counts(), 1.0)

    per_counts = [counts_for(pred, exp) for pred, exp in pairs]
    macro_p = sum(c.precision for c in per_counts) / len(per_counts)
    macro_r = sum(c.recall for c in per_counts) / len(per_counts)
    macro_f1 = sum(c.f1 for c in per_counts) / len(per_counts)
    micro = sum(per_counts, Counts())
    exact = sum(1 for pred, exp in pairs if pred == exp) / len(pairs)
    return RetrievalReport(
        n=len(pairs),
        macro_precision=macro_p,
        macro_recall=macro_r,
        macro_f1=macro_f1,
        micro=micro,
        exact_match=exact,
    )


def accuracy(correct: int, total: int) -> float:
    return correct / total if total else 1.0
