#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/.build}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/dist}"
FINAL_APP="$OUTPUT_DIR/PawShot.app"
SIGN_IDENTITY="${SHIGUANG_SIGN_IDENTITY:-}"
# Local builds keep one persistent certificate; release builds sign with Developer ID.
if [[ -z "$SIGN_IDENTITY" ]]; then
    python3 "$PROJECT_DIR/scripts/local-signing.py" check
fi
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"

BUILD_OPTIONS=(--package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" --disable-sandbox -c release)
# Optional extra arguments, for example "--arch arm64 --arch x86_64" for a universal build.
if [[ -n "${SWIFT_BUILD_ARGS:-}" ]]; then
    read -r -a EXTRA_BUILD_ARGS <<< "$SWIFT_BUILD_ARGS"
    BUILD_OPTIONS+=("${EXTRA_BUILD_ARGS[@]}")
fi
# Swift 6.4 defaults to Swift Build, which requires extra Xcode components on some Macs.
if swift build --help | grep -q 'swiftbuild'; then
    BUILD_OPTIONS+=(--build-system native)
fi
swift build "${BUILD_OPTIONS[@]}"
BIN_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/.shiguang-build.XXXXXX")"
APP="$STAGING_DIR/PawShot.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Shiguang" "$APP/Contents/MacOS/Shiguang"
cp "$PROJECT_DIR/Info.plist" "$APP/Contents/Info.plist"
ICON_BUILD_DIR="$BUILD_DIR/IconRenderer"
ICON_RENDERER="$ICON_BUILD_DIR/icon-renderer"
mkdir -p "$ICON_BUILD_DIR"
cp "$PROJECT_DIR/scripts/icon.swift" "$ICON_BUILD_DIR/main.swift"
CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" swiftc \
    "$PROJECT_DIR/Sources/Shiguang/BrandArtwork.swift" "$ICON_BUILD_DIR/main.swift" \
    -o "$ICON_RENDERER"
"$ICON_RENDERER" "$BUILD_DIR/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    # CI fallback without certificates: ad-hoc signing keeps the bundle launchable locally.
    # Pin a stable designated requirement to the bundle identifier so TCC
    # permissions (Screen Recording, Accessibility) survive local rebuilds.
    codesign --force --sign - --identifier dev.shiguang.screenshot \
        --requirements '=designated => identifier "dev.shiguang.screenshot"' "$APP"
elif [[ -n "$SIGN_IDENTITY" ]]; then
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_IDENTITY" --identifier dev.shiguang.screenshot "$APP"
else
    python3 "$PROJECT_DIR/scripts/local-signing.py" sign "$APP"
fi
codesign --verify --strict "$APP"
# Publish only after signing and verification; preserve the previous app on failure.
python3 - "$APP" "$FINAL_APP" <<'PY'
from pathlib import Path
import os
import shutil
import sys

staged, destination = map(Path, sys.argv[1:])
previous = staged.parent / "previous.app"
if destination.exists():
    os.replace(destination, previous)
try:
    os.replace(staged, destination)
except OSError:
    if previous.exists():
        os.replace(previous, destination)
    raise
shutil.rmtree(staged.parent)
PY
echo "Built: $FINAL_APP"
