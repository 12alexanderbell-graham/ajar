#!/bin/sh
# Builds a signed, notarized Nocturnal.app and the zip for the website and Homebrew. Needs (once):
#   1. Apple Developer Program membership, and a "Developer ID Application" certificate in your keychain
#      (Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application).
#   2. A notarytool profile:  xcrun notarytool store-credentials nocturnal --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#      (it asks for an app-specific password from account.apple.com › Sign-In and Security).
# Then:  sh release.sh TEAMID
# Output: dist/Nocturnal-<version>-mac.zip, signed with your Developer ID, notarized and stapled, plus its SHA-256.
set -eu
cd "$(dirname "$0")"
TEAM="${1:?usage: sh release.sh TEAMID}"
PROFILE="${NOTARY_PROFILE:-nocturnal}"
IDENTITY="Developer ID Application"
DD="${TMPDIR:-/tmp}/nocturnal-signed"
rm -rf "$DD"
echo "Building…"
/usr/bin/xcodebuild -project Nocturnal.xcodeproj -scheme Nocturnal -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DD" ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" build | tail -3
APP="$DD/Build/Products/Release/Nocturnal.app"
VERSION=$(/usr/bin/defaults read "$APP/Contents/Info" CFBundleShortVersionString)
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
mkdir -p dist
ZIP="dist/Nocturnal-$VERSION-mac.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
echo "Notarizing (usually a few minutes)…"
/usr/bin/xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
/usr/bin/xcrun stapler staple "$APP"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
/usr/sbin/spctl --assess --type execute --verbose "$APP"
echo "Done: $ZIP"
/usr/bin/shasum -a 256 "$ZIP"
