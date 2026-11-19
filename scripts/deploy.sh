#!/usr/bin/env bash
# Deploy Idea Board to a Kubernetes environment with automatic rollback.
#
#   scripts/deploy.sh <staging|production> <backend-image> <frontend-image>
#
# Flow:
#   1. ensure namespace + secrets (from env vars, never from git)
#   2. render k8s/overlays/<env> with the given images and apply it
#   3. wait for `kubectl rollout status` (readiness probes gate this)
#   4. smoke-test /ready and /api/ideas from inside the cluster
#   5. collect logs/events and run the AI log analyzer on them
#   6. on any failure in 3-4: `kubectl rollout undo` to the exact revision that
#      was live before this deploy, wait for it, and exit non-zero
#
# Env vars:
#   POSTGRES_PASSWORD   (required on first deploy) -> secret ideaboard-db
#   ANTHROPIC_API_KEY   (optional)                 -> secret ideaboard-ai
#   SIMULATE_UNHEALTHY  (optional, "true")         -> deploys a deliberately bad release
#   ROLLOUT_TIMEOUT     (default 180s)
#   LOG_DIR             (default deploy-logs)
#   GITHUB_STEP_SUMMARY (set by GitHub Actions)    -> report is appended there
#
# Requires: kubectl (with a working context), python3 with backend/requirements.txt
# installed (for the AI analyzer; the deploy still works if that step fails).
set -euo pipefail

ENVIRONMENT="${1:?usage: deploy.sh <staging|production> <backend-image> <frontend-image>}"
BACKEND_IMAGE="${2:?backend image required}"
FRONTEND_IMAGE="${3:?frontend image required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAY="$ROOT/k8s/overlays/$ENVIRONMENT"
NS="ideaboard-$ENVIRONMENT"
TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"
LOG_DIR="${LOG_DIR:-$ROOT/deploy-logs}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
APP_DEPLOYMENTS=(backend frontend)

[[ -d "$OVERLAY" ]] || { echo "Unknown environment: $ENVIRONMENT"; exit 1; }
mkdir -p "$LOG_DIR"
log() { echo "==> $*"; }

# ---------- 1. namespace + secrets ----------
log "Ensuring namespace $NS and secrets"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
  kubectl -n "$NS" create secret generic ideaboard-db \
    --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD" --dry-run=client -o yaml | kubectl apply -f -
elif ! kubectl -n "$NS" get secret ideaboard-db >/dev/null 2>&1; then
  echo "ERROR: secret ideaboard-db missing in $NS and POSTGRES_PASSWORD not set"; exit 1
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

SOURCE="$OVERLAY"
if [[ "${SIMULATE_UNHEALTHY:-false}" == "true" ]]; then
  # Wrap the overlay and add an env override to the backend pod template only.
  # (Not editing the ConfigMap: the previous revision also reads it, so a
  # rollback would not really undo the change.)
  log "SIMULATE_UNHEALTHY=true: deploying a deliberately broken release to exercise rollback"
  SOURCE="$LOG_DIR/simulate-$ENVIRONMENT"
  mkdir -p "$SOURCE"
  cat > "$SOURCE/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - $(realpath --relative-to="$SOURCE" "$OVERLAY")
patches:
  - target: { kind: Deployment, name: backend }
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value: { name: SIMULATE_UNHEALTHY, value: "true" }
EOF
fi

RENDERED="$LOG_DIR/rendered-$ENVIRONMENT.yaml"
log "Rendering $SOURCE"
kubectl kustomize "$SOURCE" \
  | sed -E "s#image: .*ideaboard-backend(:.*)?\$#image: $BACKEND_IMAGE#; s#image: .*ideaboard-frontend(:.*)?\$#image: $FRONTEND_IMAGE#" \
  > "$RENDERED"
kubectl apply -f "$RENDERED"

# ---------- 3 + 4. wait + smoke test ----------
healthy=true
log "Waiting for postgres"
kubectl -n "$NS" rollout status statefulset/postgres --timeout="$TIMEOUT" || healthy=false
for d in "${APP_DEPLOYMENTS[@]}"; do
  if $healthy; then
    log "Waiting for deployment/$d (timeout $TIMEOUT)"
    kubectl -n "$NS" rollout status "deployment/$d" --timeout="$TIMEOUT" || healthy=false
  fi
done
if $healthy; then
  log "Smoke test"
  # urlopen raises on any non-2xx status, which makes the command fail.
  kubectl -n "$NS" exec deploy/backend -- python -c "
import urllib.request
for path in ('/ready', '/api/ideas'):
    print(path, urllib.request.urlopen('http://127.0.0.1:8000' + path, timeout=5).status)
" || healthy=false
fi

# ---------- 5. collect logs + AI analysis ----------
LOGFILE="$LOG_DIR/$ENVIRONMENT.log"
{
  echo "--- rollout target: backend=$BACKEND_IMAGE frontend=$FRONTEND_IMAGE ---"
  # Marker read by the AI analyzer (rule-based path) to tell transient startup
  # probe failures apart from a broken release.
  if $healthy; then echo "rollout result: success"; else echo "rollout result: failed"; fi
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
ai_rc=0
(cd "$ROOT/backend" && python -m app.analyze_cli logs "$LOGFILE" \
   --context "$ENVIRONMENT rollout of $BACKEND_IMAGE") > "$LOG_DIR/ai-analysis-$ENVIRONMENT.md" || ai_rc=$?
cat "$LOG_DIR/ai-analysis-$ENVIRONMENT.md" | tee -a "$SUMMARY" || true
# The AI verdict is advisory here: the rollback decision is driven by the
# objective rollout/smoke-test result, so a wrong LLM answer can't break prod.
log "AI analyzer exit code: $ai_rc (0=proceed 1=investigate 2=rollback)"

# ---------- 6. rollback on failure ----------
if ! $healthy; then
  log "Deployment FAILED - rolling back"
  echo -e "\n### Rollback\nDeployment to **$ENVIRONMENT** failed; rolling back." >> "$SUMMARY"
  for d in "${APP_DEPLOYMENTS[@]}"; do
    before="${BEFORE[$d]}"
    after="$(revision "$d")"
    if [[ -z "$before" ]]; then
      log "deployment/$d had no previous revision (first deploy) - nothing to roll back to"
    elif [[ "$before" != "$after" ]]; then
      log "deployment/$d: undo revision $after -> $before"
      kubectl -n "$NS" rollout undo "deployment/$d" --to-revision="$before"
      kubectl -n "$NS" rollout status "deployment/$d" --timeout="$TIMEOUT" \
        && echo "- \`$d\` restored to revision $before" >> "$SUMMARY" \
        || echo "- \`$d\` rollback did NOT become healthy - manual action needed" >> "$SUMMARY"
    else
      log "deployment/$d unchanged by this deploy - leaving it alone"
    fi
  done
  exit 1
fi

log "Deployment to $ENVIRONMENT succeeded"
echo -e "\n### Deployment\n**$ENVIRONMENT** is running backend \`$BACKEND_IMAGE\`." >> "$SUMMARY"
