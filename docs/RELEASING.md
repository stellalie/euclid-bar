# Releasing

Push a tag, get a signed + notarized DMG and a Sparkle update:

```sh
git tag v1.2.0 && git push origin v1.2.0
```

`.github/workflows/release.yml` runs `scripts/release.sh`, then publishes a GitHub release in the
public [euclid-bar-releases](https://github.com/stellalie/euclid-bar-releases) repo (this source repo
is private, and private repos' release files can't be downloaded anonymously):

| File | For |
| --- | --- |
| `Euclid-<v>.dmg` | First install (website / Releases download) |
| `Euclid-<v>.zip` | Sparkle update archive |
| `appcast.xml` | Sparkle feed; the app reads `releases/latest/download/appcast.xml` |

The bundle is `Euclid.app`; the binary inside stays `euclid-bar` (the CLI name). Never change
`CFBundleIdentifier` (`dev.euclid.Euclid`): Sparkle finds the new app in the update zip by it, and
installs it at the old path, so copies installed as `euclid-bar.app` keep that folder name.

The tag sets the app version (`CFBundleVersion`), and Sparkle only offers versions newer than the
installed one, so tags must keep going up.

To try the pipeline without publishing: **Actions › Release › Run workflow** (dry run, files land
in the run's artifacts).

## Dev builds

Every push to `main` that passes CI also ships, on Xcode Cloud: after the checks,
`XcodeCloud/ci_scripts/ci_post_clone.sh` runs `scripts/dev-release.sh`, which builds, signs and
notarizes it and replaces the files on the rolling **`dev`** pre-release in euclid-bar-releases
(version like `1.1.0-dev.214`). A build never replaces a newer one. It uses the same secrets as
stable releases, set as Xcode Cloud workflow variables (`XcodeCloud/README.md`).

To get them, set this in `config.toml`; the next update check switches feeds:

```toml
[updates]
channel = "dev"
```

`CFBundleVersion` is the commit count on `main` for both channels, so builds always go up. Switching
back to `"stable"` keeps the dev build until the next release is newer.

Claude merges its own pull requests once CI is green, so each one becomes a dev build to try.
Stable releases stay tag-only.

## One-time setup (~30 min)

1. **Developer ID certificate.** Xcode › Settings › Accounts › Manage Certificates › **+** ›
   *Developer ID Application*. Then Keychain Access › right-click it › Export as `.p12` with a password.
   ```sh
   base64 -i DeveloperID.p12 | pbcopy   # → secret MACOS_CERTIFICATE_P12
   ```
   Secret `MACOS_CERTIFICATE_PASSWORD` = the export password.
2. **Notary API key.** [App Store Connect › Users and Access › Integrations › Keys](https://appstoreconnect.apple.com/access/integrations/api)
   › **+**, access *Developer*. Download the `.p8` once.
   - `NOTARY_KEY_P8` = the `.p8` file's text (`pbcopy < AuthKey_XXXX.p8`)
   - `NOTARY_KEY_ID` = the key ID, `NOTARY_ISSUER_ID` = the issuer ID shown above the table
3. **Sparkle keys.** After any `swift build`:
   ```sh
   .build/artifacts/sparkle/Sparkle/bin/generate_keys            # prints the public key, keeps the private one in Keychain
   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle.key   # export the private key
   ```
   - Repository **variable** `SPARKLE_PUBLIC_KEY` = the printed public key
   - Secret `SPARKLE_PRIVATE_KEY` = contents of `sparkle.key` (then delete the file)

   Losing the private key means installed copies can't verify future updates. Keep it in your
   password manager too.

4. **Releases repo + token.** Create the public repo `stellalie/euclid-bar-releases` with a README.
   Then [create a fine-grained token](https://github.com/settings/personal-access-tokens/new):
   repository access *Only euclid-bar-releases*, permission *Contents: Read and write*, expiry 1 year.
   Secret `RELEASES_TOKEN` = the token.

5. **Licence keys.** After any `swift build`:
   ```sh
   .build/debug/euclid-bar --licence-keygen
   ```
   - Repository **variable** `LICENCE_PUBLIC_KEY` = the printed public key. Builds without it
     have no trial and no licence menu.
   - Keep `LICENCE_PRIVATE_KEY` in your password manager only. It is not a CI secret: the app
     never signs anything. Losing it means you can't issue keys that existing builds accept.

Add all of these under **GitHub › Settings › Secrets and variables › Actions** of this repo (stable
releases), and to the Xcode Cloud workflow's environment variables (dev builds, `XcodeCloud/README.md`).

## Local release

Same script, credentials from your login keychain:

```sh
xcrun notarytool store-credentials euclid --apple-id you@example.com --team-id TEAMID
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=euclid \
SPARKLE_PUBLIC_KEY=… SPARKLE_PRIVATE_KEY="$(cat sparkle.key)" scripts/release.sh 1.2.0
```

Without the env vars you get a locally signed, un-notarized build for testing.

## Licence keys

**Beta:** Personal use is free while `Evaluation.betaEnds` is `nil`. At launch, set it to the
launch date: anyone who first ran Euclid before then keeps Personal free, and new installs get the trial.

Euclid is fully unlocked during and after its 30-day trial. Once the trial is over it shows
"Unregistered" in the panel footer and a reminder every 3 days. A key turns both off.

Issue a key for a Paddle sale (the order is the `txn_…` id from the Paddle notification):

```sh
LICENCE_PRIVATE_KEY=… .build/debug/euclid-bar --issue-licence "Ada Lovelace" personal 1 txn_01abc
LICENCE_PRIVATE_KEY=… .build/debug/euclid-bar --issue-licence "Acme Pty Ltd" business 12 txn_01def
```

Key format, for anything else that issues them: `EUCLID-<payload>.<signature>`. The payload is
base64url JSON `{"edition","issued","name","order","seats"}`, and the signature is Ed25519, base64url,
over the payload's base64url text. The app checks it offline and stores it in
`~/Library/Application Support/Euclid/licence.json` with the trial's start date.
