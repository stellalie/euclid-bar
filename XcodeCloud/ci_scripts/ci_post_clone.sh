#!/bin/zsh
# Xcode Cloud entry point: build, test and bundle every commit; UI screens on PRs and UI pushes to main; then publish:
# the signed dev build on pushes to main, the stable release on v* tags. Xcode Cloud can't build a standalone Swift package, so the workflow
# builds the placeholder EuclidCI app and this script, which runs first, does the real work.
# Any failure fails the build.
#
# Optional workflow secrets (XcodeCloud/README.md):
#   GITHUB_SCREENS_TOKEN  publishes a PR's screenshots to screens/pr-<n> (main's go to euclid-bar-releases site-media, with RELEASES_TOKEN)
#   RELEASES_TOKEN + the signing secrets  publish releases (scripts/publish-release.sh)
#   EUCLID_RELEASE_SECRETS  all of those in one paste: base64 of gzipped NAME=<base64 value> lines
set -euo pipefail
cd "$CI_PRIMARY_REPOSITORY_PATH"

# Xcode Cloud's log isn't readable from GitHub: on failure, push it to the ci-logs/<branch or pr-n> branch.
ci_log="${TMPDIR:-/tmp}/euclid-ci.log"
exec > >(tee "$ci_log") 2>&1
publish_log() {
  local code=$1
  (( code != 0 )) && [[ -n "${GITHUB_SCREENS_TOKEN:-}" ]] || return 0
  sleep 1 # let tee flush
  local dir="$(mktemp -d)" branch="ci-logs/${CI_PULL_REQUEST_NUMBER:+pr-}${CI_PULL_REQUEST_NUMBER:-${CI_BRANCH:-${CI_TAG:-unknown}}}"
  tail -c 2000000 "$ci_log" > "$dir/ci.log"
  ( cd "$dir" && git init -q -b "$branch" && git add ci.log \
    && git -c user.name="Xcode Cloud" -c user.email=noreply@lgtm.ninja commit -qm "Failed CI log for ${CI_COMMIT:-?} (exit $code)" \
    && git push -qf "https://x-access-token:${GITHUB_SCREENS_TOKEN}@github.com/stellalie/euclid-bar.git" "$branch" ) || true
}
trap 'publish_log $?' EXIT

# SwiftPM sometimes trips over its own half-downloaded Sparkle zip ("... already exists in file system"):
# resolve on its own, clearing the partial download and retrying.
for attempt in 1 2 3; do
  swift package resolve --disable-dependency-cache && break
  (( attempt < 3 )) || exit 1
  echo "resolve failed (attempt $attempt); clearing partial artifacts"
  rm -rf .build/artifacts ~/Library/Caches/org.swift.swiftpm/artifacts
  sleep 5
done

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

# Pushes to main that touch the app's UI: render the screens, clips and site demo video and publish
# them to the site-media branch of euclid-bar-releases (the website's videos come from there). Never blocks the dev build.
publish_screens() { # $1 = branch [$2 = owner/repo, $3 = token]
  local repo="${2:-stellalie/euclid-bar}" token="${3:-${GITHUB_SCREENS_TOKEN:-}}"
  [[ -n "$token" ]] || { echo "No token: screens not published"; return 0; }
  (
    cd screens
    git init -q -b "$1"
    git -c user.name="Xcode Cloud" -c user.email=noreply@lgtm.ninja add .
    git -c user.name="Xcode Cloud" -c user.email=noreply@lgtm.ninja commit -qm "UI screens for ${CI_PULL_REQUEST_SOURCE_COMMIT:-$CI_COMMIT}"
    git push -qf "https://x-access-token:${token}@github.com/$repo.git" "$1"
  )
  echo "Published to $repo $1"
}
render_screens() { # chained with &&: set -e doesn't apply inside `… || echo`
  local bin
  swift build -c release && bin="$(swift build -c release --show-bin-path)" \
    && "$bin/euclid-bar" --render-screens screens && "$bin/euclid-bar" --render-demo screens/demo \
    && du -sh screens/clips screens/demo
}
if [[ -z "${CI_PULL_REQUEST_NUMBER:-}" && "${CI_BRANCH:-}" == main && -z "${CI_TAG:-}" ]] \
   && ! git diff --quiet HEAD^ HEAD -- Sources/EuclidBar XcodeCloud 2>/dev/null; then
  echo "== UI screens (main)"
  # They're the public website's media, so they go to the public releases repo with RELEASES_TOKEN.
  { render_screens && publish_screens site-media stellalie/euclid-bar-releases "${RELEASES_TOKEN:-}"; } \
    || echo "UI screens failed; the dev build goes on"
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

# PRs only from here: the speed budget when search code changes, UI screens when the app's UI does.
[[ -n "${CI_PULL_REQUEST_NUMBER:-}" ]] || exit 0
base="${CI_PULL_REQUEST_TARGET_COMMIT:-}"
changed() { # true when the PR touches any of these paths (or the base is unknown)
  [[ -z "$base" ]] || ! git cat-file -e "$base^{commit}" 2>/dev/null || ! git diff --quiet "$base"...HEAD -- "$@"
}
ui=0 search=0
changed Sources/EuclidBar XcodeCloud && ui=1
changed Sources/EuclidCore/FuzzyMatcher.swift Sources/EuclidCore/Ranking Sources/EuclidCore/Transforms \
  Sources/EuclidCore/Calculator Sources/EuclidBar/Panel XcodeCloud && search=1
(( ui || search )) || { echo "== Speed budget and UI screens: skipped, no search or UI changes"; exit 0; }

swift build -c release
bin="$(swift build -c release --show-bin-path)"
if (( search )); then
  echo "== Speed budget"
  "$bin/euclid-bar" --speed-budget # every keystroke over 10k+ items under 8 ms
fi
(( ui )) || exit 0

echo "== UI screens"
"$bin/euclid-bar" --render-screens screens
"$bin/euclid-bar" --render-demo screens/demo
du -sh screens/clips screens/demo
publish_screens "screens/pr-$CI_PULL_REQUEST_NUMBER"
