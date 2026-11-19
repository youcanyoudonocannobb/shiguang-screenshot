import AppKit
import AVFoundation
import ImageIO

private struct FeatureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class MockAIURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FeatureFailure(message: message) }
}

private func requireValue<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw FeatureFailure(message: message) }
    return value
}

private func requestBodyData(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data
}

/// A mouse event at a point in a flipped view that is not in a window.
@MainActor
private func mouseEvent(_ type: NSEvent.EventType, at viewPoint: CGPoint, in view: NSView,
                        clickCount: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type,
                       location: CGPoint(x: viewPoint.x, y: view.bounds.height - viewPoint.y),
                       modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                       windowNumber: 0, context: nil, eventNumber: 0,
                       clickCount: clickCount, pressure: 1)!
}

private func keyEvent(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                      isRepeat: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                     windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                     isARepeat: isRepeat, keyCode: keyCode)!
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
        let text = Mark(tool: .text, points: [UnitPoint(x: 0.2, y: 0.3)], colorHex: "111111",
                        text: "中文 + Text", fontSize: 0.04, lineWidth: 0.008,
                        arrowDoubleHeaded: true, textPresentation: .highlighted,
                        maskStyle: .blur, maskStrength: .strong,
                        spotlightStrength: .deep)
        let roundTrip = try JSONDecoder().decode(Mark.self, from: JSONEncoder().encode(text))
        try require(roundTrip == text, "Advanced annotation styles must survive history round trips")
    }

    static func annotationPointSizes() async throws {
        let suite = "Shiguang.AnnotationPointSizeChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(historyDirectory: folder, preferences: defaults)
        try require(model.markLineWidthPoints == AnnotationSizeMetrics.defaultLineWidthPoints &&
                    model.numberSizePoints == AnnotationSizeMetrics.defaultNumberSizePoints &&
                    model.textFontSize == 20 &&
                    model.maskSizePoints == AnnotationSizeMetrics.defaultMaskSizePoints,
                    "Annotation controls must start from explicit point sizes")

        try require(AnnotationSizeMetrics.clampedPoints(
            from: " 12 pt ", within: AnnotationSizeMetrics.lineWidthRange
        ) == 12, "Manual point-size input must accept an optional pt suffix")
        try require(AnnotationSizeMetrics.clampedPoints(
            from: "120", within: AnnotationSizeMetrics.lineWidthRange
        ) == AnnotationSizeMetrics.lineWidthRange.upperBound,
                    "Manual point-size input must clamp values above the range")
        try require(AnnotationSizeMetrics.clampedPoints(
            from: "0", within: AnnotationSizeMetrics.numberSizeRange
        ) == AnnotationSizeMetrics.numberSizeRange.lowerBound,
                    "Manual point-size input must clamp values below the range")
        try require(AnnotationSizeMetrics.clampedPoints(
            from: "not-a-size", within: AnnotationSizeMetrics.textSizeRange
        ) == nil, "Manual point-size input must reject non-numeric text")

        let sourceSize = CGSize(width: 400, height: 200)
        let lineFraction = AnnotationSizeMetrics.fraction(points: 4, imageSize: sourceSize)
        let maskFraction = AnnotationSizeMetrics.fraction(points: 24, imageSize: sourceSize)
        try require(abs(lineFraction * Double(sourceSize.height) - 4) < 0.0001 &&
                    abs(maskFraction * Double(sourceSize.height) - 24) < 0.0001,
                    "Point sizes must convert to image fractions without changing their value")

        let mosaic = Mark(tool: .mosaic,
                          points: [UnitPoint(x: 0.1, y: 0.1), UnitPoint(x: 0.5, y: 0.5)],
                          colorHex: "111111", maskStyle: .pixel,
                          maskStrength: .medium, maskSize: maskFraction)
        let roundTrip = try JSONDecoder().decode(Mark.self, from: JSONEncoder().encode(mosaic))
        try require(roundTrip == mosaic, "Point-based mosaic sizes must survive history round trips")

        let image = sample()
        func linePixels(points: Double) -> Int {
            let mark = Mark(tool: .line,
                            points: [UnitPoint(x: 0.2, y: 0.5), UnitPoint(x: 0.8, y: 0.5)],
                            colorHex: "E45F3C",
                            lineWidth: AnnotationSizeMetrics.fraction(points: points, imageSize: image.size))
            let bitmap = NSBitmapImageRep(data: ImageRenderer.render(image, marks: [mark]).pngData!)!
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.redComponent > 0.65 && color.greenComponent < 0.55 && color.blueComponent < 0.55 {
                        count += 1
                    }
                }
            }
            return count
        }
        let thin = linePixels(points: 2)
        let thick = linePixels(points: 8)
        try require(thin > 0 && thick > thin + 500,
                    "Changing line width in points must visibly change the rendered stroke")

        func numberPixels(points: Double) -> Int {
            let fraction = AnnotationSizeMetrics.fraction(points: points, imageSize: image.size)
            let mark = Mark(tool: .number, points: [UnitPoint(x: 0.5, y: 0.5)],
                            colorHex: "E45F3C", text: "1",
                            lineWidth: fraction, numberSize: fraction)
            let bitmap = NSBitmapImageRep(data: ImageRenderer.render(image, marks: [mark]).pngData!)!
            var count = 0
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.redComponent > 0.65 && color.greenComponent < 0.55 && color.blueComponent < 0.55 {
                        count += 1
                    }
                }
            }
            return count
        }
        let smallNumber = numberPixels(points: 8)
        let largeNumber = numberPixels(points: 24)
        try require(smallNumber > 0 && largeNumber > smallNumber * 4,
                    "Number marker size must scale directly with its point value")
        let number = Mark(tool: .number, points: [UnitPoint(x: 0.5, y: 0.5)],
                          colorHex: "111111", text: "1", numberSize: 0.024)
        let decodedNumber = try JSONDecoder().decode(Mark.self, from: JSONEncoder().encode(number))
        try require(decodedNumber == number,
                    "Number marker point sizes must survive history round trips")
    }

    static func annotationMarksCanBeMoved() async throws {
        let canvas = NativeImageCanvas(frame: NSRect(x: 0, y: 0, width: 320, height: 240))

        let original = Mark(
            tool: .arrow,
            points: [UnitPoint(x: 0.2, y: 0.2), UnitPoint(x: 0.7, y: 0.6)],
            colorHex: "E45F3C"
        )
        var moved: Mark?
        var beganEditing = false
        var finishedEditing = false
        canvas.onBeginMarkEdit = { id in beganEditing = id == original.id }
        canvas.onUpdateMark = { moved = $0 }
        canvas.onFinishMarkEdit = { finishedEditing = true }
        canvas.configure(
            image: sample(),
            marks: [original],
            tool: .arrow,
            color: "E45F3C",
            zoom: 1,
            resetID: UUID(),
            movesWindow: false,
            enabled: true
        )

        func event(_ type: NSEvent.EventType, viewPoint: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type,
                location: CGPoint(x: viewPoint.x, y: canvas.bounds.height - viewPoint.y),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )!
        }

        let midpoint = CGPoint(x: 145, y: 105)
        let destination = CGPoint(x: 185, y: 130)
        canvas.mouseDown(with: event(.leftMouseDown, viewPoint: midpoint))
        canvas.mouseDragged(with: event(.leftMouseDragged, viewPoint: destination))
        canvas.mouseUp(with: event(.leftMouseUp, viewPoint: destination))

        let updated = try requireValue(moved, "Dragging an existing arrow must update its position")
        try require(updated.id == original.id, "Moving an annotation must preserve its identity")
        try require(abs(updated.points[0].x - original.points[0].x) > 0.05 &&
                    abs(updated.points[0].y - original.points[0].y) > 0.05,
                    "Dragging an existing arrow must move both endpoints")
        try require(beganEditing && finishedEditing,
                    "Moving an annotation must register one undoable edit")

        let textMark = Mark(tool: .text, points: [UnitPoint(x: 0.2, y: 0.3)],
                            colorHex: "111111", text: "测试文字", fontSize: 0.2)
        moved = nil
        beganEditing = false
        finishedEditing = false
        canvas.onBeginMarkEdit = { id in beganEditing = id == textMark.id }
        canvas.onFinishMarkEdit = { finishedEditing = true }
        canvas.configure(
            image: sample(),
            marks: [textMark],
            tool: .text,
            color: "111111",
            zoom: 1,
            resetID: UUID(),
            movesWindow: false,
            enabled: true
        )
        canvas.mouseDown(with: event(.leftMouseDown, viewPoint: CGPoint(x: 105, y: 103)))
        canvas.mouseDragged(with: event(.leftMouseDragged, viewPoint: CGPoint(x: 145, y: 123)))
        canvas.mouseUp(with: event(.leftMouseUp, viewPoint: CGPoint(x: 145, y: 123)))
        let movedText = try requireValue(moved, "Dragging existing text must update its position")
        try require(movedText.id == textMark.id && movedText.text == textMark.text,
                    "Moving text must preserve its content")
        try require(beganEditing && finishedEditing,
                    "Moving text must register one undoable edit")
    }

    /// Selected marks can be deleted, nudged, restyled and re-edited, as in
    /// CleanShot X, Snipaste and PixPin. The canvas is the 320x240 fixture
    /// whose 200x100 image is drawn at (12, 46, 296, 148).
    static func selectedAnnotationEditing() async throws {
        let canvas = NativeImageCanvas(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        // Reuse one image: a new image counts as a new capture and clears the selection.
        let image = sample()
        let resetID = UUID()
        let rectangle = Mark(tool: .rectangle,
                             points: [UnitPoint(x: 0.2, y: 0.2), UnitPoint(x: 0.5, y: 0.6)],
                             colorHex: "E45F3C",
                             lineWidth: AnnotationSizeMetrics.fraction(points: 4, imageSize: image.size))
        var marks = [rectangle]
        var began: [UUID] = []
        var finished = 0
        var updates: [Mark] = []
        var deleted: [UUID] = []
        var created: [Mark] = []
        var selected: [(Mark, CGSize)] = []
        canvas.onBeginMarkEdit = { began.append($0) }
        canvas.onUpdateMark = { mark in
            updates.append(mark)
            if let index = marks.firstIndex(where: { $0.id == mark.id }) { marks[index] = mark }
        }
        canvas.onFinishMarkEdit = { finished += 1 }
        canvas.onDeleteMark = { id in deleted.append(id); marks.removeAll { $0.id == id } }
        canvas.onMark = { created.append($0); marks.append($0) }
        canvas.onSelectMark = { selected.append(($0, $1)) }
        func configure(tool: MarkTool = .pointer, color: String = "E45F3C", lineWidth: Double = 4,
                       numberSize: Double = AnnotationSizeMetrics.defaultNumberSizePoints) {
            canvas.configure(image: image, marks: marks, tool: tool, color: color, zoom: 1,
                             resetID: resetID, movesWindow: false, enabled: true,
                             lineWidthPoints: lineWidth, numberSizePoints: numberSize)
        }
        func click(_ point: CGPoint, count: Int = 1) {
            canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: canvas, clickCount: count))
            canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: point, in: canvas, clickCount: count))
        }

        configure()
        click(CGPoint(x: 115, y: 105))
        try require(selected.count == 1 && selected[0].0.id == rectangle.id &&
                    selected[0].1 == image.size && updates.isEmpty,
                    "Clicking a mark must select it and report its image size without editing it")

        canvas.keyDown(with: keyEvent(124))
        canvas.keyDown(with: keyEvent(124, isRepeat: true))
        var moved = try requireValue(updates.last, "The arrow keys must move the selected mark")
        try require(abs(moved.points[0].x - 0.21) < 0.0001 && abs(moved.points[1].x - 0.51) < 0.0001 &&
                    moved.points[0].y == 0.2 && moved.id == rectangle.id,
                    "Each arrow press must move the selected mark by one image point")
        try require(began == [rectangle.id] && finished == 2,
                    "Holding an arrow key must register a single undo step")
        canvas.keyDown(with: keyEvent(125, modifiers: .shift))
        moved = try requireValue(updates.last, "Shift-arrow must move the selected mark")
        try require(abs(moved.points[0].y - 0.3) < 0.0001 && abs(moved.points[0].x - 0.21) < 0.0001,
                    "Shift-arrow must move the selected mark by ten image points, and down must move down")
        try require(began.count == 2, "A new arrow press must register another undo step")

        configure(color: "3F7EE0")
        try await Task.sleep(for: .milliseconds(50))
        let recolored = try requireValue(updates.last, "Changing the color must restyle the selected mark")
        try require(recolored.colorHex == "3F7EE0" && recolored.lineWidth == rectangle.lineWidth &&
                    recolored.points == moved.points,
                    "Changing the color must restyle only the color of the selected mark")
        configure(color: "3F7EE0", lineWidth: 10)
        try await Task.sleep(for: .milliseconds(50))
        let thicker = try requireValue(updates.last, "Changing the line width must restyle the selected mark")
        try require(thicker.colorHex == "3F7EE0" &&
                    thicker.lineWidth == AnnotationSizeMetrics.fraction(points: 10, imageSize: image.size),
                    "Changing the line width must keep the newly chosen color")
        let restyleCount = updates.count
        configure(color: "3F7EE0", lineWidth: 10)
        try await Task.sleep(for: .milliseconds(50))
        try require(updates.count == restyleCount, "Reconfiguring with the same style must not rewrite the mark")

        canvas.keyDown(with: keyEvent(51))
        try require(deleted == [rectangle.id] && marks.isEmpty,
                    "Delete must remove the selected mark")
        let afterDelete = updates.count
        canvas.keyDown(with: keyEvent(124))
        try require(updates.count == afterDelete, "The arrow keys must not move a deleted mark")

        let text = Mark(tool: .text, points: [UnitPoint(x: 0.2, y: 0.3)], colorHex: "111111",
                        text: "Before", fontSize: 0.2)
        marks = [text]
        configure()
        click(CGPoint(x: 105, y: 103))
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: CGPoint(x: 105, y: 103), in: canvas, clickCount: 2))
        let field = try requireValue(canvas.subviews.compactMap { $0 as? NSTextField }.first,
                                     "Double-clicking text must reopen it for editing")
        try require(field.stringValue == "Before", "The edit field must start with the current text")
        field.stringValue = "After"
        canvas.commitPendingText()
        let edited = try requireValue(updates.last, "Committing edited text must update the mark")
        try require(edited.id == text.id && edited.text == "After" && edited.fontSize == text.fontSize &&
                    marks.count == 1 && created.isEmpty,
                    "Editing text must keep the same mark instead of adding another one")

        let one = Mark(tool: .number, points: [UnitPoint(x: 0.1, y: 0.5)], colorHex: "E45F3C", text: "1")
        let three = Mark(tool: .number, points: [UnitPoint(x: 0.3, y: 0.5)], colorHex: "E45F3C", text: "3")
        marks = [one, three]
        configure(tool: .number)
        click(CGPoint(x: 249, y: 164))
        try require(created.last?.text == "4",
                    "A new number must follow the highest number, so a deletion never causes duplicates")
    }

    /// Selecting a mark copies its style into the toolbar so its controls
    /// show, and then change, that mark.
    static func selectingMarkAdoptsItsStyle() async throws {
        let suite = "Shiguang.AdoptStyleChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }
        defaults.set(false, forKey: "autoOCR.v2")
        let model = AppModel(historyDirectory: folder, preferences: defaults)
        let image = sample()
        model.acceptImage(image, title: "Adopt", inlineRect: CGRect(x: 0, y: 0, width: 200, height: 100))
        let arrow = Mark(tool: .arrow, points: [UnitPoint(x: 0.2, y: 0.2), UnitPoint(x: 0.7, y: 0.6)],
                         colorHex: "3F7EE0",
                         lineWidth: AnnotationSizeMetrics.fraction(points: 9, imageSize: image.size),
                         arrowDoubleHeaded: true)
        model.addMark(arrow)
        model.tool = .rectangle
        let canvas = NativeImageCanvas(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        canvas.bindAnnotationEditing(to: model)
        let resetID = UUID()
        func configure() {
            canvas.configure(image: image, marks: model.marks, tool: model.tool, color: model.markColor,
                             zoom: 1, resetID: resetID, movesWindow: false, enabled: true,
                             filledShapes: model.fillShapes, lineWidthPoints: model.markLineWidthPoints,
                             numberSizePoints: model.numberSizePoints,
                             arrowDoubleHeaded: model.arrowDoubleHeaded)
        }
        configure()
        let point = CGPoint(x: 145, y: 105)
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: canvas))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: point, in: canvas))
        try require(model.markColor == "3F7EE0" && model.markLineWidthPoints == 9 &&
                    model.arrowDoubleHeaded && model.tool == .arrow,
                    "Selecting a mark must show its color, size and tool in the toolbar")
        configure()
        try await Task.sleep(for: .milliseconds(50))
        try require(model.marks == [arrow],
                    "Showing a selected mark's style must not rewrite the mark")
        model.markColor = "58B75B"
        configure()
        try await Task.sleep(for: .milliseconds(50))
        try require(model.marks.first?.colorHex == "58B75B" && model.marks.first?.lineWidth == arrow.lineWidth,
                    "Choosing a color while a mark is selected must recolor it")
        model.undo()
        try require(model.marks == [arrow], "Restyling a selected mark must be undoable")

        model.tool = .picker
        model.applyPickedColor("111111")
        try require(model.markColor == "111111" && model.tool == .arrow,
                    "The eyedropper must return to the tool it was opened from")
    }

    /// The eyedropper must sample the pixel under the pointer.
    static func eyedropperSamplesClickedPixel() async throws {
        let context = CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Core Graphics puts y = 0 at the bottom: red fills the top half.
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 50, width: 200, height: 50))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 50))
        let image = NSImage(cgImage: context.makeImage()!, size: CGSize(width: 200, height: 100))
        let canvas = NativeImageCanvas(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        var picked: [String] = []
        canvas.onColorPick = { picked.append($0) }
        canvas.configure(image: image, marks: [], tool: .picker, color: "E45F3C", zoom: 1,
                         resetID: UUID(), movesWindow: false, enabled: true)
        for point in [CGPoint(x: 160, y: 60), CGPoint(x: 160, y: 180)] {
            canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: canvas))
            canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: point, in: canvas))
        }
        func channels(_ hex: String) -> (red: Int, blue: Int) {
            (Int(hex.prefix(2), radix: 16) ?? -1, Int(hex.suffix(2), radix: 16) ?? -1)
        }
        try require(picked.count == 2, "Each eyedropper click must report a color")
        let top = channels(picked[0]), bottom = channels(picked[1])
        try require(top.red > 200 && top.blue < 60 && bottom.blue > 200 && bottom.red < 60,
                    "The eyedropper must sample the pixel under the pointer, not its mirror image (got \(picked))")
    }

    /// Text size is stored against the image height, which is what the
    /// renderer uses; portrait captures used to draw text twice too large.
    static func textSizeMatchesPointsInPortraitImages() async throws {
        let context = CGContext(data: nil, width: 100, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        let portrait = NSImage(cgImage: context.makeImage()!, size: CGSize(width: 100, height: 200))
        let canvas = NativeImageCanvas(frame: NSRect(x: 0, y: 0, width: 240, height: 320))
        var created: Mark?
        canvas.onMark = { created = $0 }
        canvas.configure(image: portrait, marks: [], tool: .text, color: "111111", zoom: 1,
                         resetID: UUID(), movesWindow: false, enabled: true, textFontSize: 20)
        let point = CGPoint(x: 100, y: 120)
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: canvas))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: point, in: canvas))
        let field = try requireValue(canvas.subviews.compactMap { $0 as? NSTextField }.first,
                                     "The text tool must open a text field")
        field.stringValue = "Size"
        canvas.commitPendingText()
        let mark = try requireValue(created, "Committing text must add a text mark")
        let fraction = try requireValue(mark.fontSize, "Text marks must store their size")
        try require(abs(fraction * 200 - 20) < 0.0001,
                    "20 pt text in a portrait image must render 20 pt tall, not scale with the width")
        try require(AnnotationSizeMetrics.points(fromFraction: fraction, base: 200,
                                                 within: AnnotationSizeMetrics.textSizeRange) == 20,
                    "A stored text size must convert back to the same toolbar value")
    }

    /// Status-menu items show the registered global shortcuts natively.
    static func menuKeyEquivalents() async throws {
        func equivalent(_ key: String) -> String { HotkeySettings(key: key).menuKeyEquivalent }
        func scalar(_ value: Int) -> String { String(Character(UnicodeScalar(UInt32(value))!)) }
        try require(equivalent("S") == "s" && equivalent("1") == "1" && equivalent("/") == "/",
                    "Character keys must use their lowercase character")
        try require(equivalent("Space") == " " && equivalent("↩") == "\r" && equivalent("Esc") == "\u{1b}",
                    "Named keys must use the characters NSMenuItem expects")
        try require(equivalent("F5") == scalar(NSF5FunctionKey) && equivalent("F19") == scalar(NSF19FunctionKey) &&
                    equivalent("←") == scalar(NSLeftArrowFunctionKey) &&
                    equivalent("⌦") == scalar(NSDeleteFunctionKey),
                    "Function and arrow keys must use their function-key code points")
    }

    /// Toolbar style popovers become the key window as soon as they open.
    /// Editing keys must still reach the canvas, and letters typed while a
    /// text mark is open must never trigger the tool shortcuts.
    static func toolbarPopoverKeysReachCanvas() async throws {
        func route(_ key: UInt16, _ flags: NSEvent.ModifierFlags = [], field: Bool = false,
                   text: Bool = false) -> NativeImageCanvas.PopoverKeyRoute {
            NativeImageCanvas.popoverKeyRoute(keyCode: key, modifiers: flags,
                                              popoverIsEditingText: field, canvasIsEditingText: text)
        }
        // Delete, Forward Delete, arrows, Return, Enter, "1" and "o".
        for key: UInt16 in [51, 117, 123, 124, 125, 126, 36, 76, 18, 31] {
            try require(route(key) == .canvas, "Key \(key) in a style popover must reach the canvas")
        }
        try require(route(124, .shift) == .canvas, "Shift-arrow must still nudge the selected mark")
        try require(route(53) == .popover && route(48) == .popover && route(49) == .popover,
                    "Esc must close the popover; Tab and Space keep keyboard navigation")
        try require(route(51, .command) == .popover && route(18, .option) == .popover &&
                    route(18, .control) == .popover,
                    "Modified keys are not canvas editing keys")
        try require(route(51, field: true) == .popover && route(123, field: true) == .popover &&
                    route(36, field: true) == .popover,
                    "Typing a pt value must keep every key in the popover")
        try require(route(17, text: true) == .openText && route(49, text: true) == .openText &&
                    route(51, text: true) == .openText && route(19, .option, text: true) == .openText,
                    "Typing must continue in an open text mark, never trigger tool shortcuts")
        try require(route(9, .command, text: true) == .popover && route(53, text: true) == .popover,
                    "Command shortcuts and Esc are not typed into the text mark")
    }

    /// Number keys follow the toolbar, so the n-th button is key n.
    static func toolShortcutsFollowToolbarOrder() async throws {
        let picked = (1...9).map { MarkTool.forShortcut(String($0)) }
        try require(picked == MarkTool.toolbarOrder.map { Optional($0) },
                    "Keys 1–9 must pick the toolbar tools in order (got \(picked))")
        try require(MarkTool.forShortcut("0") == nil &&
                    MarkTool.forShortcut("10") == nil &&
                    MarkTool.forShortcut("a") == nil,
                    "Other keys must not pick a tool")
        try require(!picked.contains(.highlighter),
                    "No number key may select a tool that is not shown in the toolbar")
    }

    /// The text box starts at its placeholder's width and grows while
    /// typing, instead of opening as a fixed 360 pt box.
    static func textFieldGrowsWithContent() async throws {
        // A 224 x 124 canvas shows the 200 x 100 sample at 1:1 (12 pt inset).
        let canvas = NativeImageCanvas(frame: NSRect(x: 0, y: 0, width: 224, height: 124))
        canvas.configure(image: sample(), marks: [], tool: .text, color: "111111", zoom: 1,
                         resetID: UUID(), movesWindow: false, enabled: true)
        let point = CGPoint(x: 20, y: 20)
        canvas.mouseDown(with: mouseEvent(.leftMouseDown, at: point, in: canvas))
        canvas.mouseUp(with: mouseEvent(.leftMouseUp, at: point, in: canvas))
        let field = try requireValue(canvas.subviews.compactMap { $0 as? NSTextField }.first,
                                     "Clicking with the text tool must open a text field")
        let empty = field.frame.width
        let available = canvas.bounds.maxX - field.frame.minX
        try require(empty > 40 && empty < available - 40,
                    "An empty text box must fit its placeholder, not fill the canvas (\(empty) of \(available))")
        field.stringValue = String(repeating: "Wide label ", count: 4)
        canvas.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        try require(field.frame.width > empty && field.frame.width <= available,
                    "The text box must grow with its text up to the canvas edge")
        canvas.commitPendingText()
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

    static func advancedAnnotationStyles() async throws {
        let single = Mark(tool: .arrow,
                          points: [UnitPoint(x: 0.2, y: 0.5), UnitPoint(x: 0.8, y: 0.5)],
                          colorHex: "111111", lineWidth: 0.008)
        var double = single
        double.arrowDoubleHeaded = true
        func bitmap(_ mark: Mark) -> NSBitmapImageRep {
            let bitmap = NSBitmapImageRep(data: ImageRenderer.render(sample(), marks: [mark]).pngData!)!
            return bitmap
        }
        let singleBitmap = bitmap(single), doubleBitmap = bitmap(double)
        func spreadAtStart(_ image: NSBitmapImageRep) -> Int {
            (40..<55).reduce(0) { count, x in
                count + (40..<60).filter { y in
                    abs(y - 50) > 3 &&
                        image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!.redComponent < 0.35
                }.count
            }
        }
        try require(spreadAtStart(doubleBitmap) > spreadAtStart(singleBitmap) + 10,
                    "Double-headed arrows must add a visible head at the start and end")

        let spotlight = Mark(tool: .spotlight,
                             points: [UnitPoint(x: 0.25, y: 0.2), UnitPoint(x: 0.75, y: 0.8)],
                             colorHex: "111111", spotlightStrength: .deep)
        let spotlightBitmap = NSBitmapImageRep(data: ImageRenderer.render(sample(), marks: [spotlight]).pngData!)!
        let outside = spotlightBitmap.colorAt(x: 10, y: 50)!.usingColorSpace(.deviceRGB)!.redComponent
        let inside = spotlightBitmap.colorAt(x: 100, y: 50)!.usingColorSpace(.deviceRGB)!.redComponent
        try require(outside < 0.55 && inside > 0.92,
                    "Spotlight must dim outside the selected region while preserving the focus area")
    }

    static func fixedAspectSelection() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let drawn = CaptureSelectionGeometry.selectionRect(
            from: CGPoint(x: 100, y: 100), to: CGPoint(x: 500, y: 300),
            bounds: bounds, aspectRatio: 1
        )
        try require(abs(drawn.width - drawn.height) < 0.01 && abs(drawn.width - 400) < 0.01,
                    "Fixed-ratio selection must use the dominant drag distance without distorting the ratio")
        let portrait = CaptureSelectionGeometry.selectionRect(
            from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 500),
            bounds: bounds, aspectRatio: 9.0 / 16.0
        )
        try require(abs(portrait.width / portrait.height - 9.0 / 16.0) < 0.001 &&
                    abs(portrait.height - 400) < 0.01,
                    "Portrait ratios must follow a vertical drag instead of collapsing to the minimum width")
        let resized = CaptureSelectionGeometry.resized(
            CGRect(x: 100, y: 100, width: 400, height: 225),
            handle: .right, delta: CGSize(width: 100, height: 0),
            bounds: bounds, aspectRatio: 16.0 / 9.0
        )
        try require(abs(resized.width / resized.height - 16.0 / 9.0) < 0.001 &&
                    bounds.contains(resized),
                    "Aspect-locked handle resizing must preserve the selected ratio inside the screen")
        let edgeResized = CaptureSelectionGeometry.resized(
            CGRect(x: 250, y: 200, width: 300, height: 300),
            handle: .top, delta: CGSize(width: 0, height: -80),
            bounds: bounds, aspectRatio: 1
        )
        try require(abs(edgeResized.width - edgeResized.height) < 0.01 &&
                    edgeResized.width > 150 && bounds.contains(edgeResized),
                    "Dragging a side handle with a locked ratio must resize proportionally instead of collapsing")
        let fitted = CaptureSelectionGeometry.fittedToAspect(
            CGRect(x: 900, y: 650, width: 200, height: 100),
            aspectRatio: 1, bounds: bounds
        )
        try require(abs(fitted.width - fitted.height) < 0.01 && bounds.contains(fitted),
                    "Switching to a fixed ratio must refit the current selection on screen")
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

    static func defaultPreferences() async throws {
        let suite = "Shiguang.DefaultPreferencesChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: folder) }

        defaults.set(TranslationProvider.ai.rawValue, forKey: "translationProvider")
        let first = AppModel(historyDirectory: folder, preferences: defaults)
        try require(first.translationProvider == .apple,
                    "A first run upgraded from an older version must default to Apple translation")
        try require(first.showsMenuBarIcon && first.menuBarDogStyle == .system,
                    "Menu bar visibility and monochrome dog must use safe defaults")

        first.translationProvider = .ai
        first.showsMenuBarIcon = false
        first.menuBarDogStyle = .lake
        let second = AppModel(historyDirectory: folder, preferences: defaults)
        try require(second.translationProvider == .ai,
                    "A translation engine explicitly selected after migration must persist")
        try require(!second.showsMenuBarIcon && second.menuBarDogStyle == .lake,
                    "Menu bar visibility and dog colour must persist across launches")

        second.menuBarDogStyle = .cat
        let third = AppModel(historyDirectory: folder, preferences: defaults)
        try require(third.menuBarDogStyle == .cat,
                    "Animal menu bar styles must persist across launches")

        let customIconData = Data([0x89, 0x50, 0x4E, 0x47])
        third.customMenuBarIconData = customIconData
        third.menuBarDogStyle = .custom
        let fourth = AppModel(historyDirectory: folder, preferences: defaults)
        try require(fourth.menuBarDogStyle == .custom &&
                    fourth.customMenuBarIconData == customIconData,
                    "Custom menu bar image data must persist across launches")
    }

    static func manualHotkeyInput() async throws {
        let compact = try requireValue(HotkeySettings.parseInput("⌥⇧K"),
                                       "Compact modifier notation must be accepted")
        try require(compact.key == "K" && compact.option && compact.shift &&
                    !compact.control && !compact.command,
                    "⌥⇧K must parse into the expected modifier flags")

        let words = try requireValue(HotkeySettings.parseInput("control + option + s"),
                                     "Word modifier notation must be accepted")
        try require(words.key == "S" && words.control && words.option &&
                    !words.shift && !words.command,
                    "Word modifier notation must parse consistently")

        let optionLetter = try requireValue(HotkeySettings.fromKeyEvent(keyCode: 1, modifiers: [.option]),
                                            "Option+S must be captured from its physical key code")
        try require(optionLetter.key == "S" && optionLetter.option && !optionLetter.shift &&
                    optionLetter.keyCode == 1,
                    "Option+S capture must not depend on the modified text character")

        let optionDigit = try requireValue(HotkeySettings.fromKeyEvent(keyCode: 18, modifiers: [.option]),
                                           "Option+1 must be accepted")
        try require(optionDigit.key == "1" && optionDigit.option && optionDigit.keyCode == 18,
                    "Number keys must retain their physical key code")

        let optionFunction = try requireValue(
            HotkeySettings.fromKeyEvent(keyCode: 122, modifiers: [.option, .shift]),
            "Option+Shift+F1 must be accepted"
        )
        try require(optionFunction.key == "F1" && optionFunction.option && optionFunction.shift &&
                    optionFunction.keyCode == 122,
                    "Function keys must retain their physical key code")

        try require(HotkeySettings.fromKeyEvent(keyCode: 1, modifiers: []) == nil,
                    "A physical key without modifiers must be rejected")
        try require(HotkeySettings.parseInput("K") == nil,
                    "A shortcut without a modifier must be rejected")
        try require(HotkeySettings.parseInput("⌥⇧KK") == nil,
                    "A shortcut must contain exactly one letter key")
    }

    static func selectedTextTranslation() async throws {
        try require(SelectedTextReader.normalized(nil) == nil,
                    "Missing selected text must not start translation")
        try require(SelectedTextReader.normalized(" \n\t ") == nil,
                    "Whitespace-only selected text must be rejected")
        try require(SelectedTextReader.normalized("  一段选中的文字。\n") == "一段选中的文字。",
                    "Selected text must be trimmed without changing its content")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShiguangSelection-\(UUID().uuidString)", isDirectory: true)
        let defaults = UserDefaults(suiteName: "Shiguang.Selection.\(UUID().uuidString)")!
        let model = AppModel(historyDirectory: folder, preferences: defaults)
        model.translationProvider = .apple
        model.translateSelectedText("A selected sentence for translation.")
        try require(model.editorMode == .text,
                    "Selected text must open the standalone translation workspace")
        try require(model.sourceText == "A selected sentence for translation.",
                    "Selected text must be placed in the source editor")
        try require(model.translationJob != nil,
                    "Selected text must begin translation immediately")
        model.cancelTranslation()
    }

    static func aiTranslationRequests() async throws {
        try require(AITranslationService.endpoint(for: "https://api.example.com/v1")?.absoluteString ==
                    "https://api.example.com/v1/chat/completions",
                    "AI endpoint must append Chat Completions to a base URL")
        try require(AITranslationService.endpoint(for: "https://api.example.com/v1/chat/completions")?.absoluteString ==
                    "https://api.example.com/v1/chat/completions",
                    "A complete Chat Completions endpoint must remain unchanged")
        try require(AITranslationService.endpoint(for: "http://insecure.example.com") == nil,
                    "AI translation must require HTTPS")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAIURLProtocol.self]
        let session = URLSession(configuration: configuration)
        var capturedPath = ""
        var capturedAuthorization = ""
        var capturedBody = ""
        MockAIURLProtocol.handler = { request in
            capturedPath = request.url?.path ?? ""
            capturedAuthorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            if let body = request.httpBody {
                capturedBody = String(data: body, encoding: .utf8) ?? ""
            }
            let data = Data(#"{"choices":[{"message":{"role":"assistant","content":"你好"}}]}"#.utf8)
            return (200, data)
        }
        defer { MockAIURLProtocol.handler = nil }
        let translated = try await AITranslationService(session: session).translate(
            text: "Hello",
            source: "en",
            target: "zh-Hans",
            configuration: AITranslationConfiguration(baseURL: "https://api.example.com/v1",
                                                       model: "test-model", instructions: "Keep names unchanged"),
            apiKey: "test-key"
        )
        try require(translated == "你好", "AI translation must decode assistant content")
        try require(capturedPath == "/v1/chat/completions", "AI request must use the configured endpoint")
        try require(capturedAuthorization == "Bearer test-key", "AI request must carry the API key as a bearer token")
        if !capturedBody.isEmpty {
            try require(capturedBody.contains("test-model") && capturedBody.contains("Hello") &&
                        capturedBody.contains("Keep names unchanged"),
                        "AI request body must include model, source text and custom instructions")
        }
    }

    static func aiModelDiscovery() async throws {
        let openAI = AITranslationConfiguration(
            baseURL: "https://api.example.com/v1",
            model: "model-b",
            instructions: "",
            api: .openAIChat
        )
        let responses = AITranslationConfiguration(
            baseURL: "https://api.example.com/v1/responses",
            model: "model-b",
            instructions: "",
            api: .openAIResponses
        )
        let anthropic = AITranslationConfiguration(
            baseURL: "https://api.example.com/v1",
            model: "claude-test",
            instructions: "",
            api: .anthropicMessages
        )
        let gemini = AITranslationConfiguration(
            baseURL: "https://api.example.com/v1beta",
            model: "gemini-test",
            instructions: "",
            api: .gemini
        )

        try require(AITranslationService.modelsEndpoint(for: openAI)?.path == "/v1/models",
                    "OpenAI model discovery must use the models endpoint")
        try require(AITranslationService.modelsEndpoint(for: responses)?.path == "/v1/models",
                    "Responses model discovery must remove the operation suffix")
        try require(AITranslationService.modelsEndpoint(for: anthropic)?.path == "/v1/models",
                    "Claude model discovery must use the versioned models endpoint")
        try require(AITranslationService.modelsEndpoint(for: gemini)?.path == "/v1beta/models",
                    "Gemini model discovery must use the models collection endpoint")

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockAIURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        var observedMethod = ""
        var observedPath = ""
        var observedAuthorization = ""
        var observedAnthropicKey = ""
        var observedAnthropicVersion = ""
        var observedGeminiKey = ""
        MockAIURLProtocol.handler = { request in
            observedMethod = request.httpMethod ?? ""
            observedPath = request.url?.path ?? ""
            observedAuthorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            observedAnthropicKey = request.value(forHTTPHeaderField: "x-api-key") ?? ""
            observedAnthropicVersion = request.value(forHTTPHeaderField: "anthropic-version") ?? ""
            observedGeminiKey = request.value(forHTTPHeaderField: "x-goog-api-key") ?? ""

            if !observedAnthropicKey.isEmpty {
                return (200, Data(#"{"data":[{"id":"claude-a","display_name":"Claude A"}]}"#.utf8))
            }
            if !observedGeminiKey.isEmpty || observedPath == "/v1beta/models" {
                return (200, Data(#"{"models":[{"name":"models/gemini-2.5-pro","displayName":"Gemini 2.5 Pro"}]}"#.utf8))
            }
            return (200, Data(#"{"data":[{"id":"model-b"},{"id":"model-a"}]}"#.utf8))
        }
        defer { MockAIURLProtocol.handler = nil }

        let service = AITranslationService(session: session)
        let openAIModels = try await service.fetchModels(configuration: openAI,
                                                          apiKey: "openai-key")
        try require(openAIModels.map(\.id) == ["model-a", "model-b"],
                    "OpenAI model lists must decode and sort model IDs")
        try require(observedMethod == "GET" && observedPath == "/v1/models" &&
                    observedAuthorization == "Bearer openai-key",
                    "OpenAI model discovery must use GET and bearer authentication")

        let anthropicModels = try await service.fetchModels(configuration: anthropic,
                                                             apiKey: "anthropic-key")
        try require(anthropicModels == [AIModelOption(id: "claude-a", title: "Claude A")],
                    "Claude model lists must decode display names")
        try require(observedAnthropicKey == "anthropic-key" &&
                    observedAnthropicVersion == "2023-06-01",
                    "Claude model discovery must send the native authentication headers")

        let geminiModels = try await service.fetchModels(configuration: gemini,
                                                          apiKey: "gemini-key")
        try require(geminiModels == [AIModelOption(id: "gemini-2.5-pro",
                                                   title: "Gemini 2.5 Pro")],
                    "Gemini model lists must normalize the models/ prefix")
        try require(observedGeminiKey == "gemini-key",
                    "Gemini model discovery must send the Google API key header")
    }

    static func aiProtocolAutoFallback() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockAIURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let service = AITranslationService(session: session)
        let responses = AITranslationConfiguration(
            baseURL: "https://api.example.com/v1",
            model: "deepseek-chat",
            instructions: "",
            api: .openAIResponses
        )

        var paths: [String] = []
        MockAIURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            if path == "/v1/responses" {
                return (404, Data(#"{"error":{"message":"Unknown endpoint"}}"#.utf8))
            }
            return (200, Data(#"{"choices":[{"message":{"content":"自动切换成功"}}]}"#.utf8))
        }
        defer { MockAIURLProtocol.handler = nil }

        let result = try await service.translateWithProtocolFallback(
            text: "Hello",
            source: "en",
            target: "zh-Hans",
            configuration: responses,
            apiKey: "test-key"
        )
        try require(result.text == "自动切换成功" &&
                    result.api == .openAIChat &&
                    result.usedFallback,
                    "An unsupported Responses endpoint must fall back to Chat Completions")
        try require(paths == ["/v1/responses", "/v1/chat/completions"],
                    "Protocol fallback must retry the alternate OpenAI endpoint exactly once")

        paths = []
        MockAIURLProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            return (401, Data(#"{"error":{"message":"Invalid API key"}}"#.utf8))
        }
        var failed = false
        do {
            _ = try await service.translateWithProtocolFallback(
                text: "Hello",
                source: "en",
                target: "zh-Hans",
                configuration: responses,
                apiKey: "bad-key"
            )
        } catch {
            failed = true
        }
        try require(failed && paths == ["/v1/responses"],
                    "Authentication failures must not trigger an unnecessary protocol retry")
    }

    static func aiTranslationErrors() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockAIURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockAIURLProtocol.handler = { _ in
            (401, Data(#"{"error":{"message":"Invalid API key"}}"#.utf8))
        }
        defer { MockAIURLProtocol.handler = nil }
        var failed = false
        do {
            _ = try await AITranslationService(session: session).translate(
                text: "Hello", source: "en", target: "zh-Hans",
                configuration: AITranslationConfiguration(baseURL: "https://api.example.com/v1",
                                                           model: "test-model", instructions: ""),
                apiKey: "bad-key"
            )
        } catch {
            failed = true
            try require(error.localizedDescription.contains("Invalid API key"),
                        "AI server errors must surface the service message")
        }
        try require(failed, "A 401 response must fail translation")
    }

    static func aiProtocolCompatibility() async throws {
        let chat = AITranslationConfiguration(
            baseURL: "https://api.example.com/v1",
            model: "chat-model",
            instructions: "",
            api: .openAIChat
        )
        let responses = AITranslationConfiguration(
            baseURL: "https://api.example.com/v1",
            model: "responses-model",
            instructions: "",
            api: .openAIResponses
        )
        let anthropic = AITranslationConfiguration(
            baseURL: "https://api.example.com/v1",
            model: "claude-test",
            instructions: "",
            api: .anthropicMessages
        )
        let gemini = AITranslationConfiguration(
            baseURL: "https://api.example.com/v1beta",
            model: "gemini-test",
            instructions: "",
            api: .gemini
        )
        try require(AITranslationService.endpoint(for: chat)?.path == "/v1/chat/completions",
                    "OpenAI Chat must append its native endpoint")
        try require(AITranslationService.endpoint(for: responses)?.path == "/v1/responses",
                    "OpenAI Responses must append its native endpoint")
        try require(AITranslationService.endpoint(for: anthropic)?.path == "/v1/messages",
                    "Claude Messages must append its native endpoint")
        try require(AITranslationService.endpoint(for: gemini)?.absoluteString ==
                    "https://api.example.com/v1beta/models/gemini-test:generateContent",
                    "Gemini must place the model in the generateContent path")
        try require(AITranslationService.endpoint(for: AITranslationConfiguration(
            baseURL: "http://127.0.0.1:11434/v1", model: "local")) != nil,
                    "Loopback OpenAI-compatible services may use local HTTP")
        try require(AITranslationService.endpoint(for: AITranslationConfiguration(
            baseURL: "http://remote.example.com/v1", model: "remote")) == nil,
                    "Non-loopback endpoints must still require HTTPS")

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockAIURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { MockAIURLProtocol.handler = nil }

        var capturedPath = ""
        var capturedBody: [String: Any] = [:]
        var capturedHeaders: [String: String] = [:]
        MockAIURLProtocol.handler = { request in
            capturedPath = request.url?.path ?? ""
            capturedHeaders = [
                "authorization": request.value(forHTTPHeaderField: "Authorization") ?? "",
                "x-api-key": request.value(forHTTPHeaderField: "x-api-key") ?? "",
                "anthropic-version": request.value(forHTTPHeaderField: "anthropic-version") ?? "",
                "x-goog-api-key": request.value(forHTTPHeaderField: "x-goog-api-key") ?? ""
            ]
            let data = requestBodyData(request)
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                capturedBody = body
            }
            return (200, Data(#"{"choices":[{"message":{"content":"聊天译文"}}]}"#.utf8))
        }
        let chatResult = try await AITranslationService(session: session).translate(
            text: "Hello", source: "en", target: "zh-Hans",
            configuration: chat, apiKey: "chat-key"
        )
        try require(chatResult == "聊天译文" && capturedPath == "/v1/chat/completions" &&
                    capturedHeaders["authorization"] == "Bearer chat-key" &&
                    capturedBody["model"] as? String == "chat-model",
                    "OpenAI Chat request contract must remain compatible: result=\(chatResult) " +
                    "path=\(capturedPath) headers=\(capturedHeaders) body=\(capturedBody)")

        capturedPath = ""
        capturedBody = [:]
        capturedHeaders = [:]
        MockAIURLProtocol.handler = { request in
            capturedPath = request.url?.path ?? ""
            capturedHeaders = [
                "authorization": request.value(forHTTPHeaderField: "Authorization") ?? "",
                "x-api-key": request.value(forHTTPHeaderField: "x-api-key") ?? "",
                "anthropic-version": request.value(forHTTPHeaderField: "anthropic-version") ?? "",
                "x-goog-api-key": request.value(forHTTPHeaderField: "x-goog-api-key") ?? ""
            ]
            let data = requestBodyData(request)
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                capturedBody = body
            }
            return (200, Data(#"{"output":[{"content":[{"type":"output_text","text":"响应译文"}]}]}"#.utf8))
        }
        let responsesResult = try await AITranslationService(session: session).translate(
            text: "Hello", source: "en", target: "zh-Hans",
            configuration: responses, apiKey: "responses-key"
        )
        try require(responsesResult == "响应译文" && capturedPath == "/v1/responses" &&
                    capturedBody["input"] as? String == "Hello" &&
                    capturedBody["instructions"] is String,
                    "OpenAI Responses must send instructions and decode output content")

        capturedPath = ""
        capturedBody = [:]
        capturedHeaders = [:]
        MockAIURLProtocol.handler = { request in
            capturedPath = request.url?.path ?? ""
            capturedHeaders = [
                "authorization": request.value(forHTTPHeaderField: "Authorization") ?? "",
                "x-api-key": request.value(forHTTPHeaderField: "x-api-key") ?? "",
                "anthropic-version": request.value(forHTTPHeaderField: "anthropic-version") ?? "",
                "x-goog-api-key": request.value(forHTTPHeaderField: "x-goog-api-key") ?? ""
            ]
            let data = requestBodyData(request)
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                capturedBody = body
            }
            return (200, Data(#"{"content":[{"type":"text","text":"Claude 译文"}]}"#.utf8))
        }
        let anthropicResult = try await AITranslationService(session: session).translate(
            text: "Hello", source: "en", target: "zh-Hans",
            configuration: anthropic, apiKey: "anthropic-key"
        )
        try require(anthropicResult == "Claude 译文" && capturedPath == "/v1/messages" &&
                    capturedHeaders["x-api-key"] == "anthropic-key" &&
                    capturedHeaders["anthropic-version"] == "2023-06-01" &&
                    capturedBody["max_tokens"] as? Int == 4096,
                    "Claude Messages must use x-api-key and its versioned message body")

        capturedPath = ""
        capturedBody = [:]
        capturedHeaders = [:]
        MockAIURLProtocol.handler = { request in
            capturedPath = request.url?.path ?? ""
            capturedHeaders = [
                "authorization": request.value(forHTTPHeaderField: "Authorization") ?? "",
                "x-api-key": request.value(forHTTPHeaderField: "x-api-key") ?? "",
                "anthropic-version": request.value(forHTTPHeaderField: "anthropic-version") ?? "",
                "x-goog-api-key": request.value(forHTTPHeaderField: "x-goog-api-key") ?? ""
            ]
            let data = requestBodyData(request)
            if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                capturedBody = body
            }
            return (200, Data(#"{"candidates":[{"content":{"parts":[{"text":"Gemini 译文"}]}}]}"#.utf8))
        }
        let geminiResult = try await AITranslationService(session: session).translate(
            text: "Hello", source: "en", target: "zh-Hans",
            configuration: gemini, apiKey: "gemini-key"
        )
        try require(geminiResult == "Gemini 译文" &&
                    capturedPath == "/v1beta/models/gemini-test:generateContent" &&
                    capturedHeaders["x-goog-api-key"] == "gemini-key" &&
                    capturedBody["systemInstruction"] != nil &&
                    capturedBody["contents"] != nil,
                    "Gemini must use generateContent, google key header and native body")

        let local = AITranslationConfiguration(
            baseURL: "http://127.0.0.1:11434/v1",
            model: "local-model",
            instructions: "",
            api: .openAIChat
        )
        MockAIURLProtocol.handler = { _ in
            (200, Data(#"{"choices":[{"message":{"content":"本机译文"}}]}"#.utf8))
        }
        let localResult = try await AITranslationService(session: session).translate(
            text: "Hello", source: "en", target: "zh-Hans",
            configuration: local, apiKey: ""
        )
        try require(localResult == "本机译文",
                    "Loopback OpenAI-compatible services must work without an API key")
        try require(local.allowsEmptyAPIKey,
                    "Local configuration must explicitly allow an empty API key")
    }

    static func textToolboxGeneration() async throws {
        try require(VariableNameTransformer.convert(
            "user profile", defaultStyle: .lowerCamel).value == "userProfile",
                    "Lower camel conversion must produce xt-style names")
        try require(VariableNameTransformer.convert(
            "user profile", defaultStyle: .upperCamel).value == "UserProfile",
                    "Upper camel conversion must capitalize every word")
        try require(VariableNameTransformer.convert(
            "用户 名称", defaultStyle: .lowerCamel).value == "userName",
                    "Chinese phrases must translate into English before variable naming: " +
                    VariableNameTransformer.convert("用户 名称", defaultStyle: .lowerCamel).value)
        try require(VariableNameTransformer.convert(
            "lt 用户登录页面", defaultStyle: .upperCamel).value == "userLoginPage",
                    "lt must alias lower camel and translate Chinese arguments into English")
        try require(QuickLauncherParser.invocation(from: "xt 用户登录") ==
                    QuickLauncherInvocation(command: .variable(.lowerCamel), argument: "用户登录"),
                    "Launcher parser must split command aliases and Chinese arguments")
        try require(QuickLauncherParser.invocation(from: "lt用户登录")?.command == .variable(.lowerCamel),
                    "Launcher parser must accept a command immediately followed by Chinese")
        try require(QuickLauncherCommand.matching("sfz") == .random(.identityCard),
                    "Launcher commands must expose short Chinese aliases")
        try require(VariableNameTransformer.convert(
            "snake API response", defaultStyle: .lowerCamel).value == "api_response",
                    "Command prefixes must override the selected variable style")
        try require(VariableNameTransformer.convert(
            "upper API response", defaultStyle: .lowerCamel).value == "API_RESPONSE",
                    "Constant command must generate upper snake case")
        try require(RandomDataType.fromKeyword("地址") == .address,
                    "Quick input must recognize the address keyword")
        try require(RandomDataType.fromKeyword("  IP  ") == .ipv4,
                    "Quick input keyword matching must ignore whitespace and case")
        try require(RandomDataType.fromKeyword("身份证") == .identityCard,
                    "Quick input must recognize the identity card keyword")
        try require(RandomDataType.fromKeyword("random-email") == nil,
                    "Quick input keywords must be exact to avoid accidental random generation")

        for type in RandomDataType.allCases {
            let value = RandomDataGenerator.generate(type)
            try require(!value.isEmpty, "Random \(type.title) must not be empty")
            switch type {
            case .email:
                try require(value.contains("@") && value.contains("."),
                            "Generated email must contain a domain")
            case .address:
                try require(value.contains("号") && value.contains("室"),
                            "Generated address must be a complete sample address")
            case .phone:
                try require(value.count == 11 && value.allSatisfy(\.isNumber),
                            "Generated mobile number must contain 11 digits")
            case .ipv4:
                let parts = value.split(separator: ".").compactMap { Int($0) }
                try require(parts.count == 4 && parts.allSatisfy { (0...255).contains($0) },
                            "Generated IPv4 address must be valid")
            case .identityCard:
                try require(value.count == 18 && RandomDataGenerator.isChecksumValidIdentityCard(value),
                            "Generated identity card must have a valid checksum")
            case .uuid:
                try require(UUID(uuidString: value) != nil, "Generated UUID must be valid")
            case .password:
                try require(value.count == 16 &&
                            value.contains(where: \.isLowercase) &&
                            value.contains(where: \.isUppercase) &&
                            value.contains(where: \.isNumber) &&
                            value.contains { !$0.isLetter && !$0.isNumber },
                            "Generated password must include every character class")
            case .name:
                try require(value.count >= 2, "Generated name must contain at least two characters")
            }
        }
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
        var pinned = 0
        var copiedImage: NSImage?
        var pinnedImage: NSImage?
        var pinnedRect: CGRect?
        var pinSawActiveDraft = false
        model.publishImage = { copied += 1; copiedImage = $0 }
        model.pinImage = { image, rect in
            pinned += 1
            pinnedImage = image
            pinnedRect = rect
            pinSawActiveDraft = model.draftImage != nil
        }
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
        try require(copied == 1 && pinned == 1 && model.draftImage == nil && !pinSawActiveDraft && pinnedRect == nil &&
                    pinnedImage?.pngData == ImageRenderer.render(sample(), marks: [mark]).pngData,
                    "Pin must dismiss the draft first, then immediately publish the annotated image without copying it")
        let pinnedHistory = try model.store!.load()
        try require(pinnedHistory.count == original.count &&
                    pinnedHistory.first?.text == original.first?.text,
                    "Pinning directly must not add or overwrite a PNG/history record")
        model.acceptImage(sample(), title: "Cancelled")
        model.discardDraft()
        try require(copied == 1 && pinned == 1,
                    "Cancel must not copy or pin a discarded draft")
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
        try require(copied == 2 && pinned == 1 &&
                    copiedImage?.pngData == ImageRenderer.render(sample(), marks: [mark]).pngData,
                    "Checkmark must copy the fully annotated image by default")
        model.requestPin()
        try require(pinned == 2 && pinnedRect == nil,
                    "Pin must be available immediately for an already confirmed image")
        model.confirmDraft()
        try require(model.records.count == 2 && copied == 2, "Repeated confirmation must not duplicate history or clipboard writes")
        model.keepHistory = false
        model.acceptImage(sample(), title: "Clipboard only")
        model.confirmDraft()
        try require(copied == 3 && model.draftImage == nil && model.records.count == 2,
                    "History disabled must still copy immediately without a save dialog")
        let region = CGRect(x: 100, y: 150, width: 300, height: 200)
        model.acceptImage(sample(), title: "Pinned region", inlineRect: region)
        model.requestPin()
        try require(pinned == 3 && pinnedRect == region && model.draftImage == nil && copied == 3,
                    "Pinning a screen selection must place the pin over the captured area without copying it")
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
        try require(
            CaptureSelectionGeometry.handle(
                at: CGPoint(x: initial.midX, y: initial.maxY + 6),
                in: initial
            ) == .top,
            "Any point along the top edge must start a resize"
        )
        try require(
            CaptureSelectionGeometry.handle(
                at: CGPoint(x: initial.minX + 4, y: initial.minY + 5),
                in: initial
            ) == .bottomLeft,
            "The inside corner band must also be draggable"
        )
        try require(
            CaptureSelectionGeometry.handle(
                at: CGPoint(x: initial.maxX - 5, y: initial.midY),
                in: initial
            ) == .right,
            "Any point along the right edge must start a resize"
        )
        try require(
            CaptureSelectionGeometry.handle(
                at: CGPoint(x: initial.midX, y: initial.minY + 3),
                in: initial
            ) == .bottom,
            "Any point along the bottom edge must start a resize"
        )
        try require(
            CaptureSelectionGeometry.handle(
                at: CGPoint(x: initial.maxX - 3, y: initial.maxY - 4),
                in: initial
            ) == .topRight,
            "Every selection corner must start a two-axis resize"
        )
        try require(
            CaptureSelectionGeometry.handle(
                at: CGPoint(x: initial.midX, y: initial.midY),
                in: initial
            ) == nil,
            "The selection centre must remain available for moving or annotating"
        )
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
        try require(abs(below.maxY - (initial.minY - 10)) < 0.01 && bounds.contains(below),
                    "Toolbar must default to a 10pt gap below the selection")
        let low = CGRect(x: 800, y: 0, width: 100, height: 80)
        let above = CaptureSelectionGeometry.toolbarFrame(selection: low, size: barSize, visible: bounds)
        try require(above.minY == low.maxY + 10 && bounds.contains(above),
                    "A bottom-edge crop must attach above with the same 10pt gap")
        let tall = CGRect(x: 280, y: 0, width: 180, height: 700)
        let side = CaptureSelectionGeometry.toolbarFrame(
            selection: tall, size: CGSize(width: 220, height: 46), visible: bounds)
        try require(side.minX == tall.maxX + 10 && bounds.contains(side),
                    "A full-height selection must attach to the nearest horizontal edge")

        let pinned = PinnedWindowGeometry.resizedContentSize(
            current: CGSize(width: 400, height: 200), imageAspectRatio: 0.5,
            scale: 1.25, chromeHeight: 28, visibleFrameSize: CGSize(width: 1000, height: 700))
        try require(pinned == CGSize(width: 500, height: 250),
                    "Pinned image zoom must scale both dimensions proportionally")
        let pinnedMaximum = PinnedWindowGeometry.resizedContentSize(
            current: pinned, imageAspectRatio: 0.5, scale: 10,
            chromeHeight: 28, visibleFrameSize: CGSize(width: 1000, height: 700))
        try require(pinnedMaximum.width * 0.5 + 28 <= 700 * 0.92 &&
                    pinnedMaximum.width <= 1000 * 0.92,
                    "Pinned image zoom must remain inside the visible screen")
        let pinnedFrame = PinnedWindowGeometry.anchoredFrame(
            currentFrame: CGRect(x: 300, y: 250, width: 400, height: 228),
            currentContentSize: CGSize(width: 400, height: 200),
            targetContentSize: CGSize(width: 500, height: 250),
            anchorInContent: CGPoint(x: 100, y: 50), chromeHeight: 28, visibleFrame: bounds)
        try require(abs(pinnedFrame.minX - 275) < 0.01 && abs(pinnedFrame.minY - 237.5) < 0.01 &&
                    bounds.contains(pinnedFrame),
                    "Pinned image zoom must keep the point under the pointer stable")
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
                    "Line, highlighter and numbered marker must render onto the image " +
                    "(line=\(linePixels), highlighter=\(highlighterPixels), number=\(numberPixels))")
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
            ("annotation_sizes_use_points", annotationPointSizes),
            ("annotation_marks_can_be_moved", annotationMarksCanBeMoved),
            ("selected_marks_delete_nudge_restyle_and_reedit", selectedAnnotationEditing),
            ("selecting_a_mark_adopts_its_style", selectingMarkAdoptsItsStyle),
            ("eyedropper_samples_clicked_pixel", eyedropperSamplesClickedPixel),
            ("portrait_text_size_matches_points", textSizeMatchesPointsInPortraitImages),
            ("status_menu_key_equivalents", menuKeyEquivalents),
            ("toolbar_popover_keys_reach_canvas", toolbarPopoverKeysReachCanvas),
            ("tool_shortcuts_follow_toolbar_order", toolShortcutsFollowToolbarOrder),
            ("text_field_grows_with_content", textFieldGrowsWithContent),
            ("text_annotation_export_pixels", textPixels),
            ("mosaic_changes_only_selected_pixels", mosaicPixels),
            ("advanced_annotation_styles", advancedAnnotationStyles),
            ("fixed_ratio_selection_geometry", fixedAspectSelection),
            ("cursor_anchored_zoom_and_limits", zoomGeometry),
            ("editor_close_translation_undo_and_record_actions", editorActions),
            ("apple_translation_and_menu_bar_defaults", defaultPreferences),
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
            ("unsaved_recording_survives_relaunch", recordingDraftRecovery),
            ("manual_hotkey_input_parser", manualHotkeyInput),
            ("selected_text_translation", selectedTextTranslation),
            ("ai_translation_request_contract", aiTranslationRequests),
            ("ai_model_discovery", aiModelDiscovery),
            ("ai_protocol_auto_fallback", aiProtocolAutoFallback),
            ("ai_translation_server_error", aiTranslationErrors),
            ("ai_protocol_compatibility", aiProtocolCompatibility),
            ("variable_names_and_random_test_data", textToolboxGeneration)
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
