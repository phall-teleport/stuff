#!/bin/bash
# Teleport Beams — Git Status
# Shows git status and recent history for the repository on the current beam.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_require) || exit 1
root=$(beams_require_repo "$id") || exit 1
q=$(beams_shell_quote "$root")

output=$(beams_tsh_raw beams exec "$id" -- "cd $q && echo \"# \$(pwd) on \$(git rev-parse --abbrev-ref HEAD) (\$(git rev-parse --short HEAD))\" && echo && git status && echo && echo '# Recent commits' && git log --oneline --decorate -15" 2>&1)
{
    echo "# git status — beam $id"
    echo
    printf '%s\n' "$output" | beams_strip_ansi
} | beams_show "$id: git status" "Log File"
