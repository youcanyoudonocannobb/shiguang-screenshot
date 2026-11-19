import AppKit
import Combine
import SwiftUI

@MainActor
final class ScreenRegionEditorController {
    let window: NSWindow
    private let view: ScreenRegionEditorView

    init(snapshot: NSImage, screen: NSScreen, selection: CGRect, model: AppModel) {
        window = CaptureEditorWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.title = "PawShot · 选区编辑"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        view = ScreenRegionEditorView(snapshot: snapshot, screen: screen,
            selection: selection.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), model: model)
        window.contentView = view
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view.canvas)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide() { window.orderOut(nil) }
}

@MainActor
private final class ScreenRegionEditorView: NSView {
    let canvas = NativeImageCanvas()
    private let model: AppModel
    private let snapshot: NSImage
    private let screen: NSScreen
    private var selection: CGRect
    private var startRect = CGRect.zero
    private var startPoint = CGPoint.zero
    private var dragHandle: SelectionHandle?
    private var selecting = false
    private var subscription: AnyCancellable?
    private var refreshScheduled = false
    private var cachedToolbarSize = CGSize.zero
    private let decoration = SelectionDecorationView()
    private let toolbar: NSHostingView<AnyView>

    init(snapshot: NSImage, screen: NSScreen, selection: CGRect, model: AppModel) {
        self.snapshot = snapshot
        self.screen = screen
        self.selection = selection
        self.model = model
        toolbar = NSHostingView(rootView: AnyView(
            ScreenCaptureToolbar(model: model)
                .environment(\.locale, model.appLanguage.locale)
        ))
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        addSubview(canvas)
        addSubview(decoration)
        addSubview(toolbar)
        canvas.onMark = { [weak model] in model?.addMark($0) }
        canvas.onEscape = { [weak model] in model?.discardDraft() }
        canvas.onColorPick = { [weak model] color in
            model?.markColor = color
            model?.tool = .pointer
        }
        canvas.onZoom = { [weak model] in model?.zoomFactor = $0 }
        canvas.onSelectionDrag = { [weak self] event, phase in
            guard let self, !model.isBusy else { return }
            if phase == .began { self.startRect = self.selection; self.startPoint = event.locationInWindow }
            let delta = CGSize(width: event.locationInWindow.x - self.startPoint.x, height: event.locationInWindow.y - self.startPoint.y)
            self.changeSelection(CaptureSelectionGeometry.clamped(self.startRect.offsetBy(dx: delta.width, dy: delta.height), to: self.bounds))
        }
        model.finishPendingAnnotation = { [weak canvas] in canvas?.commitPendingText() }
        subscription = model.objectWillChange.sink { [weak self] _ in
            self?.scheduleRefresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        guard let image = model.image else { return }
        canvas.frame = selection
        canvas.configure(image: image, marks: model.marks, tool: model.tool, color: model.markColor,
            zoom: model.zoomFactor, resetID: model.viewportResetID, movesWindow: false,
            enabled: !model.isBusy, inPlace: true, filledShapes: model.fillShapes,
            lineWidthPoints: model.markLineWidthPoints, numberSizePoints: model.numberSizePoints,
            arrowDoubleHeaded: model.arrowDoubleHeaded,
            textFontSize: model.textFontSize, textPresentation: model.textPresentation,
            maskStyle: model.maskStyle, maskSizePoints: model.maskSizePoints,
            spotlightStrength: model.spotlightStrength)
        decoration.frame = bounds
        decoration.selection = selection
        decoration.scale = screen.backingScaleFactor
        decoration.needsDisplay = true
        if cachedToolbarSize.width <= 100 || cachedToolbarSize.height <= 20 {
            toolbar.layoutSubtreeIfNeeded()
            let fitted = toolbar.fittingSize
            cachedToolbarSize = fitted.width > 100 && fitted.height > 20 ? fitted
                : CGSize(width: AnnotationToolbar.minimumWidth, height: 46 + AnnotationToolbar.hoverSpace)
        }
        let size = cachedToolbarSize
        let visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let barSize = CGSize(width: size.width, height: max(20, size.height - AnnotationToolbar.hoverSpace))
        var frame = CaptureSelectionGeometry.toolbarFrame(
            selection: selection, size: barSize, visible: visible, horizontal: .center
        )
        // Grow upward so the hover label has room without moving the bar.
        frame.size.height += AnnotationToolbar.hoverSpace
        toolbar.frame = frame
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        snapshot.draw(in: bounds)
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(selection)
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.42).setFill()
        shade.fill()
    }

    private func handle(at point: CGPoint) -> SelectionHandle? {
        CaptureSelectionGeometry.handle(at: point, in: selection, tolerance: 9)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if toolbar.frame.contains(point) { return super.hitTest(point) }
        if handle(at: point) != nil { return self }
        if selection.contains(point) { return canvas.hitTest(point) ?? canvas }
        return self
    }

