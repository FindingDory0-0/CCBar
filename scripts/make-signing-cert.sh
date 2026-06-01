#!/bin/bash
# One-time setup: create a dedicated, self-signed *code-signing* identity for
# CCBar and import it into the login keychain.
#
# WHY this exists (the keychain-prompt bug):
#   CCBar reads Claude Code's `Claude Code-credentials` keychain item to draw
#   the usage bars. macOS guards that item with an ACL. When you click
#   "항상 허용", the system records the *requesting app* in the ACL.
#
#   For an **ad-hoc** signed app there is no stable signing authority, and a
#   bare `identifier "com.ccbar.menubar"` requirement is forgeable (any ad-hoc
#   binary can claim that id). So the keychain refuses to anchor trust to the
#   bundle id and instead pins the **cdhash**. Every rebuild / Sparkle update
#   changes the cdhash → the stored trust no longer matches → you get prompted
#   again. (TCC is more lenient and honours the pinned DR, which is why
#   Accessibility/Automation grants *do* survive rebuilds but the keychain one
#   does not.)
#
#   Signing with a real — even self-signed — certificate fixes this: codesign's
#   designated requirement becomes
#       identifier "com.ccbar.menubar" and certificate leaf = H"<cert hash>"
#   which is anchored to a stable cert. The keychain (and TCC) then keep the
#   grant across every rebuild that reuses the same cert.
#
#   We deliberately do NOT reuse any Developer ID already in the keychain (e.g.
#   a corporate cert) — distributed GitHub builds shouldn't carry someone
#   else's identity. A dedicated self-signed cert keeps the project's "not
#   enrolled in Apple Developer Program" posture intact.
#
# Idempotent: re-running detects an existing CCBar cert and does nothing.
# After signing with this cert you'll be prompted exactly once more per
# protected resource (keychain item, Accessibility, …); grant "항상 허용" and
# it sticks for all future builds.

set -euo pipefail

CERT_CN="CCBar Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
BACKUP_DIR="$HOME/.ccbar/signing"

# Already present? (search whole keychain by common name)
if security find-certificate -c "$CERT_CN" "$KEYCHAIN" >/dev/null 2>&1; then
    HASH=$(security find-certificate -c "$CERT_CN" -Z "$KEYCHAIN" 2>/dev/null \
           | awk '/SHA-1 hash:/ {print $3; exit}')
    echo "✓ '$CERT_CN' already exists (SHA-1 $HASH) — nothing to do."
    echo "  build-app.sh will pick it up automatically."
    exit 0
fi

echo "▸ Generating self-signed code-signing certificate '$CERT_CN' …"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# OpenSSL config: code-signing EKU + digitalSignature key usage. Using a config
# file (not -addext) keeps this working on macOS's LibreSSL.
cat > "$TMP/cert.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[ dn ]
CN = CCBar Code Signing
O  = CCBar

[ v3 ]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
subjectKeyIdentifier   = hash
CNF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/ccbar-signing.key" \
    -out    "$TMP/ccbar-signing.crt" \
    -days 7300 \
    -config "$TMP/cert.cnf" >/dev/null 2>&1

# Bundle key+cert into a PKCS#12 for import. OpenSSL 3.x's default PKCS#12
# (AES + PBKDF2/SHA-256 MAC) is unreadable by macOS's Security framework
# ("MAC verification failed during PKCS12 import"), so force the legacy
# SHA1-3DES PBE + SHA1 MAC that `security import` understands.
P12_PASS="ccbar"
openssl pkcs12 -export -legacy \
    -keypbe  PBE-SHA1-3DES \
    -certpbe PBE-SHA1-3DES \
    -macalg  sha1 \
    -inkey "$TMP/ccbar-signing.key" \
    -in    "$TMP/ccbar-signing.crt" \
    -name  "$CERT_CN" \
    -out   "$TMP/ccbar-signing.p12" \
    -passout "pass:$P12_PASS" >/dev/null 2>&1

# Import into login keychain. -A lets any tool use the private key without a
# per-use prompt (it's a throwaway local signing key, no real authority), so
# `build-app.sh` never stalls on a "codesign wants to use key" dialog.
echo "▸ Importing into $KEYCHAIN …"
security import "$TMP/ccbar-signing.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A \
    -T /usr/bin/codesign >/dev/null 2>&1

# Keep a backup of the identity outside the repo. Losing both this and the
# keychain copy just means re-granting the prompts once after regenerating.
mkdir -p "$BACKUP_DIR"
cp "$TMP/ccbar-signing.p12" "$BACKUP_DIR/ccbar-signing.p12"
chmod 600 "$BACKUP_DIR/ccbar-signing.p12"

HASH=$(security find-certificate -c "$CERT_CN" -Z "$KEYCHAIN" 2>/dev/null \
       | awk '/SHA-1 hash:/ {print $3; exit}')

echo "✓ Created '$CERT_CN'"
echo "    SHA-1 : $HASH"
echo "    backup: $BACKUP_DIR/ccbar-signing.p12 (PKCS#12, passphrase: ccbar)"
echo ""
echo "Next: rebuild with ./scripts/build-app.sh — it auto-detects this identity."
