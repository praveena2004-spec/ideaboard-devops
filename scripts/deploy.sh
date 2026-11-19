#!/usr/bin/env bash
# Deploy Idea Board to any Kubernetes cluster (k3s, EKS, GKE, kind) with
# AI-assisted health analysis and automatic rollback.
#
#   scripts/deploy.sh <overlay> <backend-image> <frontend-image>
#   overlay = free-tier | staging | production | local   (k8s/overlays/<overlay>)
#
# Flow:
#   1. ensure namespace + secrets (from env vars, never from git)
#   2. render the overlay (+ optional AI environment plan / bad-release
#      simulation) with the given images and apply it
#   3. wait for `kubectl rollout status` (readiness probes gate this)
#   4. smoke-test /ready and /api/ideas from inside the cluster
#   5. collect logs/events; AI analyzes them and writes a human-readable summary
#   6. roll back if (a) the rollout/smoke test failed, or (b) the AI is highly
#      confident the release is bad even though the checks passed
#
# Env vars:
#   POSTGRES_HOST, POSTGRES_PASSWORD   database connection -> secret ideaboard-db
#   POSTGRES_PORT/DB/USER              (defaults 5432 / ideaboard / ideaboard)
#   ANTHROPIC_API_KEY   optional -> secret ideaboard-ai (and enables LLM analysis here)
#   AI_ENV_GOAL         optional, e.g. "cost-sensitive staging": AI sizes replicas/resources
#   AI_ROLLBACK         "true" (default): allow a high-confidence LLM verdict to roll back
#   SIMULATE_UNHEALTHY  "true": deploy a deliberately broken backend to demo rollback
#   ROLLOUT_TIMEOUT     default 180s;  LOG_DIR default deploy-logs
#   GITHUB_STEP_SUMMARY set by GitHub Actions -> report is appended there
#
# Requires kubectl with a working context, and python with backend/requirements.txt
# installed for the AI analyzer (the deploy itself still works if that step fails).
set -euo pipefail

OVERLAY_NAME="${1:?usage: deploy.sh <overlay> <backend-image> <frontend-image>}"
BACKEND_IMAGE="${2:?backend image required}"
FRONTEND_IMAGE="${3:?frontend image required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAY="$ROOT/k8s/overlays/$OVERLAY_NAME"
[[ -d "$OVERLAY" ]] || { echo "Unknown overlay: $OVERLAY_NAME"; exit 1; }
NS="$(sed -n 's/^namespace: *//p' "$OVERLAY/kustomization.yaml")"
TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"
LOG_DIR="${LOG_DIR:-$ROOT/deploy-logs}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
PYTHON="${PYTHON:-python}"
APP_DEPLOYMENTS=(backend frontend)

mkdir -p "$LOG_DIR"
log() { echo "==> $*"; }
ai() { (cd "$ROOT/backend" && "$PYTHON" -m app.analyze_cli "$@"); }

# ---------- 1. namespace + secrets ----------
log "Ensuring namespace $NS and secrets"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
  kubectl -n "$NS" create secret generic ideaboard-db \
    --from-literal=POSTGRES_HOST="${POSTGRES_HOST:?POSTGRES_HOST required with POSTGRES_PASSWORD}" \
    --from-literal=POSTGRES_PORT="${POSTGRES_PORT:-5432}" \
    --from-literal=POSTGRES_DB="${POSTGRES_DB:-ideaboard}" \
    --from-literal=POSTGRES_USER="${POSTGRES_USER:-ideaboard}" \
    --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
elif ! kubectl -n "$NS" get secret ideaboard-db >/dev/null 2>&1; then
  echo "ERROR: secret ideaboard-db missing in $NS and POSTGRES_PASSWORD/POSTGRES_HOST not set"; exit 1
fi
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  kubectl -n "$NS" create secret generic ideaboard-ai \
    --from-literal=ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" --dry-run=client -o yaml | kubectl apply -f -
fi

# ---------- 2. render + apply ----------
revision() {
  kubectl -n "$NS" get deployment "$1" \
    -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null || true
}
declare -A BEFORE
for d in "${APP_DEPLOYMENTS[@]}"; do BEFORE[$d]="$(revision "$d")"; done

# A throwaway kustomization that layers optional patches on top of the overlay.
WRAP="$LOG_DIR/render-$OVERLAY_NAME"
rm -rf "$WRAP" && mkdir -p "$WRAP"
{
  echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  echo "kind: Kustomization"
  echo "resources:"
  echo "  - $(realpath --relative-to="$WRAP" "$OVERLAY")"
  echo "patches:"
} > "$WRAP/kustomization.yaml"
patches=0

if [[ -n "${AI_ENV_GOAL:-}" ]]; then
  # Generative configuration: the AI turns a goal into replicas/resources;
  # guardrails in app/ai.py clamp the values before they get here.
  log "AI environment plan for goal: $AI_ENV_GOAL"
  ai plan "$AI_ENV_GOAL" --patch-out "$WRAP/ai-plan.yaml" | tee -a "$SUMMARY"
  echo "  - path: ai-plan.yaml" >> "$WRAP/kustomization.yaml"; patches=$((patches+1))
fi
if [[ "${SIMULATE_UNHEALTHY:-false}" == "true" ]]; then
  # Env override on the backend pod template only (not the shared ConfigMap,
  # which the previous revision also reads - a rollback must really undo it).
  log "SIMULATE_UNHEALTHY=true: deploying a deliberately broken release to exercise rollback"
  cat >> "$WRAP/kustomization.yaml" <<'EOF'
  - target: { kind: Deployment, name: backend }
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value: { name: SIMULATE_UNHEALTHY, value: "true" }
EOF
  patches=$((patches+1))
