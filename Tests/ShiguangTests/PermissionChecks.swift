import AppKit
import ScreenCaptureKit

private struct RegressionFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw RegressionFailure(message: message) }
}

@main
@MainActor
struct PermissionChecks {
    static func permissionInspection() throws {
        var granted = false
        var requests = 0
        var permission = ScreenCapturePermission(preflight: { granted }, request: { requests += 1; return false })
        permission.refresh()
        permission.refresh()
        try require(!permission.isGranted && requests == 0, "Checking status must never request authorization")
        granted = true
        permission.refresh()
        try require(permission.isGranted, "Status must refresh after returning from System Settings")
        permission.authorize()
        try require(requests == 0, "An already authorized app must not prompt again")
        granted = false
        permission.refresh()
        try require(!permission.isGranted, "Revoked access must be reflected")
        permission.captureSucceeded()
        try require(permission.refresh(), "A real capture must override a false legacy preflight result")
        permission.captureDenied()
        try require(!permission.isGranted && !permission.refresh(), "Actual denial must invalidate cached capture access")
    }

    static func permissionRequest() throws {
        var granted = false
        var requests = 0
        var permission = ScreenCapturePermission(preflight: { granted }, request: {
            requests += 1
            granted = true
            return true
        })
        try require(permission.authorize(), "New access must be usable without an unconditional restart")
        try require(permission.isGranted && requests == 1, "Request access exactly once")
        var delayed = ScreenCapturePermission(preflight: { false }, request: { true })
        try require(!delayed.authorize(), "An accepted request is not proof of live process access")
        try require(delayed.requestAccepted && !delayed.isGranted, "Expose the accepted-but-not-active state")
    }

    static func captureGeometry() throws {
        guard let region = CaptureRegion(selection: CGRect(x: 20, y: 30, width: 120, height: 80),
                                         displaySize: CGSize(width: 1440, height: 900), scale: 2) else {
            throw RegressionFailure(message: "Valid Retina region rejected")
        }
        try require(region.sourceRect == CGRect(x: 20, y: 790, width: 120, height: 80),
                    "Convert bottom-left AppKit coordinates to display-local top-left coordinates")
        try require(region.pixelWidth == 240 && region.pixelHeight == 160, "Retain Retina output resolution")
        let clipped = CaptureRegion(selection: CGRect(x: -20, y: 880, width: 80, height: 80),
                                    displaySize: CGSize(width: 1440, height: 900), scale: 1)
        try require(clipped?.sourceRect == CGRect(x: 0, y: 0, width: 60, height: 20),
                    "Clip selections at display boundaries")
        let fractional = CaptureRegion(selection: CGRect(x: 0, y: 0, width: 10.25, height: 5.25),
                                       displaySize: CGSize(width: 100, height: 100), scale: 2)
        try require(fractional?.pixelWidth == 21 && fractional?.pixelHeight == 11,
                    "Fractional point regions must not lose edge pixels")
        try require(CaptureRegion(selection: CGRect(x: 200, y: 0, width: 10, height: 10),
                                  displaySize: CGSize(width: 100, height: 100), scale: 1) == nil,
                    "Reject entirely off-screen selections")
        try require(CaptureRegion(selection: CGRect(x: 0, y: 0, width: 10, height: 10),
                                  displaySize: .zero, scale: 2) == nil, "Reject disconnected display sizes")
    }

    static func withModel(granted: Bool, run: (AppModel) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(historyDirectory: directory,
                             permission: ScreenCapturePermission(preflight: { granted }, request: { false }))
        model.image = NSImage(size: NSSize(width: 100, height: 80))
        model.sourceText = "Unfinished OCR edits"
        model.translatedText = "尚未导出的译文"
        model.addMark(Mark(tool: .rectangle, points: [UnitPoint(x: 0.1, y: 0.2), UnitPoint(x: 0.7, y: 0.8)],
                           colorHex: "E45F3C"))
        try run(model)
    }

