"""AI-powered deployment log analysis and deployment recommendations.

Two entry points, both returning validated Pydantic objects:

* analyze_logs(logs, context)     -> LogAnalysisOut
* recommend_deployment(signals)   -> DeploymentRecommendationOut

If ANTHROPIC_API_KEY is set, Claude is asked for a structured JSON answer
(constrained by a JSON schema). If no key is configured, or the API call fails,
a transparent rule-based fallback is used instead, and the response says so via
`source="rules"`. This keeps the demo, the tests and the CI pipeline working
without any credentials.

The same functions are used by the FastAPI endpoints and by the CI script
(`python -m app.analyze_cli`), so the pipeline and the UI give identical answers.
"""
from __future__ import annotations

import json
import logging
import re
from typing import TypeVar

from pydantic import BaseModel

from .config import settings
from .schemas import (
    DeploymentRecommendation,
    DeploymentRecommendationOut,
    DeploymentSignals,
    EnvironmentPlan,
    EnvironmentPlanOut,
    LogAnalysis,
    LogAnalysisOut,
)

log = logging.getLogger("ideaboard.ai")

T = TypeVar("T", bound=BaseModel)

LOG_SYSTEM_PROMPT = """You are a senior SRE reviewing logs from a deployment of a \
containerised web application (React frontend, FastAPI backend, PostgreSQL) running \
on Kubernetes or Docker Compose.

Classify the deployment as healthy, degraded or failed, identify the most likely \
root cause, list concrete issues you can see in the logs, and suggest specific fixes. \
Recommend "rollback" only when the new release itself is clearly broken (crash loops, \
failing readiness checks, schema or config errors introduced by the release). \
Recommend "investigate" when the evidence is ambiguous or the problem looks \
environmental. Recommend "proceed" when the logs show a normal rollout. \
Base every claim on lines you can actually see; if the logs are inconclusive, say so \
and use low confidence."""

RECOMMEND_SYSTEM_PROMPT = """You are a release manager deciding whether a release of \
a web application should be deployed. You receive the target environment, a change \
summary and health signals from the pipeline.

Choose one decision:
- deploy: low risk, roll out normally (rolling update).
- canary: moderate risk, roll out to a small share of traffic first.
- hold: do not deploy yet; something must be checked or fixed first.
- rollback: the currently rolling-out release is unhealthy and should be reverted.

Be conservative for production. Failing tests always mean hold. Give short, concrete \
reasons tied to the signals you were given, and list checks to run before deploying."""

PLAN_SYSTEM_PROMPT = """You are a platform engineer sizing a Kubernetes environment for \
a small web app (stateless React/nginx frontend, stateless FastAPI backend, managed \
PostgreSQL). Turn the developer's high-level goal into concrete settings.

Guidance:
- cluster_flavor "k3s" = one small VM running lightweight Kubernetes (cheapest, fits cloud \
free tiers, no redundancy); "managed" = EKS/GKE with a node group (costs more, survives \
node failure).
- node_size small/medium/large maps to roughly 1/2/4 vCPU-class burstable instances.
- Cost-sensitive or free-tier goals: k3s, 1 node, 1 replica each, micro database, no DB HA.
- High-availability goals: managed, >= 3 nodes, >= 3 backend replicas, >= 2 frontend \
replicas, DB HA on.
- The backend uses ~80 MiB at idle; keep its memory limit between 128 and 2048 MiB.
Explain each choice briefly in rationale, mentioning the cost/availability trade-off."""

# Hard limits applied to every plan, whoever produced it. The LLM proposes,
# these guardrails decide what is actually allowed.
_PLAN_LIMITS = {
    "node_count": (1, 10),
    "backend_replicas": (1, 10),
    "frontend_replicas": (1, 10),
    "backend_cpu_request_millicores": (50, 2000),
    "backend_memory_limit_mib": (128, 2048),
}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
def analyze_logs(logs: str, context: str = "") -> LogAnalysisOut:
    _check_size(logs)
    if settings.anthropic_api_key:
        prompt = f"Deployment context: {context or 'not provided'}\n\n<logs>\n{logs}\n</logs>"
        try:
            result = _ask_claude(LOG_SYSTEM_PROMPT, prompt, LogAnalysis)
            return LogAnalysisOut(**result.model_dump(), source="llm")
        except Exception as exc:  # noqa: BLE001 - any failure falls back to rules
            log.warning("LLM log analysis failed, using rules: %s", exc)
            return _rule_based_log_analysis(logs, note=f"LLM unavailable ({type(exc).__name__}); used rule-based analysis.")
    return _rule_based_log_analysis(logs, note="ANTHROPIC_API_KEY not set; used rule-based analysis.")


