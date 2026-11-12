#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/.build}"
mkdir -p "$BUILD_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx15.0" \
    "$PROJECT_DIR/Sources/Shiguang/Models.swift" \
    "$PROJECT_DIR/Sources/Shiguang/ScreenCaptureSupport.swift" \
    "$PROJECT_DIR/Sources/Shiguang/AppRelauncher.swift" \
    "$PROJECT_DIR/Sources/Shiguang/AppModel.swift" \
    "$PROJECT_DIR/Tests/ShiguangTests/PermissionChecks.swift" \
    -o "$BUILD_DIR/ShiguangPermissionChecks"
"$BUILD_DIR/ShiguangPermissionChecks"
