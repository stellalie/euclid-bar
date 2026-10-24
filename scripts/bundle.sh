#!/usr/bin/env bash
# Build euclid-bar.app from the SwiftPM executable.
# Usage: scripts/bundle.sh [release|debug]
#   UNIVERSAL=1  build for Apple Silicon + Intel
#   VERSION=x.y  stamp the bundle version (default: Resources/Info.plist)
#   SIGN_IDENTITY="Developer ID Application: …"  release signing (hardened runtime + timestamp)
#   SPARKLE_PUBLIC_KEY=…  turn on auto-update (EdDSA public key from Sparkle's generate_keys)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
ARCH=()
[[ "${UNIVERSAL:-}" == 1 ]] && ARCH=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" ${ARCH[@]+"${ARCH[@]}"}
BIN="$(swift build -c "$CONFIG" ${ARCH[@]+"${ARCH[@]}"} --show-bin-path)"

APP="build/euclid-bar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/euclid-bar" "$APP/Contents/MacOS/euclid-bar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  plutil -insert SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
fi
if [[ -n "${VERSION:-}" ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi
# SwiftPM resource bundles (e.g. KeyboardShortcuts localizations)
find "$BIN" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

# Sparkle (auto-update). SwiftPM finds it via @loader_path; the bundle needs ../Frameworks.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/euclid-bar"

# Release: Developer ID + hardened runtime + secure timestamp, as notarization requires.
# Dev: the stable "Euclid Dev" identity if present (scripts/make-dev-cert.sh), so macOS
# keeps the Accessibility grant across rebuilds; else ad-hoc, which changes every build
# and makes macOS re-ask for permission.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$SIGN_IDENTITY"
  FLAGS=(--force --options runtime --timestamp)
else
  IDENTITY="-"
  if security find-certificate -c "Euclid Dev" >/dev/null 2>&1; then IDENTITY="Euclid Dev"; fi
  FLAGS=(--force)
fi
# Inside out, never --deep (Sparkle's documented order; Downloader keeps its own entitlements).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${FLAGS[@]}" --sign "$IDENTITY" "$SPARKLE/XPCServices/Installer.xpc"
codesign "${FLAGS[@]}" --sign "$IDENTITY" --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
codesign "${FLAGS[@]}" --sign "$IDENTITY" "$SPARKLE/Autoupdate"
codesign "${FLAGS[@]}" --sign "$IDENTITY" "$SPARKLE/Updater.app"
codesign "${FLAGS[@]}" --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${FLAGS[@]}" --sign "$IDENTITY" --entitlements Resources/euclid-bar.entitlements "$APP"
echo "$APP (signed: $IDENTITY)"
