#!/bin/sh
# Builds the release binary with SwiftPM and assembles a signed Beams.app.
# Usage: Scripts/bundle.sh [debug|release]   (default: release)
#
# Versioning: VERSION holds the marketing version (e.g. 0.1.0, edit by hand);
# BUILD_NUMBER is incremented on every successful build, so the About panel
# shows e.g. "Version 0.1.0 (2)". Both files are committed.
set -eu
cd "$(dirname "$0")/.."
CONF="${1:-release}"
APP="build/Beams.app"
ICON_PNG="Resources/appicon.png"
mkdir -p build

# Fail on compile errors instead of bundling a stale binary from a previous build.
if ! swift build -c "$CONF" > build/swift-build.log 2>&1; then
  grep -E 'error' build/swift-build.log | grep -v '^\s*|' | sed 's/\x1b\[[0-9;]*m//g' | sort -u >&2 || cat build/swift-build.log >&2
  echo "build failed; see build/swift-build.log" >&2
  exit 1
fi
BIN="$(swift build -c "$CONF" --show-bin-path)/Beams"
[ -x "$BIN" ] || { echo "build failed: $BIN missing" >&2; exit 1; }

VERSION="$(tr -d ' \n' < VERSION 2>/dev/null || true)"; [ -n "$VERSION" ] || VERSION="0.1.0"
BUILD="$(tr -d ' \n' < BUILD_NUMBER 2>/dev/null || true)"
case "$BUILD" in ''|*[!0-9]*) BUILD=0 ;; esac
BUILD=$((BUILD + 1))
echo "$BUILD" > BUILD_NUMBER

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Beams"

# Icon: build an .icns from the full-bleed 1024px PNG (macOS 26 masks it itself).
if [ -f "$ICON_PNG" ]; then
  ICONSET="build/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2)); sips -z $d $d "$ICON_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Beams</string>
  <key>CFBundleDisplayName</key><string>Beams</string>
  <key>CFBundleIdentifier</key><string>com.teleport.beams.native</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Beams</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key><string>Beams opens iTerm or Terminal to run tsh login when a cluster needs a password prompt.</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "Built $APP — version $VERSION ($BUILD)"

# Ship a committed copy for people who just want to run it.
rm -rf dist/Beams.app && mkdir -p dist && cp -R "$APP" dist/Beams.app
echo "Copied to dist/Beams.app"
