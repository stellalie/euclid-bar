# Xcode Cloud

Runs the same checks as the GitHub `CI` and `UI screens` workflows on Xcode Cloud, which comes
with the Apple Developer Program (25 compute hours a month) and doesn't use GitHub Actions minutes.

Xcode Cloud can't build a standalone Swift package, so:

- `EuclidCI.xcodeproj` builds a placeholder app (`EuclidCI/main.swift`) that the workflow needs.
- `ci_scripts/ci_post_clone.sh` runs before that build and does the real work:
  `swift build`, `swift test`, bundle + verify `Euclid.app`, and on PRs that touch
  `Sources/EuclidBar` the UI screens (`--render-screens`, `--render-demo`).

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
6. Save and **Start Build** on `main`. It should show as a `CI | Build - macOS` check on GitHub.

Results: Xcode › Report navigator › Cloud, or App Store Connect › the app › Xcode Cloud.
