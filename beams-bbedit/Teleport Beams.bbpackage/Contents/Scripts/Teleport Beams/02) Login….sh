#!/bin/bash
# Teleport Beams — Login…
# Opens a Terminal window running `tsh login --proxy=<cluster>` so the browser/MFA flow can
# complete, and remembers the cluster as BEAMS_CLUSTER so every other script pins tsh to it
# (tsh otherwise acts on whichever profile you logged in to most recently).
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

default="${BEAMS_PREFERRED_CLUSTER:-${BEAMS_CLUSTER:-example.beams.sh}}"

cluster=$(beams_ask "Teleport Beams cluster proxy address:" "$default") || { echo "Cancelled."; exit 0; }
cluster=$(printf '%s' "$cluster" | tr -d '[:space:]' | sed -E 's#^https?://##; s#/$##')
if ! printf '%s' "$cluster" | grep -qE '^[A-Za-z0-9._-]+(:[0-9]+)?$'; then
    beams_die "“$cluster” does not look like a proxy address (expected something like example.beams.sh)."
    exit 1
fi

beams_remember_cluster "${cluster%%:*}"
beams_terminal "$(beams_shell_quote "$TSH") login --proxy=$(beams_shell_quote "$cluster")"
echo "Started tsh login for $cluster in ${BEAMS_TERMINAL:-Terminal}; complete the browser/MFA flow there. Cluster remembered as BEAMS_CLUSTER."
