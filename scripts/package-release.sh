#!/bin/bash
# Build PawShot and package it as a drag-to-Applications DMG plus a ZIP archive.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/dist}"
APP="$OUTPUT_DIR/PawShot.app"
SKIP_BUILD=0
NOTARIZE=0

for argument in "$@"; do
    case "$argument" in
        --skip-build) SKIP_BUILD=1 ;;
        --notarize) NOTARIZE=1 ;;
        *) echo "Unknown argument: $argument" >&2; exit 2 ;;
    esac
done

if [[ "$SKIP_BUILD" == "0" ]]; then
    bash "$PROJECT_DIR/scripts/build.sh"
fi

if [[ ! -d "$APP" ]]; then
    echo "Missing app bundle: $APP" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
ARCH="$(lipo -archs "$APP/Contents/MacOS/Shiguang" | tr ' ' '-')"
BASENAME="PawShot-${VERSION}-${ARCH}"
DMG="$OUTPUT_DIR/${BASENAME}.dmg"
ZIP="$OUTPUT_DIR/${BASENAME}.zip"

echo "Packaging PawShot ${VERSION} (${BUILD_NUMBER}) for ${ARCH}"

if [[ "$NOTARIZE" == "1" ]]; then
    : "${APPLE_ID:?APPLE_ID is required for notarization}"
    : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required for notarization}"
    : "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required for notarization}"
    NOTARY_ZIP="$(mktemp -d)/PawShot.zip"
    ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
    xcrun notarytool submit "$NOTARY_ZIP" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_SPECIFIC_PASSWORD" \
        --wait
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pawshot-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP" "$STAGING_DIR/PawShot.app"
ln -s /Applications "$STAGING_DIR/Applications"

rm -f "$DMG" "$ZIP"
hdiutil create \
    -volname "PawShot ${VERSION}" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

ditto -c -k --keepParent "$APP" "$ZIP"

(
    cd "$OUTPUT_DIR"
    shasum -a 256 "${BASENAME}.dmg" "${BASENAME}.zip" > "${BASENAME}.sha256"
)

echo "Created:"
echo "  $DMG"
echo "  $ZIP"
echo "  $OUTPUT_DIR/${BASENAME}.sha256"