def recommend_deployment(signals: DeploymentSignals) -> DeploymentRecommendationOut:
    _check_size(signals.recent_logs)
    if settings.anthropic_api_key:
        prompt = "Deployment signals (JSON):\n" + signals.model_dump_json(indent=2)
        try:
            result = _ask_claude(RECOMMEND_SYSTEM_PROMPT, prompt, DeploymentRecommendation)
            return DeploymentRecommendationOut(**result.model_dump(), source="llm")
        except Exception as exc:  # noqa: BLE001
            log.warning("LLM recommendation failed, using rules: %s", exc)
            return _rule_based_recommendation(signals, note=f"LLM unavailable ({type(exc).__name__}); used rule-based recommendation.")
    return _rule_based_recommendation(signals, note="ANTHROPIC_API_KEY not set; used rule-based recommendation.")


def plan_environment(goal: str) -> EnvironmentPlanOut:
    """High-level goal ("cost-sensitive staging") -> validated environment sizing."""
    if settings.anthropic_api_key:
        try:
            plan = _ask_claude(PLAN_SYSTEM_PROMPT, f"Goal: {goal}", EnvironmentPlan)
            return _apply_plan_guardrails(plan, source="llm", note="")
        except Exception as exc:  # noqa: BLE001
            log.warning("LLM environment planning failed, using rules: %s", exc)
            return _apply_plan_guardrails(_rule_based_plan(goal), source="rules",
                                          note=f"LLM unavailable ({type(exc).__name__}); used rule-based plan.")
    return _apply_plan_guardrails(_rule_based_plan(goal), source="rules",
                                  note="ANTHROPIC_API_KEY not set; used rule-based plan.")


def _apply_plan_guardrails(plan: EnvironmentPlan, source: str, note: str) -> EnvironmentPlanOut:
    data = plan.model_dump()
    adjustments: list[str] = []
    for field, (lo, hi) in _PLAN_LIMITS.items():
        clamped = max(lo, min(hi, data[field]))
        if clamped != data[field]:
            adjustments.append(f"{field} {data[field]} -> {clamped} (allowed {lo}-{hi})")
            data[field] = clamped
    if data["cluster_flavor"] == "k3s" and data["node_count"] != 1:
        adjustments.append(f"node_count {data['node_count']} -> 1 (k3s flavor is a single VM)")
        data["node_count"] = 1
    return EnvironmentPlanOut(**data, source=source, note=note, adjustments=adjustments)


def _rule_based_plan(goal: str) -> EnvironmentPlan:
    g = goal.lower()
    if re.search(r"\b(ha|high[- ]availab\w*|resilien\w*|mission[- ]critical|production)\b", g) \
            and not re.search(r"\b(cheap|cost|free|budget)\b", g):
        return EnvironmentPlan(
            profile_name="high-availability", cluster_flavor="managed", node_size="medium", node_count=3,
            backend_replicas=3, frontend_replicas=2, backend_cpu_request_millicores=250,
            backend_memory_limit_mib=512, db_size="small", db_high_availability=True,
            rationale=["Goal asks for availability: spread 3 backend replicas over 3 managed nodes.",
                       "Multi-AZ database survives a zone outage, at roughly double the DB cost."],
        )
    if re.search(r"\b(perf\w*|high[- ]traffic|load|scale)\b", g):
        return EnvironmentPlan(
            profile_name="performance", cluster_flavor="managed", node_size="large", node_count=2,
            backend_replicas=4, frontend_replicas=2, backend_cpu_request_millicores=500,
            backend_memory_limit_mib=1024, db_size="medium", db_high_availability=False,
            rationale=["Goal asks for throughput: larger nodes and more backend replicas.",
                       "DB HA left off to control cost; enable it for production traffic."],
        )
    return EnvironmentPlan(
        profile_name="cost-optimised", cluster_flavor="k3s", node_size="small", node_count=1,
        backend_replicas=1, frontend_replicas=1, backend_cpu_request_millicores=50,
        backend_memory_limit_mib=256, db_size="micro", db_high_availability=False,
        rationale=["Default / cost-sensitive goal: one free-tier-sized VM running k3s.",
                   "Single replicas and a micro single-zone database keep cost near zero; no redundancy."],
    )


