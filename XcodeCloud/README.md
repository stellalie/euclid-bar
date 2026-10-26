# Xcode Cloud

Runs the same checks as the GitHub `CI` and `UI screens` workflows on Xcode Cloud, and publishes
the signed dev build on each push to `main` and the stable release on each `v*` tag. It comes with the Apple Developer Program
(25 compute hours a month) and doesn't use GitHub Actions minutes.

Xcode Cloud can't build a standalone Swift package, so:

- `EuclidCI.xcodeproj` builds a placeholder app (`EuclidCI/main.swift`) that the workflow needs.
- `ci_scripts/ci_post_clone.sh` runs before that build and does the real work:
  `swift build`, `swift test`, bundle + verify `Euclid.app`; on PRs that touch search code, the
  speed budget (`--speed-budget`: every keystroke over 10k+ items under 8 ms, release build); and on
  PRs that touch `Sources/EuclidBar`, the UI screens (`--render-screens`, `--render-demo`). On pushes to `main`
  and `v*` tags it then runs `scripts/publish-release.sh`: signed, notarized, uploaded to the
  `dev` pre-release or the tag's release (see `docs/RELEASING.md`).

## One-time setup (~15 min, on a Mac)

1. Open `XcodeCloud/EuclidCI.xcodeproj` in Xcode 16 or later.
2. **Product › Xcode Cloud › Create Workflow…**, pick the **EuclidCI** product, sign in with the
   Apple Developer account, and let it create the app record (bundle ID `dev.euclid.ci`; any
   name, e.g. "Euclid CI": it's never published).
3. Grant access to GitHub when asked: it installs Apple's Xcode Cloud app on `stellalie/euclid-bar`.
4. Edit the workflow (name it `CI`):
   - **Environment:** Xcode = *Latest Release*, macOS = *Latest Release*.
   - **Start conditions:** *Branch Changes* on `main`, and *Pull Request Changes* from any branch into `main`.
   - **Actions:** one *Build* action, scheme **EuclidCI**, platform macOS. Remove any Test/Archive action.
5. Optional, for screenshots on PRs: GitHub › Settings › Developer settings › Fine-grained tokens ›
   new token for `euclid-bar` with **Contents: Read and write**. In the workflow's
   **Environment › Environment Variables** add `GITHUB_SCREENS_TOKEN` with it, ticked **Secret**.
6. Save and **Start Build** on this branch (or `main` once merged). It should show as a `CI | Build - macOS` check on GitHub.

Results: Xcode › Report navigator › Cloud, or App Store Connect › the app › Xcode Cloud.

## Release secrets

Add these in the workflow's **Environment › Environment Variables**, each ticked **Secret**. They're
the values behind the GitHub Actions secrets of the same names (`docs/RELEASING.md`, one-time setup);
GitHub can't show those again, so take them from where you made them. Until `RELEASES_TOKEN` is set,
`main` builds skip the dev build and tag builds fail.

| Name | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | `base64 -i DeveloperID.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `NOTARY_KEY_P8` | the `AuthKey_XXXX.p8` text (line breaks may be lost; fine), or `base64 -i` of it |
| `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | from App Store Connect › Integrations › Keys |
| `SPARKLE_PRIVATE_KEY` | `generate_keys -x sparkle.key`, then the file's contents |
| `SPARKLE_PUBLIC_KEY`, `LICENCE_PUBLIC_KEY` | the public keys (not secret, but tick Secret anyway) |
| `RELEASES_TOKEN` | fine-grained token, *Contents: Read and write* on `euclid-bar-releases` |

Or put them all in one secret, `EUCLID_RELEASE_SECRETS`: base64 of gzipped `NAME=<base64 of value>`
lines, one per variable above:

```sh
for n in MACOS_CERTIFICATE_P12 …; do printf '%s=%s\n' "$n" "$(printf '%s' "${(P)n}" | base64)"; done | gzip | base64 | pbcopy
```

The workflow's start conditions must include *Branch Changes* on `main` and *Tag Changes* matching `v*`.

