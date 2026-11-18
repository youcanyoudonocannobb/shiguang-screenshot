import AppKit
import Carbon
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
    private var windowCandidates: [CGRect] = []
    private var captureTask: Task<Void, Never>?
    private var captureWatchdog: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var prefetchTask: Task<(CGRect, NSImage?), Never>?
    private var escapeHotKey: EventHotKeyRef?
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
            preparationTask = Task {
                do { try await settleFocus(on: targetApplication) } catch { return }
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
        hoveredRect = nil
        hoveredScreen = .zero
        cacheWindowCandidates()
        guard !NSScreen.screens.isEmpty else {
            onError(CaptureFailure.displayUnavailable)
            return
        }
        for screen in NSScreen.screens {
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.controller = self
            view.screenFrame = screen.frame
            view.backingScale = screen.backingScaleFactor
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
            window.animationBehavior = .none
            window.hasShadow = false
            window.isMovable = false
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            window.makeFirstResponder(view)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKey()
        let keyID = EventHotKeyID(signature: OSType(0x53484747), id: 7)
        RegisterEventHotKey(53, 0, keyID, GetApplicationEventTarget(), 0, &escapeHotKey)
        NSCursor.crosshair.push()
    }

    func cancel() {
        preparationTask?.cancel()
        preparationTask = nil
        captureTask?.cancel()
        captureTask = nil
        captureWatchdog?.cancel()
        captureWatchdog = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        if let escapeHotKey { UnregisterEventHotKey(escapeHotKey) }
        escapeHotKey = nil
        guard !windows.isEmpty else { return }
        NSCursor.pop()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        startPoint = nil
        currentPoint = nil
        activeScreen = nil
        hoveredRect = nil
        hoveredScreen = .zero
        windowCandidates.removeAll(keepingCapacity: false)
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
        startSnapshotPrefetch(for: activeScreen)
        // A new drag invalidates hover holes on the other displays too.
        refresh()
    }

    fileprivate func mouseDragged(to point: NSPoint) {
        currentPoint = point
        refresh(screenFrame: activeScreen?.frame)
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
        guard !local.isNull, local.width > 4, local.height > 4 else {
            cancel()
            onCancel()
            return
        }
        let prefetched = prefetchTask
        prefetchTask = nil
        cancel()
        let global = NSRect(x: screen.frame.minX + local.minX,
                            y: screen.frame.minY + local.minY,
                            width: local.width, height: local.height)
        let captureRequest = CaptureRequest(screen: screen, local: local, global: global, excluded: excluded)
        captureWatchdog = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard captureTask != nil else { return }
            captureTask?.cancel()
            captureTask = nil
            onError(CaptureFailure.timedOut)
        }
        captureTask = Task { @MainActor in
            defer {
                captureWatchdog?.cancel()
                captureWatchdog = nil
            }
            do {
                // Returning focus after dismissing the panel also restores Stage Manager's target window.
                if let targetApplication, !targetApplication.isTerminated {
                    try await settleFocus(on: targetApplication)
                } else { try await Task.sleep(for: .milliseconds(50)) }
                try Task.checkCancellation()
                if let prefetched {
                    let (prefetchedFrame, snapshot) = await prefetched.value
                    if prefetchedFrame == screen.frame, let snapshot {
                        if let onScreenSelected {
                            captureTask = nil
                            onScreenSelected(snapshot, screen, global)
                            return
                        }
                        if let image = CaptureSelectionGeometry.crop(
                            snapshot, rect: local, displaySize: screen.frame.size
                        ) {
                            captureTask = nil
                            onComplete(image, global)
                            return
                        }
                    }
                }
                if let onRegionSelected {
                    captureTask = nil
                    onRegionSelected(screen, local, global)
                    return
                }
                if let onScreenSelected {
                    let snapshot = try await ScreenCaptureService.capture(screen: captureRequest.screen,
                        selection: CGRect(origin: .zero, size: captureRequest.screen.frame.size),
                        excludingWindowIDs: captureRequest.excluded)
                    captureTask = nil
                    onScreenSelected(snapshot, captureRequest.screen, captureRequest.global)
                    return
                }
                let image = try await ScreenCaptureService.capture(screen: captureRequest.screen,
                    selection: captureRequest.local, excludingWindowIDs: captureRequest.excluded)
                captureTask = nil
                onComplete(image, captureRequest.global)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                captureTask = nil
                onError(error)
            }
        }
    }

    private func startSnapshotPrefetch(for screen: NSScreen?) {
        guard onRegionSelected == nil, prefetchTask == nil, let screen else { return }
        let screenFrame = screen.frame
        let excluded = Set(windows.map { CGWindowID($0.windowNumber) })
        prefetchTask = Task { @MainActor in
            do {
                let image = try await ScreenCaptureService.capture(
                    screen: screen,
                    selection: CGRect(origin: .zero, size: screenFrame.size),
                    excludingWindowIDs: excluded
                )
                return (screenFrame, image)
            } catch {
                return (screenFrame, nil)
            }
        }
    }

    private func settleFocus(on application: NSRunningApplication) async throws {
        application.activate(options: [])
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(160))
        while !application.isActive, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(8))
        }
        // Give Stage Manager/WindowServer one short pass to restore the app's
        // visible window before ScreenCaptureKit reads the display.
        try await Task.sleep(for: .milliseconds(40))
    }

    fileprivate func refresh(screenFrame: CGRect? = nil) {
        let views = windows.compactMap { $0.contentView as? SelectionView }
        if let screenFrame {
            views.filter { $0.screenFrame == screenFrame }.forEach { $0.needsDisplay = true }
        } else {
            views.forEach { $0.needsDisplay = true }
        }
    }

    fileprivate func hover(at point: NSPoint, screenFrame: CGRect) {
        guard startPoint == nil else { return }
        let global = CGPoint(x: screenFrame.minX + point.x, y: screenFrame.minY + point.y)
        let previousScreen = hoveredScreen
        hoveredRect = windowCandidates.lazy.compactMap { rect in
            guard rect.contains(global) else { return nil }
            let clipped = rect.intersection(screenFrame)
            guard !clipped.isNull, clipped.width >= 8, clipped.height >= 8 else { return nil }
            return clipped.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        }.first
        hoveredScreen = screenFrame
        if previousScreen != screenFrame {
            refresh(screenFrame: previousScreen)
        }
        refresh(screenFrame: screenFrame)
    }

    private func cacheWindowCandidates() {
        windowCandidates.removeAll(keepingCapacity: true)
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let ignored = Set(["Dock", "Window Server", "WindowManager", "Control Center", "Notification Center"])
        windowCandidates = windows.compactMap { item in
            guard let layer = item[kCGWindowLayer as String] as? Int, (0...3).contains(layer),
                  let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  pid != ProcessInfo.processInfo.processIdentifier,
                  let owner = item[kCGWindowOwnerName as String] as? String,
                  !ignored.contains(owner),
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.width > 60, rect.height > 40 else { return nil }
            return CGRect(
                x: rect.minX, y: primaryTop - rect.maxY,
                width: rect.width, height: rect.height
            )
        }
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

private struct CaptureRequest {
    let screen: NSScreen
    let local: CGRect
    let global: CGRect
    let excluded: Set<CGWindowID>
}

final class SelectionWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        guard let view = contentView as? SelectionView else { return }
        view.controller?.cancelByUser()
    }
}

