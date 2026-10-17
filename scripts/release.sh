#!/usr/bin/env bash
# Build a universal euclid-bar.app and zip it for a GitHub release.
# Usage: scripts/release.sh 1.1.0    → build/euclid-bar-1.1.0-macos-universal.zip
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/release.sh <version>}"

scripts/check-toolchain.sh
swift test
UNIVERSAL=1 VERSION="$VERSION" scripts/bundle.sh release
ZIP="build/euclid-bar-$VERSION-macos-universal.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/euclid-bar.app "$ZIP"   # ditto keeps the signature intact
lipo -info build/euclid-bar.app/Contents/MacOS/euclid-bar
codesign --verify --strict build/euclid-bar.app && echo "signature ok"
shasum -a 256 "$ZIP"
