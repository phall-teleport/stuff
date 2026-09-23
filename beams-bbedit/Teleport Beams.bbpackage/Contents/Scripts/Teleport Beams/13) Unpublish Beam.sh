#!/bin/bash
# Teleport Beams — Unpublish Beam
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_require) || exit 1
beams_tsh beams unpublish "$id" >/dev/null || exit 1
beams_notify "Beam “$id” unpublished."
echo "Unpublished “$id”."
