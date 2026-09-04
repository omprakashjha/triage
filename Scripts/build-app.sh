#!/bin/bash
#
# Assembles Triage.app from the SwiftPM executable.
#
# SwiftPM cannot emit a .app bundle, and a bare binary costs three things that matter
# here:
#
#   1. Code-signing identity. Keychain ACLs are bound to the accessing code's
#      signature, so an UNSIGNED binary is re-prompted for the Gmail tokens on every
#      launch. A signed bundle is prompted once per build instead.
#   2. A real app name. The bare executable shows up everywhere as "TriageApp".
#   3. Finder / Spotlight / Dock launch, without keeping a terminal open.
#
# Note what a bundle does NOT fix: OAuth already works from a bare binary, because
# ASWebAuthenticationSession(url:callbackURLScheme:) intercepts the redirect in-process
# rather than going through LaunchServices.
#
# Usage: Scripts/build-app.sh [debug|release]

set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Triage.app"
# Must match the Keychain service string in GmailAuthService and the bundle ID
# registered for the OAuth client in Google Cloud Console. Changing it orphans the
# stored tokens.
BUNDLE_ID="com.triage.app"
VERSION="0.1.0"

echo "==> building TriageApp ($CONFIG)"
cd "$ROOT"
# --disable-sandbox: SwiftPM's manifest sandbox is blocked in some shells here.
swift build -c "$CONFIG" --disable-sandbox --product TriageApp

BINARY="$(swift build -c "$CONFIG" --disable-sandbox --show-bin-path)/TriageApp"
[ -f "$BINARY" ] || { echo "no binary at $BINARY" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Triage"

# The icon is drawn from source rather than committed as a binary, so it can be edited
# and re-rendered. Regenerated only when the renderer is newer than its output, because
# it costs a few seconds to compile.
ICNS="$ROOT/build/Triage.icns"
if [ ! -f "$ICNS" ] || [ "$ROOT/Scripts/make-icon.swift" -nt "$ICNS" ]; then
    echo "==> drawing icon"
    swift "$ROOT/Scripts/make-icon.swift" "$ICNS" | sed 's/^/    /'
fi
cp "$ICNS" "$APP/Contents/Resources/Triage.icns"

# The OAuth callback scheme is the REVERSED client id, which lives in the gitignored
# Secrets.swift. Read it at build time so the scheme can be declared in the bundle
# without the client id ever being committed. Optional: the auth session does not
# depend on this registration, it just makes the bundle honest about what it handles.
URL_SCHEME_BLOCK=""
SECRETS="$ROOT/Triage/Config/Secrets.swift"
if [ -f "$SECRETS" ]; then
    CLIENT_ID="$(sed -n 's/.*gmailClientId *= *"\([^"]*\)".*/\1/p' "$SECRETS" | head -1)"
    if [ -n "$CLIENT_ID" ]; then
        # com.googleusercontent.apps.<id>  <-  <id>.apps.googleusercontent.com
        REVERSED="$(printf '%s' "$CLIENT_ID" | awk -F. '{for(i=NF;i>0;i--){printf "%s%s", $i, (i>1?".":"")}}')"
        URL_SCHEME_BLOCK="
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>Google OAuth callback</string>
            <key>CFBundleURLSchemes</key>
            <array><string>${REVERSED}</string></array>
        </dict>
    </array>"
        echo "    registered OAuth callback scheme from Secrets.swift"
    fi
else
    echo "    no Secrets.swift — skipping OAuth scheme registration"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Triage</string>
    <key>CFBundleDisplayName</key><string>Triage</string>
    <key>CFBundleExecutable</key><string>Triage</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>Triage</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>

    <!-- Deliberately NOT LSUIElement, unlike Cadence: Triage is a regular windowed
         app whose whole job is a table you read and act on. -->
$URL_SCHEME_BLOCK
</dict>
</plist>
PLIST

# No sandbox entitlements. Triage reaches Gmail and IMAP over the network, reads the
# AWS SSO token cache under ~/.aws when cloud categorization is on, and writes its
# database to Application Support. Sandboxing it properly needs per-capability
# entitlements and a container migration for the existing database, which is a
# distribution concern rather than a local-run one.
#
# Signing identity: prefer a stable certificate over ad-hoc.
#
# This is not cosmetic. macOS binds Keychain ACLs to the code signature, and an ad-hoc
# signature's cdhash changes on EVERY rebuild — so each new build is a stranger to the
# stored Gmail tokens and macOS re-prompts for the login password on every access.
# Signing with a certificate makes the designated requirement depend on the cert
# instead, so "Always Allow" survives rebuilds. Run Scripts/setup-signing.sh once.
SIGN_IDENTITY="Triage Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "==> signing with '$SIGN_IDENTITY'"
    codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime "$APP" 2>&1 | sed 's/^/    /'
else
    echo "==> signing (ad-hoc — no stable identity found)"
    echo "    NOTE: ad-hoc means macOS will ask for your login password every time the"
    echo "    app reads its stored Gmail tokens, and again after each rebuild."
    echo "    Run Scripts/setup-signing.sh once to stop that."
    codesign --force --deep --sign - --options runtime "$APP" 2>&1 | sed 's/^/    /'
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo
echo "built $APP"
echo
echo "run it:      open '$APP'"
echo "install it:  cp -R '$APP' /Applications/"
echo
echo "If cloud categorization is enabled, note that an app launched from Finder cannot"
echo "see AWS_PROFILE — the profile it uses must be named 'default'."
