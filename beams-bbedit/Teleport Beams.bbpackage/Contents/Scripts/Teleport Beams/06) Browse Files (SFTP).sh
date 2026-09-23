#!/bin/bash
# Teleport Beams — Browse Files (SFTP)
# Opens the current beam's home directory in BBEdit's SFTP browser.
# Files opened from there save straight back to the beam.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_require) || exit 1
url=$(beams_sftp_url "$id" "$BEAMS_HOME/") || exit 1
beams_open_url "$url"
