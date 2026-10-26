#!/bin/zsh
# Xcode Cloud entry point: build, test and bundle every commit; UI screens on PRs; then publish:
# the signed dev build on pushes to main, the stable release on v* tags. Xcode Cloud can't build a standalone Swift package, so the workflow
# builds the placeholder EuclidCI app and this script, which runs first, does the real work.
# Any failure fails the build.
#
# Optional workflow secrets (XcodeCloud/README.md):
#   GITHUB_SCREENS_TOKEN  publishes a PR's screenshots to the screens/pr-<n> branch
#   RELEASES_TOKEN + the signing secrets  publish releases (scripts/publish-release.sh)
#   EUCLID_RELEASE_SECRETS  all of those in one paste: base64 of gzipped NAME=<base64 value> lines
set -euo pipefail
cd "$CI_PRIMARY_REPOSITORY_PATH"

# A test reads an old helper script from git history (ConfigAndActionTests.ghosttyRunV1).
if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
  git fetch --quiet --unshallow
fi

echo "== Build"
swift build
echo "== Test"
swift test
echo "== Bundle app"
scripts/bundle.sh debug
codesign --verify --strict --deep build/Euclid.app
# Proves dyld finds Sparkle.framework inside the bundle (exits after rendering).
build/Euclid.app/Contents/MacOS/euclid-bar --render-icon "${TMPDIR:-/tmp}/icon.icns"

# One-paste form of the release secrets (XcodeCloud/README.md); separate variables still work.
if [[ -n "${EUCLID_RELEASE_SECRETS:-}" ]]; then
  while IFS='=' read -r name value; do
    [[ -n "$name" ]] && export "$name=$(printf '%s' "$value" | base64 --decode)"
  done < <(printf '%s' "$EUCLID_RELEASE_SECRETS" | base64 --decode | gunzip)
fi

# Releases: a v* tag publishes that stable version; a push to main, the dev build.
if [[ "${CI_TAG:-}" == v* ]]; then
  release=("$CI_TAG")
elif [[ -z "${CI_PULL_REQUEST_NUMBER:-}" && "${CI_BRANCH:-}" == main ]]; then
  release=()
fi
if (( ${+release} )); then
  [[ -n "${RELEASES_TOKEN:-}" ]] || { echo "== Release: skipped, no RELEASES_TOKEN"; [[ -z "${CI_TAG:-}" ]]; exit; }
  echo "== Release ${CI_TAG:-dev}"
  git fetch --quiet --tags
  command -v gh >/dev/null || brew install --quiet gh
  signing="$(mktemp -d)"
  touch "$signing/env"
  RUNNER_TEMP="$signing" GITHUB_ENV="$signing/env" P12="${MACOS_CERTIFICATE_P12:-}" \
    P12_PASSWORD="${MACOS_CERTIFICATE_PASSWORD:-}" NOTARY_KEY_P8="${NOTARY_KEY_P8:-}" scripts/ci-signing.sh
  while IFS= read -r line; do export "$line"; done < "$signing/env" # SIGN_IDENTITY, NOTARY_KEY_PATH
  GH_TOKEN="$RELEASES_TOKEN" scripts/publish-release.sh "${release[@]}"
  exit 0
fi

# UI screens: PRs that touch the app's UI code (or this setup) only, like screens.yml.
[[ -n "${CI_PULL_REQUEST_NUMBER:-}" ]] || exit 0
base="${CI_PULL_REQUEST_TARGET_COMMIT:-}"
if [[ -n "$base" ]] && git cat-file -e "$base^{commit}" 2>/dev/null &&
   git diff --quiet "$base"...HEAD -- Sources/EuclidBar XcodeCloud; then
  echo "== UI screens: skipped, no UI changes"
  exit 0
fi

echo "== UI screens"
swift build -c release
bin="$(swift build -c release --show-bin-path)"
"$bin/euclid-bar" --render-screens screens
"$bin/euclid-bar" --render-demo screens/demo
du -sh screens/clips screens/demo

[[ -n "${GITHUB_SCREENS_TOKEN:-}" ]] || { echo "No GITHUB_SCREENS_TOKEN: screens not published"; exit 0; }
branch="screens/pr-$CI_PULL_REQUEST_NUMBER"
cd screens
git init -q -b "$branch"
git -c user.name="Xcode Cloud" -c user.email=noreply@euclid.lgtmworks.com add .
git -c user.name="Xcode Cloud" -c user.email=noreply@euclid.lgtmworks.com commit -qm "UI screens for ${CI_PULL_REQUEST_SOURCE_COMMIT:-$CI_COMMIT}"
git push -qf "https://x-access-token:${GITHUB_SCREENS_TOKEN}@github.com/stellalie/euclid-bar.git" "$branch"
echo "Published to $branch"
