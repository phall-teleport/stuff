#!/bin/bash
# Teleport Beams — Git Diff
# Shows unstaged and staged changes for the repository on the current beam.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_require) || exit 1
root=$(beams_require_repo "$id") || exit 1
q=$(beams_shell_quote "$root")

output=$(beams_tsh_raw beams exec "$id" -- "cd $q && git --no-pager diff && git --no-pager diff --cached && git status --short --untracked-files=all | sed -n 's/^?? /# untracked: /p'" 2>&1)
if [ -z "$(printf '%s' "$output" | tr -d '[:space:]')" ]; then
    beams_notify "No changes in $root" "$id"
    exit 0
fi
printf '%s\n' "$output" | beams_strip_ansi | beams_show "$id: git diff"
