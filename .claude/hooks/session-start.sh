#!/bin/bash
# Claude Code cloud sessions only: install a Linux Swift toolchain and zsh so
# EuclidCore can be built and tested there (scripts/test-core-linux.sh).
# Idempotent; a no-op on your Mac.
set -euo pipefail
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

SWIFT_VERSION=6.4.1
if [ ! -x /opt/swift/usr/bin/swift ] || ! /opt/swift/usr/bin/swift --version 2>/dev/null | grep -q "$SWIFT_VERSION"; then
  . /etc/os-release
  platform="ubuntu${VERSION_ID//./}"
  rm -rf /opt/swift && mkdir -p /opt/swift
  curl -fsSL "https://download.swift.org/swift-$SWIFT_VERSION-release/$platform/swift-$SWIFT_VERSION-RELEASE/swift-$SWIFT_VERSION-RELEASE-$ID$VERSION_ID.tar.gz" \
    | tar xz -C /opt/swift --strip-components=1
fi
ln -sf /opt/swift/usr/bin/* /usr/local/bin/

# CommandRunner and its tests run actions through /bin/zsh, as on macOS.
[ -x /bin/zsh ] || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq -o Dpkg::Options::=--force-confold zsh >/dev/null; }

swift --version
