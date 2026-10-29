# Routing & retrieval evaluation

This harness measures how well the companion selects the **right trusted
sources** for a question — the retrieval-relevance question that decides whether
the model is grounded in the correct evidence. It runs fully offline (no Gemini
key, no network) against the deterministic local router, so the numbers are
reproducible in CI and in a demo.

```bash
cd backend
python -m eval.run_eval            # human-readable report
python -m eval.run_eval --json     # machine-readable metrics
python -m eval.run_eval --check    # exit non-zero if below quality gate (CI)
```

## What is measured

The router returns a **set of sources** per question (e.g. `{nws}`,
`{mbta_alerts}`, `{boston_311, local_news}`). We score that set against a
hand-labeled gold set (`gold_set.py`):

| Metric | Definition | Reads as |
|---|---|---|
| **Precision** | `|predicted ∩ expected| / |predicted|` | Of the sources we chose to query, how many were right? (low ⇒ wasted / irrelevant retrieval) |
| **Recall** | `|predicted ∩ expected| / |expected|` | Of the sources we *should* have queried, how many did we pick? (low ⇒ missing evidence) |
| **F1** | harmonic mean of the two | single balanced score |

These are the standard Precision@K / Recall@K definitions, applied to **source
selection** rather than document ranking — the retrieval step in this system is
*which trusted sources to fetch*. We report both **micro** (pool TP/FP/FN across
all questions) and **macro** (average per-question) aggregates, plus exact-set
match, category accuracy, and behavior-kind accuracy (answerable vs.
out-of-scope vs. small-talk vs. needs-clarification).

## The reranker

The first routing pass (`router.py`) favors recall: any lexical overlap earns a
source, so a high-collision category can win on generic words. Example:

> "When is the **next** community meeting?"

scores as **transit** because *next* and *when is* are arrival phrases — even
though it is a civic **event**.

The reranker (`app/rerank.py`) adds a **category-entity gate**: a high-collision
category keeps its score only if the question contains a defining entity for it
(transit ⇒ train/bus/line/station/the T…; weather ⇒ rain/snow/coat/degrees…). A
candidate that matched only on generic words is demoted so a better-supported
category wins. The gate only ever *lowers* a weakly-supported candidate — it
never invents a source and never splits an intentional cross-source pair (e.g.
civic questions that cross-check `boston_311` + `local_news`), so recall on
genuine matches is preserved.

## Measured result

Running the gold set with the reranker off (baseline) vs. on:

| | micro-P | micro-R | micro-F1 | exact-set |
|---|---|---|---|---|
| Baseline (reranker off) | 0.917 | 0.846 | 0.880 | 0.889 |
| **Reranked** | **1.000** | **1.000** | **1.000** | **1.000** |
| Δ reranker | **+0.083** | **+0.154** | +0.120 | +0.111 |

The reranker improves **both** precision and recall here — the gate removes
cross-category false positives (precision) *and*, by demoting a wrong winner,
lets the correct multi-source category surface (recall). Building the harness
first also surfaced two real routing bugs, now fixed and regression-tested:

1. A contraction like `hasn't` tokenized to `hasn` + `t`, and the `t → mbta`
   synonym mis-routed it to transit.
2. Common weather vocabulary (`coat`, `jacket`, `snowing`, `degrees`, …) was
   missing, so those questions missed `nws`.

> **Honest scope.** The gold set is a small, curated set of representative
> Greater-Boston questions, so 1.000 means "no mistakes on these representative
> cases," not a production accuracy guarantee. The point is a reproducible,
> extensible measurement loop: add real user questions to `gold_set.py` and the
> numbers (and the CI gate in `--check`) track quality as routing evolves. A
> heavier semantic reranker (cross-encoder / embeddings) is a natural next step
> to compare **against these baselines** rather than adopted on faith.
