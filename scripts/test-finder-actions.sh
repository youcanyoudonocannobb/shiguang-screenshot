#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/.build}"
mkdir -p "$BUILD_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx15.0" \
    "$PROJECT_DIR/Sources/Shiguang/Localization.swift" \
    "$PROJECT_DIR/Sources/Shiguang/FinderActionRequest.swift" \
    "$PROJECT_DIR/Sources/Shiguang/FinderFiles.swift" \
    "$PROJECT_DIR/Tests/ShiguangTests/FinderActionsChecks.swift" \
    -o "$BUILD_DIR/PawShotFinderActionsChecks"
"$BUILD_DIR/PawShotFinderActionsChecks"
