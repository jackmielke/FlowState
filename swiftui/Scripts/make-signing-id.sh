#!/usr/bin/env bash
# Creates a stable, self-signed code-signing identity for Vibe Voice.
#
# WHY THIS EXISTS
# Ad-hoc signing (`codesign --sign -`) makes the app's designated requirement a raw
# cdhash — the hash of the binary. Rebuild the app and the hash changes, so macOS TCC
# treats it as a different app entirely and voids every privacy grant it had. The
# symptom is brutal to diagnose: System Settings still shows the toggle ON, but the
# app keeps being told no and re-prompts forever.
#
# A self-signed certificate produces a requirement of the form
#     identifier "com.jackmielke.vibevoice" and certificate leaf = H"<cert hash>"
# which is stable no matter how many times the binary is rebuilt.
#
# Everything lives in its own keychain with a generated password, so this never needs
# and never touches your login keychain password. Run once.
set -euo pipefail

D="$HOME/.config/vibe-voice/signing"
KC="vibevoice.keychain"
NAME="Vibe Voice Dev"

mkdir -p "$D" && chmod 700 "$D"
cd "$D"

KCPASS=$(openssl rand -hex 24)
P12PASS=$(openssl rand -hex 24)
printf '%s' "$KCPASS"  > kc.pass  && chmod 600 kc.pass
printf '%s' "$P12PASS" > p12.pass && chmod 600 p12.pass

echo "==> generating self-signed code-signing certificate (10 years)"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
chmod 600 key.pem

# Apple's importer cannot read OpenSSL 3's default PKCS#12 encryption
# ("MAC verification failed"), so force the legacy algorithms it understands.
openssl pkcs12 -export -inkey key.pem -in cert.pem -out ident.p12 \
  -passout pass:"$P12PASS" -name "$NAME" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo "==> creating dedicated keychain"
security delete-keychain "$KC" 2>/dev/null || true
security create-keychain -p "$KCPASS" "$KC"
security set-keychain-settings -lut 100000 "$KC"     # don't auto-lock mid-build
security unlock-keychain -p "$KCPASS" "$KC"
security import ident.p12 -k "$KC" -P "$P12PASS" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPASS" "$KC" >/dev/null 2>&1

# Append to the search list without disturbing what is already there.
CURRENT=$(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"$//')
if ! printf '%s\n' "$CURRENT" | grep -q "$KC"; then
  # shellcheck disable=SC2046
  security list-keychains -d user -s $(printf '"%s" ' $CURRENT | tr -d '\n') "$HOME/Library/Keychains/$KC-db"
fi

echo "==> done"
security find-identity "$KC" | sed -n 's/^ *1)/    /p'
echo ""
echo "The cert is self-signed, so it reports CSSMERR_TP_NOT_TRUSTED — that is expected"
echo "and does not stop codesign from using it. Now run ./build.sh, then grant Screen"
echo "Recording once. The grant will survive every future rebuild."
