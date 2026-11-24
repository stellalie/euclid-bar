#!/usr/bin/env bash
# CI only: put the Developer ID certificate and notary key from CI secrets where
# scripts/release.sh finds them. Missing secrets mean an unsigned or un-notarized build.
#   env P12, P12_PASSWORD, NOTARY_KEY_P8  → SIGN_IDENTITY, NOTARY_KEY_PATH in $GITHUB_ENV
# The .pkg is signed with a Developer ID Installer certificate made from the same private key as the
# P12's, so it needs no secret of its own: the certificate is checked in (DEVELOPER_ID_INSTALLER_CER)
# → INSTALLER_SIGN_IDENTITY. Until it is, this writes the request Apple needs → INSTALLER_CSR.
# NOTARY_KEY_P8 is the .p8 text (line breaks optional: Xcode Cloud's field can drop them), or that
# text base64-encoded.
# Outside Actions, set RUNNER_TEMP and GITHUB_ENV to a temp dir and an env file to read back.
set -euo pipefail
DEVELOPER_ID_INSTALLER_CER="$(cd "$(dirname "$0")/.." && pwd)/Resources/DeveloperIDInstaller.cer"

if [[ -z "${P12:-}" ]]; then
  echo "No certificate secret: building unsigned."
else
  KEYCHAIN="$RUNNER_TEMP/release.keychain-db"
  PASS="$(openssl rand -hex 16)"
  echo "$P12" | base64 --decode > "$RUNNER_TEMP/cert.p12"
  security create-keychain -p "$PASS" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$PASS" "$KEYCHAIN"
  security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/productbuild
  security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
  if [[ -f "$DEVELOPER_ID_INSTALLER_CER" ]]; then
    security import "$DEVELOPER_ID_INSTALLER_CER" -k "$KEYCHAIN" # pairs with the P12's private key
  fi
  INSTALLER_ID="$(security find-identity -v "$KEYCHAIN" | sed -n 's/.*"\(Developer ID Installer: .*\)"/\1/p' | head -1)"
  if [[ -n "$INSTALLER_ID" ]]; then
    echo "INSTALLER_SIGN_IDENTITY=$INSTALLER_ID" >> "$GITHUB_ENV"
  else
    # Public: a certificate signing request for the P12's key, to upload at developer.apple.com ›
    # Certificates › + › Developer ID Installer. Save the .cer it gives as $DEVELOPER_ID_INSTALLER_CER.
    # Never fails the build: without the request, releases just go out without the .pkg.
    key="$RUNNER_TEMP/key.pem" csr="$RUNNER_TEMP/installer.csr"
    for ssl in /usr/bin/openssl /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
      [[ -x "$ssl" ]] || continue
      for legacy in "" -legacy; do
        # shellcheck disable=SC2086 # $legacy is empty or one flag
        "$ssl" pkcs12 $legacy -in "$RUNNER_TEMP/cert.p12" -nocerts -nodes -passin env:P12_PASSWORD -out "$key" 2>/dev/null &&
          "$ssl" req -new -key "$key" -subj "/CN=LGTM Ninja/emailAddress=hello@lgtm.ninja/C=AU" -out "$csr" && break 2
      done
    done
    rm -f "$key"
    if [[ -s "$csr" ]]; then
      echo "INSTALLER_CSR=$csr" >> "$GITHUB_ENV"
      echo "No Developer ID Installer certificate: the .pkg won't be signed (request: $csr)"
    else
      echo "No Developer ID Installer certificate, and couldn't write a signing request ($(openssl version))"
    fi
  fi
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