def plan_to_kustomize_patch(plan: EnvironmentPlanOut) -> str:
    """Render the plan as a Kustomize patch the deploy script can layer on an overlay."""
    return f"""# Generated by AI environment planning ({plan.source}) - profile: {plan.profile_name}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
spec:
  replicas: {plan.backend_replicas}
  template:
    spec:
      containers:
        - name: backend
          resources:
            requests:
              cpu: {plan.backend_cpu_request_millicores}m
            limits:
              memory: {plan.backend_memory_limit_mib}Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
spec:
  replicas: {plan.frontend_replicas}
"""


def plan_to_tfvars(plan: EnvironmentPlanOut) -> str:
    """Render the infrastructure part of the plan as Terraform variables."""
    return (
        f"# Generated by AI environment planning ({plan.source}) - profile: {plan.profile_name}\n"
        f'cluster_flavor   = "{plan.cluster_flavor}"\n'
        f'node_size        = "{plan.node_size}"\n'
        f"node_count       = {plan.node_count}\n"
        f'db_size          = "{plan.db_size}"\n'
        f"db_high_availability = {str(plan.db_high_availability).lower()}\n"
    )


class LogTooLargeError(ValueError):
    pass


def _check_size(text: str) -> None:
    # We refuse oversized input instead of silently truncating it, so the
    # analysis never quietly ignores the part of the log that matters.
    if len(text) > settings.ai_max_log_chars:
        raise LogTooLargeError(
            f"Log input is {len(text)} characters; the limit is {settings.ai_max_log_chars}. "
            "Send the relevant excerpt (e.g. the last few hundred lines of the failing pod)."
        )


# ---------------------------------------------------------------------------
# Claude call
# ---------------------------------------------------------------------------
def _strict_schema(model: type[BaseModel]) -> dict:
    """JSON schema for structured outputs: every field required, no extras."""
    schema = model.model_json_schema()
    schema["additionalProperties"] = False
    schema["required"] = list(schema["properties"].keys())
    return schema


def _ask_claude(system: str, user_prompt: str, output_model: type[T]) -> T:
    import anthropic  # imported lazily so the rules-only path has no SDK dependency at runtime

    client = anthropic.Anthropic(api_key=settings.anthropic_api_key, timeout=120.0, max_retries=2)
    response = client.beta.messages.create(
        model=settings.ai_model,
        max_tokens=16000,
        system=system,
        messages=[{"role": "user", "content": user_prompt}],
        # Structured outputs: the reply is guaranteed to be JSON matching the schema.
        output_config={
            "effort": "medium",
            "format": {"type": "json_schema", "schema": _strict_schema(output_model)},
        },
        # If the model declines on a safety classifier (rare for log text),
        # the API retries the same request on a fallback model it picks.
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",
    )
    if response.stop_reason == "refusal":
        raise RuntimeError("model declined the request")
    if response.stop_reason == "max_tokens":
        raise RuntimeError("model output was cut off (max_tokens)")
    text = next(b.text for b in response.content if b.type == "text")
    return output_model.model_validate(json.loads(text))


# ---------------------------------------------------------------------------
# Rule-based fallback (deterministic, used without an API key)
# ---------------------------------------------------------------------------
# (regex, issue description, suggested fix, is_release_breaking, is_transient_at_startup)
# "Transient" patterns (probe failures, refused connections) appear in the
# events of almost every normal pod start, so they are ignored when the log
# also shows the rollout completed successfully.
_RULES: list[tuple[str, str, str, bool, bool]] = [
    (r"CrashLoopBackOff|Back-off restarting failed container", "Container is crash-looping",
     "Check the previous container logs (kubectl logs --previous) for the startup error.", True, False),
    (r"OOMKilled|out of memory", "Container was killed for exceeding its memory limit",
     "Raise resources.limits.memory or fix the memory leak.", True, False),
    (r"ImagePullBackOff|ErrImagePull|manifest unknown", "Image could not be pulled",
     "Verify the image tag exists in the registry and the pull secret is valid.", True, False),
    (r"exceeded its progress deadline", "Rollout did not become ready before its progress deadline",
     "Find the pod-level cause in the events/logs; the rollout should be undone.", True, False),
    (r"Readiness probe failed|Liveness probe failed", "Health probes are failing",
     "Call /ready inside the pod to see which dependency is failing.", True, True),
    (r"ModuleNotFoundError|ImportError|SyntaxError", "Application fails to start (code/dependency error)",
     "Fix the import or add the missing package to requirements.txt.", True, False),
    (r"KeyError: '[A-Z_]+'|environment variable .* (is )?(not set|missing)", "Required configuration is missing",
     "Add the missing variable to the ConfigMap/Secret for this environment.", True, False),
    (r"password authentication failed", "Database credentials are wrong",
     "Check that the ideaboard-db secret matches the Postgres user password.", False, False),
    (r"connection refused|could not connect to server|Connection timed out", "A dependency is unreachable",
     "Check that Postgres is running and the host/port settings are correct.", False, True),
    (r"relation .* does not exist|UndefinedTable|column .* does not exist", "Database schema mismatch",
     "Run or fix the schema migration for this release.", True, False),
    # Only real API traffic counts; 503s from /ready while starting up are expected.
    (r'"(GET|POST|PUT|DELETE) /api\S* HTTP/[\d.]+" 5\d\d', "HTTP 5xx responses are being served to API clients",
     "Look at the backend traceback that accompanies the 5xx responses.", False, False),
    (r"Traceback \(most recent call last\)", "Unhandled Python exception",
     "Read the traceback's last frame to find the failing line.", False, False),
]

