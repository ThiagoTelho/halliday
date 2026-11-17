#!/bin/sh
# Creates a local, self-signed code-signing identity ("Halliday Dev") in the login keychain.
#
# Why: macOS ties privacy permissions (Screen Recording, Accessibility) to an app's code signature.
# With ad-hoc signing every build looks like a new app and the permissions are lost. Signing with a
# fixed identity keeps them across builds. The Makefile uses this identity when it exists.
#
# The certificate is only for this Mac's development builds: it is not trusted by anyone else and
# can't be used to distribute the app. Remove it any time with:
#   security delete-identity -c "Halliday Dev"
set -eu

NAME="Halliday Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
	echo "\"$NAME\" already exists in the login keychain."
	exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The system LibreSSL writes PKCS#12 files the `security` tool can read (OpenSSL 3 defaults it cannot).
OPENSSL=/usr/bin/openssl
PASS=$($OPENSSL rand -hex 16)

cat >"$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

$OPENSSL req -x509 -newkey rsa:2048 -nodes -days 3650 \
	-keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
$OPENSSL pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
	-out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null

# -T lets codesign use the key without a keychain prompt.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\" in the login keychain. Rebuild with: make clean && make"
