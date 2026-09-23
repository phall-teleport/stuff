#!/bin/bash
# Teleport Beams — Git Push
# Pushes the current branch of the repository on the current beam to origin.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_require) || exit 1
root=$(beams_require_repo "$id") || exit 1
q=$(beams_shell_quote "$root")

branch=$(beams_tsh_raw beams exec "$id" -- "cd $q && git rev-parse --abbrev-ref HEAD" 2>/dev/null | beams_strip_ansi | tr -d '[:space:]')
[ -n "$branch" ] || { beams_die "Could not determine the current branch in $root."; exit 1; }
if [ "$branch" = "HEAD" ]; then
    beams_die "The repository on beam “$id” is in detached HEAD state; check out a branch first."
    exit 1
fi

beams_confirm "Push branch “$branch” from beam “$id” to origin?" "Push" || { echo "Cancelled."; exit 0; }
beams_notify "Pushing $branch…" "$id"

output=$(beams_tsh_raw beams exec "$id" -- "cd $q && git push -u origin HEAD 2>&1" 2>&1)
rc=$?
clean=$(printf '%s' "$output" | beams_strip_ansi)
if [ $rc -ne 0 ]; then
    beams_die "git push failed on beam “$id”:

$(printf '%s' "$clean" | tail -15)"
    exit 1
fi

printf '%s\n' "$clean"
pr_url=$(printf '%s' "$clean" | grep -oE 'https://github\.com/[^[:space:]]+/pull/new/[^[:space:]]+' | head -1)
if [ -n "$pr_url" ]; then
    choice=$(beams_choose_button "Pushed “$branch”.

$(printf '%s' "$clean" | tail -6)" "OK" "Open Pull Request Page") || exit 0
    [ "$choice" = "Open Pull Request Page" ] && open "$pr_url"
else
    beams_alert "$BEAMS_TITLE" "Pushed “$branch” from beam “$id”.

$(printf '%s' "$clean" | tail -6)"
fi
exit 0
