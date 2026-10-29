"""Hand-labeled gold set for evaluating hyperlocal source routing.

Each case carries the expected *trusted sources* a correct router should select
for the question, plus the expected high-level behavior (answerable, out of
scope, small talk, or needs clarification). These labels are the ground truth
against which Precision@K / Recall@K and routing accuracy are computed.

Labels reflect the project's retrieval policy:
- Weather questions should retrieve only ``nws``.
- Transit *arrival* questions retrieve ``mbta_predictions``; *disruption*
  questions retrieve ``mbta_alerts``.
- Accountability / recurring-civic questions cross-check ``boston_311`` and
  ``local_news`` so a premise can be verified against more than one source.
- Out-of-scope, small-talk, and under-specified questions should retrieve no
  source (an answer there would be ungrounded or premature).

Keeping the labels in one place means the metrics measure the router, not a
second copy of the routing rules.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

Kind = Literal["answerable", "out_of_scope", "small_talk", "needs_clarification"]


@dataclass(frozen=True)
class GoldCase:
    question: str
    expected_sources: frozenset[str]
    expected_category: str
    kind: Kind = "answerable"
    location: str | None = None
    note: str = ""


def _case(
    question: str,
    sources: tuple[str, ...],
    category: str,
    *,
    kind: Kind = "answerable",
    location: str | None = None,
    note: str = "",
) -> GoldCase:
    return GoldCase(
        question=question,
        expected_sources=frozenset(sources),
        expected_category=category,
        kind=kind,
        location=location,
        note=note,
    )


# --- Weather ---------------------------------------------------------------
_WEATHER = [
    _case("Will it rain in Boston, MA tomorrow?", ("nws",), "weather"),
    _case("Should I carry an umbrella tomorrow?", ("nws",), "weather",
          location="Boston, MA", note="intent, no 'weather' keyword"),
    _case("How hot is it going to get in Cambridge, MA today?", ("nws",), "weather"),
    _case("Is it snowing right now in Somerville, MA?", ("nws",), "weather"),
    _case("What's the wind like near the harbor in Boston, MA?", ("nws",), "weather"),
    _case("Do I need a coat this evening in Brookline, MA?", ("nws",), "weather"),
]

# --- Transit: arrivals (predictions) --------------------------------------
_TRANSIT_ARRIVALS = [
    _case("When is the next Red Line train from Harvard?", ("mbta_predictions",), "transit"),
    _case("How long until the next bus on Huntington Ave?", ("mbta_predictions",), "transit"),
    _case("What time does the next Commuter Rail depart?", ("mbta_predictions",), "transit",
          location="Boston, MA"),
    _case("Next train arrival at Park Street?", ("mbta_predictions",), "transit"),
]

# --- Transit: disruptions (alerts) ----------------------------------------
_TRANSIT_ALERTS = [
    _case("Is the Green Line delayed right now?", ("mbta_alerts",), "transit"),
    _case("Are there any MBTA service alerts today?", ("mbta_alerts",), "transit"),
    _case("Is Orange Line service disrupted this morning?", ("mbta_alerts",), "transit"),
    _case("Is the Blue Line station closed?", ("mbta_alerts",), "transit"),
]

# --- Civic services / accountability --------------------------------------
_CIVIC = [
    _case("Why are flooding complaints increasing near Riverway in Boston, MA?",
          ("boston_311", "local_news"), "civic_services",
          note="recurring pattern -> cross-check 311 + local news"),
    _case("Has the pothole on Dorchester Ave been fixed?",
          ("boston_311", "local_news"), "civic_services", location="Boston, MA"),
    _case("Why hasn't the broken streetlight complaint been resolved?",
          ("boston_311", "local_news"), "civic_services", location="Boston, MA"),
    _case("Is illegal dumping being addressed in my neighborhood?",
          ("boston_311", "local_news"), "civic_services", location="Boston, MA"),
]

# --- Housing ---------------------------------------------------------------
_HOUSING = [
    _case("How do I report a landlord ignoring a housing code violation in Boston, MA?",
          ("boston_311", "local_news"), "housing"),
    _case("Where can I find affordable housing applications in Boston, MA?",
          ("boston_311", "local_news"), "housing"),
]

# --- Public safety ---------------------------------------------------------
_PUBLIC_SAFETY = [
    _case("Is there a power outage near Fenway in Boston, MA?",
          ("local_news", "boston_311"), "public_safety"),
    _case("Which roads are closed after the water main break in Boston, MA?",
          ("local_news", "boston_311"), "public_safety"),
]

# --- Events ----------------------------------------------------------------
_EVENTS = [
    _case("Is there a Northeastern campus event this weekend?",
          ("university_events", "local_news"), "events", location="Boston, MA"),
    _case("When is the next community meeting in Boston, MA?",
          ("university_events", "local_news"), "events"),
]

# --- Local news / accountability ------------------------------------------
_LOCAL_NEWS = [
    _case("Why is the city delaying the investigation into these repeated outages?",
          ("local_news",), "local_news", location="Boston, MA"),
]

# --- Cross-category collisions (generic transit words, non-transit intent) -
# These contain "next" / "when is" / "how long until" (strong transit-arrival
# phrases) but are not transit questions. They exercise the reranker's gate.
_COLLISIONS = [
    _case("When is the next town hall meeting in Boston, MA?",
          ("university_events", "local_news"), "events",
          note="'next'/'when is' collide with transit arrivals"),
    _case("How long until my pothole complaint is fixed in Boston, MA?",
          ("boston_311", "local_news"), "civic_services",
          note="'how long until' collides with transit arrivals"),
]

# --- Out of scope ----------------------------------------------------------
_OUT_OF_SCOPE = [
    _case("What is the best pizza in Boston?", (), "other", kind="out_of_scope"),
    _case("Tell me a joke.", (), "other", kind="out_of_scope"),
    _case("Write my essay about climate change.", (), "other", kind="out_of_scope"),
    _case("What's the best restaurant in Cambridge?", (), "other", kind="out_of_scope"),
    _case("Give me a shopping recommendation.", (), "other", kind="out_of_scope"),
]

# --- Small talk ------------------------------------------------------------
_SMALL_TALK = [
    _case("Hi", (), "other", kind="small_talk"),
    _case("Thank you!", (), "other", kind="small_talk"),
    _case("Good morning", (), "other", kind="small_talk"),
]

# --- Needs clarification ---------------------------------------------------
_CLARIFY = [
    _case("When do fall classes start in Boston?", ("university_events", "local_news"),
          "events", kind="needs_clarification", note="which school?"),
    _case("What's the weather?", ("nws",), "weather",
          kind="needs_clarification", note="no location"),
]


GOLD_CASES: tuple[GoldCase, ...] = tuple(
    _WEATHER
    + _TRANSIT_ARRIVALS
    + _TRANSIT_ALERTS
    + _CIVIC
    + _HOUSING
    + _PUBLIC_SAFETY
    + _EVENTS
    + _LOCAL_NEWS
    + _COLLISIONS
    + _OUT_OF_SCOPE
    + _SMALL_TALK
    + _CLARIFY
)


def answerable_cases() -> list[GoldCase]:
    """Cases where a specific set of trusted sources should be retrieved."""
    return [case for case in GOLD_CASES if case.kind == "answerable"]