final class SelectionView: NSView {
    var controller: SelectionCaptureController?
    var screenFrame = CGRect.zero
    var backingScale: CGFloat = 1

    override var acceptsFirstResponder: Bool { true }
    // The overlay is a nonactivating panel: without this the first click is swallowed
    // whenever the underlying app still owns key focus, which feels like a freeze.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        controller?.hover(at: convert(event.locationInWindow, from: nil), screenFrame: screenFrame)
    }

    override func draw(_ dirtyRect: NSRect) {
        let mask = NSBezierPath(rect: bounds)
        if let rect = controller?.selection(in: self) {
            mask.appendRect(rect)
            mask.windingRule = .evenOdd
        }
        SelectionChrome.mask.setFill()
        mask.fill()
        let prompt = (controller?.prompt ?? "") as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold), .foregroundColor: NSColor.white
        ]
        let size = prompt.size(withAttributes: attributes)
        let badge = CGRect(x: (bounds.width - size.width) / 2 - 15, y: bounds.height - 78,
                           width: size.width + 30, height: 34)
        NSColor(hex: "172A38").withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 17, yRadius: 17).fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let promptBorder = NSBezierPath(roundedRect: badge, xRadius: 17, yRadius: 17)
        promptBorder.lineWidth = 0.8
        promptBorder.stroke()
        prompt.draw(at: CGPoint(x: badge.minX + 15, y: badge.minY + (badge.height - size.height) / 2),
                    withAttributes: attributes)
        if let rect = controller?.selection(in: self) {
            if let context = NSGraphicsContext.current?.cgContext {
                SelectionChrome.draw(in: rect, context: context)
            }

            // Real-time dimensions badge
            if rect.width > 20 && rect.height > 15 {
                let text = "\(Int((rect.width * backingScale).rounded())) × \(Int((rect.height * backingScale).rounded())) px" as NSString
                let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.white
                ]
                let textSize = text.size(withAttributes: attrs)
                let badgeY = rect.minY >= textSize.height + 10 ? rect.minY - textSize.height - 8 : rect.maxY + 6
                let badgeRect = NSRect(x: rect.minX, y: max(4, badgeY),
                                       width: textSize.width + 14, height: textSize.height + 7)
                NSColor(hex: "172A38").withAlphaComponent(0.88).setFill()
                NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6).fill()
                NSColor.white.withAlphaComponent(0.12).setStroke()
                let badgeBorder = NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6)
                badgeBorder.lineWidth = 0.8
                badgeBorder.stroke()
                text.draw(at: NSPoint(x: badgeRect.minX + 7,
                                      y: badgeRect.minY + (badgeRect.height - textSize.height) / 2),
                          withAttributes: attrs)
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

    override func rightMouseDown(with event: NSEvent) {
        controller?.cancelByUser()
    }
}

