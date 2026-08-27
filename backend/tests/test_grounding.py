import os
import unittest
from unittest.mock import patch

import httpx
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app.auth import (
    AuthenticatedUser,
    PerUserRateLimiter,
    authorize_chat_request,
    verify_supabase_token,
)
from app.gemini import _grounded_response, _parse_model_answer
from app.main import app
from app.schemas import AskRequest, EvidenceItem, ModelAnswer


class GroundingTests(unittest.TestCase):
    def setUp(self) -> None:
        async def authenticated_user() -> AuthenticatedUser:
            return AuthenticatedUser(id="test-user", email="reader@example.com")

        app.dependency_overrides[authorize_chat_request] = authenticated_user
        self.evidence = EvidenceItem(
            source_id="nws-forecast",
            title="National Weather Service forecast for Boston, MA",
            url="https://www.weather.gov/",
            text="Tomorrow: rain chance 70%; high 68°F.",
            retrieved_at="2026-08-18T20:00:00Z",
        )

    def tearDown(self) -> None:
        app.dependency_overrides.clear()

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

    def test_ambiguous_school_question_requests_clarification_not_logging(self) -> None:
        request = AskRequest(question="When do fall classes start in Boston?")
        model_answer = ModelAnswer(
            answer="Which Boston school or university do you mean?",
            status="needs_clarification",
            category="events",
            confidence=0.99,
            citation_source_ids=[],
        )

        response = _grounded_response(model_answer, request)

        self.assertEqual(response.status, "needs_clarification")
        self.assertEqual(response.outcome, "out_of_scope")
        self.assertFalse(response.save_for_journalist)

    def test_unconnected_official_source_is_a_system_miss_not_a_gap(self) -> None:
        request = AskRequest(
            question="What is Northeastern University tuition for a master's degree?"
        )
        model_answer = ModelAnswer(
            answer=(
                "I do not have Northeastern University's official tuition source "
                "connected yet, so I cannot verify the current amount."
            ),
            status="source_unavailable",
            category="other",
            confidence=0.98,
            citation_source_ids=[],
        )

        response = _grounded_response(model_answer, request)

        self.assertEqual(response.status, "source_unavailable")
        self.assertEqual(response.outcome, "system_miss")
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
        self.assertIn("authentication_configured", response.json())
        self.assertNotIn("api_key", response.json())

    def test_ask_requires_a_signed_in_user(self) -> None:
        app.dependency_overrides.pop(authorize_chat_request, None)
        response = TestClient(app).post(
            "/ask",
            json={"question": "Will it rain in Boston?", "evidence": []},
        )

        self.assertEqual(response.status_code, 401)
        self.assertIn("Sign in", response.json()["detail"])

    def test_missing_model_key_is_a_system_miss_not_a_gap(self) -> None:
        response = TestClient(app).post(
            "/ask",
            json={"question": "Will it rain in Boston?", "evidence": []},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["outcome"], "system_miss")
        self.assertFalse(response.json()["save_for_journalist"])
        self.assertIn("system problem", response.json()["answer"])

    def test_long_range_weather_limit_is_not_logged_as_a_gap(self) -> None:
        response = TestClient(app).post(
            "/ask",
            json={"question": "What will Boston weather be after 15 days?"},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "source_unavailable")
        self.assertEqual(response.json()["outcome"], "system_miss")
        self.assertFalse(response.json()["save_for_journalist"])
        self.assertIn("forecast limit", response.json()["answer"])

    def test_routine_academic_calendar_question_is_not_a_gap(self) -> None:
        response = TestClient(app).post(
            "/ask",
            json={"question": "When will college classes start for fall 2026?"},
        )

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "source_unavailable")
        self.assertEqual(response.json()["outcome"], "system_miss")
        self.assertFalse(response.json()["save_for_journalist"])

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


class AuthenticationTests(unittest.IsolatedAsyncioTestCase):
    async def test_valid_supabase_session_returns_user(self) -> None:
        def handler(request: httpx.Request) -> httpx.Response:
            self.assertEqual(request.headers["authorization"], "Bearer valid-token")
            self.assertEqual(request.headers["apikey"], "public-key")
            return httpx.Response(
                200,
                json={"id": "user-123", "email": "reader@example.com"},
            )

        environment = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_PUBLISHABLE_KEY": "public-key",
        }
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            with patch.dict(os.environ, environment):
                user = await verify_supabase_token("valid-token", client=client)

        self.assertEqual(user.id, "user-123")
        self.assertEqual(user.email, "reader@example.com")

    async def test_invalid_supabase_session_is_rejected(self) -> None:
        def handler(_request: httpx.Request) -> httpx.Response:
            return httpx.Response(401, json={"message": "invalid token"})

        environment = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_PUBLISHABLE_KEY": "public-key",
        }
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            with patch.dict(os.environ, environment):
                with self.assertRaises(HTTPException) as context:
                    await verify_supabase_token("invalid-token", client=client)

        self.assertEqual(context.exception.status_code, 401)

    async def test_per_user_rate_limit_rejects_burst(self) -> None:
        limiter = PerUserRateLimiter()
        with patch.dict(os.environ, {"CHAT_REQUESTS_PER_MINUTE": "2"}):
            await limiter.check("user-123")
            await limiter.check("user-123")
            with self.assertRaises(HTTPException) as context:
                await limiter.check("user-123")

        self.assertEqual(context.exception.status_code, 429)


class ModelParsingTests(unittest.TestCase):
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
