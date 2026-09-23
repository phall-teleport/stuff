#!/bin/bash
# Teleport Beams — Delete Beam…
# Deletes a beam after confirmation and removes its SSH alias.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_pick "Choose a beam to delete") || { echo "Cancelled."; exit 0; }
beams_confirm "Delete beam “$id”?

Everything on the beam is lost. This cannot be undone." "Delete" || { echo "Cancelled."; exit 0; }

beams_tsh beams rm "$id" || exit 1
beams_remove_ssh "$id"
[ "$(beams_current_id)" = "$id" ] && beams_clear_current
beams_notify "Beam “$id” deleted."
echo "Deleted beam “$id” and removed its SSH alias."
