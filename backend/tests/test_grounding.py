import unittest

from fastapi.testclient import TestClient

from app.gemini import _grounded_response, _parse_model_answer
from app.main import app
from app.schemas import AskRequest, EvidenceItem, ModelAnswer


class GroundingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.evidence = EvidenceItem(
            source_id="nws-forecast",
            title="National Weather Service forecast for Boston, MA",
            url="https://www.weather.gov/",
            text="Tomorrow: rain chance 70%; high 68°F.",
            retrieved_at="2026-08-18T20:00:00Z",
        )

    def test_answer_keeps_only_a_known_citation(self) -> None:
        request = AskRequest(
            question="Will it rain tomorrow in Boston?",
            location="Boston, MA",
            evidence=[self.evidence],
        )
        model_answer = ModelAnswer(
            answer="Yes—rain is likely tomorrow, so bring an umbrella.",
            status="answered",
            category="weather",
            confidence=0.9,
            citation_source_ids=["made-up-source", "nws-forecast"],
        )

        response = _grounded_response(model_answer, request)

        self.assertEqual(response.status, "answered")
        self.assertEqual(response.outcome, "answered")
        self.assertFalse(response.save_for_journalist)
        self.assertEqual(len(response.citations), 1)
        self.assertIn("National Weather Service", response.citations[0].title)

    def test_unsupported_answer_is_forced_to_abstain(self) -> None:
        request = AskRequest(question="Why is the Green Line delayed?")
        model_answer = ModelAnswer(
            answer="A signal problem caused the delay.",
            status="answered",
            category="transit",
            confidence=0.8,
            citation_source_ids=[],
        )

        response = _grounded_response(model_answer, request)

        self.assertEqual(response.status, "abstained")
        self.assertEqual(response.outcome, "true_gap")
        self.assertTrue(response.save_for_journalist)
        self.assertEqual(response.confidence, 0)
        self.assertEqual(response.citations, [])
        self.assertIn("don’t want to guess", response.answer)

    def test_non_civic_question_is_out_of_scope_not_a_gap(self) -> None:
        request = AskRequest(question="What is the best pizza topping?")
        model_answer = ModelAnswer(
            answer=(
                "I focus on local civic and community information, so that "
                "question is outside this companion’s scope."
            ),
            status="out_of_scope",
            category="other",
            confidence=0.98,
            citation_source_ids=[],
        )

        response = _grounded_response(model_answer, request)

        self.assertEqual(response.status, "out_of_scope")
        self.assertEqual(response.outcome, "out_of_scope")
        self.assertFalse(response.save_for_journalist)

    def test_greeting_is_conversational_not_a_gap(self) -> None:
        request = AskRequest(question="Good night")
        model_answer = ModelAnswer(
            answer="Good night! I’ll be here when you need a local update.",
            status="conversational",
            category="other",
            confidence=1,
            citation_source_ids=[],
        )

        response = _grounded_response(model_answer, request)

        self.assertEqual(response.status, "conversational")
        self.assertEqual(response.outcome, "out_of_scope")
        self.assertFalse(response.save_for_journalist)
        self.assertEqual(response.citations, [])

    def test_health_reports_missing_key_without_exposing_secrets(self) -> None:
        response = TestClient(app).get("/health")

        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["model_configured"])
        self.assertNotIn("api_key", response.json())

    def test_missing_model_key_is_a_system_miss_not_a_gap(self) -> None:
        response = TestClient(app).post(
            "/ask",
            json={"question": "Will it rain in Boston?", "evidence": []},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["outcome"], "system_miss")
        self.assertFalse(response.json()["save_for_journalist"])
        self.assertIn("system problem", response.json()["answer"])

    def test_request_accepts_bounded_conversation_context(self) -> None:
        request = AskRequest(
            question="What about tomorrow?",
            history=[
                {"role": "user", "content": "What is Boston weather today?"},
                {"role": "assistant", "content": "It is sunny in Boston."},
            ],
            evidence=[self.evidence],
        )

        self.assertEqual(len(request.history), 2)
        self.assertEqual(request.history[0].role, "user")

    def test_transit_answer_keeps_official_mbta_citation(self) -> None:
        transit_evidence = EvidenceItem(
            source_id="mbta-alerts",
            title="MBTA live service alerts for the Green Line",
            url="https://www.mbta.com/alerts",
            text="Green Line: a delay alert is active due to a disabled train.",
            retrieved_at="2026-08-19T20:00:00Z",
        )
        request = AskRequest(
            question="Why is the Green Line delayed?",
            location="the Green Line",
            evidence=[transit_evidence],
        )
        model_answer = ModelAnswer(
            answer="The MBTA reports a disabled train is causing a Green Line delay.",
            status="answered",
            category="transit",
            confidence=0.95,
            citation_source_ids=["mbta-alerts"],
        )

        response = _grounded_response(model_answer, request)

        self.assertEqual(response.status, "answered")
        self.assertEqual(response.outcome, "answered")
        self.assertEqual(len(response.citations), 1)
        self.assertIn("MBTA", response.citations[0].title)

    def test_parser_accepts_json_split_across_text_parts(self) -> None:
        response = {
            "candidates": [
                {
                    "content": {
                        "parts": [
                            {"text": '{"answer":"Next train in 5 minutes",'},
                            {
                                "text": (
                                    '"status":"answered","category":"transit",'
                                    '"confidence":0.9,'
                                    '"citation_source_ids":["mbta-predictions"]}'
                                )
                            },
                        ]
                    }
                }
            ]
        }

        answer = _parse_model_answer(response)

        self.assertEqual(answer.status, "answered")
        self.assertEqual(answer.citation_source_ids, ["mbta-predictions"])

    def test_parser_accepts_fenced_json(self) -> None:
        response = {
            "candidates": [
                {
                    "content": {
                        "parts": [
                            {
                                "text": (
                                    '```json\n{"answer":"No trusted answer yet",'
                                    '"status":"abstained","category":"other",'
                                    '"confidence":0,"citation_source_ids":[]}\n```'
                                )
                            }
                        ]
                    }
                }
            ]
        }

        answer = _parse_model_answer(response)

        self.assertEqual(answer.status, "abstained")


if __name__ == "__main__":
    unittest.main()
