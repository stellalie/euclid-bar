# euclid-bar

AppKit macOS launcher. Building the app needs macOS; on Linux run `scripts/test-core-linux.sh`
(EuclidCore tests only). The macOS `CI` check is the real build gate; Xcode Cloud runs the same
checks from `XcodeCloud/` (see its README).

## Shipping

- Merge your own pull request once its CI checks are green (Stella's standing approval, 2026-10-24).
  Each merge to `main` becomes a signed dev build (`[updates] channel = "dev"`); see `docs/RELEASING.md`.
- Push a `v*` tag only when Stella asks for a release: it publishes a stable version to everyone.
