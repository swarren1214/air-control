#!/bin/bash
# Production build of Air Control:
#   archive (Release) → sign with Developer ID → notarize with Apple → staple → install in /Applications
# and a notarized zip in dist/ you can hand to anyone.
#
#   scripts/release.sh                 full production build, installed and launched
#   scripts/release.sh --no-notarize   Developer ID signed but not notarized (fine for this Mac only)
#   scripts/release.sh --no-install    just produce dist/AirControl-<version>.zip
#
# One-time setup:
#   1. A "Developer ID Application" certificate: Xcode → Settings → Accounts → Manage Certificates → + .
#   2. Notarization credentials saved in your keychain (uses an app-specific password from account.apple.com):
#        xcrun notarytool store-credentials AirControl --apple-id YOUR_APPLE_ID --team-id BH8R3BX5WF
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Air Control"
SCHEME="AirControl"
TEAM_ID="BH8R3BX5WF"
PROFILE="${NOTARY_PROFILE:-AirControl}"
NOTARIZE=1
INSTALL=1

for arg in "$@"; do
    case "$arg" in
        --no-notarize) NOTARIZE=0 ;;
        --no-install) INSTALL=0 ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
    esac
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31m✗ %s\033[0m\n' "$1"; exit 1; }

# --- Preflight -----------------------------------------------------------------------------
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application.*($TEAM_ID)"; then
    fail "No \"Developer ID Application\" certificate for team $TEAM_ID in your keychain.
  Create one in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application."
fi
if [ "$NOTARIZE" = 1 ] && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    fail "No notarization credentials saved as \"$PROFILE\". Run once:
  xcrun notarytool store-credentials $PROFILE --apple-id YOUR_APPLE_ID --team-id $TEAM_ID
  (it asks for an app-specific password from account.apple.com), or use --no-notarize."
fi

BUILD="build/release"
ARCHIVE="$BUILD/AirControl.xcarchive"
EXPORT="$BUILD/export"
DIST="dist"
rm -rf "$BUILD"
mkdir -p "$BUILD" "$DIST"

VERSION=$(xcodebuild -project AirControl.xcodeproj -scheme "$SCHEME" -configuration Release -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
# Build number: commit count once the repo has commits, otherwise a timestamp. Always increases.
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)

# --- Archive -------------------------------------------------------------------------------
step "Archiving $APP_NAME $VERSION ($BUILD_NUMBER)"
xcodebuild archive \
    -project AirControl.xcodeproj -scheme "$SCHEME" -configuration Release \
    -destination "generic/platform=macOS" -archivePath "$ARCHIVE" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" -quiet

# --- Sign ----------------------------------------------------------------------------------
step "Signing with Developer ID"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist scripts/ExportOptions.plist -allowProvisioningUpdates -quiet
APP="$EXPORT/$APP_NAME.app"
codesign --verify --deep --strict "$APP" || fail "Code signature didn't verify."

# --- Notarize ------------------------------------------------------------------------------
if [ "$NOTARIZE" = 1 ]; then
    step "Notarizing with Apple (usually a few minutes)"
    ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
    RESULT=$(xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile "$PROFILE" --wait --output-format json)
    if ! grep -q '"status" *: *"Accepted"' <<<"$RESULT"; then
        ID=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' <<<"$RESULT" | head -1)
        echo "$RESULT"
        [ -n "$ID" ] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" || true
        fail "Notarization was rejected — the log above says why."
    fi
    xcrun stapler staple -q "$APP"
    spctl --assess --type execute "$APP" || fail "Gatekeeper rejected the notarized app."
fi

ZIP="$DIST/AirControl-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# --- Install -------------------------------------------------------------------------------
if [ "$INSTALL" = 1 ]; then
    step "Installing to /Applications"
    osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
    sleep 1
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP" "/Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
fi

printf '\n\033[32m✓ %s %s (%s)\033[0m' "$APP_NAME" "$VERSION" "$BUILD_NUMBER"
[ "$NOTARIZE" = 1 ] && printf ' — signed, notarized and stapled' || printf ' — signed, not notarized'
printf '\n  %s\n' "$ZIP"
[ "$INSTALL" = 1 ] && printf '  /Applications/%s.app\n' "$APP_NAME"
