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
    let model: AppModel
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
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NativeImageCanvas { NativeImageCanvas() }

    func updateNSView(_ view: NativeImageCanvas, context: Context) {
        view.bindAnnotationEditing(to: model)
        view.onEscape = onEscape
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

extension NativeImageCanvas {
    /// Routes every annotation edit to the model. Each editor host must use
    /// this so moving, deleting and restyling marks behave (and undo) the same
    /// in the on-screen selection editor and the editor window.
    func bindAnnotationEditing(to model: AppModel) {
        onMark = { [weak model] in model?.addMark($0) }
        onBeginMarkEdit = { [weak model] in model?.beginEditingMark($0) }
        onUpdateMark = { [weak model] in model?.updateMark($0) }
        onFinishMarkEdit = { [weak model] in model?.finishEditingMark() }
        onDeleteMark = { [weak model] in model?.deleteMark($0) }
        onSelectMark = { [weak model] mark, size in model?.adoptStyle(of: mark, imagePointSize: size) }
        onColorPick = { [weak model] in model?.applyPickedColor($0) }
    }
}

/// The toolbar values a canvas was last configured with. Comparing two
/// snapshots tells which control the user just changed.
private struct CanvasStyle: Equatable {
    var color: String
    var filled: Bool
    var lineWidthPoints: Double
    var numberSizePoints: Double
    var arrowDoubleHeaded: Bool
    var textFontSize: Double
    var textPresentation: TextPresentation
    var maskStyle: MaskStyle
    var maskSizePoints: Double
}

final class NativeImageCanvas: NSView, NSTextFieldDelegate {
    enum SelectionDrag { case began, changed, ended }
    var onSelectionDrag: ((NSEvent, SelectionDrag) -> Void)?
    var onMark: ((Mark) -> Void)?
    var onBeginMarkEdit: ((UUID) -> Void)?
    var onUpdateMark: ((Mark) -> Void)?
    var onFinishMarkEdit: (() -> Void)?
    var onDeleteMark: ((UUID) -> Void)?
    /// Called when the user clicks an existing mark, with the image size in points.
    var onSelectMark: ((Mark, CGSize) -> Void)?
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
    /// An existing text mark whose content is open in the text field; it is
    /// hidden from the rendered image until editing ends.
    private var editingTextMark: Mark?
    private var fieldPresentation = TextPresentation.plain
    private var hasConfiguredStyle = false
    private var isConfiguring = false
    private var nudgeRegisteredUndo = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    private var imageSize: CGSize { rendered?.size ?? CGSize(width: 1, height: 1) }
    private var imagePointSize: CGSize {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return imageSize }
        return size
    }
    private var imageRect: CGRect { viewport.imageRect(image: imageSize, viewport: bounds.size) }
    private var currentStyle: CanvasStyle {
        CanvasStyle(color: color, filled: filledShapes, lineWidthPoints: lineWidthPoints,
                    numberSizePoints: numberSizePoints, arrowDoubleHeaded: arrowDoubleHeaded,
                    textFontSize: textFontSize, textPresentation: textPresentation,
                    maskStyle: maskStyle, maskSizePoints: maskSizePoints)
    }

    func configure(image: NSImage, marks: [Mark], tool: MarkTool, color: String, zoom: CGFloat,
                   resetID: UUID, movesWindow: Bool, enabled: Bool, inPlace: Bool = false,
                   filledShapes: Bool = false,
                   lineWidthPoints: Double = AnnotationSizeMetrics.defaultLineWidthPoints,
                   numberSizePoints: Double = AnnotationSizeMetrics.defaultNumberSizePoints,
                   arrowDoubleHeaded: Bool = false, textFontSize: Double = 20,
                   textPresentation: TextPresentation = .plain, maskStyle: MaskStyle = .pixel,
                   maskSizePoints: Double = AnnotationSizeMetrics.defaultMaskSizePoints,
                   spotlightStrength: SpotlightStrength = .light) {
        isConfiguring = true
        defer { isConfiguring = false }
        let changedImage = self.image !== image
        let previousStyle = currentStyle
        if changedImage {
            finishText(commit: false)
            viewport = CanvasViewport()
            draft = nil
            selectedMarkID = nil
        }
        if changedImage || self.marks != marks {
            self.image = image
            self.marks = marks
            if let selectedMarkID, !marks.contains(where: { $0.id == selectedMarkID }) {
                self.selectedMarkID = nil
            }
            rerender()
        }
        self.color = color
        self.filledShapes = filledShapes
        self.lineWidthPoints = lineWidthPoints
        self.numberSizePoints = numberSizePoints
        self.arrowDoubleHeaded = arrowDoubleHeaded
        self.textFontSize = textFontSize
        self.textPresentation = textPresentation
        self.maskStyle = maskStyle
        self.maskSizePoints = maskSizePoints
        let nextStyle = currentStyle
        // A toolbar change made while a mark is selected, or while text is
        // being typed, restyles it (as in CleanShot X and Snipaste).
        if hasConfiguredStyle, !changedImage, previousStyle != nextStyle {
            styleDidChange(from: previousStyle, to: nextStyle)
        }
        hasConfiguredStyle = true
        if self.tool != tool {
            finishText(commit: true)
            draft = nil
            // Choosing another drawing tool ends the selection. The eyedropper
            // keeps it so the sampled color can be applied to the selected mark.
            if self.tool != .picker, tool != .picker, let selectedMarkID,
               marks.first(where: { $0.id == selectedMarkID })?.tool != tool {
                self.selectedMarkID = nil
            }
        }
        self.tool = tool
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

    private func rerender() {
        guard let image else { rendered = nil; return }
        let visible = editingTextMark.map { editing in marks.filter { $0.id != editing.id } } ?? marks
        rendered = ImageRenderer.render(image, marks: visible)
    }

    /// Shows an edit immediately instead of waiting for the model to round-trip it.
    private func replaceLocally(_ mark: Mark) {
        guard let index = marks.firstIndex(where: { $0.id == mark.id }) else { return }
        marks[index] = mark
        rerender()
        needsDisplay = true
    }

    /// Model callbacks triggered from `configure` run inside a SwiftUI or
    /// AppKit update pass, so they are deferred instead of mutating the
    /// model mid-update.
    private func publish(_ body: @escaping (NativeImageCanvas) -> Void) {
        if isConfiguring {
            DispatchQueue.main.async { [weak self] in
                if let self { body(self) }
            }
        } else {
            body(self)
        }
    }

    private func publishEdit(_ mark: Mark) {
        publish { canvas in
            canvas.onBeginMarkEdit?(mark.id)
            canvas.onUpdateMark?(mark)
            canvas.onFinishMarkEdit?()
        }
    }

    private func styleDidChange(from old: CanvasStyle, to new: CanvasStyle) {
        if let field = textField {
            if old.color.uppercased() != new.color.uppercased() { textColor = new.color }
            if old.textFontSize != new.textFontSize {
                textFraction = AnnotationSizeMetrics.textFraction(points: new.textFontSize,
                                                                  imageSize: imagePointSize)
            }
            if old.textPresentation != new.textPresentation { fieldPresentation = new.textPresentation }
            styleTextField(field)
            return
        }
        guard enabled, let selectedMarkID,
              let original = marks.first(where: { $0.id == selectedMarkID }) else { return }
        let updated = Self.restyled(original, from: old, to: new, imageSize: imagePointSize)
        guard updated != original else { return }
        replaceLocally(updated)
        publishEdit(updated)
    }

    /// Applies only the toolbar value that changed, and only when the mark
    /// does not already show it. Selecting a mark copies its style into the
    /// toolbar, and that round trip must not rewrite the mark.
    private static func restyled(_ mark: Mark, from old: CanvasStyle, to new: CanvasStyle,
                                 imageSize: CGSize) -> Mark {
        var updated = mark
        let shortestSide = min(imageSize.width, imageSize.height)
        func shown(_ fraction: Double?, base: CGFloat, range: ClosedRange<Double>) -> Double? {
            fraction.map { AnnotationSizeMetrics.points(fromFraction: $0, base: base, within: range) }
        }
        if old.color.uppercased() != new.color.uppercased(), mark.tool.usesColor,
           mark.colorHex.uppercased() != new.color.uppercased() {
            updated.colorHex = new.color
        }
        if old.filled != new.filled, mark.tool == .rectangle || mark.tool == .ellipse,
           (mark.filled == true) != new.filled {
            updated.filled = new.filled
        }
        if old.lineWidthPoints != new.lineWidthPoints, mark.tool.usesStroke,
           shown(mark.lineWidth, base: shortestSide,
                 range: AnnotationSizeMetrics.lineWidthRange) != new.lineWidthPoints {
            updated.lineWidth = AnnotationSizeMetrics.fraction(points: new.lineWidthPoints,
                                                               imageSize: imageSize)
        }
        if old.numberSizePoints != new.numberSizePoints, mark.tool == .number,
           shown(mark.numberSize, base: shortestSide,
                 range: AnnotationSizeMetrics.numberSizeRange) != new.numberSizePoints {
            let fraction = AnnotationSizeMetrics.fraction(points: new.numberSizePoints, imageSize: imageSize)
            updated.numberSize = fraction
            updated.lineWidth = fraction
        }
        if old.arrowDoubleHeaded != new.arrowDoubleHeaded, mark.tool == .arrow,
           (mark.arrowDoubleHeaded == true) != new.arrowDoubleHeaded {
            updated.arrowDoubleHeaded = new.arrowDoubleHeaded ? true : nil
        }
        if mark.tool == .text {
            if old.textFontSize != new.textFontSize,
               shown(mark.fontSize, base: imageSize.height,
                     range: AnnotationSizeMetrics.textSizeRange) != new.textFontSize {
                updated.fontSize = AnnotationSizeMetrics.textFraction(points: new.textFontSize,
                                                                      imageSize: imageSize)
            }
            if old.textPresentation != new.textPresentation,
               (mark.textPresentation ?? .plain) != new.textPresentation {
                updated.textPresentation = new.textPresentation
            }
        }
        if mark.tool == .mosaic {
            if old.maskStyle != new.maskStyle, (mark.maskStyle ?? .pixel) != new.maskStyle {
                updated.maskStyle = new.maskStyle
            }
            if old.maskSizePoints != new.maskSizePoints,
               shown(mark.maskSize, base: shortestSide,
                     range: AnnotationSizeMetrics.maskSizeRange) != new.maskSizePoints {
                updated.maskSize = AnnotationSizeMetrics.fraction(points: new.maskSizePoints,
                                                                  imageSize: imageSize)
            }
        }
        return updated
    }

    /// Moves every point by the same offset without pushing the mark further
    /// outside the image. Marks may already overhang after the selection shrinks.
    static func translated(_ mark: Mark, dx: Double, dy: Double) -> Mark {
        let xs = mark.points.map(\.x), ys = mark.points.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 1
        let clampedX = min(max(0, 1 - maxX), max(min(0, -minX), dx))
        let clampedY = min(max(0, 1 - maxY), max(min(0, -minY), dy))
        var moved = mark
        moved.points = mark.points.map { UnitPoint(x: $0.x + clampedX, y: $0.y + clampedY) }
        return moved
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
        if let selectedMarkID, selectedMarkID != editingTextMark?.id,
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
        nudgeRegisteredUndo = false
        guard imageRect.contains(point) else { return }

        if tool == .picker {
            // Sampling keeps the current selection, so the picked color can
            // be applied to the selected mark.
            if enabled, let picked = sampledColor(at: point) { onColorPick?(picked) }
            return
        }

        if enabled, let hit = hitMark(at: point) {
            // Existing annotations take precedence over creating another mark.
            // This lets users drag immediately after drawing, even while the
            // drawing tool is still selected.
            if event.clickCount >= 2, hit.tool == .text {
                beginEditingText(hit)
                return
            }
            selectedMarkID = hit.id
            editingMark = hit
            editingPointIndex = handleIndex(for: hit, at: point, in: imageRect)
            onSelectMark?(hit, imagePointSize)
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
        if tool == .number {
            // Continue after the highest number so deleting a marker never
            // produces a duplicate.
            let next = (marks.filter { $0.tool == .number }
                .compactMap { Int($0.text ?? "") }.max() ?? 0) + 1
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
                updated = Self.translated(original,
                                          dx: Double((point.x - dragStart.x) / max(1, rect.width)),
                                          dy: Double((point.y - dragStart.y) / max(1, rect.height)))
            }
            replaceLocally(updated)
            onUpdateMark?(updated)
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
        // Bitmap rows start at the top, like the flipped view, so y needs no
        // flipping; flipping it sampled the mirrored pixel.
        guard let color = bitmap.colorAt(x: x, y: y)?
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
        if event.keyCode == 53 { cancelOperation(nil); return }
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        if plain, enabled, textField == nil, let selectedMarkID,
           let mark = marks.first(where: { $0.id == selectedMarkID }) {
            if event.keyCode == 51 || event.keyCode == 117, let onDeleteMark {
                marks.removeAll { $0.id == mark.id }
                self.selectedMarkID = nil
                editingMark = nil
                rerender()
                needsDisplay = true
                onDeleteMark(mark.id)
                return
            }
            if [123, 124, 125, 126].contains(event.keyCode) {
                // A selected mark takes the arrow keys; without a selection
                // they fall through and move the capture region instead.
                nudge(mark, keyCode: event.keyCode,
                      step: event.modifierFlags.contains(.shift) ? 10 : 1,
                      isRepeat: event.isARepeat)
                return
            }
        }
        super.keyDown(with: event)
    }

    /// Moves the selected mark by whole image points. Holding the key is one
    /// undo step; every new press is another.
    private func nudge(_ mark: Mark, keyCode: UInt16, step: CGFloat, isRepeat: Bool) {
        let size = imagePointSize
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch keyCode {
        case 123: dx = -step
        case 124: dx = step
        case 125: dy = step // The view is flipped, so down is +y.
        case 126: dy = -step
        default: return
        }
        let moved = Self.translated(mark, dx: Double(dx / max(1, size.width)),
                                    dy: Double(dy / max(1, size.height)))
        guard moved != mark else { return }
        if !isRepeat || !nudgeRegisteredUndo {
            onBeginMarkEdit?(mark.id)
            nudgeRegisteredUndo = true
        }
        replaceLocally(moved)
        onUpdateMark?(moved)
        onFinishMarkEdit?()
    }

    override func cancelOperation(_ sender: Any?) {
        if textField != nil { finishText(commit: false) }
        else { draft = nil; onEscape?() }
    }

    // MARK: Keys typed while a toolbar popover is key

    private static let popoverKeyTargets = NSHashTable<NativeImageCanvas>.weakObjects()
    private static var popoverKeyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        Self.popoverKeyTargets.add(self)
        guard Self.popoverKeyMonitor == nil else { return }
        Self.popoverKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let forwarded = MainActor.assumeIsolated { NativeImageCanvas.forwardPopoverKey(event) }
            return forwarded ? nil : event
        }
    }

    enum PopoverKeyRoute: Equatable { case popover, canvas, openText }

    /// Where a key typed in a toolbar popover belongs. Style popovers open on
    /// tool and mark selection and become the key window, which swallowed
    /// Delete, the arrow keys, Return and the tool shortcuts. Esc still
    /// closes the popover, Tab keeps moving between its controls, and a value
    /// being typed in the popover keeps every key.
    nonisolated static func popoverKeyRoute(keyCode: UInt16,
                                            modifiers: NSEvent.ModifierFlags,
                                            popoverIsEditingText: Bool,
                                            canvasIsEditingText: Bool) -> PopoverKeyRoute {
        if popoverIsEditingText || keyCode == 53 || keyCode == 48 { return .popover }
        let flags = modifiers.intersection([.command, .control, .option])
        if canvasIsEditingText {
            // Typing continues in the open text mark; Option types symbols.
            // Letters must never reach the tool shortcuts here.
            return flags.subtracting(.option).isEmpty ? .openText : .popover
        }
        // Space stays with the popover for keyboard navigation.
        return flags.isEmpty && keyCode != 49 ? .canvas : .popover
    }

    private static func forwardPopoverKey(_ event: NSEvent) -> Bool {
        guard let source = event.window, let parent = source.parent,
              NSStringFromClass(type(of: source)).contains("Popover"),
              let canvas = popoverKeyTargets.allObjects.first(where: {
                  $0.window === parent && parent.isVisible && !$0.isHiddenOrHasHiddenAncestor
              })
        else { return false }
        switch popoverKeyRoute(keyCode: event.keyCode, modifiers: event.modifierFlags,
                               popoverIsEditingText: source.firstResponder is NSText,
                               canvasIsEditingText: canvas.textField != nil) {
        case .popover:
            return false
        case .canvas:
            canvas.keyDown(with: event)
            return true
        case .openText:
            // Give the keyboard back first so input methods keep composing
            // in the text mark, then deliver this key to it.
            guard let editor = canvas.textField?.currentEditor() else { return false }
            parent.makeKey()
            editor.keyDown(with: event)
            return true
        }
    }

    private func beginText(at point: CGPoint) {
        editingTextMark = nil
        textColor = color
        // Text renders relative to the image height, so its size must be
        // stored against the height as well.
        textFraction = AnnotationSizeMetrics.textFraction(points: textFontSize, imageSize: imagePointSize)
        fieldPresentation = textPresentation
        openTextField(anchor: normalized(point), text: "")
    }

    /// Double-clicking a text mark reopens it in place, keeping its identity.
    private func beginEditingText(_ mark: Mark) {
        guard let anchor = mark.points.first else { return }
        editingTextMark = mark
        selectedMarkID = mark.id
        textColor = mark.colorHex
        textFraction = mark.fontSize ?? 0.035
        fieldPresentation = mark.textPresentation ?? .plain
        rerender()
        openTextField(anchor: anchor, text: mark.text ?? "")
        needsDisplay = true
    }

    private func openTextField(anchor: UnitPoint, text: String) {
        textAnchor = anchor
        let origin = imagePoint(anchor, in: imageRect)
        // The field's cell insets its text by 2 pt; offset it so the typed
        // text lines up with where the mark is drawn.
        let field = NSTextField(frame: CGRect(x: origin.x - 2, y: origin.y, width: 60, height: 30))
        field.isBezeled = false
        field.isBordered = false
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = L("输入文字")
        field.focusRingType = .exterior
        field.stringValue = text
        field.delegate = self
        textField = field
        styleTextField(field)
        addSubview(field)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
    }

    private func styleTextField(_ field: NSTextField) {
        // Match ImageRenderer: the font is a fraction of the image height,
        // drawn at the current display scale.
        let displayScale = imageRect.height / max(1, imageSize.height)
        let fontSize = max(8, CGFloat(textFraction) * imageSize.height) * displayScale
        field.font = .systemFont(ofSize: max(4, fontSize), weight: .semibold)
        field.textColor = NSColor(hex: textColor)
        field.drawsBackground = fieldPresentation == .highlighted
        field.backgroundColor = fieldPresentation == .highlighted
            ? NSColor(hex: textColor).withAlphaComponent(0.18) : .clear
        resizeTextField(field)
    }

    private func resizeTextField(_ field: NSTextField) {
        guard let font = field.font else { return }
        // Grow with the text, starting at the placeholder's width, instead of
        // a fixed 360 pt box that dwarfed short labels.
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let placeholder = ((field.placeholderString ?? "") as NSString).size(withAttributes: attributes)
        let typed = (field.stringValue as NSString).size(withAttributes: attributes)
        let available = max(40, bounds.maxX - field.frame.minX)
        let width = min(available, ceil(max(placeholder.width, typed.width)) + 24)
        let height = max(24, ceil(font.ascender - font.descender + font.leading) + 6)
        field.setFrameSize(CGSize(width: width, height: height))
    }

    private func finishText(commit: Bool) {
        guard let field = textField else { return }
        textField = nil
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()
        let anchor = textAnchor
        textAnchor = nil
        if let original = editingTextMark {
            editingTextMark = nil
            if commit, value.isEmpty {
                // Clearing the text removes the annotation.
                marks.removeAll { $0.id == original.id }
                if selectedMarkID == original.id { selectedMarkID = nil }
                rerender()
                publish { $0.onDeleteMark?(original.id) }
            } else if commit {
                var updated = original
                updated.text = value
                // Only record values that changed, so reopening text without
                // editing it adds no undo step.
                if textColor.uppercased() != original.colorHex.uppercased() { updated.colorHex = textColor }
                if textFraction != (original.fontSize ?? 0.035) { updated.fontSize = textFraction }
                if fieldPresentation != (original.textPresentation ?? .plain) {
                    updated.textPresentation = fieldPresentation
                }
                replaceLocally(updated)
                if updated != original { publishEdit(updated) }
            } else {
                rerender()
            }
            needsDisplay = true
            return
        }
        if commit, !value.isEmpty, let anchor {
            let mark = Mark(tool: .text, points: [anchor], colorHex: textColor, text: value,
                            fontSize: textFraction, lineWidth: nil,
                            textPresentation: fieldPresentation)
            selectedMarkID = mark.id
            publish { $0.onMark?(mark) }
        }
    }

    func commitPendingText() { finishText(commit: true) }

    func controlTextDidEndEditing(_ notification: Notification) { finishText(commit: true) }

    func controlTextDidChange(_ notification: Notification) {
        if let textField { resizeTextField(textField) }
    }

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
