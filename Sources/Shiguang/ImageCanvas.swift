import AppKit
import SwiftUI

struct CanvasViewport {
    var zoom: CGFloat = 1
    var offset = CGPoint.zero
    var inset: CGFloat = 12
    var alignsToBottom = false

    func imageRect(image: CGSize, viewport: CGSize) -> CGRect {
        let scale = min(max(1, viewport.width - inset * 2) / max(1, image.width),
                        max(1, viewport.height - inset * 2) / max(1, image.height)) * zoom
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (viewport.width - size.width) / 2 + offset.x,
                      y: (alignsToBottom ? viewport.height - size.height - inset :
                            (viewport.height - size.height) / 2) + offset.y,
                      width: size.width, height: size.height)
    }

    mutating func setZoom(_ value: CGFloat, anchor: CGPoint, image: CGSize, viewport: CGSize) {
        let next = min(8, max(0.25, value))
        let before = imageRect(image: image, viewport: viewport)
        let unit = CGPoint(x: (anchor.x - before.minX) / before.width,
                           y: (anchor.y - before.minY) / before.height)
        zoom = next
        let after = imageRect(image: image, viewport: viewport)
        offset.x += anchor.x - after.minX - unit.x * after.width
        offset.y += anchor.y - after.minY - unit.y * after.height
        constrain(image: image, viewport: viewport)
    }

    mutating func constrain(image: CGSize, viewport: CGSize) {
        let rect = imageRect(image: image, viewport: viewport)
        let x = max(0, (rect.width + viewport.width) / 2 - min(48, rect.width / 2))
        let y = max(0, (rect.height + viewport.height) / 2 - min(48, rect.height / 2))
        offset.x = min(x, max(-x, offset.x))
        offset.y = min(y, max(-y, offset.y))
    }
}

struct ImageCanvas: NSViewRepresentable {
    let image: NSImage
    let marks: [Mark]
    let tool: MarkTool
    let colorHex: String
    @Binding var zoom: CGFloat
    var resetID: UUID
    var movesWindow = false
    var enabled = true
    var filledShapes = false
    var lineWidthPoints = AnnotationSizeMetrics.defaultLineWidthPoints
    var numberSizePoints = AnnotationSizeMetrics.defaultNumberSizePoints
    var arrowDoubleHeaded = false
    var textFontSize: Double = 20
    var textPresentation: TextPresentation = .plain
    var maskStyle: MaskStyle = .pixel
    var maskSizePoints = AnnotationSizeMetrics.defaultMaskSizePoints
    var spotlightStrength: SpotlightStrength = .light
    var onColorPick: ((String) -> Void)?
    let onMark: (Mark) -> Void
    var onBeginMarkEdit: ((UUID) -> Void)?
    var onUpdateMark: ((Mark) -> Void)?
    var onFinishMarkEdit: (() -> Void)?
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NativeImageCanvas { NativeImageCanvas() }

    func updateNSView(_ view: NativeImageCanvas, context: Context) {
        view.onMark = onMark
        view.onBeginMarkEdit = onBeginMarkEdit
        view.onUpdateMark = onUpdateMark
        view.onFinishMarkEdit = onFinishMarkEdit
        view.onEscape = onEscape
        view.onColorPick = onColorPick
        view.onZoom = { zoom = $0 }
        view.configure(image: image, marks: marks, tool: tool, color: colorHex, zoom: zoom,
                       resetID: resetID, movesWindow: movesWindow, enabled: enabled,
                       filledShapes: filledShapes, lineWidthPoints: lineWidthPoints,
                       numberSizePoints: numberSizePoints,
                       arrowDoubleHeaded: arrowDoubleHeaded, textFontSize: textFontSize,
                       textPresentation: textPresentation, maskStyle: maskStyle,
                       maskSizePoints: maskSizePoints, spotlightStrength: spotlightStrength)
    }
}

