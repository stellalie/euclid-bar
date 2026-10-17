#!/usr/bin/env bash
# Fail early, with a fix, when the active Swift toolchain is older than Swift 6.
# Package.swift uses swift-tools-version 6.0, which needs Xcode 16+ (or matching Command Line Tools).
set -euo pipefail

REQUIRED=6

fail() {
  echo "error: $1" >&2
  echo >&2
  echo "Euclid needs Swift $REQUIRED or newer (Xcode 16+) on macOS 14+." >&2
  echo "Active developer directory: $(xcode-select -p 2>/dev/null || echo 'none')" >&2
  XCODES="$(ls -d /Applications/Xcode*.app 2>/dev/null || true)"
  if [[ -n "$XCODES" ]]; then
    echo "Installed Xcode apps:" >&2
    echo "$XCODES" | sed 's/^/  /' >&2
  fi
  echo >&2
  echo "Fix it with one of:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app                          # switch for good" >&2
  echo "  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make run     # this build only, no sudo" >&2
  echo "  xcode-select --install                                                # update Command Line Tools" >&2
  echo >&2
  echo "Or skip building: download the app from https://github.com/stellalie/euclid-bar/releases/latest" >&2
  exit 1
}

command -v swift >/dev/null 2>&1 || fail "swift not found on PATH."

VERSION_LINE="$(swift --version 2>&1 | grep -Eo 'Swift version [0-9]+(\.[0-9]+)*' | head -1 || true)"
[[ -n "$VERSION_LINE" ]] || fail "could not read the Swift version from 'swift --version'."
VERSION="${VERSION_LINE#Swift version }"
MAJOR="${VERSION%%.*}"
(( MAJOR >= REQUIRED )) || fail "found Swift $VERSION."
