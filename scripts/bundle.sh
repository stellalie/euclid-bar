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

# Ad-hoc sign. Note: each rebuild changes the signature, so macOS will
# re-ask for Accessibility permission (needed from step 2 for paste).
codesign --force --deep --sign - "$APP"
echo "$APP"
