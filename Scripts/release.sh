#!/bin/bash
# Build Earmark for release: Developer ID signed, notarized, stapled, in a drag-to-Applications DMG.
# Needs: xcodegen, create-dmg (brew install xcodegen create-dmg), a "Developer ID Application"
# certificate, and a notarytool keychain profile (default "lonar-notary"; override with NOTARY_PROFILE):
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team>
# Usage: Scripts/release.sh
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

IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing (usually 1-5 minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

shasum -a 256 "$DMG"
echo "==> Built $DMG (notarized + stapled)"