final class NativeImageCanvas: NSView, NSTextFieldDelegate {
    enum SelectionDrag { case began, changed, ended }
    var onSelectionDrag: ((NSEvent, SelectionDrag) -> Void)?
    var onMark: ((Mark) -> Void)?
    var onBeginMarkEdit: ((UUID) -> Void)?
    var onUpdateMark: ((Mark) -> Void)?
    var onFinishMarkEdit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onColorPick: ((String) -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    private var image: NSImage?
    private var rendered: NSImage?
    private var marks: [Mark] = []
    private var tool = MarkTool.pointer
    private var color = "E45F3C"
    private var filledShapes = false
    private var lineWidthPoints = AnnotationSizeMetrics.defaultLineWidthPoints
    private var numberSizePoints = AnnotationSizeMetrics.defaultNumberSizePoints
    private var arrowDoubleHeaded = false
    private var textFontSize: Double = 20
    private var textPresentation = TextPresentation.plain
    private var maskStyle = MaskStyle.pixel
    private var maskSizePoints = AnnotationSizeMetrics.defaultMaskSizePoints
    private var spotlightStrength = SpotlightStrength.light
    private var enabled = true
    private var viewport = CanvasViewport()
    private var draft: Mark?
    private var dragStart = CGPoint.zero
    private var offsetStart = CGPoint.zero
    private var textField: NSTextField?
    private var textAnchor: UnitPoint?
    private var textColor = ""
    private var textFraction = 0.035
    private var resetID: UUID?
    private var movesWindow = false
    private var isPanning = false
    private var inPlace = false
    private var isMovingSelection = false
    private var selectedMarkID: UUID?
    private var editingMark: Mark?
    private var editingPointIndex: Int?
    private var didBeginMarkEdit = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    private var imageSize: CGSize { rendered?.size ?? CGSize(width: 1, height: 1) }
    private var imagePointSize: CGSize {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return imageSize }
        return size
    }
    private var imageRect: CGRect { viewport.imageRect(image: imageSize, viewport: bounds.size) }

