#!/bin/bash
# Launch one headless pi agent per brief (Briefs/<owner>.md), in waves.
#
#   Scripts/fanout.sh 1            # wave 1 (all briefs marked "Wave 1"), 6 at a time
#   Scripts/fanout.sh 2 4          # wave 2, 4 at a time
#   Scripts/fanout.sh all          # wave 1, then wave 2
#   Scripts/fanout.sh only nettools,fleet
#
# Logs:   .agents/logs/<owner>.log   (final report at the end)
# Resume: pi --session-id sl-sync-<owner>   (from this directory)
# Env:    SL_AGENT_MODEL (default: $PI_MODEL or pi's default), SL_AGENT_THINKING (default: medium)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p .agents/logs

WHAT="${1:-1}"; MAX="${2:-6}"

briefs_for_wave() {
  grep -l "Wave $1\." Briefs/*.md | xargs -n1 basename | sed 's/\.md$//' | grep -v '^_'
}

run_one() {
  owner="$1"
  log=".agents/logs/$owner.log"
  model_args=()
  m="${SL_AGENT_MODEL:-${PI_MODEL:-}}"
  [ -n "$m" ] && model_args=(--model "$m")
  prompt="You are the '$owner' owner for the ServerLife Swift port's 0.16.0→0.39.0 sync.
Read CLAUDE.md, Briefs/_common.md and Briefs/$owner.md in full, then do the work they describe,
end to end, without asking questions: read the upstream sources, port them into your owned paths in
your mirror, build, test, publish (Scripts/agent.sh), and finish with the final report the brief asks for."
  echo "[$(date +%H:%M:%S)] start $owner" | tee -a .agents/logs/fanout.log
  pi -p --no-mcp --approve --name "sl-sync-$owner" --session-id "sl-sync-$owner" \
     --thinking "${SL_AGENT_THINKING:-medium}" "${model_args[@]}" "$prompt" > "$log" 2>&1 && rc=0 || rc=$?
  echo "[$(date +%H:%M:%S)] done  $owner (exit $rc)" | tee -a .agents/logs/fanout.log
}
export -f run_one

launch() { xargs -P "$MAX" -I{} bash -c 'run_one "$@"' _ {}; }

case "$WHAT" in
  1|2) briefs_for_wave "$WHAT" | launch ;;
  all) briefs_for_wave 1 | launch; briefs_for_wave 2 | launch ;;
  only) echo "${2:?owners}" | tr ',' '\n' | MAX=6 launch ;;
  *) echo "usage: $0 1|2|all [max] | only a,b" >&2; exit 2 ;;
esac
