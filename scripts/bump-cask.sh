#!/usr/bin/env bash
# Point the Homebrew cask (Casks/euclid.rb in stellalie/euclid-bar-releases) at a stable release.
# Usage: scripts/bump-cask.sh 1.4.1 build/release/Euclid-1.4.1.zip
# Run by scripts/publish-release.sh after a stable release; safe to re-run by hand. Needs GH_TOKEN
# with Contents write on the releases repo (RELEASES_TOKEN).
set -euo pipefail
VERSION="${1:?usage: scripts/bump-cask.sh <version> <zip>}"
ZIP="${2:?usage: scripts/bump-cask.sh <version> <zip>}"
REPO=stellalie/euclid-bar-releases
CASK=Casks/euclid.rb

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "not a stable version: $VERSION" >&2; exit 1; }
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
BLOB="$(gh api "repos/$REPO/contents/$CASK" -q .sha)"
OLD="$(gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/$CASK")"
NEW="$(sed -E -e "s/^  version \"[^\"]*\"/  version \"$VERSION\"/" \
              -e "s/^  sha256 \"[^\"]*\"/  sha256 \"$SHA\"/" <<<"$OLD")"
grep -q "^  version \"$VERSION\"$" <<<"$NEW" && grep -q "^  sha256 \"$SHA\"$" <<<"$NEW" ||
  { echo "$CASK: couldn't find the version/sha256 lines" >&2; exit 1; }
[[ "$NEW" != "$OLD" ]] || { echo "Cask already at $VERSION"; exit 0; }

gh api -X PUT "repos/$REPO/contents/$CASK" -f message="Cask: Euclid $VERSION" -f sha="$BLOB" \
  -f content="$(printf '%s\n' "$NEW" | base64 | tr -d '\n')" >/dev/null
echo "Cask now at $VERSION ($SHA)"
