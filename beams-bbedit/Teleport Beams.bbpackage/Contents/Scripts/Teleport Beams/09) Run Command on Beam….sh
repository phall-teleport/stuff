#!/bin/bash
# Teleport Beams — Run Command on Beam…
# Runs one shell command on the current beam and shows its output in a new document.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_require) || exit 1
last_file="$BEAMS_CONFIG_DIR/last-command"
default=""
[ -f "$last_file" ] && default=$(cat "$last_file")

cmd=$(beams_ask "Command to run on beam “$id” (runs in a login shell from $BEAMS_HOME):" "$default") || { echo "Cancelled."; exit 0; }
[ -n "$cmd" ] || { echo "No command entered."; exit 0; }
printf '%s' "$cmd" >"$last_file"

start=$(date +%s)
output=$(beams_tsh_raw beams exec "$id" -- "cd $BEAMS_HOME && $cmd" 2>&1)
rc=$?
end=$(date +%s)

{
    echo "\$ $cmd"
    echo "# beam: $id · exit status: $rc · $((end - start))s"
    echo
    printf '%s\n' "$output" | beams_strip_ansi
} | beams_show "$id: $cmd" "Log File"
