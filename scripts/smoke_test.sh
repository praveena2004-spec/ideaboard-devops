#!/usr/bin/env bash
# End-to-end smoke test through the frontend's nginx (so the /api proxy is
# exercised too). Used by CI after `docker compose up` and handy locally.
#
#   scripts/smoke_test.sh [base-url]      default: http://localhost:3000
#   READ_ONLY=1 skips the write test (used against public production URLs).
set -euo pipefail
BASE="${1:-http://localhost:3000}"

check() { echo "-> $1"; }

check "frontend serves the app"
curl -fsS "$BASE/" | grep -q '<div id="root">'

check "health endpoint"
curl -fsS "$BASE/healthz" >/dev/null

check "backend version via proxy"
curl -fsS "$BASE/api/version"; echo

if [[ "${READ_ONLY:-0}" != "1" ]]; then
  check "create an idea"
  curl -fsS -X POST "$BASE/api/ideas" -H 'Content-Type: application/json' \
    -d '{"content":"Smoke test idea (created by scripts/smoke_test.sh)"}'; echo

  check "list ideas contains it"
  curl -fsS "$BASE/api/ideas" | grep -q 'Smoke test idea'
else
  check "list ideas (read-only mode)"
  curl -fsS "$BASE/api/ideas" | grep -q '^\['
fi

check "AI environment planning endpoint"
curl -fsS -X POST "$BASE/api/ai/environment-plan" -H 'Content-Type: application/json' \
  -d '{"goal":"cost-sensitive staging"}' | grep -q '"cluster_flavor"'

check "AI log analysis endpoint"
curl -fsS -X POST "$BASE/api/ai/analyze-logs" -H 'Content-Type: application/json' \
  -d '{"logs":"Back-off restarting failed container backend (CrashLoopBackOff)"}' | grep -q '"recommendation"'

echo "Smoke test passed."
