#!/bin/zsh
# Xcode Cloud entry point: the same checks as .github/workflows/ci.yml and screens.yml.
# Xcode Cloud can't build a standalone Swift package, so the workflow builds the placeholder
# EuclidCI app and this script, which runs first, does the real work. Any failure fails the build.
#
# Optional workflow secret GITHUB_SCREENS_TOKEN (fine-grained, Contents: write on euclid-bar):
# publishes the PR's screenshots to the screens/pr-<n> branch, like the GitHub render check.
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
