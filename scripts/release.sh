#!/usr/bin/env bash
# Build, sign, notarize and package a release.
# Usage: scripts/release.sh 1.2.0
#   → build/release/euclid-bar-1.2.0.dmg   (download from the website / GitHub release)
#     build/release/euclid-bar-1.2.0.zip   (Sparkle update archive)
#     build/release/appcast.xml            (Sparkle feed, attached to the GitHub release)
#
# Env (all optional; without them you get a locally signed, un-notarized build):
#   SIGN_IDENTITY       "Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE      notarytool keychain profile (xcrun notarytool store-credentials), or
#   NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID   App Store Connect API key
#   SPARKLE_PUBLIC_KEY  turns on auto-update in the app
#   SPARKLE_PRIVATE_KEY signs the update archive and writes appcast.xml
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version>}"
OUT="build/release"
APP="build/euclid-bar.app"
REPO_URL="https://github.com/stellalie/euclid-bar-releases" # public: downloads + Sparkle feed (source repo is private)

notarize() { # <file>
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
  else
    return 1
  fi
}
can_notarize() { [[ -n "${SIGN_IDENTITY:-}" && ( -n "${NOTARY_PROFILE:-}" || -n "${NOTARY_KEY_PATH:-}" ) ]]; }

scripts/check-toolchain.sh
swift test
UNIVERSAL=1 VERSION="$VERSION" scripts/bundle.sh release
lipo -info "$APP/Contents/MacOS/euclid-bar"
codesign --verify --strict --deep "$APP" && echo "signature ok"

rm -rf "$OUT" && mkdir -p "$OUT"
ZIP="$OUT/euclid-bar-$VERSION.zip"
DMG="$OUT/euclid-bar-$VERSION.dmg"

# 1. Notarize the app itself and staple the ticket, so it opens offline on first launch.
if can_notarize; then
  ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
  notarize "$OUT/notarize.zip"
  rm "$OUT/notarize.zip"
  xcrun stapler staple "$APP"
else
  echo "warning: not notarized (set SIGN_IDENTITY and notary credentials)" >&2
fi

# 2. Sparkle update archive (ditto keeps the signature and stapled ticket intact).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 3. Drag-to-Applications disk image, signed and notarized on its own.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/euclid-bar.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "euclid-bar" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
if can_notarize; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

# 4. Sparkle feed: signs the zip with the EdDSA key and points at this release's assets.
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  TOOLS="$(dirname "$(find .build/artifacts -type f -name generate_appcast -path '*Sparkle*' | head -1)")"
  [[ -x "$TOOLS/generate_appcast" ]] || { echo "error: Sparkle's generate_appcast not found under .build/artifacts" >&2; exit 1; }
  FEED="$(mktemp -d)"
  cp "$ZIP" "$FEED/"
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$TOOLS/generate_appcast" --ed-key-file - \
    --download-url-prefix "$REPO_URL/releases/download/v$VERSION/" --link "$REPO_URL" "$FEED"
  cp "$FEED/appcast.xml" "$OUT/appcast.xml"
  rm -rf "$FEED"
fi

shasum -a 256 "$OUT"/*.zip "$OUT"/*.dmg
ls -l "$OUT"
