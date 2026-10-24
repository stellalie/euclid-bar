#!/usr/bin/env bash
# Build and test EuclidCore on Linux (e.g. a Claude Code cloud session).
# Works on a scratch copy so the repo is untouched: drops the AppKit app target and
# swaps CryptoKit (Apple-only) for swift-crypto, which has the same API.
# Usage: scripts/test-core-linux.sh [repo-dir] [extra swift test args...]
set -euo pipefail
SRC=$(cd "${1:-.}" && pwd); shift || true
WORK=${EUCLID_LINUX_WORK:-/tmp/euclid-core-linux/$(basename "$SRC")}

mkdir -p "$WORK"
rm -rf "$WORK/Sources" "$WORK/Tests"
# .git is kept: a test reads an old script version from git history.
(cd "$SRC" && tar cf - --exclude=./.build .) | tar xf - -C "$WORK"
cd "$WORK"

python3 - <<'PY'
import re
p = open("Package.swift").read()
p = re.sub(r'\n\s*\.package\(url: "https://github.com/sindresorhus/KeyboardShortcuts"[^\n]*', '', p)
p = re.sub(r'\n\s*\.package\(url: "https://github.com/sparkle-project/Sparkle"[^\n]*', '', p)
p = p.replace('dependencies: [\n', 'dependencies: [\n        .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0"),\n', 1)
p = re.sub(r'\n\s*\.executableTarget\(\s*name: "euclid-bar".*?\),', '', p, flags=re.S)
p = p.replace('.product(name: "GRDB", package: "GRDB.swift"),',
              '.product(name: "GRDB", package: "GRDB.swift"),\n                .product(name: "Crypto", package: "swift-crypto"),', 1)
open("Package.swift", "w").write(p)
PY
rm -f Package.resolved
grep -rl '^import CryptoKit$' Sources Tests | xargs -r sed -i 's/^import CryptoKit$/import Crypto/'

swift test "$@"
