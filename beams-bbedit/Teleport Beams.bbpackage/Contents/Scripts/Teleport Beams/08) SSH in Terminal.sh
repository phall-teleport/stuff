#!/bin/bash
# Teleport Beams — SSH in Terminal
# Opens an interactive `tsh beams ssh` session for the current beam in Terminal (or iTerm).
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_require) || exit 1
beams_terminal "$(beams_tsh_cmdline beams ssh "$id")"
echo "Opened an SSH session to “$id” in ${BEAMS_TERMINAL:-Terminal}."
