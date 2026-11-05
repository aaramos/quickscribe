#!/usr/bin/env bash
# Creates the self-made code signing certificate "QuickScribe Release", once,
# so every release build is signed by the SAME identity and macOS recognizes
# updates as the same app instead of a stranger.
#
# - Nothing to do if the certificate already exists. Run it once; it never
#   makes a second one.
# - The private key goes into the keychain and nowhere else: the intermediate
#   files live in a private temporary folder destroyed on the way out.
# - The certificate says only "QuickScribe Release". No name, no email, no
#   machine. It is self-made, so it removes nothing of the first-open block;
#   only Apple's paid program does that. It costs nothing.
# - Trust settings stay untouched: signing is work the key does, not a
#   judgment macOS is asked to make. Nothing here changes system trust.
#
# Target: the login keychain, or a keychain file passed as the first argument
# (that is how the script itself gets tested, on a throwaway keychain).
set -euo pipefail
NAME="QuickScribe Release"
KEYCHAIN="${1:-$HOME/Library/Keychains/login.keychain-db}"

if security find-certificate -c "$NAME" -Z "$KEYCHAIN" >/dev/null 2>&1; then
    echo "==> \"$NAME\" already lives in $KEYCHAIN: nothing to do"
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK:?}"' EXIT
chmod 700 "$WORK"

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = codesign
prompt = no
[dn]
CN = ${NAME}
[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
CNF

# RSA 2048: the shape the keychain accepts for signing identities.
# (Elliptic-curve keys import fine as keys but are refused as signing
# identities: "an invalid key was encountered".)
/usr/bin/openssl req -x509 -newkey rsa:2048 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -nodes -config "$WORK/cert.cnf" -extensions codesign

# The keychain's importer reads PKCS#12 with the old SHA1/3DES ciphers;
# LibreSSL defaults to newer ones it will not accept, and refuses an empty
# passphrase as a MAC mismatch, so the pack pass uses a throwaway phrase
# that exists only inside this folder.
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout pass:once \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

# -A rather than a codesign-only ACL: the tested behavior of the named-app
# variant still gated access behind a confirmation. The keychain password, if
# macOS asks for it, is typed by whoever runs this: never put it on a command line.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P once -T /usr/bin/codesign -A
rm -f "$WORK/identity.p12"

if security find-certificate -c "$NAME" -Z "$KEYCHAIN" >/dev/null 2>&1; then
    echo "==> \"$NAME\" is in $KEYCHAIN, valid to $(/usr/bin/openssl x509 -in "$WORK/cert.pem" -noout -enddate | cut -d= -f2)"
    echo "    build releases with:  CODESIGN_IDENTITY=\"$NAME\" ./make_installer.sh"
    echo "    (an ordinary ./build_app.sh stays ad-hoc, for anyone building from source)"
else
    echo "FATAL: import reported no error but the certificate is not in $KEYCHAIN" >&2
    exit 1
fi
