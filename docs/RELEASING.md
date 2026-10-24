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
| `euclid-bar-<v>.dmg` | First install (website / Releases download) |
| `euclid-bar-<v>.zip` | Sparkle update archive |
| `appcast.xml` | Sparkle feed; the app reads `releases/latest/download/appcast.xml` |

The tag sets the app version (`CFBundleVersion`), and Sparkle only offers versions newer than the
installed one, so tags must keep going up.

To try the pipeline without publishing: **Actions › Release › Run workflow** (dry run, files land
in the run's artifacts).

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

Add all of these under **GitHub › Settings › Secrets and variables › Actions** of this repo.

## Local release

Same script, credentials from your login keychain:

```sh
xcrun notarytool store-credentials euclid --apple-id you@example.com --team-id TEAMID
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=euclid \
SPARKLE_PUBLIC_KEY=… SPARKLE_PRIVATE_KEY="$(cat sparkle.key)" scripts/release.sh 1.2.0
```

Without the env vars you get a locally signed, un-notarized build for testing.
