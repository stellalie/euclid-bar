#!/usr/bin/env bash
# Build, sign, notarize and publish to stellalie/euclid-bar-releases (the source repo is private).
# Usage: scripts/publish-release.sh          main → the rolling `dev` pre-release (1.2.0-dev.214)
#        scripts/publish-release.sh v1.2.1   stable release v1.2.1 + the appcast every app reads
# Run by Xcode Cloud (XcodeCloud/ci_scripts/ci_post_clone.sh) on pushes to main and v* tags, or by
# hand from Actions (.github/workflows/dev-release.yml). Needs full history and tags, and CI to have
# tested this commit. Env: what scripts/release.sh takes, plus GH_TOKEN (RELEASES_TOKEN: Contents
# write on the releases repo).
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=stellalie/euclid-bar-releases
TAG="${1:-}"

if [[ -n "$TAG" ]]; then
  [[ "$TAG" == v* ]] || { echo "usage: $0 [v<version>]" >&2; exit 1; }
  VERSION="${TAG#v}"
  RELEASE_TAG="$TAG"
else
  # "1.1.0-dev.214": the last release (or Info.plist) plus the build number.
  BASE="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
  BUILD="$(git rev-list --count HEAD)"
  VERSION="${BASE#v}-dev.$BUILD"
  RELEASE_TAG=dev
fi

# Xcode Cloud runs builds in parallel, so an older commit can finish last. Never replace a newer
# (or the same) dev build.
superseded() {
  [[ -z "$TAG" ]] || return 1
  local title published
  title="$(gh release view dev --repo "$REPO" --json name -q .name 2>/dev/null || true)"
  published="${title##*-dev.}"
  if [[ "$published" =~ ^[0-9]+$ ]] && (( published >= BUILD )); then
    echo "Dev release already has build $published; not publishing $VERSION"
    return 0
  fi
  return 1
}
superseded && exit 0

RELEASE_TAG="$RELEASE_TAG" SKIP_TESTS=1 scripts/release.sh "$VERSION"

# Never publish an un-notarized build. Apple's ticket lookup drops connections now and then, so retry.
for wait in 10 20 40 0; do
  xcrun stapler validate build/release/*.dmg && break
  [[ $wait == 0 ]] && exit 1
  sleep "$wait"
done
# The .pkg ships only signed + notarized (needs the Developer ID Installer certificate,
# scripts/ci-signing.sh). Until then releases go out without it.
pkg=(build/release/*.pkg)
if [[ -e "${pkg[0]}" ]] && ! { pkgutil --check-signature "${pkg[0]}" | grep -q 'Developer ID Installer' && xcrun stapler validate "${pkg[0]}"; }; then
  echo "warning: $(basename "${pkg[0]}") isn't signed and notarized; publishing without it" >&2
  rm -f build/release/*.pkg
fi
[[ -f build/release/appcast.xml ]] || { echo "No appcast.xml: set SPARKLE_PRIVATE_KEY" >&2; exit 1; }
superseded && exit 0 # a newer build may have landed while this one notarized
# shellcheck disable=SC2207 # file names have no spaces
assets=($(ls build/release/*.dmg build/release/*.zip build/release/*.pkg 2>/dev/null))

if [[ -n "$TAG" ]]; then
  gh release create "$TAG" --repo "$REPO" --title "Euclid $VERSION" --notes "Euclid $VERSION for macOS 14+ (Apple Silicon + Intel)." \
    "${assets[@]}" build/release/appcast.xml
  echo "Published Euclid $VERSION"
  scripts/bump-cask.sh "$VERSION" "build/release/Euclid-$VERSION.zip" # Homebrew follows stable only
  exit 0
fi

gh release view dev --repo "$REPO" >/dev/null 2>&1 ||
  gh release create dev --repo "$REPO" --prerelease --target main --title "Dev build" --notes "Rolling build of main."
# The new archive goes up before the feed that points at it.
gh release upload dev --repo "$REPO" --clobber "${assets[@]}"
gh release upload dev --repo "$REPO" --clobber build/release/appcast.xml
for asset in $(gh release view dev --repo "$REPO" --json assets -q '.assets[].name'); do
  case "$asset" in appcast.xml|"Euclid-$VERSION".*) ;; *) gh release delete-asset dev "$asset" --repo "$REPO" --yes ;; esac
done
gh release edit dev --repo "$REPO" --title "Dev build $VERSION" \
  --notes "Euclid $VERSION, built from main @ $(git rev-parse --short HEAD). For testing: set \`[updates] channel = \"dev\"\` to get these automatically."
echo "Published dev build $VERSION"
