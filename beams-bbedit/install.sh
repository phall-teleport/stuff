#!/bin/bash
# Installs (or uninstalls) the Teleport Beams package into BBEdit's Packages folder.
#
#   ./install.sh            copy the package into BBEdit's Packages folder (default)
#   ./install.sh --link     symlink instead (development only — BBEdit does not reliably
#                           pick up symlinked packages; use --copy / make install to test)
#   ./install.sh --uninstall
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
package="$here/Teleport Beams.bbpackage"
support="$HOME/Library/Application Support/BBEdit"
dest="$support/Packages/Teleport Beams.bbpackage"

mode="copy"
case "${1:-}" in
    --copy) mode="copy" ;;
    --link) mode="link" ;;
    --uninstall) mode="uninstall" ;;
    "") ;;
    *) echo "usage: $0 [--copy|--link|--uninstall]" >&2; exit 2 ;;
esac

if [ "$mode" = "uninstall" ]; then
    if [ -L "$dest" ] || [ -d "$dest" ]; then
        rm -rf "$dest"
        echo "Removed $dest"
    else
        echo "Not installed."
    fi
    echo "Note: SSH aliases in ~/.ssh/config were left in place; run “Clean Up SSH Config” first or"
    echo "delete the block between the “Teleport Beams (BBEdit)” markers by hand."
    exit 0
fi

if [ ! -d "$support" ]; then
    echo "BBEdit application support folder not found at: $support" >&2
    echo "Launch BBEdit once, then re-run this script." >&2
    exit 1
fi

chmod +x "$package"/Contents/Scripts/*/*.sh "$package"/Contents/Text\ Filters/*/*.sh
mkdir -p "$support/Packages"
rm -rf "$dest"
if [ "$mode" = "link" ]; then
    ln -s "$package" "$dest"
    echo "Symlinked package → $dest"
else
    cp -R "$package" "$dest"
    echo "Copied package → $dest"
fi

for tool in tsh python3; do
    if ! command -v "$tool" >/dev/null 2>&1 && [ ! -x "/Applications/Teleport Connect.app/Contents/MacOS/tsh.app/Contents/MacOS/tsh" ]; then
        echo "warning: $tool not found in PATH" >&2
    fi
done
if ! command -v bbedit >/dev/null 2>&1 && [ ! -x "/Applications/BBEdit.app/Contents/Helpers/bbedit_tool" ]; then
    echo "warning: bbedit command-line tool not found (BBEdit → Install Command Line Tools)" >&2
fi

cat <<'EOF'

Done. Quit and relaunch BBEdit (it scans the Packages folder at launch), then open the
Scripts menu (the script-icon menu right of Window) → “Teleport Beams”. The same items are in
the Scripts palette (Window → Palettes → Scripts), where you can assign keyboard shortcuts.
EOF
