#!/usr/bin/env bash
# Creates a self-signed code-signing identity for local builds.
#
# macOS ties Accessibility and Microphone permissions to an app's code signature. Ad-hoc
# signatures change with every build, so permissions silently stop working after a
# rebuild. A stable identity fixes that: grant once, keep it across rebuilds.
#
# Everything lives in .signing/ inside this project (a dedicated keychain with a random
# password). Nothing is added to your login keychain. Delete .signing/ to remove it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$ROOT/.signing"
KEYCHAIN="$DIR/signing.keychain-db"
NAME="Transcriber Local Signing"

if [ -f "$DIR/identity" ] && [ -f "$KEYCHAIN" ] && [ -f "$DIR/password" ]; then
    echo "==> Signing identity already set up ($(cat "$DIR/identity"))"
    exit 0
fi

echo "==> Creating local code-signing identity in $DIR"
mkdir -p "$DIR"
chmod 700 "$DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

PASSWORD="$(/usr/bin/openssl rand -hex 24)"
# The system openssl (LibreSSL) writes PKCS#12 files that `security import` understands.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout "pass:$PASSWORD" -name "$NAME"

rm -f "$KEYCHAIN"
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN" # no auto-lock
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null

HASH="$(security find-identity -p codesigning "$KEYCHAIN" | awk -v name="\"$NAME\"" '$0 ~ name {print $2; exit}')"
if [ -z "$HASH" ]; then
    echo "Could not find the new identity in $KEYCHAIN" >&2
    exit 1
fi

printf '%s' "$PASSWORD" > "$DIR/password"
chmod 600 "$DIR/password"
printf '%s' "$HASH" > "$DIR/identity"
echo "==> Created identity $HASH"
