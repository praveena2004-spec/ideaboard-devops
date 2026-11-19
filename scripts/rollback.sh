#!/usr/bin/env bash
# Manual rollback of the app deployments of one overlay/environment.
#
#   scripts/rollback.sh <overlay> [revision]      overlay = free-tier | staging | production | local
#
# Without a revision, each deployment goes back to its previous revision.
# Inspect history first:  kubectl -n <namespace> rollout history deployment/backend
set -euo pipefail
OVERLAY_NAME="${1:?usage: rollback.sh <overlay> [revision]}"
REVISION="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="$(sed -n 's/^namespace: *//p' "$ROOT/k8s/overlays/$OVERLAY_NAME/kustomization.yaml")"

for d in backend frontend; do
  if [[ -n "$REVISION" ]]; then
    kubectl -n "$NS" rollout undo "deployment/$d" --to-revision="$REVISION"
  else
    kubectl -n "$NS" rollout undo "deployment/$d"
  fi
  kubectl -n "$NS" rollout status "deployment/$d" --timeout=180s
done
kubectl -n "$NS" get deployments -o wide
