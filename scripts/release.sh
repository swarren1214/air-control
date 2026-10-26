#!/bin/bash
# Production build of Air Control:
#   archive (Release) → sign with Developer ID → notarize → staple → disk image → sign, notarize and
#   staple the disk image → install in /Applications.
# The result is dist/AirControl-<version>.dmg: open it, drag Air Control onto Applications, done.
#
#   scripts/release.sh                 full production build + DMG, installed and launched
#   scripts/release.sh --no-notarize   Developer ID signed but not notarized (fine for this Mac only)
#   scripts/release.sh --no-install    just produce the DMG
#
# One-time setup:
#   1. A "Developer ID Application" certificate: Xcode → Settings → Accounts → Manage Certificates → + .
#   2. Notarization credentials saved in your keychain (uses an app-specific password from account.apple.com):
#        xcrun notarytool store-credentials AirControl --apple-id YOUR_APPLE_ID --team-id BH8R3BX5WF
#   The first DMG build asks to let Terminal control Finder — that's what lays out the install window.
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
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (try --help)"; exit 1 ;;
    esac
done

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31m✗ %s\033[0m\n' "$1"; exit 1; }

# --- Preflight -----------------------------------------------------------------------------
IDENTITY=$(security find-identity -v -p codesigning | awk -v t="($TEAM_ID)" '/Developer ID Application/ && index($0, t) {print $2; exit}')
[ -n "$IDENTITY" ] || fail "No \"Developer ID Application\" certificate for team $TEAM_ID in your keychain.
  Create one in Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application."
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
# Build number: commit count (always increases).
BUILD_NUMBER=$(git rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)

# Submits a file to Apple, waits, staples the ticket onto it.
notarize() {
    local file="$1" upload="$1"
    if [ -d "$file" ]; then
        upload="$BUILD/notarize.zip"
        ditto -c -k --keepParent "$file" "$upload"
    fi
    local result id
    result=$(xcrun notarytool submit "$upload" --keychain-profile "$PROFILE" --wait --output-format json)
    if ! grep -q '"status" *: *"Accepted"' <<<"$result"; then
        id=$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' <<<"$result" | head -1)
        echo "$result"
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" || true
        fail "Notarization of $(basename "$file") was rejected — the log above says why."
    fi
    xcrun stapler staple -q "$file"
}

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

if [ "$NOTARIZE" = 1 ]; then
    step "Notarizing the app (usually a few minutes)"
    notarize "$APP"
    spctl --assess --type execute "$APP" || fail "Gatekeeper rejected the notarized app."
fi

# --- Disk image ----------------------------------------------------------------------------
step "Building the disk image"
DMG="$DIST/AirControl-$VERSION.dmg"
STAGE="$BUILD/dmg"
RW="$BUILD/rw.dmg"
VOL="$APP_NAME"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
tiffutil -cathidpicheck Design/DMG/background.png Design/DMG/background@2x.png \
    -out "$STAGE/.background/background.tiff" >/dev/null 2>&1
# The volume shows the app's icon in Finder's sidebar and on the desktop.
ICON_FILE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null || true)
[ -n "$ICON_FILE" ] && [ -f "$APP/Contents/Resources/${ICON_FILE%.icns}.icns" ] && \
    cp "$APP/Contents/Resources/${ICON_FILE%.icns}.icns" "$STAGE/.VolumeIcon.icns"

hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" -quiet
DEVICE=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | awk '/Apple_HFS/ {print $1; exit}')
[ -f "/Volumes/$VOL/.VolumeIcon.icns" ] && xcrun SetFile -a C "/Volumes/$VOL" 2>/dev/null || true

# Lay out the window: background art, big icons, app on the left, Applications on the right.
if ! osascript >/dev/null <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 548}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "$APP_NAME.app" of container window to {170, 190}
        set position of item "Applications" of container window to {470, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
then
    echo "  Finder layout skipped. Allow Terminal to control Finder (System Settings → Privacy & Security →"
    echo "  Automation) and run again for the styled install window. The DMG still works without it."
fi
chmod -Rf go-w "/Volumes/$VOL" 2>/dev/null || true
sync
hdiutil detach "$DEVICE" -quiet || { sleep 2; hdiutil detach "$DEVICE" -force -quiet; }
hdiutil convert "$RW" -format ULFO -o "$DMG" -ov -quiet
rm -f "$RW"

codesign --sign "$IDENTITY" --timestamp "$DMG"
if [ "$NOTARIZE" = 1 ]; then
    step "Notarizing the disk image"
    notarize "$DMG"
    spctl --assess --type open --context context:primary-signature "$DMG" || fail "Gatekeeper rejected the disk image."
fi

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
printf '\n  %s\n' "$DMG"
[ "$INSTALL" = 1 ] && printf '  /Applications/%s.app\n' "$APP_NAME"