    func configure(image: NSImage, marks: [Mark], tool: MarkTool, color: String, zoom: CGFloat,
                   resetID: UUID, movesWindow: Bool, enabled: Bool, inPlace: Bool = false,
                   filledShapes: Bool = false,
                   lineWidthPoints: Double = AnnotationSizeMetrics.defaultLineWidthPoints,
                   numberSizePoints: Double = AnnotationSizeMetrics.defaultNumberSizePoints,
                   arrowDoubleHeaded: Bool = false, textFontSize: Double = 20,
                   textPresentation: TextPresentation = .plain, maskStyle: MaskStyle = .pixel,
                   maskSizePoints: Double = AnnotationSizeMetrics.defaultMaskSizePoints,
                   spotlightStrength: SpotlightStrength = .light) {
        let changedImage = self.image !== image
        if changedImage {
            finishText(commit: false)
            viewport = CanvasViewport()
            draft = nil
            selectedMarkID = nil
        }
        if changedImage || self.marks != marks {
            self.image = image
            self.marks = marks
            rendered = ImageRenderer.render(image, marks: marks)
            if let selectedMarkID, !marks.contains(where: { $0.id == selectedMarkID }) {
                self.selectedMarkID = nil
            }
        }
        if self.tool != tool { finishText(commit: true); draft = nil }
        self.tool = tool
        self.color = color
        self.filledShapes = filledShapes
        self.lineWidthPoints = lineWidthPoints
        self.numberSizePoints = numberSizePoints
        self.arrowDoubleHeaded = arrowDoubleHeaded
        self.textFontSize = textFontSize
        self.textPresentation = textPresentation
        self.maskStyle = maskStyle
        self.maskSizePoints = maskSizePoints
        self.spotlightStrength = spotlightStrength
        self.enabled = enabled
        self.movesWindow = movesWindow
        self.inPlace = inPlace
        if self.resetID != resetID {
            viewport = CanvasViewport()
            self.resetID = resetID
        }
        viewport.inset = movesWindow || inPlace ? 0 : 12
        viewport.alignsToBottom = movesWindow
        if abs(viewport.zoom - zoom) > 0.0001 {
            finishText(commit: true)
            viewport.setZoom(zoom, anchor: CGPoint(x: bounds.midX, y: bounds.midY),
                             image: imageSize, viewport: bounds.size)
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        viewport.constrain(image: imageSize, viewport: bounds.size)
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .pointer ? .openHand : (tool == .text ? .iBeam : .crosshair))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rendered else { return }
        let rect = imageRect
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = inPlace ? 0 : 10
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(rect: rect).fill()
        NSShadow().set()
        rendered.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                      hints: [.interpolation: NSImageInterpolation.high])
        NSBezierPath(rect: rect).addClip()
        if let draft { drawDraft(draft, rect: rect) }
        if let selectedMarkID,
           let selectedMark = marks.first(where: { $0.id == selectedMarkID }) {
            drawSelection(for: selectedMark, in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawDraft(_ mark: Mark, rect: CGRect) {
        guard let a = mark.points.first, let b = mark.points.last else { return }
        func point(_ p: UnitPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
        }
        let first = point(a), last = point(b)
        let box = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                         width: abs(first.x - last.x), height: abs(first.y - last.y))
        let path = NSBezierPath()
        let displayScale = min(rect.width / max(1, imageSize.width),
                               rect.height / max(1, imageSize.height))
        path.lineWidth = max(2, min(imageSize.width, imageSize.height) *
                             (mark.lineWidth ?? 0.005) * displayScale)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let color = NSColor(hex: mark.colorHex)
        switch mark.tool {
        case .pointer, .picker, .number, .text: return
        case .redact:
            NSColor.black.setFill(); NSBezierPath(rect: box).fill(); return
        case .mosaic:
            NSColor.gray.withAlphaComponent(mark.maskStyle == .blur ? 0.34 : 0.48).setFill()
            NSBezierPath(rect: box).fill()
            path.appendRect(box)
        case .spotlight:
            NSColor.black.withAlphaComponent(mark.spotlightStrength?.alpha ?? SpotlightStrength.light.alpha)
                .setFill()
            let shade = NSBezierPath(rect: imageRect)
            shade.appendRoundedRect(box, xRadius: 5, yRadius: 5)
            shade.windingRule = .evenOdd
            shade.fill()
            NSColor.white.withAlphaComponent(0.42).setStroke()
            path.appendRoundedRect(box, xRadius: 5, yRadius: 5)
        case .rectangle:
            if mark.filled == true {
                color.setFill()
                NSBezierPath(rect: box).fill()
                return
            }
            path.appendRect(box)
        case .ellipse:
            if mark.filled == true {
                color.setFill()
                NSBezierPath(ovalIn: box).fill()
                return
            }
            path.appendOval(in: box)
        case .line:
            path.move(to: first)
            path.line(to: last)
        case .pen:
            path.move(to: first)
            for p in mark.points.dropFirst() { path.line(to: point(p)) }
        case .highlighter:
            color.withAlphaComponent(0.34).setStroke()
            path.lineWidth *= 3.8
            path.move(to: first)
            for p in mark.points.dropFirst() { path.line(to: point(p)) }
            path.stroke()
            return
        case .arrow:
            path.move(to: first); path.line(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = min(path.lineWidth * 5, hypot(last.x - first.x, last.y - first.y) * 0.4)
            drawArrowHead(in: path, tip: last, angle: angle, length: length)
            if mark.arrowDoubleHeaded == true {
                drawArrowHead(in: path, tip: first, angle: angle + .pi, length: length)
            }
        }
        color.setStroke()
        path.stroke()
    }

    private func drawArrowHead(in path: NSBezierPath, tip: CGPoint, angle: CGFloat, length: CGFloat) {
        for offset in [-Double.pi / 6, Double.pi / 6] {
            path.move(to: tip)
            path.line(to: CGPoint(x: tip.x - length * cos(angle + offset),
                                  y: tip.y - length * sin(angle + offset)))
        }
    }

    private func drawSelection(for mark: Mark, in rect: CGRect) {
        guard let firstPoint = mark.points.first, rect.width > 0, rect.height > 0 else { return }
        let first = imagePoint(firstPoint, in: rect)
        let last = mark.points.last.map { imagePoint($0, in: rect) } ?? first
        let accent = NSColor.controlAccentColor
        let selectionPath = NSBezierPath()
        var handlePoints: [CGPoint] = []

        switch mark.tool {
        case .text:
            selectionPath.appendRoundedRect(textBounds(for: mark, in: rect), xRadius: 4, yRadius: 4)
        case .number:
            let radius = numberRadius(for: mark, in: rect) + 2
            selectionPath.appendOval(in: CGRect(x: first.x - radius, y: first.y - radius,
                                                width: radius * 2, height: radius * 2))
        case .line, .arrow:
            selectionPath.move(to: first)
            selectionPath.line(to: last)
            handlePoints = [first, last]
        case .pen, .highlighter:
            selectionPath.move(to: first)
            for point in mark.points.dropFirst() {
                selectionPath.line(to: imagePoint(point, in: rect))
            }
        case .rectangle, .ellipse, .redact, .mosaic, .spotlight:
            let box = markBounds(mark, in: rect)
            if mark.tool == .ellipse {
                selectionPath.appendOval(in: box)
            } else {
                selectionPath.appendRoundedRect(box, xRadius: 3, yRadius: 3)
            }
            handlePoints = [first, last]
        case .pointer, .picker:
            return
        }

        NSGraphicsContext.saveGraphicsState()
        accent.setStroke()
        selectionPath.lineWidth = 1.4
        selectionPath.setLineDash([4, 3], count: 2, phase: 0)
        selectionPath.stroke()
        NSGraphicsContext.restoreGraphicsState()

        for point in handlePoints {
            let handle = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            NSColor.white.setFill()
            accent.setStroke()
            let path = NSBezierPath(ovalIn: handle)
            path.lineWidth = 1.5
            path.fill()
            path.stroke()
        }
    }

    private func imagePoint(_ point: UnitPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width,
                y: rect.minY + point.y * rect.height)
    }

    private func markBounds(_ mark: Mark, in rect: CGRect) -> CGRect {
        guard let first = mark.points.first else { return .zero }
        let firstPoint = imagePoint(first, in: rect)
        let lastPoint = imagePoint(mark.points.last ?? first, in: rect)
        return CGRect(x: min(firstPoint.x, lastPoint.x),
                      y: min(firstPoint.y, lastPoint.y),
                      width: abs(lastPoint.x - firstPoint.x),
                      height: abs(lastPoint.y - firstPoint.y))
    }

    private func textBounds(for mark: Mark, in rect: CGRect) -> CGRect {
        guard let text = mark.text, let first = mark.points.first else { return .zero }
        let origin = imagePoint(first, in: rect)
        let displayScale = rect.height / max(1, imageSize.height)
        let font = NSFont.systemFont(
            ofSize: max(8, (mark.fontSize ?? 0.035) * imageSize.height) * displayScale,
            weight: .semibold
        )
        let measured = (text as NSString).size(withAttributes: [.font: font])
        let padding = max(3, font.pointSize * 0.2)
        return CGRect(x: origin.x - padding,
                      y: origin.y - padding * 0.55,
                      width: measured.width + padding * 2,
                      height: measured.height + padding * 1.1)
    }

    private func numberRadius(for mark: Mark, in rect: CGRect) -> CGFloat {
        let shortestSide = min(rect.width, rect.height)
        if let sizeFraction = mark.numberSize {
            return max(2, min(shortestSide * 0.45, shortestSide * max(0.002, sizeFraction)))
        }
        return max(9, min(46, shortestSide * 0.022))
    }

    private func hitMark(at point: CGPoint) -> Mark? {
        let rect = imageRect
        guard rect.contains(point) else { return nil }
        return marks.reversed().first { markContains($0, point: point, in: rect) }
    }

    private func markContains(_ mark: Mark, point: CGPoint, in rect: CGRect) -> Bool {
        let tolerance: CGFloat = 16
        switch mark.tool {
        case .text:
            return textBounds(for: mark, in: rect).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .number:
            guard let first = mark.points.first else { return false }
            let center = imagePoint(first, in: rect)
            return hypot(point.x - center.x, point.y - center.y) <= numberRadius(for: mark, in: rect) + tolerance
        case .rectangle, .ellipse, .redact, .mosaic, .spotlight:
            return markBounds(mark, in: rect).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .line, .arrow, .pen, .highlighter:
            guard let first = mark.points.first else { return false }
            let path = mark.points.map { imagePoint($0, in: rect) }
            let points = mark.tool == .line || mark.tool == .arrow
                ? [imagePoint(first, in: rect), imagePoint(mark.points.last ?? first, in: rect)]
                : path
            let width = max(2, min(imageSize.width, imageSize.height) *
                            (mark.lineWidth ?? 0.005) * (rect.width / max(1, imageSize.width)))
            let hitWidth = max(tolerance, width * (mark.tool == .highlighter ? 2 : 0.75))
            guard points.count > 1 else { return false }
            for index in 1..<points.count {
                if distance(from: point, toSegment: points[index - 1], points[index]) <= hitWidth {
                    return true
                }
            }
            return false
        case .pointer, .picker:
            return false
        }
    }

    private func handleIndex(for mark: Mark, at point: CGPoint, in rect: CGRect) -> Int? {
        guard mark.points.count >= 2 else { return nil }
        switch mark.tool {
        case .line, .arrow, .rectangle, .ellipse, .redact, .mosaic, .spotlight:
            let first = imagePoint(mark.points[0], in: rect)
            let last = imagePoint(mark.points[mark.points.count - 1], in: rect)
            if hypot(point.x - first.x, point.y - first.y) <= 11 { return 0 }
            if hypot(point.x - last.x, point.y - last.y) <= 11 { return mark.points.count - 1 }
            return nil
        default:
            return nil
        }
    }

    private func distance(from point: CGPoint, toSegment start: CGPoint, _ end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let nearest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - nearest.x, point.y - nearest.y)
    }

