import AppKit
import AVFoundation
import ImageIO

private struct FeatureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FeatureFailure(message: message) }
}

@main
@MainActor
struct EditorFeatureChecks {
    static func sample(pattern: Bool = false) -> NSImage {
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        if pattern {
            for x in 0..<200 {
                context.setFillColor(CGColor(gray: x % 2 == 0 ? 0 : 1, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: 1, height: 100))
            }
        }
        return NSImage(cgImage: context.makeImage()!, size: CGSize(width: 200, height: 100))
    }

    static func legacyMarks() async throws {
        let mark = Mark(tool: .rectangle, points: [UnitPoint(x: 0.1, y: 0.1), UnitPoint(x: 0.5, y: 0.5)], colorHex: "E45F3C")
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mark)) as! [String: Any]
        old.removeValue(forKey: "text")
        old.removeValue(forKey: "fontSize")
        let decoded = try JSONDecoder().decode(Mark.self, from: JSONSerialization.data(withJSONObject: old))
        try require(decoded == mark, "Legacy mark history must remain readable")
        let text = Mark(tool: .text, points: [UnitPoint(x: 0.2, y: 0.3)], colorHex: "111111", text: "中文 + Text", fontSize: 0.04)
        let roundTrip = try JSONDecoder().decode(Mark.self, from: JSONEncoder().encode(text))
        try require(roundTrip == text, "Text and font size must survive history round trips")
    }

    static func textPixels() async throws {
        let text = Mark(tool: .text, points: [UnitPoint(x: 0.1, y: 0.1)], colorHex: "111111", text: "TEXT", fontSize: 0.2)
        let bitmap = NSBitmapImageRep(data: ImageRenderer.render(sample(), marks: [text]).pngData!)!
        var topInk = 0, bottomInk = 0
        for x in 0..<200 {
            for y in 0..<100 {
                let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if color.redComponent < 0.5 {
                    if y < 50 { topInk += 1 } else { bottomInk += 1 }
                }
            }
        }
        try require(topInk > 80 && bottomInk == 0, "Text must be visible at its top-left image coordinates")
        try require(bitmap.pixelsWide == 200 && bitmap.pixelsHigh == 100, "Annotations must retain original dimensions")
    }

    static func mosaicPixels() async throws {
        let original = sample(pattern: true)
        let mark = Mark(tool: .mosaic, points: [UnitPoint(x: 0.1, y: 0.1), UnitPoint(x: 0.5, y: 0.4)], colorHex: "111111")
        let bitmap = NSBitmapImageRep(data: ImageRenderer.render(original, marks: [mark]).pngData!)!
        let input = NSBitmapImageRep(data: original.pngData!)!
        func red(_ image: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
            image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!.redComponent
        }
        try require(abs(red(bitmap, 24, 20) - red(bitmap, 25, 20)) < 0.02, "Mosaic must remove the original stripe detail")
        try require(abs(red(bitmap, 24, 20) - red(input, 24, 20)) +
                    abs(red(bitmap, 25, 20) - red(input, 25, 20)) > 0.5, "Mosaic must change covered pixels")
        try require(abs(red(bitmap, 24, 80) - red(input, 24, 80)) < 0.02 &&
                    abs(red(bitmap, 25, 80) - red(input, 25, 80)) < 0.02, "Pixels outside the mosaic must remain intact")
    }

    static func zoomGeometry() async throws {
        let image = CGSize(width: 1400, height: 900), size = CGSize(width: 700, height: 500)
        var viewport = CanvasViewport(zoom: 2)
        let anchor = CGPoint(x: 400, y: 300)
        let before = viewport.imageRect(image: image, viewport: size)
        let unit = CGPoint(x: (anchor.x - before.minX) / before.width, y: (anchor.y - before.minY) / before.height)
        viewport.setZoom(3, anchor: anchor, image: image, viewport: size)
        let after = viewport.imageRect(image: image, viewport: size)
        try require(abs(after.minX + unit.x * after.width - anchor.x) < 0.001 &&
                    abs(after.minY + unit.y * after.height - anchor.y) < 0.001, "Wheel zoom must preserve the point under the cursor")
        viewport.setZoom(100, anchor: anchor, image: image, viewport: size)
        try require(viewport.zoom == 8, "Zoom must stop at the upper bound")
        viewport.setZoom(0.01, anchor: anchor, image: image, viewport: size)
        try require(viewport.zoom == 0.25, "Zoom must stop at the lower bound")
        viewport.offset = CGPoint(x: 60, y: 40)
        viewport.constrain(image: image, viewport: size)
        try require(viewport.offset == CGPoint(x: 60, y: 40), "Small images must remain draggable")
        viewport.offset = CGPoint(x: 10000, y: 10000)
        viewport.constrain(image: image, viewport: size)
        try require(viewport.imageRect(image: image, viewport: size).intersects(CGRect(origin: .zero, size: size)),
                    "Dragging must keep part of the image reachable")
    }

    static func editorActions() async throws {
        let suite = "Shiguang.EditorFeatureChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        defaults.set(false, forKey: "autoOCR.v2")
        defaults.set(false, forKey: "keepHistory")
        let model = AppModel(historyDirectory: folder,
                             permission: ScreenCapturePermission(preflight: { false }, request: { false }),
                             preferences: defaults, recognizeImage: { _ in
            try await Task.sleep(for: .milliseconds(30))
            return "Hello world"
        })
        model.acceptImage(sample(), title: "Fixture")
        model.acceptDraft()
        model.translateImage()
        try await Task.sleep(for: .milliseconds(100))
        try require(model.translationJob?.text == "Hello world", "Toolbar translation must recognize an image with no text first")
        var closed = false
        model.hideEditor = { closed = true }
        model.closeEditor()
        try require(closed && !model.isBusy && model.translationJob == nil, "Closing must dismiss the editor and cancel work")
        model.zoomFactor = 4
        model.acceptImage(sample(), title: "Next")
        model.acceptDraft()
        try require(model.zoomFactor == 1, "New images must start fitted to the viewport")
        let text = Mark(tool: .text, points: [UnitPoint(x: 0.1, y: 0.1)], colorHex: "111111", text: "Hello")
        model.addMark(text)
        model.undo()
        try require(model.marks.isEmpty, "Text must participate in annotation undo")
        var selectedFormat: RecordingFormat?
        model.beginRecording = { format, _ in selectedFormat = format }
        model.record(.gif)
        try require(selectedFormat == .gif, "GIF toolbar selection must reach the recording controller")
        model.recordingReady = true
        model.record(.video)
        try require(selectedFormat == .video, "Unsaved drafts must not redirect the new recording action")
        var scrollMode: ScrollCaptureMode?
        model.beginScrollCapture = { mode, _ in scrollMode = mode }
        model.captureScrolling(.manual)
        try require(scrollMode == .manual, "Manual long screenshot must reach its controller")
    }

    static func draftCancellationDismissesWindows() async throws {
        let suite = "Shiguang.DraftCancellationChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        defaults.set(false, forKey: "autoOCR.v2")
        defaults.set(false, forKey: "autoTranslate")
        defaults.set(true, forKey: "keepHistory")

        for mode: AppModel.EditorMode in [.annotation, .recognition, .text] {
            for useEscape in [false, true] {
                let model = AppModel(historyDirectory: folder, preferences: defaults)
                model.acceptImage(sample(), title: "Unconfirmed screenshot")
                model.editorMode = mode
                var editorVisible = true
                var overlayVisible = true
                var dismissedBeforeReset = true
                var reopenedWindows = 0
                model.hideEditor = { [unowned model] in
                    editorVisible = false
                    dismissedBeforeReset = dismissedBeforeReset && model.image != nil
                }
                model.closeCaptureOverlay = { [unowned model] in
                    overlayVisible = false
                    dismissedBeforeReset = dismissedBeforeReset && model.image != nil
                }
                model.showEditor = { reopenedWindows += 1 }
                model.showWorkspace = { reopenedWindows += 1 }

                if useEscape { model.closeEditor() }
                else { model.discardDraft() }

                try require(!editorVisible && !overlayVisible,
                            "Cancel and Esc must dismiss both editor windows, including text mode")
                try require(dismissedBeforeReset,
                            "Dismiss windows before clearing the screenshot so translation UI cannot flash")
                try require(reopenedWindows == 0 && model.editorMode == .annotation,
                            "Cancel must not open another workspace or switch to text translation")
                try require(model.image == nil && model.draftImage == nil && model.sourceText.isEmpty &&
                            model.translatedText.isEmpty && model.translationJob == nil && !model.isBusy,
                            "Cancel must clear the entire draft")
                let saved = try model.store!.load()
                try require(model.records.isEmpty && saved.isEmpty,
                            "A canceled screenshot must not be saved to history")
            }
        }
    }

    static func textTranslationRequiresExplicitEntry() async throws {
        let suite = "Shiguang.TextEntryChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        defaults.set(false, forKey: "autoOCR.v2")
        defaults.set(false, forKey: "autoTranslate")
        let model = AppModel(historyDirectory: folder, preferences: defaults)
        try require(model.image == nil && model.editorMode == .annotation,
                    "An empty model must not implicitly select text translation")
        var opened = 0
        model.showEditor = { opened += 1 }
        model.newText()
        try require(opened == 1 && model.image == nil && model.editorMode == .text,
                    "New text must explicitly open text translation")
        model.acceptImage(sample(), title: "Screenshot")
        try require(model.editorMode == .annotation, "A new screenshot must return to image editing")
        model.startTextTranslation()
        try require(model.image == nil && model.draftImage == nil && model.editorMode == .text,
                    "The translation menu must open text mode without retaining a screenshot draft")
    }

    static func recordingDimensions() async throws {
        let size = RecordingExport.videoSize(CGSize(width: 5119, height: 2879))
        try require(size.width <= 2560 && Int(size.width) % 2 == 0 && Int(size.height) % 2 == 0,
                    "H.264 output must use bounded, even pixel dimensions")
        let small = RecordingExport.videoSize(CGSize(width: 3, height: 5))
        try require(small.width == 2 && small.height == 4, "Small valid regions must remain encodable")
    }

    static func recordingDraftRecovery() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mp4")
        let bytes = Data("recording fixture".utf8)
        try bytes.write(to: source)
        let store = RecordingDraftStore(directory: folder.appendingPathComponent("Pending"))
        let saved = try store.preserve(source, format: .gif)
        let second = try store.preserve(source, format: .gif)
        let third = try store.preserve(source, format: .video)
        try require(Set(store.loadAll().map { $0.url.resolvingSymlinksInPath() }) == Set([saved, second, third].map { $0.resolvingSymlinksInPath() }),
                    "New MP4 and GIF recordings must preserve every unsaved draft")
        try FileManager.default.removeItem(at: source)
        let reopened = RecordingDraftStore(directory: store.directory)
        let drafts = reopened.loadAll()
        try require(!drafts.isEmpty && drafts.contains(where: { $0.url.resolvingSymlinksInPath() == saved.resolvingSymlinksInPath() && $0.format == .gif }),
                    "Cancelled saves must remain available after relaunch")
        let recoveredBytes = try Data(contentsOf: saved)
        try require(recoveredBytes == bytes, "Recovered recording must retain its contents")
        try store.removeExported(saved)
        try require(Set(store.loadAll().map { $0.url.resolvingSymlinksInPath() }) == Set([second, third].map { $0.resolvingSymlinksInPath() }), "Successful export must clear only its own pending draft")
    }

    static func draftCommitIsTransactional() async throws {
        let suite = "Shiguang.ConfirmationChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        defaults.set(false, forKey: "autoOCR.v2")
        defaults.set(true, forKey: "keepHistory")
        let model = AppModel(historyDirectory: folder, preferences: defaults)
        var copied = 0
        var copiedImage: NSImage?
        model.publishImage = { copied += 1; copiedImage = $0 }
        model.acceptImage(sample(), title: "Existing")
        model.sourceText = "Original history"
        model.confirmDraft()
        let original = try model.store!.load()
        model.acceptImage(sample(), title: "Draft")
        model.sourceEdited("Unconfirmed text")
        let mark = Mark(tool: .text, points: [UnitPoint(x: 0.1, y: 0.1)], colorHex: "111111", text: "Draft mark")
        model.addMark(mark)
        let unchanged = try model.store!.load()
        try require(unchanged.count == 1 && unchanged.first?.text == "Original history",
                    "Draft recognition and marks must not mutate the previously selected history record")
        model.exportImage()
        model.requestPin()
        try require(copied == 1 && model.draftImage != nil && model.draftPinsImage,
                    "Editing and optional actions must not copy or export before confirmation")
        model.discardDraft()
        try require(copied == 1 && !model.draftPinsImage,
                    "Cancel must clear all queued actions")
        let cancelled = try model.store!.load()
        try require(cancelled.count == original.count && cancelled.first?.text == original.first?.text,
                    "Cancel must not add or overwrite a PNG/history record")
        model.acceptImage(sample(), title: "Confirmed")
        model.sourceText = "Confirmed text"
        model.translatedText = "Confirmed translation"
        model.addMark(mark)
        var closed = false
        model.closeCaptureOverlay = { closed = true }
        model.confirmDraft()
        let saved = try model.store!.load()
        try require(closed && model.draftImage == nil && saved.count == 2 &&
                    saved.first?.text == "Confirmed text" && saved.first?.translation == "Confirmed translation" &&
                    saved.first?.marks == [mark], "Confirmation must commit all draft content once, then close the editor")
        try require(copied == 2 && copiedImage?.pngData == ImageRenderer.render(sample(), marks: [mark]).pngData,
                    "Checkmark must copy the fully annotated image by default")
        model.confirmDraft()
        try require(model.records.count == 2 && copied == 2, "Repeated confirmation must not duplicate history or clipboard writes")
        model.keepHistory = false
        model.acceptImage(sample(), title: "Clipboard only")
        model.confirmDraft()
        try require(copied == 3 && model.draftImage == nil && model.records.count == 2,
                    "History disabled must still copy immediately without a save dialog")
        let region = CGRect(x: 100, y: 150, width: 300, height: 200)
        var recordingRegion: CGRect?
        model.beginRecording = { _, selected in recordingRegion = selected }
        model.acceptImage(sample(), title: "Selected region", inlineRect: region)
        model.record(.gif)
        try require(recordingRegion == region && model.draftImage == nil && copied == 3,
                    "Recording must reuse the edited selection without saving the image or selecting again")
        var scrollingRegion: CGRect?
        model.beginScrollCapture = { _, selected in scrollingRegion = selected }
        model.acceptImage(sample(), title: "Scrolling region", inlineRect: region)
        model.captureScrolling(.manual)
        try require(scrollingRegion == region && copied == 3, "Long capture must receive the existing selection")
    }

    static func recordingConfirmation() async throws {
        for format in RecordingFormat.allCases {
            let session = RecordingSession(format: format)
            try require(!session.requestConfirmation() && session.begin(), "Selecting a region alone cannot save a recording")
            session.didStart()
            try require(session.stop() && !session.confirmRequested, "Stopping must enter preview without confirmation")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("draft.mp4")
            session.didFinish(url)
            try require(session.phase == .review && session.movieURL == url && !session.confirmRequested,
                        "A finished MP4/GIF must remain an unconfirmed draft")
            session.cancel()
            session.didFinish(url)
            try require(session.cancelled && session.movieURL == nil && !session.requestConfirmation(),
                        "Cancel must invalidate late finish callbacks and prevent persistence")
            let confirmed = RecordingSession(format: format)
            _ = confirmed.begin()
            confirmed.didStart()
            try require(confirmed.requestConfirmation() && confirmed.stop(), "Checkmark while recording must request save then stop")
            confirmed.didFinish(url)
            try require(confirmed.beginCopy() && !confirmed.requestConfirmation(), "Copying must be a single confirmed transaction")
            confirmed.didCommit()
            try require(confirmed.phase == .confirmed, "Only a confirmed finished movie can be committed")
            let paused = RecordingSession(format: format)
            _ = paused.begin(); paused.didStart()
            try require(paused.pause() && !paused.requestConfirmation(), "Wait for a pause to finalize before confirmation")
            paused.didPause()
            try require(paused.phase == .paused && paused.resume(), "A paused recording must resume the same draft")
            paused.didStart()
            _ = paused.pause(); paused.didPause()
            try require(paused.requestConfirmation() && paused.stop(), "Confirming while paused must finalize and copy")
            paused.didFinish(url)
            try require(paused.beginCopy(), "A paused recording must use the same confirmation transaction")
            paused.cancel(); paused.didPause(); paused.didFinish(url)
            try require(paused.cancelled && paused.movieURL == nil && !paused.resume(), "Late pause callbacks must not revive cancellation")
        }
    }

    static func screenSelectionGeometry() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let secondary = CGRect(x: -800, y: -100, width: 800, height: 600)
        let window = CaptureSelectionGeometry.windowRect(CGRect(x: -750, y: 350, width: 400, height: 300),
            primaryTop: 700, screenFrame: secondary)
        try require(window == CGRect(x: 50, y: 150, width: 400, height: 300),
                    "Window snapping must convert global CG coordinates on offset displays")
        let initial = CGRect(x: 100, y: 150, width: 300, height: 200)
        let resized = CaptureSelectionGeometry.resized(initial, handle: .topLeft,
            delta: CGSize(width: -40, height: 50), bounds: bounds)
        try require(resized == CGRect(x: 60, y: 150, width: 340, height: 250), "Resize must retain the opposite corner in screen coordinates")
        let crossed = CaptureSelectionGeometry.resized(initial, handle: .left,
            delta: CGSize(width: 1000, height: 0), bounds: bounds)
        try require(crossed.width == 8 && crossed.maxX == initial.maxX, "Crossing a handle must keep a valid crop")
        let moved = CaptureSelectionGeometry.clamped(initial.offsetBy(dx: 1000, dy: -1000), to: bounds)
        try require(bounds.contains(moved) && moved.size == initial.size, "Moving must preserve size and remain on the original display")
        let barSize = CGSize(width: 600, height: 46)
        let below = CaptureSelectionGeometry.toolbarFrame(selection: initial, size: barSize, visible: bounds)
        try require(abs(below.maxY - (initial.minY - 2)) < 0.01 && bounds.contains(below), "Toolbar must sit immediately below the selection")
        let low = CGRect(x: 800, y: 0, width: 100, height: 80)
        let above = CaptureSelectionGeometry.toolbarFrame(selection: low, size: barSize, visible: bounds)
        try require(above.minY == low.maxY + 2 && bounds.contains(above), "A bottom-edge crop must keep every control reachable above it")
    }

    static func retinaCropAndMarkAnchors() async throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
        for y in 0..<4 { for x in 0..<8 { bitmap.setColor(y < 2 ? red : blue, atX: x, y: y) } }
        let image = NSImage(cgImage: bitmap.cgImage!, size: CGSize(width: 4, height: 2))
        let crop = CaptureSelectionGeometry.crop(image, rect: CGRect(x: 0, y: 0, width: 2, height: 1), displaySize: image.size)!
        let pixels = NSBitmapImageRep(data: crop.pngData!)!
        try require(pixels.pixelsWide == 4 && pixels.pixelsHigh == 2, "Retina cropping must retain source pixel density")
        try require(pixels.colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!.blueComponent > 0.9,
                    "AppKit bottom-left selections must crop the correct CG image rows")
        let old = CGRect(x: 10, y: 20, width: 100, height: 80), next = CGRect(x: 30, y: 30, width: 50, height: 40)
        let mark = Mark(tool: .text, points: [UnitPoint(x: 0.1, y: 0.2)], colorHex: "111111", text: "Anchor", fontSize: 0.1)
        let mapped = CaptureSelectionGeometry.remap(mark, from: old, to: next)
        let p = mapped.points[0]
        try require(abs(next.minX + p.x * next.width - (old.minX + 10)) < 0.001 &&
                    abs(next.maxY - p.y * next.height - (old.maxY - 16)) < 0.001,
                    "Changing crop bounds must preserve annotation screen anchors, including clipped marks")
        try require(p.x < 0 && mapped.fontSize == 0.2, "Clipped marks must remain recoverable and retain their absolute font size")
    }

    static func adjustedSelectionStaysDraft() async throws {
        let suite = "Shiguang.SelectionChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(historyDirectory: folder, preferences: defaults)
        model.acceptImage(sample(), title: "Selected screen", inlineRect: CGRect(x: 0, y: 0, width: 200, height: 100))
        let mark = Mark(tool: .rectangle, points: [UnitPoint(x: 0.3, y: 0.3), UnitPoint(x: 0.7, y: 0.7)], colorHex: "E45F3C")
        model.addMark(mark)
        let adjusted = CGRect(x: 25, y: 20, width: 100, height: 60)
        model.updateCaptureRegion(sample(), rect: adjusted) { CaptureSelectionGeometry.remap($0,
            from: CGRect(x: 0, y: 0, width: 200, height: 100), to: adjusted) }
        try require(model.captureRect == adjusted && model.draftImage != nil && model.records.isEmpty,
                    "Moving and resizing must not confirm or write screenshot history")
        var usedRegion: CGRect?
        model.beginRecording = { _, rect in usedRegion = rect }
        model.record(.video)
        try require(usedRegion == adjusted && model.draftImage == nil && model.records.isEmpty,
                    "Recording must inherit the adjusted screen region without committing the screenshot")
    }

    static func textWindowsAndLanguageDefaults() async throws {
        let suite = "Shiguang.TextWindowChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        defaults.set(false, forKey: "autoOCR.v2")
        let model = AppModel(historyDirectory: folder, preferences: defaults, recognizeImage: { _ in "Hello world" })
        var overlays = 0, editors = 0
        model.showCaptureOverlay = { _, _ in overlays += 1 }
        model.showEditor = { editors += 1 }
        model.acceptImage(sample(), title: "Translate", translate: true,
                          inlineRect: CGRect(x: 0, y: 0, width: 200, height: 100))
        try require(overlays == 0 && editors == 1 && model.editorMode == .text,
                    "Capture-and-translate must never display an image editor, including during OCR")
        try await Task.sleep(for: .milliseconds(50))
        try require(model.translationJob?.target == "zh-Hans", "English source must default to Chinese")
        model.cancelTranslation()
        model.sourceText = "这是用于测试语言自动识别的一段中文。"
        model.sourceLanguage = "auto"
        model.requestTranslation()
        try require(model.translationJob?.target == "en", "Chinese source must default to English")
        model.cancelTranslation()
        model.languageEdited(target: "ja")
        model.requestTranslation()
        try require(model.translationJob?.target == "ja", "An explicit target choice must be respected after detection")
        model.cancelTranslation()
        model.discardDraft()
        model.acceptImage(sample(), title: "OCR")
        model.recognizeInWindow()
        try require(model.editorMode == .recognition, "OCR must use the dedicated recognition window")
        model.closeEditor()
    }

    static func annotationToolkitAndLanguageSwap() async throws {
        let suite = "Shiguang.AnnotationToolkitChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        defaults.set(false, forKey: "autoOCR.v2")
        let model = AppModel(historyDirectory: folder, preferences: defaults)
        model.acceptImage(sample(), title: "Toolkit")
        let ellipse = Mark(tool: .ellipse, points: [UnitPoint(x: 0.1, y: 0.1), UnitPoint(x: 0.4, y: 0.5)],
                           colorHex: "E45F3C", filled: true)
        let line = Mark(tool: .line, points: [UnitPoint(x: 0.6, y: 0.2), UnitPoint(x: 0.9, y: 0.2)],
                        colorHex: "347A64")
        let highlighter = Mark(tool: .highlighter,
                               points: [UnitPoint(x: 0.6, y: 0.6), UnitPoint(x: 0.9, y: 0.6)],
                               colorHex: "3975B7")
        let number = Mark(tool: .number, points: [UnitPoint(x: 0.5, y: 0.8)],
                          colorHex: "1C2723", filled: nil, text: "1", fontSize: nil)
        for mark in [ellipse, line, highlighter, number] { model.addMark(mark) }
        try require(model.marks.count == 4 && model.canUndo, "New annotation tools must enter the undo stack")
        func coloredPixelCount(_ mark: Mark, where predicate: (NSColor) -> Bool) -> Int {
            let bitmap = NSBitmapImageRep(data: ImageRenderer.render(sample(), marks: [mark]).pngData!)!
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), predicate(color) {
                        count += 1
                    }
                }
            }
            return count
        }
        let ellipsePixels = coloredPixelCount(ellipse) {
            $0.redComponent > 0.7 && $0.greenComponent < 0.6
        }
        let linePixels = coloredPixelCount(line) {
            $0.greenComponent > $0.redComponent + 0.1
        }
        let highlighterPixels = coloredPixelCount(highlighter) {
            $0.blueComponent > $0.redComponent + 0.1 && $0.greenComponent > 0.7
        }
        let numberPixels = coloredPixelCount(number) {
            $0.redComponent < 0.3 && $0.greenComponent < 0.3 && $0.blueComponent < 0.3
        }
        try require(ellipsePixels > 500, "Ellipse fill must paint the selected interior")
        try require(linePixels > 20 && highlighterPixels > 100 && numberPixels > 100,
                    "Line, highlighter and numbered marker must render onto the image")
        model.undo()
        try require(model.marks.count == 3 && model.canRedo, "Undo must be reversible")
        model.redo()
        try require(model.marks.count == 4 && !model.canRedo, "Redo must restore the annotation")
        model.discardDraft()
        model.newText()
        model.sourceText = "Hello"
        model.sourceLanguage = "en"
        model.targetLanguage = "zh-Hans"
        model.swapTranslationLanguages()
        try require(model.sourceLanguage == "zh-Hans" && model.targetLanguage == "en" && model.translatedText.isEmpty,
                    "Language swap must reverse the current pair and clear stale translation")
        model.closeEditor()
        model.translateClipboardContent(image: nil, text: "A clipboard sentence for translation.")
        try require(model.editorMode == .text && model.sourceText == "A clipboard sentence for translation." &&
                    model.translationJob?.target == "zh-Hans",
                    "Clipboard translation failed: mode=\(model.editorMode) source=\(model.sourceText) " +
                    "target=\(model.translationJob?.target ?? "nil") busy=\(model.isBusy)")
        model.cancelTranslation()
    }

    static func movieAndGIF() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("test.mp4")
        let writer = try AVAssetWriter(outputURL: movie, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48
        ])
        writer.add(input)
        try require(writer.startWriting(), "Start video encoder: \(writer.error?.localizedDescription ?? "")")
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(20)
        for frame in 0..<12 {
            while !input.isReadyForMoreMediaData {
                if Date() > deadline { throw FeatureFailure(message: "Video encoder timed out") }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 48, kCVPixelFormatType_32ARGB, nil, &buffer)
            guard let buffer else { throw FeatureFailure(message: "Could not allocate video frame") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let data = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<48 {
                for x in 0..<64 {
                    let p = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
                    data[p] = 255; data[p + 1] = UInt8(frame * 20); data[p + 2] = UInt8(x * 3); data[p + 3] = 40
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            try require(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)), "Append video frame")
        }
        input.markAsFinished()
        await writer.finishWriting()
        try require(writer.status == .completed, "Video must finalize successfully")
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration)
        try require(duration.seconds > 1, "MP4 must have a playable duration")
        let gif = folder.appendingPathComponent("test.gif")
        try await RecordingExport.gif(from: movie, to: gif)
        guard let source = CGImageSourceCreateWithURL(gif as CFURL, nil) else { throw FeatureFailure(message: "GIF must be readable") }
        let count = CGImageSourceGetCount(source)
        try require(count >= 10, "GIF must contain animation frames")
        let first = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let last = CGImageSourceCreateImageAtIndex(source, count - 1, nil)!
        try require(first.width == 64 && first.height == 48, "GIF must preserve capture aspect ratio")
        let firstColor = NSBitmapImageRep(cgImage: first).colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
        let lastColor = NSBitmapImageRep(cgImage: last).colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
        try require(abs(firstColor.redComponent - lastColor.redComponent) > 0.3, "GIF must animate changing video content")
        let joined = folder.appendingPathComponent("resumed.mp4")
        try await RecordingExport.concatenate([movie, movie], to: joined)
        let joinedDuration = try await AVURLAsset(url: joined).load(.duration)
        try require(abs(joinedDuration.seconds - duration.seconds * 2) < 0.15,
                    "Resumed segments must join into one playable timeline with no pause interval")
        let resumedGIF = folder.appendingPathComponent("resumed.gif")
        try await RecordingExport.gif(from: joined, to: resumedGIF)
        let resumedSource = CGImageSourceCreateWithURL(resumedGIF as CFURL, nil)!
        try require(CGImageSourceGetCount(resumedSource) >= count * 2 - 1,
                    "GIF conversion must include every resumed segment")
    }

    static func main() async {
        var checks: [(String, () async throws -> Void)] = [
            ("legacy_history_and_text_roundtrip", legacyMarks),
            ("text_annotation_export_pixels", textPixels),
            ("mosaic_changes_only_selected_pixels", mosaicPixels),
            ("cursor_anchored_zoom_and_limits", zoomGeometry),
            ("editor_close_translation_undo_and_record_actions", editorActions),
            ("cancel_and_escape_dismiss_draft_windows", draftCancellationDismissesWindows),
            ("text_translation_requires_explicit_entry", textTranslationRequiresExplicitEntry),
            ("draft_commits_only_after_confirmation", draftCommitIsTransactional),
            ("recording_stop_review_cancel_and_confirmation", recordingConfirmation),
            ("selection_handles_bounds_and_toolbar_placement", screenSelectionGeometry),
            ("retina_crop_and_annotation_screen_anchors", retinaCropAndMarkAnchors),
            ("adjusted_selection_remains_draft_and_reaches_recording", adjustedSelectionStaysDraft),
            ("text_only_windows_and_detected_language_defaults", textWindowsAndLanguageDefaults),
            ("annotation_toolkit_redo_and_language_swap", annotationToolkitAndLanguageSwap),
            ("recording_dimensions_are_encodable", recordingDimensions),
            ("unsaved_recording_survives_relaunch", recordingDraftRecovery)
        ]
        if !ProcessInfo.processInfo.arguments.contains("--skip-video") { checks.append(("playable_mp4_and_animated_gif_export", movieAndGIF)) }
        var failures = 0
        for (name, run) in checks {
            do { try await run(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error.localizedDescription)") }
        }
        print("\(checks.count - failures)/\(checks.count) editor feature checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
