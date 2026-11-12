import AppKit
import SwiftUI
import Translation

@MainActor
final class SelectionCaptureController: NSObject {
    var onComplete: (NSImage, NSRect) -> Void
    var onCancel: () -> Void
    var onError: (Error) -> Void
    var onRegionSelected: ((NSScreen, NSRect, NSRect) -> Void)?
    var onScreenSelected: ((NSImage, NSScreen, NSRect) -> Void)?
    var targetApplication: NSRunningApplication?
    var prompt = "拖动框选，或点击窗口 · Esc 取消"
    private var windows: [NSWindow] = []
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var activeScreen: NSScreen?
    private var hoveredRect: CGRect?
    private var hoveredScreen = CGRect.zero
    private var captureTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    var isActive: Bool { !windows.isEmpty || captureTask != nil || preparationTask != nil }

    init(onComplete: @escaping (NSImage, NSRect) -> Void, onCancel: @escaping () -> Void,
         onError: @escaping (Error) -> Void) {
        self.onComplete = onComplete
        self.onCancel = onCancel
        self.onError = onError
    }

    func begin() {
        cancel()
        if let targetApplication, !targetApplication.isTerminated,
           targetApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            targetApplication.activate(options: [])
            preparationTask = Task {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                preparationTask = nil
                presentSelection()
            }
        } else {
            presentSelection()
        }
    }

    private func presentSelection() {
        startPoint = nil
        currentPoint = nil
        activeScreen = nil
        guard !NSScreen.screens.isEmpty else {
            onError(CaptureFailure.displayUnavailable)
            return
        }
        for screen in NSScreen.screens {
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.controller = self
            view.screenFrame = screen.frame
            let window = SelectionWindow(contentRect: screen.frame,
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.contentView = view
            window.backgroundColor = .clear
            window.isOpaque = false
            window.level = .screenSaver
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.hidesOnDeactivate = false
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            windows.append(window)
        }
        NSCursor.crosshair.push()
    }

    func cancel() {
        preparationTask?.cancel()
        preparationTask = nil
        captureTask?.cancel()
        captureTask = nil
        guard !windows.isEmpty else { return }
        NSCursor.pop()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        startPoint = nil
        currentPoint = nil
        activeScreen = nil
        hoveredRect = nil
    }

    func cancelByUser() {
        cancel()
        onCancel()
    }

    fileprivate func mouseDown(at point: NSPoint, screenFrame: NSRect) {
        hover(at: point, screenFrame: screenFrame)
        startPoint = point
        currentPoint = point
        activeScreen = NSScreen.screens.first { $0.frame == screenFrame }
        refresh()
    }

    fileprivate func mouseDragged(to point: NSPoint) {
        currentPoint = point
        refresh()
    }

    fileprivate func mouseUp() {
        guard let start = startPoint, let current = currentPoint, let screen = activeScreen else {
            cancel(); onCancel(); return
        }
        var local = NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                           width: abs(current.x - start.x), height: abs(current.y - start.y))
            .intersection(NSRect(origin: .zero, size: screen.frame.size))
        if local.width <= 4, local.height <= 4, hoveredScreen == screen.frame, let hoveredRect { local = hoveredRect }
        let excluded = Set(windows.map { CGWindowID($0.windowNumber) })
        cancel()
        guard !local.isNull, local.width > 4, local.height > 4 else {
            onCancel()
            return
        }
        let global = NSRect(x: screen.frame.minX + local.minX,
                            y: screen.frame.minY + local.minY,
                            width: local.width, height: local.height)
        captureTask = Task { @MainActor in
            do {
                // Returning focus after dismissing the panel also restores Stage Manager's target window.
                if let targetApplication, !targetApplication.isTerminated {
                    targetApplication.activate(options: [])
                    try await Task.sleep(for: .milliseconds(400))
                } else { try await Task.sleep(for: .milliseconds(90)) }
                try Task.checkCancellation()
                if let onRegionSelected {
                    captureTask = nil
                    onRegionSelected(screen, local, global)
                    return
                }
                if let onScreenSelected {
                    let snapshot = try await ScreenCaptureService.capture(screen: screen,
                        selection: CGRect(origin: .zero, size: screen.frame.size), excludingWindowIDs: excluded)
                    captureTask = nil
                    onScreenSelected(snapshot, screen, global)
                    return
                }
                let image = try await ScreenCaptureService.capture(screen: screen, selection: local,
                                                                    excludingWindowIDs: excluded)
                captureTask = nil
                onComplete(image, global)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                captureTask = nil
                onError(error)
            }
        }
    }

    fileprivate func refresh() {
        windows.compactMap { $0.contentView as? SelectionView }.forEach { $0.needsDisplay = true }
    }

    fileprivate func hover(at point: NSPoint, screenFrame: CGRect) {
        guard startPoint == nil,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        let global = CGPoint(x: screenFrame.minX + point.x, y: screenFrame.minY + point.y)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screenFrame.maxY
        let cgPoint = CGPoint(x: global.x, y: primaryTop - global.y)
        let ignored = Set(["Dock", "Window Server", "WindowManager", "Control Center", "Notification Center"])
        hoveredRect = windows.lazy.compactMap { item -> CGRect? in
            guard let layer = item[kCGWindowLayer as String] as? Int, (0...3).contains(layer),
                  let pid = item[kCGWindowOwnerPID as String] as? Int32, pid != ProcessInfo.processInfo.processIdentifier,
                  let owner = item[kCGWindowOwnerName as String] as? String, !ignored.contains(owner),
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 60, rect.height > 40,
                  rect.contains(cgPoint) else { return nil }
            return CaptureSelectionGeometry.windowRect(rect, primaryTop: primaryTop, screenFrame: screenFrame)
        }.first
        hoveredScreen = screenFrame
        refresh()
    }

    fileprivate func selection(in view: SelectionView) -> NSRect? {
        if startPoint == nil, view.screenFrame == hoveredScreen { return hoveredRect }
        guard let start = startPoint, let current = currentPoint,
              view.screenFrame == activeScreen?.frame else { return nil }
        return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
            .intersection(view.bounds)
    }
}

