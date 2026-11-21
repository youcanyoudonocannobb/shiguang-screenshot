#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/.build}"
mkdir -p "$BUILD_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx15.0" \
    "$PROJECT_DIR/Sources/Shiguang/HotkeySettings.swift" \
    "$PROJECT_DIR/Sources/Shiguang/ConfigurationExport.swift" \
    "$PROJECT_DIR/Tests/ShiguangTests/ConfigurationExportChecks.swift" \
    -o "$BUILD_DIR/ShiguangConfigurationExportChecks"
"$BUILD_DIR/ShiguangConfigurationExportChecks"