# Written by `kubectl rollout status` and by scripts/deploy.sh.
_ROLLOUT_SUCCEEDED = re.compile(r"successfully rolled out|rollout result: success", re.IGNORECASE)
_TRANSIENT_ERROR = re.compile(r"Readiness check failed|connection refused|could not connect", re.IGNORECASE)


def _rule_based_log_analysis(logs: str, note: str) -> LogAnalysisOut:
    issues, fixes, breaking = [], [], False
    rollout_ok = bool(_ROLLOUT_SUCCEEDED.search(logs))
    for pattern, issue, fix, is_breaking, is_transient in _RULES:
        if rollout_ok and is_transient:
            continue
        if re.search(pattern, logs, re.IGNORECASE):
            issues.append(issue)
            fixes.append(fix)
            breaking = breaking or is_breaking

    error_lines = sum(
        1 for line in logs.splitlines()
        if re.search(r"\b(ERROR|CRITICAL|FATAL)\b", line)
        # Readiness errors while the database comes up are normal once the rollout succeeded.
        and not (rollout_ok and _TRANSIENT_ERROR.search(line))
    )
    if breaking:
        status, recommendation, confidence = "failed", "rollback", "medium"
    elif issues or error_lines:
        status, recommendation, confidence = "degraded", "investigate", "low"
        if not issues:
            issues.append(f"{error_lines} ERROR-level log line(s) found")
            fixes.append("Inspect the ERROR lines for the failing component.")
    else:
        status, recommendation, confidence = "healthy", "proceed", "medium"

    return LogAnalysisOut(
        status=status,
        summary=f"Rule-based scan matched {len(issues)} known failure pattern(s) and {error_lines} ERROR line(s).",
        root_cause=issues[0] if issues else "No known failure pattern detected.",
        issues=issues,
        suggested_fixes=fixes,
        recommendation=recommendation,
        confidence=confidence,
        source="rules",
        note=note,
    )


def _rule_based_recommendation(s: DeploymentSignals, note: str) -> DeploymentRecommendationOut:
    reasons: list[str] = []
    log_status = None
    if s.recent_logs.strip():
        log_status = _rule_based_log_analysis(s.recent_logs, note="").status

    if log_status == "failed" or s.pod_restarts >= 3 or s.error_rate_percent >= 5:
        decision, risk = "rollback", "high"
        reasons.append("Current rollout is unhealthy (failed logs, restarts >= 3 or error rate >= 5%).")
    elif not s.tests_passed:
        decision, risk = "hold", "high"
        reasons.append("Tests failed; never deploy a release with failing tests.")
    elif s.error_rate_percent >= 1 or s.p95_latency_ms >= 1000 or log_status == "degraded":
        decision, risk = ("hold" if s.environment == "production" else "canary"), "medium"
        reasons.append("Elevated error rate / latency or degraded logs.")
    elif s.environment == "production":
        decision, risk = "canary", "low"
        reasons.append("Signals are healthy; production changes still go out gradually.")
    else:
        decision, risk = "deploy", "low"
        reasons.append("All signals are healthy.")

    return DeploymentRecommendationOut(
        decision=decision,
        strategy={
            "deploy": "Rolling update (maxUnavailable=0) gated by readiness probes.",
            "canary": "Roll out one replica first, watch error rate for 10 minutes, then continue.",
            "hold": "Do not deploy; resolve the reasons below and re-run the pipeline.",
            "rollback": "Run `kubectl rollout undo` to restore the previous ReplicaSet.",
        }[decision],
        risk_level=risk,
        reasons=reasons,
        pre_deploy_checks=[
            "kubectl rollout status completes within the progress deadline",
            "GET /ready returns 200 on every new pod",
            "Error rate stays below 1% for 10 minutes after rollout",
        ],
        source="rules",
        note=note,
    )
