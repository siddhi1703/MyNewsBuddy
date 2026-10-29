"""Run the offline routing/retrieval evaluation and print a report.

Usage (from the ``backend`` directory):

    python -m eval.run_eval              # human-readable report
    python -m eval.run_eval --json       # machine-readable metrics
    python -m eval.run_eval --check      # exit non-zero if below thresholds (CI)

No Gemini API key or network access is required: this evaluates the
deterministic local router (``app.router.local_route``) against the gold set,
with the reranker turned off (baseline) and on, so the precision gain is
measured rather than assumed.
"""

from __future__ import annotations

import argparse
import json
import sys

from app.router import local_route
from app.schemas import RouteRequest

from .gold_set import GOLD_CASES, GoldCase
from .metrics import RetrievalReport, accuracy, aggregate

# CI gate: the reranked pipeline must not regress below these.
MIN_MICRO_PRECISION = 0.90
MIN_MICRO_RECALL = 0.90
MIN_KIND_ACCURACY = 0.90


def predicted_kind(route) -> str:
    if route.out_of_scope:
        return "out_of_scope"
    if route.needs_clarification:
        return "needs_clarification"
    if route.category == "other" and not route.sources:
        return "small_talk"
    return "answerable"


def evaluate(*, rerank: bool) -> dict:
    retrieval_pairs: list[tuple[set[str], set[str]]] = []
    category_correct = 0
    category_total = 0
    kind_correct = 0
    misroutes: list[dict] = []

    for case in GOLD_CASES:
        route = local_route(
            RouteRequest(question=case.question, location=case.location),
            rerank=rerank,
        )
        predicted = set(route.sources)

        if predicted_kind(route) == case.kind:
            kind_correct += 1

        if case.kind == "answerable":
            expected = set(case.expected_sources)
            retrieval_pairs.append((predicted, expected))
            category_total += 1
            if route.category == case.expected_category:
                category_correct += 1
            if predicted != expected:
                misroutes.append(
                    {
                        "question": case.question,
                        "expected": sorted(expected),
                        "predicted": sorted(predicted),
                    }
                )

    report = aggregate(retrieval_pairs)
    return {
        "retrieval": report,
        "category_accuracy": accuracy(category_correct, category_total),
        "kind_accuracy": accuracy(kind_correct, len(GOLD_CASES)),
        "misroutes": misroutes,
    }


def _fmt(report: RetrievalReport) -> str:
    return (
        f"  micro  P={report.micro_precision:.3f}  R={report.micro_recall:.3f}  "
        f"F1={report.micro_f1:.3f}\n"
        f"  macro  P={report.macro_precision:.3f}  R={report.macro_recall:.3f}  "
        f"F1={report.macro_f1:.3f}\n"
        f"  exact-match set = {report.exact_match:.3f}  (n={report.n} answerable)"
    )


def print_report(baseline: dict, reranked: dict) -> None:
    print("=" * 66)
    print("Hyperlocal source-routing evaluation")
    print(f"Gold cases: {len(GOLD_CASES)}  "
          f"(answerable={baseline['retrieval'].n}, "
          f"other={len(GOLD_CASES) - baseline['retrieval'].n})")
    print("=" * 66)

    print("\nRetrieval relevance — BASELINE (reranker off)")
    print(_fmt(baseline["retrieval"]))
    print("\nRetrieval relevance — RERANKED (reranker on)")
    print(_fmt(reranked["retrieval"]))

    dp = reranked["retrieval"].micro_precision - baseline["retrieval"].micro_precision
    dr = reranked["retrieval"].micro_recall - baseline["retrieval"].micro_recall
    print(f"\nReranker delta: micro-precision {dp:+.3f}, micro-recall {dr:+.3f}")

    print(f"\nCategory accuracy (reranked):      {reranked['category_accuracy']:.3f}")
    print(f"Behavior-kind accuracy (reranked): {reranked['kind_accuracy']:.3f}")
    print("  (answerable vs out_of_scope vs small_talk vs needs_clarification)")

    if reranked["misroutes"]:
        print("\nRemaining source mismatches (reranked):")
        for item in reranked["misroutes"]:
            print(f"  - {item['question']}")
            print(f"      expected={item['expected']}  predicted={item['predicted']}")
    else:
        print("\nNo source mismatches on answerable cases (reranked).")
    print()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit metrics as JSON")
    parser.add_argument("--check", action="store_true",
                        help="exit non-zero if reranked metrics fall below thresholds")
    args = parser.parse_args()

    baseline = evaluate(rerank=False)
    reranked = evaluate(rerank=True)

    if args.json:
        r = reranked["retrieval"]
        print(json.dumps({
            "baseline": {
                "micro_precision": baseline["retrieval"].micro_precision,
                "micro_recall": baseline["retrieval"].micro_recall,
                "micro_f1": baseline["retrieval"].micro_f1,
            },
            "reranked": {
                "micro_precision": r.micro_precision,
                "micro_recall": r.micro_recall,
                "micro_f1": r.micro_f1,
                "macro_precision": r.macro_precision,
                "macro_recall": r.macro_recall,
                "exact_match": r.exact_match,
            },
            "category_accuracy": reranked["category_accuracy"],
            "kind_accuracy": reranked["kind_accuracy"],
        }, indent=2))
    else:
        print_report(baseline, reranked)

    if args.check:
        r = reranked["retrieval"]
        failures = []
        if r.micro_precision < MIN_MICRO_PRECISION:
            failures.append(f"micro-precision {r.micro_precision:.3f} < {MIN_MICRO_PRECISION}")
        if r.micro_recall < MIN_MICRO_RECALL:
            failures.append(f"micro-recall {r.micro_recall:.3f} < {MIN_MICRO_RECALL}")
        if reranked["kind_accuracy"] < MIN_KIND_ACCURACY:
            failures.append(f"kind-accuracy {reranked['kind_accuracy']:.3f} < {MIN_KIND_ACCURACY}")
        if failures:
            print("CHECK FAILED: " + "; ".join(failures), file=sys.stderr)
            return 1
        print("CHECK PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
