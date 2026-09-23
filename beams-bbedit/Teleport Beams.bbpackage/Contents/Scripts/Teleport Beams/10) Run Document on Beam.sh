#!/bin/bash
# Teleport Beams — Run Document on Beam
# Streams the front document to the current beam and runs it with the interpreter named
# in its #! line (falls back to bash). Output opens in a new document.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

if [ -n "${BB_DOC_PATH:-}" ] && [ -f "$BB_DOC_PATH" ]; then
    content=$(cat "$BB_DOC_PATH"; printf x); content=${content%x}
    name="${BB_DOC_NAME:-$(basename "$BB_DOC_PATH")}"
else
    content=$(osascript 2>/dev/null <<'EOF'
tell application "BBEdit"
    if (count of text documents) is 0 then error "no document"
    return contents of front text document as text
end tell
EOF
    ) || { beams_die "No document is open to run."; exit 1; }
    name="${BB_DOC_NAME:-untitled}"
fi

if [ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ]; then
    beams_die "The document is empty."
    exit 1
fi

first=$(printf '%s\n' "$content" | head -1)
case "$first" in
    '#!'*python*) interp="python3 -" ;;
    '#!'*node*)   interp="node -" ;;
    '#!'*ruby*)   interp="ruby -" ;;
    '#!'*perl*)   interp="perl -" ;;
    '#!'*zsh*)    interp="zsh -s" ;;
    '#!'*sh*)     interp="bash -s" ;;
    *)
        case "${BB_DOC_LANGUAGE:-}" in
            Python*) interp="python3 -" ;;
            JavaScript*) interp="node -" ;;
            Ruby*) interp="ruby -" ;;
            Perl*) interp="perl -" ;;
            *) interp="bash -s" ;;
        esac
        ;;
esac

id=$(beams_require) || exit 1
start=$(date +%s)
output=$(printf '%s\n' "$content" | beams_tsh_raw beams exec "$id" -- "cd $BEAMS_HOME && $interp" 2>&1)
rc=$?
end=$(date +%s)

{
    echo "# $name → $interp on beam $id · exit status: $rc · $((end - start))s"
    echo
    printf '%s\n' "$output" | beams_strip_ansi
} | beams_show "$id: $name" "Log File"
