#!/bin/bash
# Teleport Beams — Open File on Beam…
# Opens a single remote file over SFTP. Relative paths are taken from /home/beams.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_require) || exit 1
remote=$(beams_ask "Path of the file to open on beam “$id”:" "$BEAMS_HOME/") || exit 0
remote=$(printf '%s' "$remote" | sed 's/[[:space:]]*$//')
[ -n "$remote" ] || exit 0
case "$remote" in
    /*) ;;
    *) remote="$BEAMS_HOME/$remote" ;;
esac

url=$(beams_sftp_url "$id" "$remote") || exit 1
beams_open_url "$url"
