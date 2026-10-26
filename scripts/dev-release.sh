#!/usr/bin/env bash
# Build, sign, notarize and publish main to the rolling `dev` pre-release in euclid-bar-releases.
# Run by Xcode Cloud on each push to main (XcodeCloud/ci_scripts/ci_post_clone.sh), or by hand
# from Actions (.github/workflows/dev-release.yml). Needs full history and tags.
# Env: what scripts/release.sh takes, plus GH_TOKEN (RELEASES_TOKEN: Contents write on the releases repo).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=stellalie/euclid-bar-releases

# "1.1.0-dev.214": the last release (or Info.plist) plus the build number.
BASE="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
VERSION="${BASE#v}-dev.$(git rev-list --count HEAD)"
RELEASE_TAG=dev SKIP_TESTS=1 scripts/release.sh "$VERSION" # CI just tested this commit

# Never publish an un-notarized build. Apple's ticket lookup drops connections now and then, so retry.
for wait in 10 20 40 0; do
  xcrun stapler validate build/release/*.dmg && break
  [[ $wait == 0 ]] && exit 1
  sleep "$wait"
done
[[ -f build/release/appcast.xml ]] || { echo "No appcast.xml: set SPARKLE_PRIVATE_KEY" >&2; exit 1; }
gh release view dev --repo "$REPO" >/dev/null 2>&1 ||
  gh release create dev --repo "$REPO" --prerelease --target main --title "Dev build" --notes "Rolling build of main."
# The new archive goes up before the feed that points at it.
gh release upload dev --repo "$REPO" --clobber build/release/*.zip build/release/*.dmg
gh release upload dev --repo "$REPO" --clobber build/release/appcast.xml
for asset in $(gh release view dev --repo "$REPO" --json assets -q '.assets[].name'); do
  case "$asset" in appcast.xml|"Euclid-$VERSION".*) ;; *) gh release delete-asset dev "$asset" --repo "$REPO" --yes ;; esac
done
gh release edit dev --repo "$REPO" --title "Dev build $VERSION" \
  --notes "Euclid $VERSION, built from main @ $(git rev-parse --short HEAD). For testing: set \`[updates] channel = \"dev\"\` to get these automatically."
echo "Published dev build $VERSION"
