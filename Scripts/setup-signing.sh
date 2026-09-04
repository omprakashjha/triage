#!/bin/bash
#
# Creates a stable self-signed code-signing identity for local development.
#
# WHY THIS EXISTS
# ---------------
# macOS binds Keychain ACLs to the *code signature* of the app that reads them. An
# ad-hoc signature (codesign --sign -) has no stable identity: its cdhash changes on
# every rebuild, so every build is a stranger to the stored Gmail tokens and macOS
# re-prompts for the login password on every single access.
#
# Signing with a real certificate instead makes the designated requirement depend on
# the CERTIFICATE rather than the exact binary hash. Then "Always Allow" sticks across
# rebuilds, and the tokens stay encrypted in the Keychain where they belong.
#
# This is NOT for distribution. A self-signed certificate is not trusted by Gatekeeper
# and cannot notarise; shipping to anyone else needs a Developer ID from an Apple
# Developer account. This only removes the password prompts on your own machine.
#
# Run once:  Scripts/setup-signing.sh
# Undo with: security delete-certificate -c "Triage Local Signing"

set -euo pipefail

IDENTITY="Triage Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "'$IDENTITY' already exists — nothing to do."
    security find-identity -v -p codesigning | grep "$IDENTITY"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> generating a self-signed code-signing certificate"
# extendedKeyUsage=codeSigning is what makes codesign accept it as an identity.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$IDENTITY/O=Local Development" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "keyUsage=critical,digitalSignature" 2>/dev/null

# Bundle key + cert into a PKCS#12, which is the format `security import` wants for an
# identity (key and certificate together — a bare certificate is not an identity).
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout pass: 2>/dev/null

echo "==> importing into the login keychain"
echo "    macOS may ask for your login password — that is this script adding the"
echo "    certificate, and it is the LAST time you should be asked for the app."
# -T /usr/bin/codesign pre-authorises codesign to use the key without prompting.
security import "$WORK/identity.p12" \
    -k "$KEYCHAIN" \
    -P "" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

# Without this, codesign still prompts per invocation for key access. The partition
# list is the modern ACL that governs which tools may use the private key.
echo "==> authorising codesign to use the key non-interactively"
if ! security set-key-partition-list -S apple-tool:,apple: -k "" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "    could not set the partition list without a password."
    echo "    If codesign prompts on every build, run this once:"
    echo "      security set-key-partition-list -S apple-tool:,apple: -s -k <login-password> '$KEYCHAIN'"
fi

echo
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "created:"
    security find-identity -v -p codesigning | grep "$IDENTITY"
    echo
    echo "Next:"
    echo "  1. Scripts/build-app.sh    # now signs with this identity"
    echo "  2. Delete the STALE keychain items whose ACL trusts an older build:"
    echo "       Keychain Access -> search 'com.triage.app' -> delete all matches"
    echo "     (or: security delete-generic-password -s com.triage.app  — repeat per item)"
    echo "  3. Launch Triage and reconnect Gmail. Click 'Always Allow' on the prompt."
    echo
    echo "That prompt should not come back, including after future rebuilds."
else
    echo "identity was not created — codesign will fall back to ad-hoc." >&2
    exit 1
fi
