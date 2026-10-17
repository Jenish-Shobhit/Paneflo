#!/bin/bash
# Creates the self-signed "Paneflo Dev" code-signing certificate in the login keychain, once.
#
#   scripts/make-signing-identity.sh
#
# macOS ties Accessibility, Input Monitoring and Screen Recording permissions to an app's code
# signature. Signed with this stable certificate, rebuilt copies keep their permissions; signed
# ad hoc, every rebuild looks like a new app. No Apple Developer account is needed.
# Uses macOS's own /usr/bin/openssl (LibreSSL) in a scratch folder; the key never touches the repo.
set -euo pipefail

NAME="Paneflo Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12_PASS="paneflo"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" is already in the keychain; nothing to do."
  exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

cat > paneflo-dev.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Paneflo Dev
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config paneflo-dev.cnf -keyout paneflo-dev.key -out paneflo-dev.crt 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey paneflo-dev.key -in paneflo-dev.crt \
  -name "$NAME" -out paneflo-dev.p12 -passout "pass:$P12_PASS"
# -T lets codesign use the key without asking each time. macOS may ask once for your login
# password to unlock the keychain.
security import paneflo-dev.p12 -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign

# Without -v: a self-signed certificate is "not trusted" and -v would hide it. codesign uses it fine.
security find-identity -p codesigning | grep "\"$NAME\"" \
  || { echo "make-signing-identity.sh: import finished but \"$NAME\" is not listed" >&2; exit 1; }
echo "Created \"$NAME\". Rebuild with scripts/build.sh --install."
