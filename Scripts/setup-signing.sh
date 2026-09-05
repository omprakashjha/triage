#!/bin/bash
#
# Creates a stable code-signing identity so macOS stops asking for your login password
# every time Triage reads its stored Gmail tokens.
#
# WHY THIS IS NEEDED
# ------------------
# macOS binds Keychain ACLs to the code signature of the app that reads them. An ad-hoc
# signature (codesign --sign -) has a designated requirement of the form
#
#     designated => cdhash H"aaf68832bd73..."
#
# which is the hash of that exact binary. Rebuild and the hash changes, so the new build
# is a stranger to the stored tokens and macOS re-prompts. Signing with a certificate
# makes the requirement depend on the CERTIFICATE instead, which is stable across
# rebuilds, so a single "Always Allow" holds.
#
# WHAT THIS ASKS OF YOU
# ---------------------
# Your login password, once, in this terminal. It is needed for
# `security set-key-partition-list`, which is the ACL that decides whether codesign may
# use the new private key WITHOUT a GUI prompt on every build. Skipping that step is
# what makes codesign hang waiting on a dialog — verified the hard way.
#
# The password is read with `read -s` (not echoed), used only for two `security` calls,
# and never written anywhere.
#
# NOT FOR DISTRIBUTION. A self-signed certificate is not trusted by Gatekeeper and
# cannot be notarised; it will show as CSSMERR_TP_NOT_TRUSTED, which is expected and
# harmless for local signing. Shipping to other people needs a Developer ID.
#
# Run once:  Scripts/setup-signing.sh
# Undo with: security delete-identity -c "Triage Local Signing"

set -euo pipefail

IDENTITY="Triage Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# NOTE: deliberately NOT `find-identity -v`. The -v flag means "trusted", and a
# self-signed certificate is never trusted — an earlier version of this script checked
# -v and therefore always concluded it had failed.
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "'$IDENTITY' already exists — nothing to do."
    security find-identity -p codesigning | grep "$IDENTITY"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> generating a self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$IDENTITY/O=Local Development" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "keyUsage=critical,digitalSignature" 2>/dev/null

# The legacy algorithm flags are REQUIRED. OpenSSL 3 defaults to a SHA-256 MAC with
# AES-256-CBC, which Apple's Security framework cannot verify — `security import` fails
# with "MAC verification failed during PKCS12 import (wrong password?)", which is a
# misleading error since the password is fine. macOS wants a SHA-1 MAC with 3DES.
echo "==> packaging as PKCS#12 (legacy algorithms, required by macOS)"
openssl pkcs12 -export -out "$WORK/identity.p12" \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -passout pass:triage-temp \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

echo
echo "Your macOS login password is needed once, to let codesign use the new key"
echo "without a dialog on every build. It is not echoed and not stored."
printf "login password: "
read -rs LOGIN_PASSWORD
echo
echo

echo "==> importing into the login keychain"
security import "$WORK/identity.p12" \
    -k "$KEYCHAIN" \
    -P triage-temp \
    -T /usr/bin/codesign \
    -T /usr/bin/security

echo "==> authorising codesign to use the key non-interactively"
# Without this, codesign blocks on a GUI prompt every single invocation.
if ! security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s -k "$LOGIN_PASSWORD" \
        "$KEYCHAIN" >/dev/null 2>&1; then
    echo "    WARNING: could not set the key partition list (wrong password?)." >&2
    echo "    The identity exists, but codesign may prompt on each build. Retry with:" >&2
    echo "      security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <password> '$KEYCHAIN'" >&2
fi
unset LOGIN_PASSWORD

echo
if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "created:"
    security find-identity -p codesigning | grep "$IDENTITY"
    echo
    echo "CSSMERR_TP_NOT_TRUSTED above is expected — self-signed certificates are not"
    echo "trusted by Gatekeeper. It does not stop codesign using this identity, and the"
    echo "Keychain ACL only cares about the certificate, not its trust status."
    echo
    echo "Next:"
    echo "  1. Scripts/build-app.sh          # now signs with this identity"
    echo "  2. Delete the STALE keychain items, whose ACL trusts a build that no longer"
    echo "     exists. Keychain Access -> search 'com.triage.app' -> delete every match."
    echo "  3. Launch Triage, reconnect Gmail, and click 'Always Allow' once."
    echo
    echo "Verify the signature is certificate-based rather than hash-based with:"
    echo "  codesign -d -r- build/Triage.app"
    echo "A line mentioning 'certificate leaf' is what survives rebuilds; one saying"
    echo "'cdhash H\"...\"' is the ad-hoc form that does not."
else
    echo "identity was NOT created — build-app.sh will fall back to ad-hoc signing." >&2
    exit 1
fi