final class SelectionWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class SelectionView: NSView {
    var controller: SelectionCaptureController?
    var screenFrame = CGRect.zero

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.hover(at: convert(event.locationInWindow, from: nil), screenFrame: screenFrame)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.24).setFill()
        NSBezierPath(rect: bounds).fill()
        let prompt = (controller?.prompt ?? "") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white
        ]
        let size = prompt.size(withAttributes: attributes)
        let badge = CGRect(x: (bounds.width - size.width) / 2 - 16, y: bounds.height - 86,
                           width: size.width + 32, height: 40)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 12, yRadius: 12).fill()
        prompt.draw(at: CGPoint(x: badge.minX + 16, y: badge.minY + 10), withAttributes: attributes)
        if let rect = controller?.selection(in: self) {
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.setBlendMode(.clear)
                context.fill(rect)
                context.restoreGState()
            }
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 1
            border.stroke()

            // Real-time dimensions badge
            if rect.width > 20 && rect.height > 15 {
                let text = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
                let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.white
                ]
                let textSize = text.size(withAttributes: attrs)
                let badgeY = rect.minY >= textSize.height + 10 ? rect.minY - textSize.height - 8 : rect.maxY + 6
                let badgeRect = NSRect(x: rect.minX, y: max(4, badgeY),
                                       width: textSize.width + 12, height: textSize.height + 6)
                NSColor.black.withAlphaComponent(0.72).setFill()
                NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4).fill()
                text.draw(at: NSPoint(x: badgeRect.minX + 6, y: badgeRect.minY + 3), withAttributes: attrs)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        controller?.mouseDown(at: convert(event.locationInWindow, from: nil), screenFrame: screenFrame)
    }

    override func mouseDragged(with event: NSEvent) {
        controller?.mouseDragged(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        controller?.mouseDragged(to: convert(event.locationInWindow, from: nil))
        controller?.mouseUp()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            controller?.cancelByUser()
        }
    }
}

