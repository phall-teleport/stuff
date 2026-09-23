#!/bin/bash
# Teleport Beams — Run on Beam (Replace with Output)  [Text Filter]
# BBEdit pipes the selection (or whole document) in on stdin; whatever we print replaces it.
# The text is run as a bash script on the current beam. If anything goes wrong before the
# command runs, the original text is echoed back unchanged so nothing is lost.
input=$(cat; printf x); input=${input%x}

source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || { printf '%s' "$input"; exit 0; }

if [ -z "$(printf '%s' "$input" | tr -d '[:space:]')" ]; then
    printf '%s' "$input"
    exit 0
fi

id=$(beams_require) || { printf '%s' "$input"; exit 0; }

output=$(printf '%s\n' "$input" | beams_tsh_raw beams exec "$id" -- "cd $BEAMS_HOME && bash -s" 2>&1)
rc=$?
if [ $rc -ne 0 ] && [ -z "$output" ]; then
    printf '%s' "$input"
    beams_die "Command failed on beam “$id” with exit status $rc and produced no output; selection left unchanged."
    exit 0
fi
printf '%s' "$output" | beams_strip_ansi
