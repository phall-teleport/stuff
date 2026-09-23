#!/bin/bash
# Teleport Beams — Run Selection on Beam
# Runs the selected text (or the whole document if nothing is selected) as a bash script
# on the current beam. Output opens in a new document; the selection is left untouched.
# (The Text Filter of the same name replaces the selection with the output instead.)
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

script=$(beams_selection)
if [ -z "$(printf '%s' "$script" | tr -d '[:space:]')" ]; then
    beams_die "Nothing to run: select some shell commands first."
    exit 1
fi

id=$(beams_require) || exit 1
start=$(date +%s)
output=$(printf '%s\n' "$script" | beams_tsh_raw beams exec "$id" -- "cd $BEAMS_HOME && bash -s" 2>&1)
rc=$?
end=$(date +%s)

{
    printf '%s\n' "$script" | sed 's/^/$ /'
    echo "# beam: $id · exit status: $rc · $((end - start))s"
    echo
    printf '%s\n' "$output" | beams_strip_ansi
} | beams_show "$id: selection" "Log File"
