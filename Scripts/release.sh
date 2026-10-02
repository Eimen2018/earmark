#!/bin/bash
# Build Earmark for release: Developer ID signed, notarized, stapled, in a drag-to-Applications DMG.
# Needs: xcodegen, create-dmg (brew install xcodegen create-dmg), a "Developer ID Application"
# certificate, and a notarytool keychain profile (default "lonar-notary"; override with NOTARY_PROFILE):
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
# Also writes the Sparkle update: build/appcast/Earmark-<version>.zip (signed with the EdDSA key
# stored in the login keychain under account "earmark", made once with Sparkle's generate_keys)
# and refreshes appcast.xml.
# Usage: Scripts/release.sh
# Then: commit appcast.xml, and attach the DMG and the zip to a GitHub release tagged v<version>.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-lonar-notary}"
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"/\1/p' project.yml)
APP=build/release/Build/Products/Release/Earmark.app
DMG="build/Earmark-$VERSION.dmg"

echo "==> Earmark $VERSION"
xcodegen generate --quiet
xcodebuild -project Earmark.xcodeproj -scheme Earmark -configuration Release \
    -derivedDataPath build/release -destination 'platform=macOS,arch=arm64' \
    clean build | grep -E "error:|warning: .*Earmark/|BUILD (SUCCEEDED|FAILED)" || true
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }

echo "==> Re-signing Sparkle's helpers"
# Xcode leaves Sparkle's nested tools with Sparkle's own signature; notarization needs ours,
# with hardened runtime and a secure timestamp, signed inside-out, then the app again.
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
FW="$APP/Contents/Frameworks/Sparkle.framework"
SIGN=(codesign --force --sign "$IDENTITY" --options runtime --timestamp)
"${SIGN[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$FW/Versions/B/Autoupdate"
"${SIGN[@]}" "$FW/Versions/B/Updater.app"
"${SIGN[@]}" "$FW"
"${SIGN[@]}" --entitlements Earmark/Earmark.entitlements "$APP"

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "Authority=Developer ID Application|TeamIdentifier|Runtime"

echo "==> Packaging DMG"
STAGING=build/dmg-staging
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
create-dmg \
    --volname "Earmark $VERSION" \
    --volicon "$APP/Contents/Resources/AppIcon.icns" \
    --window-size 600 380 \
    --icon-size 128 \
    --icon "Earmark.app" 160 180 \
    --app-drop-link 440 180 \
    --hide-extension "Earmark.app" \
    --no-internet-enable \
    "$DMG" "$STAGING" >/dev/null
rm -rf "$STAGING"

codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing (usually 1-5 minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "==> Sparkle update"
# The DMG submission covered the app inside it, so its ticket can be stapled to the app too.
xcrun stapler staple "$APP"
ARCHIVES=build/appcast
mkdir -p "$ARCHIVES"
rm -f "$ARCHIVES"/*.zip
ditto -c -k --keepParent "$APP" "$ARCHIVES/Earmark-$VERSION.zip"
build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --account earmark \
    --download-url-prefix "https://github.com/Eimen2018/earmark/releases/download/v$VERSION/" \
    -o appcast.xml \
    "$ARCHIVES"

shasum -a 256 "$DMG"
echo "==> Built $DMG (notarized + stapled) and $ARCHIVES/Earmark-$VERSION.zip; appcast.xml updated"
