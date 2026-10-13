#!/usr/bin/env bash
# One-time: create a self-signed "Euclid Dev" code-signing identity in the login keychain.
#
# Why: ad-hoc signatures change on every build, so macOS forgets the
# Accessibility grant (needed for paste) after each rebuild. A stable identity
# keeps the grant.
#
# Undo: security delete-identity -c "Euclid Dev" ~/Library/Keychains/login.keychain-db
set -euo pipefail

NAME="Euclid Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "'$NAME' already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$(openssl rand -hex 16)"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# -legacy: macOS `security` can't read OpenSSL 3's default PKCS#12 encryption.
LEGACY=""
openssl pkcs12 -help 2>&1 | grep -q -- '-legacy' && LEGACY="-legacy"
openssl pkcs12 -export $LEGACY -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PASS"

security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Created '$NAME'. The first signing may ask to allow codesign to use the key: choose 'Always Allow'."
