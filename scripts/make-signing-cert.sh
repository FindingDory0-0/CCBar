#!/bin/bash
# One-time **developer-machine** setup: create a dedicated, self-signed
# *code-signing* identity for CCBar, import it into the login keychain, AND
# mark it trusted for code signing.
#
# WHAT this is for: keeping **TCC** grants (손쉬운 사용 / 자동화) across rebuilds.
#   codesign's designated requirement becomes
#       identifier "com.ccbar.menubar" and certificate root = H"<cert>"
#   which has no cdhash term, so TCC permissions survive every rebuild that
#   reuses this cert (ad-hoc, by contrast, re-pins the cdhash each build → TCC
#   re-prompts). We do NOT reuse a corporate Developer ID — distributed GitHub
#   builds shouldn't carry someone else's identity.
#
# WHAT this is NOT for: the recurring usage-bar "키 접근 허용" keychain popup.
#   That is an *item-ACL* problem, NOT a signing problem (the keychain pins
#   trusted apps by changing identity, unrelated to cert trust). Fix it with the
#   app's ⚙ → "사용량 키체인 접근 허용" button (Sources/CCBarCore/Usage/
#   KeychainAccessGrant.swift), or Keychain Access → "Allow all applications".
#   See CLAUDE.md trap #7. (Earlier versions of this header wrongly claimed the
#   trusted cert fixed the keychain popup — it doesn't.)
#
# Idempotent: re-running detects an existing/trusted cert and skips that step.

set -euo pipefail

CERT_CN="CCBar Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
BACKUP_DIR="$HOME/.ccbar/signing"

# Trust the cert for code signing if it isn't already (shows up in the `-v`
# "valid identities" list only once trusted). Pops a GUI password dialog the
# first time — that's macOS authorising a trust-settings change.
ensure_trusted() {
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_CN"; then
        echo "✓ '$CERT_CN' is already trusted for code signing."
        return 0
    fi
    echo "▸ Trusting '$CERT_CN' for code signing …"
    echo "  → a password dialog will appear; enter your login password to confirm."
    mkdir -p "$BACKUP_DIR"
    local pem="$BACKUP_DIR/ccbar-signing.pem"
    security find-certificate -c "$CERT_CN" -p "$KEYCHAIN" > "$pem" 2>/dev/null
    security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$pem"
    echo "✓ Trusted."
}

# Already present? Then just make sure it's trusted and we're done.
if security find-certificate -c "$CERT_CN" "$KEYCHAIN" >/dev/null 2>&1; then
    HASH=$(security find-certificate -c "$CERT_CN" -Z "$KEYCHAIN" 2>/dev/null \
           | awk '/SHA-1 hash:/ {print $3; exit}')
    echo "✓ '$CERT_CN' already exists (SHA-1 $HASH)."
    ensure_trusted
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

# Trust it for code signing (the step that actually makes the keychain grant
# stick across rebuilds on this machine).
ensure_trusted

HASH=$(security find-certificate -c "$CERT_CN" -Z "$KEYCHAIN" 2>/dev/null \
       | awk '/SHA-1 hash:/ {print $3; exit}')

echo "✓ Created '$CERT_CN'"
echo "    SHA-1 : $HASH"
echo "    backup: $BACKUP_DIR/ccbar-signing.p12 (PKCS#12, passphrase: ccbar)"
echo ""
echo "Next: rebuild with ./scripts/build-app.sh — it auto-detects this identity."
