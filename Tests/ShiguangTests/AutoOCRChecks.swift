import AppKit
import Foundation

private struct OCRCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw OCRCheckFailure(message: message) }
}

@MainActor
private final class OCRFixture {
    let suite = "Shiguang.AutoOCRChecks.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let preferences: UserDefaults

    init() {
        preferences = UserDefaults(suiteName: suite)!
        preferences.set(false, forKey: "keepHistory")
    }

    func model(recognize: @escaping (CGImage) async throws -> String = OCRService.recognize,
               timing: OCRTimingPolicy = OCRTimingPolicy()) -> AppModel {
        AppModel(historyDirectory: directory,
                 permission: ScreenCapturePermission(preflight: { false }, request: { false }),
                 preferences: preferences, recognizeImage: recognize, ocrTiming: timing)
    }

    func cleanUp() {
        preferences.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class OCRGate {
    var pending: [CheckedContinuation<String, Error>?] = []

    func recognize(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }

    func finish(_ index: Int, text: String) {
        pending[index]?.resume(returning: text)
        pending[index] = nil
    }

    func cleanUp() {
        for continuation in pending { continuation?.resume(throwing: CancellationError()) }
        pending = []
    }
}

@main
@MainActor
struct AutoOCRChecks {
    private static func image() -> NSImage {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: 32, height: 32))
    }

