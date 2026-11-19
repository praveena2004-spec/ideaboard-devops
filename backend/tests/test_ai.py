"""Tests for the rule-based path of the AI module (no API key in tests)."""
from pathlib import Path

from app import ai
from app.config import settings
from app.schemas import DeploymentSignals

SAMPLES = Path(__file__).resolve().parents[2] / "samples" / "logs"


def test_failed_logs_recommend_rollback(client):
    logs = (SAMPLES / "failed-deploy.log").read_text()
    r = client.post("/api/ai/analyze-logs", json={"logs": logs}).json()
    assert r["source"] == "rules"
    assert r["status"] == "failed"
    assert r["recommendation"] == "rollback"
    assert any("crash" in i.lower() for i in r["issues"])


def test_healthy_logs_proceed(client):
    logs = (SAMPLES / "healthy-deploy.log").read_text()
    r = client.post("/api/ai/analyze-logs", json={"logs": logs}).json()
    assert r["status"] == "healthy"
    assert r["recommendation"] == "proceed"


def test_startup_probe_noise_ignored_after_successful_rollout():
    logs = (
        "Warning Unhealthy Readiness probe failed: dial tcp 10.0.0.5:8000: connect: connection refused\n"
        "rollout result: success\n"
    )
    r = ai.analyze_logs(logs)
    assert r.status == "healthy"
    assert r.recommendation == "proceed"
    # Same events without a successful rollout are treated as a broken release.
    assert ai.analyze_logs(logs.replace("success", "failed")).recommendation == "rollback"


def test_oversized_logs_rejected(client, monkeypatch):
    monkeypatch.setattr(settings, "ai_max_log_chars", 10)
    r = client.post("/api/ai/analyze-logs", json={"logs": "x" * 11})
    assert r.status_code == 413


def test_recommendation_rules():
    assert ai.recommend_deployment(DeploymentSignals(environment="staging")).decision == "deploy"
    assert ai.recommend_deployment(DeploymentSignals(environment="production")).decision == "canary"
    assert ai.recommend_deployment(DeploymentSignals(tests_passed=False)).decision == "hold"
    assert ai.recommend_deployment(DeploymentSignals(pod_restarts=5)).decision == "rollback"


def test_recommendation_endpoint(client):
    r = client.post("/api/ai/deployment-recommendation",
                    json={"environment": "production", "error_rate_percent": 2.5}).json()
    assert r["decision"] == "hold"
    assert r["source"] == "rules"


def test_strict_schema_requires_all_fields():
    from app.schemas import LogAnalysis
    s = ai._strict_schema(LogAnalysis)
    assert s["additionalProperties"] is False
    assert set(s["required"]) == set(LogAnalysis.model_fields)


# ---------- LLM path with a mocked Anthropic client (no network, no key) ----------
import json  # noqa: E402
from types import SimpleNamespace  # noqa: E402

import anthropic  # noqa: E402


def _fake_client(stop_reason, payload, captured):
    def create(**kwargs):
        captured.update(kwargs)
        return SimpleNamespace(
            stop_reason=stop_reason,
            content=[SimpleNamespace(type="thinking", thinking=""),
                     SimpleNamespace(type="text", text=json.dumps(payload))],
        )
    return lambda **_: SimpleNamespace(beta=SimpleNamespace(messages=SimpleNamespace(create=create)))


LLM_ANSWER = {
    "status": "failed", "summary": "Backend cannot reach Postgres.",
    "root_cause": "POSTGRES_HOST points at postgres-wrong", "issues": ["crash loop"],
    "suggested_fixes": ["fix POSTGRES_HOST"], "recommendation": "rollback", "confidence": "high",
}


def test_llm_path_parses_structured_output(monkeypatch):
    captured = {}
    monkeypatch.setattr(settings, "anthropic_api_key", "test-key")
    monkeypatch.setattr(anthropic, "Anthropic", _fake_client("end_turn", LLM_ANSWER, captured))
    r = ai.analyze_logs("some logs", "staging")
    assert r.source == "llm"
    assert r.root_cause == LLM_ANSWER["root_cause"]
    assert captured["model"] == settings.ai_model
    assert captured["output_config"]["format"]["type"] == "json_schema"
    assert captured["fallbacks"] == "default"


def test_llm_refusal_falls_back_to_rules(monkeypatch):
    monkeypatch.setattr(settings, "anthropic_api_key", "test-key")
    monkeypatch.setattr(anthropic, "Anthropic", _fake_client("refusal", LLM_ANSWER, {}))
    r = ai.analyze_logs("Back-off restarting failed container")
    assert r.source == "rules"
    assert "LLM unavailable" in r.note