    private func normalized(_ point: CGPoint) -> UnitPoint {
        let rect = imageRect
        return UnitPoint(x: (point.x - rect.minX) / max(1, rect.width),
                         y: (point.y - rect.minY) / max(1, rect.height))
    }

    override func mouseDown(with event: NSEvent) {
        finishText(commit: true)
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        offsetStart = viewport.offset
        isPanning = false
        editingMark = nil
        editingPointIndex = nil
        didBeginMarkEdit = false
        guard imageRect.contains(point) else { return }

        if enabled, tool != .picker, let hit = hitMark(at: point) {
            // Existing annotations take precedence over creating another mark.
            // This lets users drag immediately after drawing, even while the
            // drawing tool is still selected.
            selectedMarkID = hit.id
            editingMark = hit
            editingPointIndex = handleIndex(for: hit, at: point, in: imageRect)
            needsDisplay = true
            return
        } else {
            selectedMarkID = nil
            needsDisplay = true
        }

        if tool == .pointer || event.modifierFlags.contains(.option) {
            if inPlace && viewport.zoom <= 1.001 && enabled {
                isMovingSelection = true
                NSCursor.closedHand.set()
                onSelectionDrag?(event, .began)
            } else if movesWindow && (viewport.zoom <= 1.001 || event.modifierFlags.contains(.option)) {
                window?.performDrag(with: event)
            } else {
                isPanning = true
                NSCursor.closedHand.set()
            }
            return
        }
        guard enabled else { return }
        if tool == .text { beginText(at: point); return }
        if tool == .picker {
            if let picked = sampledColor(at: point) { onColorPick?(picked) }
            return
        }
        if tool == .number {
            let next = marks.filter { $0.tool == .number }.count + 1
            let mark = Mark(tool: .number, points: [normalized(point)], colorHex: color,
                            filled: nil, text: String(next), fontSize: nil,
                            lineWidth: AnnotationSizeMetrics.fraction(
                                points: numberSizePoints, imageSize: imagePointSize),
                            numberSize: AnnotationSizeMetrics.fraction(
                                points: numberSizePoints, imageSize: imagePointSize))
            selectedMarkID = mark.id
            onMark?(mark)
            return
        }
        if tool != .pointer {
            let shouldFill = (tool == .rectangle || tool == .ellipse) && filledShapes
            draft = Mark(tool: tool, points: [normalized(point)], colorHex: color,
                         filled: shouldFill, text: nil, fontSize: nil,
                         lineWidth: AnnotationSizeMetrics.fraction(
                            points: lineWidthPoints, imageSize: imagePointSize),
                         arrowDoubleHeaded: arrowDoubleHeaded ? true : nil,
                         maskStyle: tool == .mosaic ? maskStyle : nil,
                         maskSize: tool == .mosaic
                            ? AnnotationSizeMetrics.fraction(points: maskSizePoints, imageSize: imagePointSize)
                            : nil,
                         spotlightStrength: tool == .spotlight ? spotlightStrength : nil)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let original = editingMark {
            if !didBeginMarkEdit {
                didBeginMarkEdit = true
                onBeginMarkEdit?(original.id)
            }
            let point = convert(event.locationInWindow, from: nil)
            let rect = imageRect
            var updated = original
            if let editingPointIndex {
                updated.points[editingPointIndex] = normalized(point)
            } else {
                let deltaX = Double((point.x - dragStart.x) / max(1, rect.width))
                let deltaY = Double((point.y - dragStart.y) / max(1, rect.height))
                let minX = original.points.map(\.x).min() ?? 0
                let maxX = original.points.map(\.x).max() ?? 1
                let minY = original.points.map(\.y).min() ?? 0
                let maxY = original.points.map(\.y).max() ?? 1
                let clampedX = min(1 - maxX, max(-minX, deltaX))
                let clampedY = min(1 - maxY, max(-minY, deltaY))
                updated.points = original.points.map {
                    UnitPoint(x: $0.x + clampedX, y: $0.y + clampedY)
                }
            }
            onUpdateMark?(updated)
            needsDisplay = true
            return
        }
        if isMovingSelection { onSelectionDrag?(event, .changed); return }
        let point = convert(event.locationInWindow, from: nil)
        if isPanning {
            viewport.offset = CGPoint(x: offsetStart.x + point.x - dragStart.x,
                                      y: offsetStart.y + point.y - dragStart.y)
            viewport.constrain(image: imageSize, viewport: bounds.size)
        } else if enabled, var mark = draft, let start = mark.points.first {
            if tool == .pen || tool == .highlighter { mark.points.append(normalized(point)) }
            else { mark.points = [start, normalized(point)] }
            draft = mark
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if editingMark != nil {
            if didBeginMarkEdit { onFinishMarkEdit?() }
            editingMark = nil
            editingPointIndex = nil
            didBeginMarkEdit = false
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }
        if isMovingSelection {
            onSelectionDrag?(event, .ended)
            isMovingSelection = false
            window?.invalidateCursorRects(for: self)
            return
        }
        isPanning = false
        window?.invalidateCursorRects(for: self)
        if let mark = draft, mark.points.count > 1 {
            selectedMarkID = mark.id
            onMark?(mark)
        }
        draft = nil
        needsDisplay = true
    }

    private func sampledColor(at point: CGPoint) -> String? {
        guard let cg = rendered?.cgImageValue else { return nil }
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let unitX = min(0.999, max(0, (point.x - rect.minX) / rect.width))
        let unitY = min(0.999, max(0, (point.y - rect.minY) / rect.height))
        let x = min(cg.width - 1, max(0, Int(unitX * CGFloat(cg.width))))
        let y = min(cg.height - 1, max(0, Int(unitY * CGFloat(cg.height))))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        guard let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1 - y)?
            .usingColorSpace(.sRGB) else { return nil }
        return String(format: "%02X%02X%02X",
                      Int((color.redComponent * 255).rounded()),
                      Int((color.greenComponent * 255).rounded()),
                      Int((color.blueComponent * 255).rounded()))
    }

    override func scrollWheel(with event: NSEvent) {
        if textField != nil { finishText(commit: true) }
    }

    override func magnify(with event: NSEvent) {
        finishText(commit: true)
        changeZoom(viewport.zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    private func changeZoom(_ value: CGFloat, anchor: CGPoint) {
        viewport.setZoom(value, anchor: anchor, image: imageSize, viewport: bounds.size)
        onZoom?(viewport.zoom)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelOperation(nil) }
        else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        if textField != nil { finishText(commit: false) }
        else { draft = nil; onEscape?() }
    }

    private func beginText(at point: CGPoint) {
        let rect = imageRect
        textAnchor = normalized(point)
        textColor = color
        textFraction = AnnotationSizeMetrics.fraction(points: textFontSize, imageSize: imagePointSize)
        let displayScale = rect.height / max(1, imagePointSize.height)
        let field = NSTextField(frame: CGRect(x: point.x, y: point.y,
                                              width: max(50, min(360, bounds.maxX - point.x)),
                                              height: max(30, textFontSize * displayScale + 10)))
        field.font = .systemFont(ofSize: textFontSize * displayScale, weight: .semibold)
        field.textColor = NSColor(hex: color)
        field.isBezeled = false
        field.drawsBackground = textPresentation == .highlighted
        field.backgroundColor = textPresentation == .highlighted
            ? NSColor(hex: color).withAlphaComponent(0.18) : .clear
        field.placeholderString = "输入文字，回车完成"
        field.focusRingType = .exterior
        field.delegate = self
        textField = field
        addSubview(field)
        window?.makeFirstResponder(field)
    }

    private func finishText(commit: Bool) {
        guard let field = textField else { return }
        textField = nil
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        if commit, !value.isEmpty, let anchor = textAnchor {
            let mark = Mark(tool: .text, points: [anchor], colorHex: textColor, text: value,
                            fontSize: textFraction, lineWidth: nil,
                            textPresentation: textPresentation)
            selectedMarkID = mark.id
            onMark?(mark)
        }
        textAnchor = nil
    }

    func commitPendingText() { finishText(commit: true) }

    func controlTextDidEndEditing(_ notification: Notification) { finishText(commit: true) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishText(commit: false)
            window?.makeFirstResponder(self)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishText(commit: true)
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }
}
