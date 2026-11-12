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
    let onMark: (Mark) -> Void
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NativeImageCanvas { NativeImageCanvas() }

    func updateNSView(_ view: NativeImageCanvas, context: Context) {
        view.onMark = onMark
        view.onEscape = onEscape
        view.onZoom = { zoom = $0 }
        view.configure(image: image, marks: marks, tool: tool, color: colorHex, zoom: zoom,
                       resetID: resetID, movesWindow: movesWindow, enabled: enabled)
    }
}

final class NativeImageCanvas: NSView, NSTextFieldDelegate {
    enum SelectionDrag { case began, changed, ended }
    var onSelectionDrag: ((NSEvent, SelectionDrag) -> Void)?
    var onMark: ((Mark) -> Void)?
    var onEscape: (() -> Void)?
    var onZoom: ((CGFloat) -> Void)?
    private var image: NSImage?
    private var rendered: NSImage?
    private var marks: [Mark] = []
    private var tool = MarkTool.pointer
    private var color = "E45F3C"
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

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    private var imageSize: CGSize { rendered?.size ?? CGSize(width: 1, height: 1) }
    private var imageRect: CGRect { viewport.imageRect(image: imageSize, viewport: bounds.size) }

    func configure(image: NSImage, marks: [Mark], tool: MarkTool, color: String, zoom: CGFloat,
                   resetID: UUID, movesWindow: Bool, enabled: Bool, inPlace: Bool = false) {
        let changedImage = self.image !== image
        if changedImage {
            finishText(commit: false)
            viewport = CanvasViewport()
            draft = nil
        }
        if changedImage || self.marks != marks {
            self.image = image
            self.marks = marks
            rendered = ImageRenderer.render(image, marks: marks)
        }
        if self.tool != tool { finishText(commit: true); draft = nil }
        self.tool = tool
        self.color = color
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
        path.lineWidth = max(2, min(imageSize.width, imageSize.height) * 0.005 * rect.width / imageSize.width)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor(hex: mark.colorHex).setStroke()
        switch mark.tool {
        case .pointer, .text: return
        case .redact:
            NSColor.black.setFill(); NSBezierPath(rect: box).fill(); return
        case .mosaic:
            NSColor.gray.withAlphaComponent(0.5).setFill()
            NSBezierPath(rect: box).fill()
            path.appendRect(box)
        case .rectangle: path.appendRect(box)
        case .pen:
            path.move(to: first)
            for p in mark.points.dropFirst() { path.line(to: point(p)) }
        case .arrow:
            path.move(to: first); path.line(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let length = min(path.lineWidth * 5, hypot(last.x - first.x, last.y - first.y) * 0.4)
            for offset in [-Double.pi / 6, Double.pi / 6] {
                path.move(to: last)
                path.line(to: CGPoint(x: last.x - length * cos(angle + offset), y: last.y - length * sin(angle + offset)))
            }
        }
        path.stroke()
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
        guard imageRect.contains(point) else { return }
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
        if tool != .pointer {
            draft = Mark(tool: tool, points: [normalized(point)], colorHex: color)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isMovingSelection { onSelectionDrag?(event, .changed); return }
        let point = convert(event.locationInWindow, from: nil)
        if isPanning {
            viewport.offset = CGPoint(x: offsetStart.x + point.x - dragStart.x,
                                      y: offsetStart.y + point.y - dragStart.y)
            viewport.constrain(image: imageSize, viewport: bounds.size)
        } else if enabled, var mark = draft, let start = mark.points.first {
            if tool == .pen { mark.points.append(normalized(point)) }
            else { mark.points = [start, normalized(point)] }
            draft = mark
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if isMovingSelection {
            onSelectionDrag?(event, .ended)
            isMovingSelection = false
            window?.invalidateCursorRects(for: self)
            return
        }
        isPanning = false
        window?.invalidateCursorRects(for: self)
        if let mark = draft, mark.points.count > 1 { onMark?(mark) }
        draft = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > 0 else { return }
        finishText(commit: true)
        let sensitivity = event.hasPreciseScrollingDeltas ? 0.008 : 0.12
        let delta = min(0.4, max(-0.4, event.scrollingDeltaY * sensitivity))
        changeZoom(viewport.zoom * exp(delta), anchor: convert(event.locationInWindow, from: nil))
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
        textFraction = max(18 / max(1, rect.height), 0.035)
        let field = NSTextField(frame: CGRect(x: point.x, y: point.y,
                                              width: max(50, min(360, bounds.maxX - point.x)),
                                              height: max(30, rect.height * textFraction + 10)))
        field.font = .systemFont(ofSize: rect.height * textFraction, weight: .semibold)
        field.textColor = NSColor(hex: color)
        field.backgroundColor = .white
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
            onMark?(Mark(tool: .text, points: [anchor], colorHex: textColor, text: value, fontSize: textFraction))
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
