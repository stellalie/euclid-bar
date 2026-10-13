#!/usr/bin/env bash
# Build Euclid.app from the SwiftPM executable.
# Usage: scripts/bundle.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/Euclid.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Euclid" "$APP/Contents/MacOS/Euclid"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SwiftPM resource bundles (e.g. KeyboardShortcuts localizations)
find "$BIN" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

# Sign with the stable "Euclid Dev" identity if present (scripts/make-dev-cert.sh),
# so macOS keeps the Accessibility grant across rebuilds. Fall back to ad-hoc,
# which changes every build and makes macOS re-ask for permission.
IDENTITY="-"
if security find-certificate -c "Euclid Dev" >/dev/null 2>&1; then IDENTITY="Euclid Dev"; fi
codesign --force --deep --sign "$IDENTITY" "$APP"
echo "$APP (signed: $IDENTITY)"