    private static func waitUntil(timeout: Duration = .seconds(3),
                                  _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw OCRCheckFailure(message: "Timed out waiting for model state") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func preferences() async throws {
        let fixture = OCRFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.set(true, forKey: "autoOCR")
        let legacy = fixture.model()
        try require(legacy.autoOCR, "Preserve the legacy enabled setting during upgrade")
        legacy.autoOCR = false
        try require(!fixture.model().autoOCR, "An explicit new setting must override the legacy value")
        legacy.autoOCR = true
        try require(fixture.model().autoOCR, "Enabling auto OCR must survive model relaunch")
        try require(UserDefaults.standard !== fixture.preferences, "Use isolated preferences")
    }

    static func automaticCapture() async throws {
        let fixture = OCRFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.set(true, forKey: "autoOCR.v2")
        fixture.preferences.set(true, forKey: "autoTranslate")
        fixture.preferences.set(true, forKey: "keepHistory")
        var calls = 0
        let model = fixture.model { _ in calls += 1; return "Automatically recognized screenshot" }
        var overlayOpened = false
        var textOpened = false
        model.showCaptureOverlay = { _, _ in overlayOpened = true }
        model.showEditor = { textOpened = true }
        model.acceptImage(image(), title: "Capture fixture", inlineRect: CGRect(x: 0, y: 0, width: 32, height: 32))
        try require(!model.isRecognizing && !textOpened && overlayOpened && model.editorMode == .annotation && calls == 0,
                    "A normal screenshot must remain editable even when automatic import preferences are enabled")
        model.recognizeInWindow()
        try require(model.isRecognizing && textOpened && model.editorMode == .recognition,
                    "Only the explicit recognition action opens its text window")
        try await waitUntil { !model.isRecognizing }
        try require(calls == 1 && model.sourceText == "Automatically recognized screenshot" && !model.isBusy,
                    "Complete auto OCR exactly once without manual action")
        let drafts = try model.store?.load()
        try require(drafts?.isEmpty == true, "Recognition in an unconfirmed screenshot must remain a draft")
        model.acceptDraft()
        let savedText = try model.store?.load().first?.text
        try require(savedText == model.sourceText, "Persist automatic OCR results with the screenshot")
        let notice = model.notice
        model.refreshPermissionStatus()
        try require(model.notice == notice, "Window activation must not overwrite the recognition result status")
    }

    static func disabledCapture() async throws {
        let fixture = OCRFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.set(false, forKey: "autoOCR.v2")
        var calls = 0
        let model = fixture.model { _ in calls += 1; return "Unexpected OCR" }
        model.acceptImage(image(), title: "Disabled fixture")
        try require(calls == 0 && !model.isRecognizing && !model.isBusy, "Honor an explicit disabled setting")
    }

    static func translationForcesOCR() async throws {
        for automatic in [false, true] {
            let fixture = OCRFixture()
            defer { fixture.cleanUp() }
            fixture.preferences.set(false, forKey: "autoOCR.v2")
            fixture.preferences.set(automatic, forKey: "autoTranslate")
            let model = fixture.model { _ in "Hello world" }
            defer { model.cancelTranslation() }
            model.acceptImage(image(), title: "Translation fixture", translate: !automatic)
            try await waitUntil { model.translationJob != nil }
            try require(model.sourceText == "Hello world" && model.translationJob?.text == "Hello world",
                        "Both explicit and automatic translation must wait for OCR")
        }
    }

    static func newCaptureCancelsOCR() async throws {
        let fixture = OCRFixture()
        let gate = OCRGate()
        defer { gate.cleanUp(); fixture.cleanUp() }
        fixture.preferences.set(true, forKey: "autoOCR.v2")
        let model = fixture.model(recognize: gate.recognize)
        model.acceptImage(image(), title: "Old capture")
        try await waitUntil { gate.pending.count == 1 }
        var selections = 0
        model.beginSelection = { _ in selections += 1 }
        model.capture()
        try require(selections == 1 && !model.isRecognizing && model.isBusy,
                    "A new screenshot must cancel OCR and enter selection immediately")
        gate.finish(0, text: "Late old text")
        try await Task.sleep(for: .milliseconds(20))
        try require(model.sourceText.isEmpty && model.activity?.contains("正在截图") == true,
                    "An old OCR completion must not replace the active capture state")
        model.activity = nil
    }

    private static func cancellationClearsPendingAlerts() throws {
        let fixture = OCRFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.set(true, forKey: "autoOCR.v2")
        let gate = OCRGate()
        defer { gate.cleanUp() }
        let model = fixture.model(recognize: gate.recognize)

        model.acceptImage(image(), title: "Draft")
        try require(model.isRecognizing, "Fixture must have pending OCR before cancellation")
        model.errorMessage = "stale translation error"
        model.discardDraft()
        try require(!model.isRecognizing && model.errorMessage == nil,
                    "Discarding a draft must cancel OCR and clear stale alerts")

        model.errorMessage = "stale capture error"
        model.capture()
        try require(model.errorMessage == nil,
                    "Starting a selection must not carry a stale alert into the cancellation path")
        model.captureCancelled()

        model.sourceText = "中文"
        model.sourceLanguage = "auto"
        model.targetLanguage = "zh-Hans"
        model.errorMessage = nil
        model.requestTranslation()
        try require(model.translationJob != nil || model.errorMessage != nil,
                    "Fixture must reach either pending translation or an explicit language alert")
        model.cancelTranslation()
        try require(model.errorMessage == nil,
                    "Canceling translation must clear an alert before the workspace is restored")

        model.sourceLanguage = "zh-Hans"
        model.targetLanguage = "zh-Hans"
        model.requestTranslation()
        try require(model.errorMessage != nil, "Identical manual languages must produce an explicit alert")
        model.cancelTranslation()
        try require(model.errorMessage == nil,
                    "Canceling translation must also clear a non-job language alert")
    }

    static func discardedDraftRejectsLateWork() async throws {
        let fixture = OCRFixture()
        let gate = OCRGate()
        defer { gate.cleanUp(); fixture.cleanUp() }
        fixture.preferences.set(true, forKey: "autoTranslate")
        let model = fixture.model(recognize: gate.recognize)
        var opened = 0
        model.showEditor = { opened += 1 }
        model.showWorkspace = { opened += 1 }
        model.acceptImage(image(), title: "Canceled before OCR completed")
        try await waitUntil { gate.pending.count == 1 }
        let openedBeforeCancel = opened
        model.discardDraft()
        gate.finish(0, text: "Late text that must not be translated")
        try await Task.sleep(for: .milliseconds(20))
        try require(model.image == nil && model.draftImage == nil && !model.isBusy &&
                    model.sourceText.isEmpty && model.translationJob == nil && model.errorMessage == nil,
                    "Late OCR must not translate or restore a discarded screenshot")
        try require(opened == openedBeforeCancel, "Cancellation and late OCR must not reopen any window")

        model.acceptImage(image(), title: "Canceled during translation")
        try await waitUntil { gate.pending.count == 2 }
        gate.finish(1, text: "Hello world")
        try await waitUntil { model.translationJob != nil }
        let job = model.translationJob!
        let openedBeforeTranslationCancel = opened
        model.discardDraft()
        model.finishTranslation(job, text: "Late translation")
        model.failTranslation(job, error: OCRCheckFailure(message: "Late translation error"))
        try require(model.image == nil && model.translatedText.isEmpty && model.translationJob == nil &&
                    !model.isBusy && model.errorMessage == nil && opened == openedBeforeTranslationCancel,
                    "Translation callbacks for a discarded screenshot must be ignored")
    }

    static func replacementRejectsStaleResult() async throws {
        let fixture = OCRFixture()
        let gate = OCRGate()
        defer { gate.cleanUp(); fixture.cleanUp() }
        fixture.preferences.set(true, forKey: "autoOCR.v2")
        let model = fixture.model(recognize: gate.recognize)
        model.acceptImage(image(), title: "First")
        try await waitUntil { gate.pending.count == 1 }
        model.acceptImage(image(), title: "Second")
        try await waitUntil { gate.pending.count == 2 }
        gate.finish(1, text: "Second image text")
        try await waitUntil { !model.isRecognizing }
        gate.finish(0, text: "Stale first image text")
        try await Task.sleep(for: .milliseconds(20))
        try require(model.sourceText == "Second image text" && model.errorMessage == nil,
                    "Late recognition from an old image must not overwrite the new image")
    }

    static func initialRecognitionBudget() async throws {
        let fixture = OCRFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.set(true, forKey: "autoOCR.v2")
        let timing = OCRTimingPolicy(initialTimeout: .seconds(2), subsequentTimeout: .milliseconds(50),
                                     preparationNoticeDelay: .milliseconds(10))
        let model = fixture.model(recognize: { _ in
            try await Task.sleep(for: .milliseconds(150))
            return "Ready"
        }, timing: timing)
        model.acceptImage(image(), title: "Initial model preparation")
        try await waitUntil { model.activity?.contains("首次") == true }
        try await waitUntil { !model.isRecognizing }
        try require(model.sourceText == "Ready" && model.errorMessage == nil,
                    "The initial request must use the longer preparation budget")
        model.acceptImage(image(), title: "Warm request timeout")
        try await waitUntil { !model.isRecognizing }
        try require(model.errorMessage?.contains("耗时过长") == true && !model.isBusy,
                    "Subsequent stalled requests must still time out and recover")
    }

    static func realVisionCapture() async throws {
        let fixture = OCRFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.set(true, forKey: "autoOCR.v2")
        let model = fixture.model()
        let sample = DemoImage.make()
        let started = ContinuousClock.now
        model.acceptImage(sample, title: "Real Vision auto OCR",
                          inlineRect: CGRect(origin: .zero, size: sample.size))
        model.recognizeInWindow()
        try await waitUntil(timeout: .seconds(125)) { !model.isRecognizing }
        try require(model.errorMessage == nil, "Real Vision pipeline failed: \(model.errorMessage ?? "")")
        try require(model.sourceText.contains("Make room") && model.sourceText.contains("good ideas") &&
                    model.sourceText.contains("Capture a thought"),
                    "The actual automatic screenshot pipeline must produce the expected text")
        log("Real automatic OCR: \(started.duration(to: .now)), \(model.sourceText.count) characters")
    }

    static func log(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static func main() async {
        var checks: [(String, () async throws -> Void)] = [
            ("auto_ocr_preference_migration_and_relaunch", preferences),
            ("capture_edits_before_explicit_recognition", automaticCapture),
            ("disabled_auto_ocr_is_respected", disabledCapture),
            ("translation_waits_for_automatic_ocr", translationForcesOCR),
            ("new_capture_cancels_pending_ocr", newCaptureCancelsOCR),
            ("cancellation_clears_pending_alerts", cancellationClearsPendingAlerts),
            ("discarded_draft_ignores_late_ocr_and_translation", discardedDraftRejectsLateWork),
            ("replacement_image_rejects_stale_ocr", replacementRejectsStaleResult),
            ("initial_preparation_and_warm_timeout_recovery", initialRecognitionBudget)
        ]
        if !ProcessInfo.processInfo.arguments.contains("--skip-vision") {
            checks.append(("real_vision_automatic_screenshot_pipeline", realVisionCapture))
        }
        var failures = 0
        for (name, run) in checks {
            do { try await run(); log("PASS \(name)") }
            catch { failures += 1; log("FAIL \(name): \(error.localizedDescription)") }
        }
        log("\(checks.count - failures)/\(checks.count) automatic OCR checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
