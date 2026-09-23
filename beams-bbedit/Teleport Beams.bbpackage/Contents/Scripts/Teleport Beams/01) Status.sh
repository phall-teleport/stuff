#!/bin/bash
# Teleport Beams — Status
# Shows the active Teleport profile and every beam in a new BBEdit document.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

beams_profile || exit 1
tsv=$(beams_list_tsv) || exit 1
current=$(beams_current_id)

{
    echo "# Teleport Beams"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Beams cluster | $BEAMS_CLUSTER (${BEAMS_PREFERRED_CLUSTER:+pinned via config}${BEAMS_PREFERRED_CLUSTER:-auto-detected; set BEAMS_CLUSTER in $BEAMS_CONFIG_FILE to pin}) |"
    echo "| User | $BEAMS_USERNAME |"
    echo "| Session valid until | ${BEAMS_VALID_UNTIL:-unknown} |"
    echo "| Current beam | ${current:-_none — use “Select Beam…”_} |"
    echo "| tsh | $TSH --proxy=$BEAMS_PROXY |"
    echo
    echo "## Beams"
    echo
    if [ -z "$tsv" ]; then
        echo "_No beams. Use “Create Beam” to start one._"
    else
        echo "| Beam | Expires in | Region | Published URL | SSH alias |"
        echo "|---|---|---|---|---|"
        # Tabs are IFS whitespace and would collapse across empty fields, so read with a
        # non-whitespace separator instead.
        while IFS=$'\x1f' read -r id expires url _owner region _uuid; do
            [ -n "$id" ] || continue
            mark=""
            [ "$id" = "$current" ] && mark=" ◀ current"
            echo "| $id$mark | $(beams_expires_in "$expires") | ${region:-—} | ${url:-—} | $BEAMS_SSH_USER@$(beams_ssh_host "$id") |"
        done <<<"$(printf '%s\n' "$tsv" | tr '\t' '\037')"
    fi
    echo
    echo "SSH aliases are written to ~/.ssh/config when you first browse a beam; BBEdit’s SFTP browser uses them."
} | beams_show "Teleport Beams — Status" "Markdown"
