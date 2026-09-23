#!/bin/bash
# Teleport Beams — Git Commit…
# Stages everything in the repository on the current beam and commits with the given message.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_require) || exit 1
root=$(beams_require_repo "$id") || exit 1
q=$(beams_shell_quote "$root")

status=$(beams_tsh_raw beams exec "$id" -- "cd $q && git status --short" 2>/dev/null | beams_strip_ansi)
if [ -z "$(printf '%s' "$status" | tr -d '[:space:]')" ]; then
    beams_alert "$BEAMS_TITLE" "Nothing to commit in $root on beam “$id”."
    exit 0
fi

msg=$(beams_ask "Commit message (all changes in $root will be staged):

$(printf '%s\n' "$status" | head -20)" "") || { echo "Cancelled."; exit 0; }
[ -n "$(printf '%s' "$msg" | tr -d '[:space:]')" ] || { beams_die "Commit message cannot be empty."; exit 1; }

output=$(printf '%s' "$msg" | beams_tsh_raw beams exec "$id" -- "cd $q && git add -A && git commit -F -" 2>&1)
rc=$?
if [ $rc -ne 0 ]; then
    beams_die "git commit failed on beam “$id”:

$(printf '%s' "$output" | beams_strip_ansi | tail -15)"
    exit 1
fi
beams_notify "$(printf '%s' "$output" | beams_strip_ansi | head -1)" "$id"
printf '%s\n' "$output" | beams_strip_ansi
