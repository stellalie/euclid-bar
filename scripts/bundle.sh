#!/usr/bin/env bash
# Build euclid-bar.app from the SwiftPM executable.
# Usage: scripts/bundle.sh [release|debug]
#   UNIVERSAL=1  build for Apple Silicon + Intel
#   VERSION=x.y  stamp the bundle version (default: Resources/Info.plist)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARCH=()
[[ "${UNIVERSAL:-}" == 1 ]] && ARCH=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" ${ARCH[@]+"${ARCH[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH[@]+"${ARCH[@]}"} --show-bin-path)"

APP="build/euclid-bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/euclid-bar" "$APP/Contents/MacOS/euclid-bar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${VERSION:-}" ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi
# SwiftPM resource bundles (e.g. KeyboardShortcuts localizations)
find "$BIN" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

# Sign with the stable "Euclid Dev" identity if present (scripts/make-dev-cert.sh),
# so macOS keeps the Accessibility grant across rebuilds. Fall back to ad-hoc,
# which changes every build and makes macOS re-ask for permission.
IDENTITY="-"
if security find-certificate -c "Euclid Dev" >/dev/null 2>&1; then IDENTITY="Euclid Dev"; fi
codesign --force --deep --sign "$IDENTITY" "$APP"
echo "$APP (signed: $IDENTITY)"
