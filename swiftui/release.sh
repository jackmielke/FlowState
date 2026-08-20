#!/usr/bin/env bash
# Build a signed, notarized Vantage.dmg that anyone can double-click.
#
#   ./release.sh
#
# WHY NOT THE MAC APP STORE
# App Store apps must be sandboxed, and Vantage cannot be. Dev Mode spawns the user's
# own `claude` binary; native tools run `/usr/bin/shortcuts`; undo runs `/usr/bin/git`
# against whatever repo the user names. A sandboxed process may not execute arbitrary
# binaries outside its container, so shipping on the App Store would mean deleting the
# feature the app exists for.
#
# Developer ID + notarization is what serious Mac apps that need real system access
# actually use — including Wispr Flow on this very machine:
#     Authority=Developer ID Application: Wispr AI INC
#     source=Notarized Developer ID
# The result is identical for the person installing it: double-click, drag, open. No
# warning, no right-click-Open, no Terminal.
#
# ONE-TIME SETUP
#   1. developer.apple.com → Certificates → + → "Developer ID Application"
#      Create it, download, double-click to install into the login keychain.
#   2. appleid.apple.com → Sign-In and Security → App-Specific Passwords → generate one.
#   3. Store it so this script can notarize unattended:
#        xcrun notarytool store-credentials notary \
#          --apple-id "you@example.com" --team-id "YOURTEAMID" --password "abcd-efgh-ijkl-mnop"
#
# After that, this script needs no input.
set -euo pipefail
cd "$(dirname "$0")"

APP="VibeVoice.app"
PRODUCT="Vantage"
DMG="$PRODUCT.dmg"
STAGING=".release-staging"
PROFILE="${NOTARY_PROFILE:-notary}"

echo "==> checking prerequisites"
# `|| true`: with `set -euo pipefail`, grep finding nothing would abort the script
# here — before the message explaining what to do about it, which is the one thing
# the person running this actually needs.
IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)

if [ -z "${IDENTITY:-}" ]; then
  cat <<'MSG'
    No "Developer ID Application" certificate found.

    That is the one thing this needs, and it cannot be created from a script —
    Apple issues it through the developer portal:

      developer.apple.com → Certificates, IDs & Profiles → Certificates → +
      → "Developer ID Application" → create, download, double-click to install

    An "Apple Development" certificate is NOT the same thing: it only works on
    devices registered to your account, so it cannot be handed to a friend.

    Until then, `./build.sh` still produces a working app for this machine.
MSG
  exit 1
fi
echo "    signing identity: $IDENTITY"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  cat <<MSG
    No stored notarization credentials under profile "$PROFILE".

    Create an app-specific password at appleid.apple.com, then:
      xcrun notarytool store-credentials $PROFILE \\
        --apple-id "you@example.com" --team-id "YOURTEAMID" --password "xxxx-xxxx-xxxx-xxxx"
MSG
  exit 1
fi

echo "==> build"
./build.sh >/dev/null

echo "==> sign with Developer ID (hardened runtime)"
# Notarization requires the hardened runtime. The entitlements below are the minimum
# this app actually needs, and each one is here for a reason:
#   audio-input               — the microphone
#   allow-jit / unsigned-exec — SwiftUI and Canvas rendering
#   disable-library-validation — lets the app spawn `claude`, which Apple did not sign
cat > "$STAGING.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
PLIST

codesign --force --deep --options runtime --timestamp \
         --entitlements "$STAGING.entitlements" \
         --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'

echo "==> stage the drag-to-install layout"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/$PRODUCT.app"
ln -s /Applications "$STAGING/Applications"

echo "==> build dmg"
hdiutil create -volname "$PRODUCT" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "==> notarize (Apple scans it; usually a minute or two)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1 | sed 's/^/    /'

echo "==> staple, so it verifies offline"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" 2>&1 | sed 's/^/    /'

rm -rf "$STAGING" "$STAGING.entitlements"

echo ""
echo "==> $DMG is ready to send"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/    /'
echo "    'accepted' + 'Notarized Developer ID' means it opens with no warning on any Mac."
