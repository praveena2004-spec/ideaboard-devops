"""CLI used by the CI/CD pipeline to analyze deployment logs.

    python -m app.analyze_cli logs <file> [--context TEXT] [--json OUT.json]
    python -m app.analyze_cli recommend --environment production [--logs FILE] [--tests-passed true]
    python -m app.analyze_cli plan "cost-sensitive staging" [--patch-out P.yaml] [--tfvars-out T.tfvars]

It prints a Markdown report (the pipeline appends it to $GITHUB_STEP_SUMMARY)
and sets the exit code so the workflow can act on it:

    logs:      0 = proceed, 1 = investigate, 2 = rollback
    recommend: 0 = deploy/canary, 1 = hold, 2 = rollback
    plan:      0 = plan written

Works without an API key (rule-based fallback), so the pipeline never depends
on the LLM being reachable.
"""
import argparse
import sys

from . import ai
from .schemas import DeploymentSignals


def _md_list(items: list[str]) -> str:
    return "\n".join(f"- {i}" for i in items) or "- (none)"


def cmd_logs(args) -> int:
    with open(args.file, encoding="utf-8", errors="replace") as f:
        logs = f.read()
    if not logs.strip():
        print("## AI deployment log analysis\n\nNo logs were captured.")
        return 1
    r = ai.analyze_logs(logs, args.context)
    if args.json:
        # Machine-readable copy for scripts/deploy.sh (AI-triggered rollback).
        with open(args.json, "w", encoding="utf-8") as f:
            f.write(r.model_dump_json(indent=2))
    print(f"""## AI deployment log analysis ({r.source})

**Status:** {r.status} | **Recommendation:** {r.recommendation} | **Confidence:** {r.confidence}

{r.summary}

**Root cause:** {r.root_cause}

**Issues**
{_md_list(r.issues)}

**Suggested fixes**
{_md_list(r.suggested_fixes)}

{('_' + r.note + '_') if r.note else ''}""")
    return {"proceed": 0, "investigate": 1, "rollback": 2}[r.recommendation]


def cmd_recommend(args) -> int:
    logs = ""
    if args.logs:
        with open(args.logs, encoding="utf-8", errors="replace") as f:
            logs = f.read()
    signals = DeploymentSignals(
        environment=args.environment,
        change_summary=args.change_summary,
        error_rate_percent=args.error_rate,
        p95_latency_ms=args.p95_latency,
        pod_restarts=args.restarts,
        tests_passed=args.tests_passed.lower() == "true",
        recent_logs=logs,
    )
    r = ai.recommend_deployment(signals)
    print(f"""## AI deployment recommendation ({r.source})

**Decision:** {r.decision} | **Risk:** {r.risk_level}

**Strategy:** {r.strategy}

**Reasons**
{_md_list(r.reasons)}

**Pre-deploy checks**
{_md_list(r.pre_deploy_checks)}

{('_' + r.note + '_') if r.note else ''}""")
    return {"deploy": 0, "canary": 0, "hold": 1, "rollback": 2}[r.decision]


def cmd_plan(args) -> int:
    r = ai.plan_environment(args.goal)
    if args.patch_out:
        with open(args.patch_out, "w", encoding="utf-8") as f:
            f.write(ai.plan_to_kustomize_patch(r))
    if args.tfvars_out:
        with open(args.tfvars_out, "w", encoding="utf-8") as f:
            f.write(ai.plan_to_tfvars(r))
    print(f"""## AI environment plan ({r.source}): `{args.goal}`

**Profile:** {r.profile_name} | **Cluster:** {r.cluster_flavor}, {r.node_count} x {r.node_size} node(s) | **DB:** {r.db_size}{' (HA)' if r.db_high_availability else ''}

| Setting | Value |
|---|---|
| backend replicas | {r.backend_replicas} |
| frontend replicas | {r.frontend_replicas} |
| backend CPU request | {r.backend_cpu_request_millicores}m |
| backend memory limit | {r.backend_memory_limit_mib}Mi |

**Rationale**
{_md_list(r.rationale)}

**Guardrail adjustments**
{_md_list(r.adjustments)}

{('_' + r.note + '_') if r.note else ''}""")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(prog="python -m app.analyze_cli")
    sub = p.add_subparsers(dest="cmd", required=True)

    pl = sub.add_parser("logs", help="analyze a deployment log file")
    pl.add_argument("file")
    pl.add_argument("--context", default="")
    pl.add_argument("--json", default="", help="also write the result as JSON to this file")
    pl.set_defaults(func=cmd_logs)

    pp = sub.add_parser("plan", help="turn a high-level goal into environment sizing")
    pp.add_argument("goal")
    pp.add_argument("--patch-out", default="", help="write a Kustomize patch (replicas/resources)")
    pp.add_argument("--tfvars-out", default="", help="write Terraform variables (cluster/db sizing)")
    pp.set_defaults(func=cmd_plan)

    pr = sub.add_parser("recommend", help="get a deploy/canary/hold/rollback recommendation")
    pr.add_argument("--environment", default="staging", choices=["development", "staging", "production"])
    pr.add_argument("--change-summary", default="")
    pr.add_argument("--error-rate", type=float, default=0.0)
    pr.add_argument("--p95-latency", type=float, default=0.0)
    pr.add_argument("--restarts", type=int, default=0)
    pr.add_argument("--tests-passed", default="true")
    pr.add_argument("--logs", default="")
    pr.set_defaults(func=cmd_recommend)

    args = p.parse_args()
    try:
        return args.func(args)
    except ai.LogTooLargeError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
