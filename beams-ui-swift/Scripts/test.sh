#!/bin/sh
# Runs the Swift Testing suite with only the Command Line Tools installed.
# SwiftPM's default backend doesn't pass the Testing macro plugin path, so
# we point the compiler at it explicitly (harmless when Xcode is present).
set -eu
cd "$(dirname "$0")/.."
PLUGINS="$(xcrun --find swift 2>/dev/null | sed 's|/bin/swift$||')/lib/swift/host/plugins/testing"
[ -d "$PLUGINS" ] || PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
