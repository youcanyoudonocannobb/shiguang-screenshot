#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$PROJECT_DIR/.build/configuration-import-checks}"
mkdir -p "$BUILD_DIR"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx15.0" \
    "$PROJECT_DIR/Sources/Shiguang/Localization.swift" \
    "$PROJECT_DIR/Sources/Shiguang/Models.swift" \
    "$PROJECT_DIR/Sources/Shiguang/HotkeySettings.swift" \
    "$PROJECT_DIR/Sources/Shiguang/AITranslation.swift" \
    "$PROJECT_DIR/Sources/Shiguang/TextToolbox.swift" \
    "$PROJECT_DIR/Sources/Shiguang/ScreenCaptureSupport.swift" \
    "$PROJECT_DIR/Sources/Shiguang/SelectedTextReader.swift" \
    "$PROJECT_DIR/Sources/Shiguang/AppRelauncher.swift" \
    "$PROJECT_DIR/Sources/Shiguang/AppModel.swift" \
    "$PROJECT_DIR/Sources/Shiguang/OCRTools.swift" \
    "$PROJECT_DIR/Sources/Shiguang/ImageCanvas.swift" \
    "$PROJECT_DIR/Sources/Shiguang/CaptureSelectionGeometry.swift" \
    "$PROJECT_DIR/Sources/Shiguang/ScreenRecorder.swift" \
    "$PROJECT_DIR/Sources/Shiguang/ClipboardHistory.swift" \
    "$PROJECT_DIR/Sources/Shiguang/FinderActionRequest.swift" \
    "$PROJECT_DIR/Sources/Shiguang/FinderFiles.swift" \
    "$PROJECT_DIR/Sources/Shiguang/FinderApps.swift" \
    "$PROJECT_DIR/Sources/Shiguang/FinderActionsCoordinator.swift" \
    "$PROJECT_DIR/Sources/Shiguang/ConfigurationExport.swift" \
    "$PROJECT_DIR/Sources/Shiguang/ConfigurationImport.swift" \
    "$PROJECT_DIR/Tests/ShiguangTests/ConfigurationImportChecks.swift" \
    -o "$BUILD_DIR/ShiguangConfigurationImportChecks"
"$BUILD_DIR/ShiguangConfigurationImportChecks" "$@"
