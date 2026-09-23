#!/bin/bash
# Teleport Beams — Create Beam
# Starts a new beam, makes it current, writes its SSH alias, and offers to open it.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

beams_profile || exit 1
beams_notify "Creating a new beam… this can take a minute."

json=$(beams_tsh beams add -f json) || exit 1
id=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
uuid=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("uuid",""))' 2>/dev/null)
if [ -z "$id" ]; then
    beams_die "Beam was created but its id could not be read from tsh output:

$json"
    exit 1
fi

beams_set_current "$id"
echo "Created beam “$id” (now the current beam)."
host=$(beams_ensure_ssh "$id" "$uuid") || true

choice=$(beams_choose_button "Beam “$id” is ready and is now the current beam.

SSH alias: ${host:-unavailable}" "Done" "SSH in Terminal" "Browse Files") || exit 0
echo "SSH alias: ${host:-unavailable}"

case "$choice" in
    "Browse Files")
        url=$(beams_sftp_url "$id" "$BEAMS_HOME/") || exit 1
        beams_open_url "$url"
        ;;
    "SSH in Terminal")
        beams_terminal "$(beams_tsh_cmdline beams ssh "$id")"
        ;;
esac
