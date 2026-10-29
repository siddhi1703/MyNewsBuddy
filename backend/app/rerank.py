"""Second-pass reranker for routing candidates.

The first routing pass (phrase/keyword scoring in ``router.py``) favors recall:
it rewards any lexical overlap, so generic words can make a high-collision
category win. For example "when is the **next** community meeting?" scores as
transit because "next" and "when is" are arrival phrases, even though the
question is about a civic event. Over-selecting a source wastes a retrieval call
and sends irrelevant evidence to the model, which lowers precision.

This reranker re-scores the candidate *profiles* before selection using a
category-entity gate: a high-collision category may only keep its score if the
question actually contains a defining entity for that category. Transit must
mention a transit entity (train, bus, line, station, the T, …); weather must
mention a weather term. A candidate that matched only on generic words is
demoted so a better-supported category can win.

The gate only ever *lowers* a weakly-supported candidate's score — it never
invents a new candidate and never touches intentional multi-source profiles
(e.g. civic questions that cross-check ``boston_311`` + ``local_news`` travel as
one profile and are unaffected). So recall on genuine matches is preserved while
cross-category precision improves.
"""

from __future__ import annotations

import re

# Category -> regex of defining entities. A profile in one of these categories
# keeps its full score only if the normalized question matches the entity.
# (Patterns run against the router's normalized text, where synonyms have
# already mapped e.g. "subway"/"tram"->"mbta", "trains"->"train".)
ENTITY_GATES: dict[str, re.Pattern[str]] = {
    "transit": re.compile(
        r"\b(train|bus|line|station|stop|mbta|commuter rail|platform|ferry|"
        r"red|orange|blue|green|silver|the t)\b"
    ),
    "weather": re.compile(
        r"\b(weather|forecast|rain\w*|snow\w*|temperature|wind\w*|umbrella|"
        r"storm\w*|hot|cold|cloud\w*|sunny|coat|jacket|boots|gloves|sunglasses|"
        r"freez\w*|chill\w*|warm|degree\w*|humid\w*|sleet|hail|frost|"
        r"precipitation)\b"
    ),
}

# How hard to demote a gated candidate that lacks its defining entity. Small
# enough that a real, well-supported alternative category overtakes it, but not
# zero, so a question with no other signal at all still routes somewhere.
GATE_PENALTY = 0.15


def rerank_profile_scores(
    normalized_question: str,
    scored: list[tuple[float, object]],
) -> list[tuple[float, object]]:
    """Re-score ranked (score, profile) pairs with the category-entity gate.

    ``profile`` only needs a ``.category`` attribute. The returned list is
    re-sorted by the adjusted score, highest first.
    """
    adjusted: list[tuple[float, object]] = []
    for score, profile in scored:
        gate = ENTITY_GATES.get(getattr(profile, "category", ""))
        if gate is not None and score > 0 and not gate.search(normalized_question):
            score = score * GATE_PENALTY
        adjusted.append((score, profile))
    adjusted.sort(key=lambda item: item[0], reverse=True)
    return adjusted
