#!/usr/bin/env bash
# Manual rollback of the app deployments in one environment.
#
#   scripts/rollback.sh <staging|production> [revision]
#
# Without a revision, each deployment goes back to its previous revision.
# See history first with:  kubectl -n ideaboard-<env> rollout history deployment/backend
set -euo pipefail
ENVIRONMENT="${1:?usage: rollback.sh <staging|production> [revision]}"
REVISION="${2:-}"
NS="ideaboard-$ENVIRONMENT"

for d in backend frontend; do
  if [[ -n "$REVISION" ]]; then
    kubectl -n "$NS" rollout undo "deployment/$d" --to-revision="$REVISION"
  else
    kubectl -n "$NS" rollout undo "deployment/$d"
  fi
  kubectl -n "$NS" rollout status "deployment/$d" --timeout=180s
done
kubectl -n "$NS" get deployments -o wide
