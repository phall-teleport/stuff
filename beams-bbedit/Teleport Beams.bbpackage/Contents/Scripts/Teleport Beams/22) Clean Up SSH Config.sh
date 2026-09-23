#!/bin/bash
# Teleport Beams — Clean Up SSH Config
# Removes ~/.ssh/config aliases for beams that no longer exist, rewrites the aliases of
# live beams (picking up any format changes), and reports any alias that does not verify.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

beams_profile || exit 1
tsv=$(beams_list_tsv) || exit 1

failed=""
for id in $(python3 "$BEAMS_LIB_DIR/ssh_config.py" list --prefix "$BEAMS_HOST_PREFIX"); do
    uuid=$(printf '%s\n' "$tsv" | awk -F'\t' -v id="$id" '$1 == id { print $6 }')
    [ -n "$uuid" ] || continue
    beams_ensure_ssh "$id" "$uuid" >/dev/null || exit 1
    beams_verify_ssh "$id" || failed="$failed $id"
done
keep=$(printf '%s\n' "$tsv" | cut -f1 | paste -sd, -)
removed=$(python3 "$BEAMS_LIB_DIR/ssh_config.py" prune --keep "$keep" --prefix "$BEAMS_HOST_PREFIX") || {
    beams_die "Could not update ~/.ssh/config."
    exit 1
}
remaining=$(python3 "$BEAMS_LIB_DIR/ssh_config.py" list --prefix "$BEAMS_HOST_PREFIX" | paste -sd' ' -)

summary=""
[ -n "$failed" ] && summary="Warning — these aliases did not verify (see $BEAMS_LOG):$failed."$'\n'
echo "Aliases kept: ${remaining:-none}. Removed: ${removed:-none}.${failed:+ Failed to verify:$failed}"
if [ -z "$removed" ]; then
    beams_alert "$BEAMS_TITLE" "${summary}Nothing else to clean up. Aliases kept: ${remaining:-none}."
else
    beams_alert "$BEAMS_TITLE" "${summary}Removed stale SSH aliases for: $(printf '%s' "$removed" | paste -sd' ' -)

Aliases kept: ${remaining:-none}.
A backup was written to ~/.ssh/config.teleport-beams-bbedit.bak."
fi
