#!/usr/bin/env bash
# CI only: put the Developer ID certificate and notary key from CI secrets where
# scripts/release.sh finds them. Missing secrets mean an unsigned or un-notarized build.
#   env P12, P12_PASSWORD, NOTARY_KEY_P8  → SIGN_IDENTITY, NOTARY_KEY_PATH in $GITHUB_ENV
# NOTARY_KEY_P8 is the .p8 text (line breaks optional: Xcode Cloud's field can drop them), or that
# text base64-encoded.
# Outside Actions, set RUNNER_TEMP and GITHUB_ENV to a temp dir and an env file to read back.
set -euo pipefail

if [[ -z "${P12:-}" ]]; then
  echo "No certificate secret: building unsigned."
else
  KEYCHAIN="$RUNNER_TEMP/release.keychain-db"
  PASS="$(openssl rand -hex 16)"
  echo "$P12" | base64 --decode > "$RUNNER_TEMP/cert.p12"
  security create-keychain -p "$PASS" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$PASS" "$KEYCHAIN"
  security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
  rm "$RUNNER_TEMP/cert.p12"
  ID="$(security find-identity -v -p codesigning "$KEYCHAIN" | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
  [[ -n "$ID" ]] || { echo "No Developer ID Application identity in the certificate" >&2; exit 1; }
  echo "SIGN_IDENTITY=$ID" >> "$GITHUB_ENV"
fi

if [[ -z "${NOTARY_KEY_P8:-}" ]]; then
  echo "No notary key: skipping notarization."
else
  if [[ "$NOTARY_KEY_P8" == -----BEGIN* ]]; then
    body="$(printf '%s' "$NOTARY_KEY_P8" | sed 's/-----[^-]*-----//g' | tr -d ' \r\n')"
    printf -- '-----BEGIN PRIVATE KEY-----\n%s\n-----END PRIVATE KEY-----\n' "$(fold -w 64 <<<"$body")" > "$RUNNER_TEMP/notary.p8"
  else
    printf '%s' "$NOTARY_KEY_P8" | base64 --decode > "$RUNNER_TEMP/notary.p8"
  fi
  echo "NOTARY_KEY_PATH=$RUNNER_TEMP/notary.p8" >> "$GITHUB_ENV"
fi