    static func deniedCapture() throws {
        try withModel(granted: false) { model in
            let original = model.image
            var selections = 0
            model.beginSelection = { _ in selections += 1 }
            model.capture()
            try require(selections == 1 && model.isBusy, "A false legacy preflight must not block the modern capture API")
            model.captureFailed(NSError(domain: SCStreamErrorDomain,
                                        code: SCStreamError.Code.userDeclined.rawValue))
            try require(!model.isBusy, "Actual permission denial must restore operation")
            try require(model.showsPermissionHelp && model.errorMessage == nil, "Offer actionable permission help")
            try require(model.image === original && model.sourceText == "Unfinished OCR edits" &&
                        model.translatedText == "尚未导出的译文" && model.marks.count == 1 && model.canUndo,
                        "Denied capture must preserve the current document and undo stack")
        }
    }

    static func pendingCapture() throws {
        try withModel(granted: true) { model in
            let original = model.image
            var selections = 0
            model.beginSelection = { translate in
                selections += 1
                assert(translate)
            }
            model.capture(translate: true)
            model.capture()
            try require(selections == 1 && model.isBusy, "Ignore concurrent capture requests")
            try require(model.image === original && model.sourceText == "Unfinished OCR edits" &&
                        model.translatedText == "尚未导出的译文" && model.marks.count == 1,
                        "Keep the document until replacement capture succeeds")
            model.activity = nil
            try require(model.canUndo, "Canceling a selection must retain annotation undo")
        }
    }

    static func captureFailure() throws {
        try withModel(granted: false) { model in
            model.activity = "Capturing"
            model.captureFailed(NSError(domain: SCStreamErrorDomain,
                                        code: SCStreamError.Code.userDeclined.rawValue))
            try require(!model.isBusy && model.showsPermissionHelp && model.errorMessage == nil,
                        "Permission failures must lead to authorization help")
            model.showsPermissionHelp = false
            model.activity = "Capturing"
            model.captureFailed(CaptureFailure.displayUnavailable)
            try require(!model.isBusy && !model.showsPermissionHelp &&
                        model.errorMessage?.contains("显示器") == true,
                        "Capture failures must not be mislabeled as cancellation or denial")
            try require(model.sourceText == "Unfinished OCR edits" && model.marks.count == 1,
                        "Capture errors must not erase the document")
            model.errorMessage = nil
            model.activity = "Capturing"
            model.captureFailed(CaptureFailure.timedOut)
            try require(!model.isBusy && !model.showsPermissionHelp &&
                        model.errorMessage?.contains("没有响应") == true,
                        "A hung capture must surface a timeout instead of staying busy forever")
        }
    }

    static func relaunchArguments() throws {
        let path = "/tmp/Chinese 空格 ' $(literal)/拾光截图.app"
        let url = URL(fileURLWithPath: path)
        let arguments = ["Shiguang"] + AppRelauncher.arguments(parentPID: 123, bundleURL: url)
        let parsed = AppRelauncher.target(from: arguments)
        try require(parsed?.pid == 123 && parsed?.url.path == path, "Preserve the exact bundle path without shell evaluation")
        try require(AppRelauncher.target(from: ["Shiguang", AppRelauncher.helperFlag, "0", path]) == nil,
                    "Reject invalid parent process IDs")
        try require(AppRelauncher.target(from: ["Shiguang", AppRelauncher.helperFlag, "123", "relative.app"]) == nil,
                    "Reject relative relaunch targets")
        var rejected = false
        do { try AppRelauncher.start(bundleURL: URL(fileURLWithPath: "/tmp/missing-shiguang.app"), parentPID: 123) }
        catch { rejected = true }
        try require(rejected, "Report helper launch errors before terminating the current app")
    }

    static func main() {
        let checks: [(String, () throws -> Void)] = [
            ("permission_check_is_read_only_and_refreshes", permissionInspection),
            ("permission_request_and_pending_access", permissionRequest),
            ("capture_geometry_and_retina_pixels", captureGeometry),
            ("legacy_preflight_does_not_block_capture_and_denial_preserves_document", deniedCapture),
            ("pending_capture_preserves_document_and_blocks_reentry", pendingCapture),
            ("capture_error_classification_and_recovery", captureFailure),
            ("relaunch_literal_path_and_preflight_failure", relaunchArguments)
        ]
        var failures = 0
        for (name, run) in checks {
            do { try run(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error.localizedDescription)") }
        }
        print("\(checks.count - failures)/\(checks.count) permission and capture checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