fi
[[ $patches -eq 0 ]] && sed -i '/^patches:$/d' "$WRAP/kustomization.yaml"

RENDERED="$LOG_DIR/rendered-$OVERLAY_NAME.yaml"
log "Rendering $OVERLAY_NAME"
kubectl kustomize "$WRAP" \
  | sed -E "s#image: .*ideaboard-backend(:.*)?\$#image: $BACKEND_IMAGE#; s#image: .*ideaboard-frontend(:.*)?\$#image: $FRONTEND_IMAGE#" \
  > "$RENDERED"
kubectl apply -f "$RENDERED"

# ---------- 3 + 4. wait + smoke test ----------
healthy=true
reason=""
if kubectl -n "$NS" get statefulset postgres >/dev/null 2>&1; then
  log "Waiting for in-cluster postgres"
  kubectl -n "$NS" rollout status statefulset/postgres --timeout="$TIMEOUT" || { healthy=false; reason="postgres not ready"; }
fi
for d in "${APP_DEPLOYMENTS[@]}"; do
  if $healthy; then
    log "Waiting for deployment/$d (timeout $TIMEOUT)"
    kubectl -n "$NS" rollout status "deployment/$d" --timeout="$TIMEOUT" || { healthy=false; reason="deployment/$d did not become ready"; }
  fi
done
if $healthy; then
  log "Smoke test"
  # urlopen raises on any non-2xx status, which makes the command fail.
  kubectl -n "$NS" exec deploy/backend -- python -c "
import urllib.request
for path in ('/ready', '/api/ideas'):
    print(path, urllib.request.urlopen('http://127.0.0.1:8000' + path, timeout=5).status)
" || { healthy=false; reason="smoke test failed"; }
fi

# ---------- 5. collect logs + AI analysis ----------
LOGFILE="$LOG_DIR/$OVERLAY_NAME.log"
{
  echo "--- rollout target: backend=$BACKEND_IMAGE frontend=$FRONTEND_IMAGE ---"
  # Marker read by the AI analyzer (rule-based path) to tell transient startup
  # probe failures apart from a broken release.
  if $healthy; then echo "rollout result: success"; else echo "rollout result: failed ($reason)"; fi
  kubectl -n "$NS" get pods -o wide || true
  echo "--- events ---"
  kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -n 60 || true
  for d in "${APP_DEPLOYMENTS[@]}"; do
    echo "--- logs: $d ---"
    kubectl -n "$NS" logs -l "app=$d" --all-containers --prefix --tail=150 || true
    echo "--- previous container logs: $d ---"
    kubectl -n "$NS" logs -l "app=$d" --all-containers --prefix --tail=100 --previous 2>/dev/null || true
  done
} > "$LOGFILE" 2>&1

log "AI log analysis"
AI_JSON="$LOG_DIR/ai-analysis-$OVERLAY_NAME.json"
rm -f "$AI_JSON"
ai logs "$LOGFILE" --context "$OVERLAY_NAME rollout of $BACKEND_IMAGE" --json "$AI_JSON" \
  > "$LOG_DIR/ai-analysis-$OVERLAY_NAME.md" || true
cat "$LOG_DIR/ai-analysis-$OVERLAY_NAME.md" | tee -a "$SUMMARY" || true

# AI-triggered rollback: objective checks passed, but the LLM read the logs and
# is highly confident the release is broken (e.g. errors on every request).
# Rule-based verdicts never trigger this - they only summarise.
if $healthy && [[ "${AI_ROLLBACK:-true}" == "true" && -f "$AI_JSON" ]]; then
  verdict="$("$PYTHON" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['source'], d['recommendation'], d['confidence'])" "$AI_JSON" || true)"
  log "AI verdict: ${verdict:-unavailable}"
  if [[ "$verdict" == "llm rollback high" ]]; then
    healthy=false
    reason="AI log analysis recommended rollback with high confidence"
  fi
fi

# ---------- 6. rollback on failure ----------
if ! $healthy; then
  log "Deployment FAILED ($reason) - rolling back"
  echo -e "\n### Rollback\nDeployment of **$OVERLAY_NAME** failed: $reason. Rolling back." >> "$SUMMARY"
  for d in "${APP_DEPLOYMENTS[@]}"; do
    before="${BEFORE[$d]}"
    after="$(revision "$d")"
    if [[ -z "$before" ]]; then
      log "deployment/$d had no previous revision (first deploy) - nothing to roll back to"
      echo "- \`$d\`: first deploy, no previous revision to restore" >> "$SUMMARY"
    elif [[ "$before" != "$after" ]]; then
      log "deployment/$d: undo revision $after -> $before"
      kubectl -n "$NS" rollout undo "deployment/$d" --to-revision="$before"
      if kubectl -n "$NS" rollout status "deployment/$d" --timeout="$TIMEOUT"; then
        echo "- \`$d\` restored to revision $before" >> "$SUMMARY"
      else
        echo "- \`$d\` rollback did NOT become healthy - manual action needed" >> "$SUMMARY"
      fi
    else
      log "deployment/$d unchanged by this deploy - leaving it alone"
    fi
  done
  exit 1
fi

log "Deployment of $OVERLAY_NAME succeeded"
echo -e "\n### Deployment\n**$OVERLAY_NAME** (namespace \`$NS\`) is running backend \`$BACKEND_IMAGE\`." >> "$SUMMARY"
