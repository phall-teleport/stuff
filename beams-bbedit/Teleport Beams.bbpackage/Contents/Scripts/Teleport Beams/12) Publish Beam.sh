#!/bin/bash
# Teleport Beams — Publish Beam
# Publishes the service running on the current beam (HTTP on 8080 by default, or TCP)
# and copies the resulting URL to the clipboard.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_require) || exit 1
kind=$(beams_choose_button "Publish beam “$id” as which kind of service?" "Cancel" "TCP" "HTTP") || { echo "Cancelled."; exit 0; }

args=(beams publish)
[ "$kind" = "TCP" ] && args+=(--tcp)
args+=("$id")

output=$(beams_tsh "${args[@]}") || exit 1
url=$(printf '%s' "$output" | beams_strip_ansi | grep -oE 'https?://[^[:space:]]+' | head -1)
[ -n "$url" ] || url=$(printf '%s' "$output" | beams_strip_ansi | tail -1)

printf '%s' "$url" | pbcopy
echo "Published “$id” ($kind): $url (copied to clipboard)"
choice=$(beams_choose_button "Beam “$id” is published (URL copied to the clipboard):

$url" "OK" "Open in Browser") || exit 0
[ "$choice" = "Open in Browser" ] && open "$url"
exit 0
