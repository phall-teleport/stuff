#!/usr/bin/env bash
# Sample the preview's CVE data fetch every INTERVAL seconds for DURATION seconds.
# The cache theory needs to span cache refreshes (max-age=3600), so run >1h.
#   scripts/cors-watch.sh                 # every 5 min for 3h
#   INTERVAL=60 DURATION=600 scripts/cors-watch.sh
set -uo pipefail
cd "$(dirname "$0")/.."
INTERVAL=${INTERVAL:-300}
DURATION=${DURATION:-10800}
end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$end" ]; do
  npx playwright test cors-cache --retries=0 --reporter=line 2>&1 | grep -E '\[cors\]|passed|failed' || true
  [ "$(date +%s)" -lt "$end" ] && sleep "$INTERVAL"
done
node scripts/cors-summary.mjs
