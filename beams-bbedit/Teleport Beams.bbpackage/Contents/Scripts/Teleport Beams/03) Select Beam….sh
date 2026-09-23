#!/bin/bash
# Teleport Beams — Select Beam…
# Picks the "current" beam that the other scripts act on, then offers to open it.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_pick "Choose the current beam") || { echo "Cancelled."; exit 0; }
beams_set_current "$id"
echo "Current beam is now “$id”. Other Teleport Beams menu items act on it."

choice=$(beams_choose_button "Current beam is now “$id”.

The other Teleport Beams menu items (Browse Files, Run…, Git…, Agent Activity) act on it. Open it now?" "Done" "SSH in Terminal" "Browse Files") || exit 0

case "$choice" in
    "Browse Files")
        url=$(beams_sftp_url "$id" "$BEAMS_HOME/") || exit 1
        beams_open_url "$url"
        ;;
    "SSH in Terminal")
        beams_terminal "$(beams_tsh_cmdline beams ssh "$id")"
        echo "Opened an SSH session to “$id” in ${BEAMS_TERMINAL:-Terminal}."
        ;;
esac
exit 0
