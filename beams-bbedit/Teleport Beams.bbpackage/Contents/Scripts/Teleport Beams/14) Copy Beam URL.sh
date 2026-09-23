#!/bin/bash
# Teleport Beams — Copy Beam URL
# Copies the current beam's published URL to the clipboard.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_require) || exit 1
url=$(beams_url "$id") || exit 1
if [ -z "$url" ]; then
    beams_alert "$BEAMS_TITLE" "Beam “$id” is not published. Use “Publish Beam” first."
    echo "“$id” is not published."
    exit 0
fi
printf '%s' "$url" | pbcopy
beams_notify "Copied $url" "$id"
echo "Copied $url to the clipboard."
