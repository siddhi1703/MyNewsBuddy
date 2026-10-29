import unittest

from app.router import local_route
from app.schemas import RouteRequest
from eval.metrics import Counts, aggregate, counts_for
from eval.run_eval import evaluate


class NormalizationBugTests(unittest.TestCase):
    def test_contraction_does_not_leak_into_transit(self) -> None:
        # "hasn't" previously tokenized to "hasn" + "t", and the "t" -> "mbta"
        # synonym mis-routed the question to transit. It must route to civic.
        route = local_route(
            RouteRequest(
                question="Why hasn't the broken streetlight complaint been resolved in Boston, MA?"
            )
        )
        self.assertEqual(route.category, "civic_services")
        self.assertEqual(route.sources, ["boston_311", "local_news"])


class WeatherVocabularyTests(unittest.TestCase):
    def test_coat_question_routes_to_weather(self) -> None:
        route = local_route(
            RouteRequest(question="Do I need a coat this evening in Brookline, MA?")
        )
        self.assertEqual(route.category, "weather")
        self.assertEqual(route.sources, ["nws"])

    def test_snowing_stem_routes_to_weather(self) -> None:
        route = local_route(
            RouteRequest(question="Is it snowing right now in Somerville, MA?")
        )
        self.assertEqual(route.category, "weather")
        self.assertEqual(route.sources, ["nws"])


class SubstringMatchTests(unittest.TestCase):
    def test_storm_drain_is_civic_not_weather(self) -> None:
        # "rain" must not match "d-rain"; "storm drain" is a civic question.
        route = local_route(
            RouteRequest(
                question="Why does the storm drain on my street keep backing up in Boston, MA?"
            )
        )
        self.assertEqual(route.category, "civic_services")
        self.assertEqual(set(route.sources), {"boston_311", "local_news"})

    def test_weather_stem_still_matches(self) -> None:
        # The word-boundary fix must still match stems like "snowing".
        route = local_route(RouteRequest(question="Is it snowing in Boston, MA?"))
        self.assertEqual(route.sources, ["nws"])


class OutOfScopeTests(unittest.TestCase):
    def test_movie_recommendation_is_out_of_scope(self) -> None:
        route = local_route(RouteRequest(question="What movie should I watch tonight?"))
        self.assertTrue(route.out_of_scope)
        self.assertEqual(route.sources, [])


class RerankGateTests(unittest.TestCase):
    def test_gate_fixes_transit_word_collision_for_events(self) -> None:
        question = "When is the next town hall meeting in Boston, MA?"
        baseline = local_route(RouteRequest(question=question), rerank=False)
        reranked = local_route(RouteRequest(question=question), rerank=True)

        # Generic "next"/"when is" make the baseline pick transit.
        self.assertIn("mbta_predictions", baseline.sources)
        # The entity gate demotes transit (no transit entity) so events wins.
        self.assertEqual(reranked.category, "events")
        self.assertEqual(set(reranked.sources), {"university_events", "local_news"})

    def test_gate_fixes_transit_word_collision_for_civic(self) -> None:
        question = "How long until my pothole complaint is fixed in Boston, MA?"
        reranked = local_route(RouteRequest(question=question), rerank=True)
        self.assertEqual(reranked.category, "civic_services")
        self.assertEqual(set(reranked.sources), {"boston_311", "local_news"})

    def test_gate_preserves_genuine_transit(self) -> None:
        route = local_route(
            RouteRequest(question="When is the next Red Line train from Harvard?")
        )
        self.assertEqual(route.category, "transit")
        self.assertEqual(route.sources, ["mbta_predictions"])

    def test_gate_never_splits_a_civic_source_pair(self) -> None:
        route = local_route(
            RouteRequest(
                question="Why are flooding complaints increasing near Riverway in Boston, MA?"
            )
        )
        self.assertEqual(route.sources, ["boston_311", "local_news"])


class MetricsTests(unittest.TestCase):
    def test_counts_for_scores_a_partial_match(self) -> None:
        counts = counts_for({"a", "b", "c"}, {"a", "b", "d"})
        self.assertEqual((counts.tp, counts.fp, counts.fn), (2, 1, 1))

    def test_empty_prediction_and_expected_is_perfect(self) -> None:
        counts = counts_for(set(), set())
        self.assertEqual(counts.precision, 1.0)
        self.assertEqual(counts.recall, 1.0)

    def test_aggregate_micro_and_macro(self) -> None:
        pairs = [({"a"}, {"a"}), ({"a", "x"}, {"a", "b"})]
        report = aggregate(pairs)
        self.assertEqual(report.n, 2)
        # micro pools tp=2, fp=1, fn=1 -> P=R=2/3
        self.assertAlmostEqual(report.micro_precision, 2 / 3)
        self.assertAlmostEqual(report.micro_recall, 2 / 3)
        self.assertAlmostEqual(report.exact_match, 0.5)

    def test_counts_add(self) -> None:
        total = Counts(1, 2, 3) + Counts(4, 5, 6)
        self.assertEqual((total.tp, total.fp, total.fn), (5, 7, 9))


class EvalHarnessTests(unittest.TestCase):
    def test_reranker_does_not_regress_baseline(self) -> None:
        baseline = evaluate(rerank=False)
        reranked = evaluate(rerank=True)
        self.assertGreaterEqual(
            reranked["retrieval"].micro_precision,
            baseline["retrieval"].micro_precision,
        )
        self.assertGreaterEqual(
            reranked["retrieval"].micro_recall,
            baseline["retrieval"].micro_recall,
        )

    def test_reranked_meets_quality_gate(self) -> None:
        reranked = evaluate(rerank=True)
        self.assertGreaterEqual(reranked["retrieval"].micro_precision, 0.90)
        self.assertGreaterEqual(reranked["retrieval"].micro_recall, 0.90)
        self.assertGreaterEqual(reranked["kind_accuracy"], 0.90)


if __name__ == "__main__":
    unittest.main()