    override func resetCursorRects() {
        let band: CGFloat = 9
        let edgeRects: [(SelectionHandle, CGRect)] = [
            (.top, CGRect(x: selection.minX, y: selection.maxY - band,
                          width: selection.width, height: band * 2)),
            (.bottom, CGRect(x: selection.minX, y: selection.minY - band,
                             width: selection.width, height: band * 2)),
            (.left, CGRect(x: selection.minX - band, y: selection.minY,
                           width: band * 2, height: selection.height)),
            (.right, CGRect(x: selection.maxX - band, y: selection.minY,
                            width: band * 2, height: selection.height))
        ]
        for (item, rect) in edgeRects {
            addCursorRect(rect, cursor: item.resizeCursor)
        }
        for item in SelectionHandle.allCases where item.isCorner {
            let point = item.point(in: selection)
            addCursorRect(CGRect(x: point.x - band, y: point.y - band,
                                 width: band * 2, height: band * 2),
                          cursor: item.resizeCursor)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard !model.isBusy else { return }
        canvas.commitPendingText()
        window?.makeFirstResponder(self)
        startPoint = event.locationInWindow
        startRect = selection
        dragHandle = handle(at: startPoint)
        selecting = dragHandle == nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard !model.isBusy else { return }
        let point = event.locationInWindow
        if let dragHandle {
            changeSelection(CaptureSelectionGeometry.resized(startRect, handle: dragHandle,
                delta: CGSize(width: point.x - startPoint.x, height: point.y - startPoint.y),
                bounds: bounds))
        } else if selecting {
            let rect = CaptureSelectionGeometry.selectionRect(
                from: startPoint, to: point, bounds: bounds
            )
            if rect.width >= 8 && rect.height >= 8 { changeSelection(rect) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        selecting = false
        dragHandle = nil
        window?.makeFirstResponder(canvas)
        window?.invalidateCursorRects(for: self)
    }

    private func changeSelection(_ rect: CGRect) {
        guard rect != selection, let image = CaptureSelectionGeometry.crop(snapshot, rect: rect, displaySize: bounds.size) else { return }
        let previous = selection
        selection = rect
        let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        model.updateCaptureRegion(image, rect: global) { CaptureSelectionGeometry.remap($0, from: previous, to: rect) }
        // objectWillChange schedules one coalesced refresh for all published
        // values that updateCaptureRegion changes.
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { model.discardDraft(); return }
        if event.keyCode == 36 || event.keyCode == 76 { model.confirmDraft(); return }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            let tools: [String: MarkTool] = [
                "1": .rectangle, "2": .ellipse, "3": .arrow, "4": .line,
                "5": .pen, "6": .highlighter, "7": .text, "8": .number,
                "9": .mosaic
            ]
            if let tool = tools[key] {
                model.tool = tool
                return
            }
            if key == "o" {
                model.recognizeInWindow()
                return
            }
            if key == "s" {
                model.captureScrolling(.automatic)
                return
            }
            if key == "t" {
                model.requestPin()
                return
            }
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1 / screen.backingScaleFactor
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch event.keyCode {
        case 123: dx = -step
        case 124: dx = step
        case 125: dy = -step
        case 126: dy = step
        default: super.keyDown(with: event); return
        }
        if !model.isBusy {
            changeSelection(CaptureSelectionGeometry.clamped(selection.offsetBy(dx: dx, dy: dy), to: bounds))
            window?.invalidateCursorRects(for: self)
        }
    }
}

private struct ScreenCaptureToolbar: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: AnnotationToolbar.hoverSpace)
            AnnotationToolbar(model: model, showsSelectionTools: false)
        }
        .fixedSize()
    }
}

private final class SelectionDecorationView: NSView {
    var selection = CGRect.zero
    var scale: CGFloat = 1
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        if let context = NSGraphicsContext.current?.cgContext {
            SelectionChrome.draw(in: selection, context: context)
        }
        let text = "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded())) px" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let y = selection.maxY + size.height + 8 < bounds.maxY ? selection.maxY + 4 : selection.maxY - size.height - 8
        let badge = CGRect(x: min(selection.minX, bounds.maxX - size.width - 16),
                           y: y, width: size.width + 16, height: size.height + 7)
        NSColor(hex: "172A38").withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let badgeBorder = NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6)
        badgeBorder.lineWidth = 0.8
        badgeBorder.stroke()
        text.draw(at: CGPoint(x: badge.minX + 8,
                              y: badge.minY + (badge.height - size.height) / 2),
                  withAttributes: attributes)
        setAccessibilityLabel(text as String)
    }
}
