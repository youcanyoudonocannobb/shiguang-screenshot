#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/.build}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_DIR/dist}"
FINAL_APP="$OUTPUT_DIR/拾光截图.app"
# Fail before replacing a build if the persistent certificate is unavailable.
python3 "$PROJECT_DIR/scripts/local-signing.py" check
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"

BUILD_OPTIONS=(--package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" --disable-sandbox -c release)
# Swift 6.4 defaults to Swift Build, which requires extra Xcode components on some Macs.
if swift build --help | grep -q 'swiftbuild'; then
    BUILD_OPTIONS+=(--build-system native)
fi
swift build "${BUILD_OPTIONS[@]}"
BIN_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/.shiguang-build.XXXXXX")"
APP="$STAGING_DIR/拾光截图.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Shiguang" "$APP/Contents/MacOS/Shiguang"
cp "$PROJECT_DIR/Info.plist" "$APP/Contents/Info.plist"
swift "$PROJECT_DIR/scripts/icon.swift" "$BUILD_DIR/AppIcon.iconset" "$APP/Contents/Resources/AppIcon.icns"
python3 "$PROJECT_DIR/scripts/local-signing.py" sign "$APP"
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
