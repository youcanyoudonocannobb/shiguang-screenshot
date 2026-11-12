#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/.build}"
mkdir -p "$BUILD_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
swiftc -parse-as-library -swift-version 5 \
    "$PROJECT_DIR/Sources/Shiguang/Models.swift" \
    "$PROJECT_DIR/Tests/ShiguangTests/ShiguangTests.swift" \
    -o "$BUILD_DIR/ShiguangChecks"
"$BUILD_DIR/ShiguangChecks"
