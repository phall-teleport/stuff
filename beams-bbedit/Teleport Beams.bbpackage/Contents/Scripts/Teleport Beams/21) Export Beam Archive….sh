#!/bin/bash
# Teleport Beams — Export Beam Archive…
# Tars a directory on the current beam (excluding node_modules, .git and .claude), copies
# it to ~/Downloads with tsh beams scp, and reveals it in the Finder.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_require) || exit 1
remote=$(beams_ask "Directory on beam “$id” to export:" "$BEAMS_HOME") || exit 0
remote=$(printf '%s' "$remote" | sed 's/[[:space:]]*$//; s#/*$##')
[ -n "$remote" ] || remote="$BEAMS_HOME"
case "$remote" in
    /*) ;;
    *) remote="$BEAMS_HOME/$remote" ;;
esac

stamp=$(date +%Y%m%d-%H%M%S)
local_path="$HOME/Downloads/$id-export-$stamp.tar.gz"
remote_archive="/tmp/beam-export-$stamp.tar.gz"
q_remote=$(beams_shell_quote "$remote")

beams_notify "Archiving $remote…" "$id"
if ! beams_exec "$id" "tar -czf $remote_archive --exclude=./node_modules --exclude=./.git --exclude=./.claude -C $q_remote ." >/dev/null; then
    exit 1
fi

beams_notify "Downloading archive…" "$id"
if ! beams_tsh beams scp -q "$id:$remote_archive" "$local_path" >/dev/null; then
    beams_exec "$id" "rm -f $remote_archive" >/dev/null 2>&1
    exit 1
fi
beams_exec "$id" "rm -f $remote_archive" >/dev/null 2>&1

size=$(du -h "$local_path" | cut -f1 | tr -d ' ')
echo "Exported $remote from “$id” to $local_path ($size)."
choice=$(beams_choose_button "Exported $remote from beam “$id” ($size):

$local_path" "OK" "Reveal in Finder") || exit 0
[ "$choice" = "Reveal in Finder" ] && open -R "$local_path"
exit 0
