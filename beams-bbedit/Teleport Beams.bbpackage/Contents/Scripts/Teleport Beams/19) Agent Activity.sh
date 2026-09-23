#!/bin/bash
# Teleport Beams — Agent Activity
# Summarises the most recent Claude Code session on the current beam: tokens, estimated
# cost, recent tool calls and a chronological event tail. Reads the JSONL transcript under
# /home/beams/.claude/projects (subagent transcripts are ignored).
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_require) || exit 1
marker="---BEAMS-TRANSCRIPT---"

raw=$(beams_tsh_raw beams exec "$id" -- "f=\$(find $BEAMS_HOME/.claude/projects -name '*.jsonl' -not -path '*/subagents/*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-); printf '%s\n$marker\n' \"\$f\"; [ -n \"\$f\" ] && cat \"\$f\"" 2>/dev/null)

transcript=$(printf '%s\n' "$raw" | sed -n '1p' | tr -d '\r')
if [ -z "$transcript" ]; then
    beams_alert "$BEAMS_TITLE" "No Claude Code session transcript was found on beam “$id”.

Start claude on the beam (SSH in Terminal) and try again."
    exit 0
fi

printf '%s\n' "$raw" | sed "1,/^$marker\$/d" \
    | python3 "$BEAMS_LIB_DIR/activity.py" --beam "$id" --path "$transcript" \
    | beams_show "$id: agent activity" "Markdown"
