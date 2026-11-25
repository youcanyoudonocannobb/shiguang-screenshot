import AppKit
import Carbon
import Darwin
import Security
import SwiftUI
import UniformTypeIdentifiers

@main
struct ShiguangApp {
    @MainActor static func main() {
        if AppRelauncher.runHelperIfNeeded() { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = AppModel()
    private let finderActions = FinderActionsCoordinator()
    private var pendingFinderRequest: FinderActionRequest?
    private lazy var finderExtensionRequirement: SecRequirement? = {
        guard let extensionURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent("PawShotFinder.appex") else {
            return nil
        }
        var application: SecStaticCode?
        var finderExtension: SecStaticCode?
        var requirement: SecRequirement?
        let nestedCode = SecCSFlags(rawValue: UInt32(kSecCSCheckNestedCode))
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &application) == errSecSuccess,
              let application, SecStaticCodeCheckValidity(application, nestedCode, nil) == errSecSuccess,
              SecStaticCodeCreateWithPath(extensionURL as CFURL, [], &finderExtension) == errSecSuccess,
              let finderExtension,
              SecCodeCopyDesignatedRequirement(finderExtension, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()
    private var window: NSWindow!
    private var editorWindow: NSWindow!
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu?
    private var pinnedWindows: [NSWindow] = []
    private var captureController: SelectionCaptureController?
    private var overlayWindow: NSWindow?
    private var screenRegionEditor: ScreenRegionEditorController?
    private var preparedCapture: (snapshot: NSImage, screen: NSScreen)?
    private var hotkeys: [EventHotKeyRef] = []
    private var hotkeyCaptureActive = false
    private var eventHandler: EventHandlerRef?
    private var isRestarting = false
    private var escapeMonitor: Any?
    private var recorder: ScreenRecorder?
    private var recordingWindow: NSWindow?
    private var recordingBorder: NSWindow?
    private var pendingRecordings: [RecordingDraft] = []
    private var recordingClipboardTask: Task<Void, Never>?
    private var regionAction: Task<Void, Never>?
    private var recordingDraftStore: RecordingDraftStore?
    private var recordingStartup: Task<Void, Never>?
    private var recordingSession: RecordingSession?
    private var recordingEscapeHotkey: EventHotKeyRef?
    private var scrollCapture: ScrollCaptureController?
    private var scrollPanel: ScrollCapturePanel?
    private var scrollBorder: NSWindow?
    private var scrollEscapeHotkey: EventHotKeyRef?
    private var lastExternalApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?
    private var captureReturnApplication: NSRunningApplication?
    private var clipboard: ClipboardHistory!
    private var clipboardWindow: NSPanel?
    private var clipboardMenuItem: NSMenuItem?
    private var clipboardTranslateMenuItem: NSMenuItem?
    private var selectionTranslateMenuItem: NSMenuItem?
    private var variableNameMenuItem: NSMenuItem?
    private var clipboardReturnApplication: NSRunningApplication?
    private weak var clipboardReturnWindow: NSWindow?
    private var quickToolWindow: NSPanel?
    private var quickActionsWindow: NSPanel?
    private var quickToolTopEdge: CGFloat?
    private var quickToolPendingHeight: CGFloat?
    private var quickToolResizeScheduled = false
    private var quickToolReturnApplication: NSRunningApplication?
    private weak var quickToolReturnWindow: NSWindow?
    private var toolboxWindow: NSPanel?
    private var selectionTranslationPanel: SelectionTranslationPanel?
    private var selectionTranslationReturnApplication: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read this first: the open-application event is only current while
        // launching.
        let launchedAtLogin = Self.launchedAsLoginItem
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            lastExternalApplication = front
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ownPID else { return }
            Task { @MainActor in self?.lastExternalApplication = app }
        }
        let support = model.store?.directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shiguang", isDirectory: true)
        clipboard = ClipboardHistory(directory: support.appendingPathComponent("Clipboard", isDirectory: true))
        makeMenu()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "NookPup"
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(hex: "F4F7FA")
        window.contentMinSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = settingsContentController(
            rootView: SettingsView(model: model, clipboard: clipboard, finderActions: finderActions)
        )
        window.center()
        window.setFrameAutosaveName("ShiguangSettingsV3")
        self.window = window
        model.showWindow = { [weak self] in self?.showWorkspace() }
        model.showEditor = { [weak self] in self?.showEditorWindow() }
        model.showWorkspace = { [weak self] in self?.showWorkspace() }
        model.showFloatingEditor = { [weak self] in self?.showFloatingEditor() }
        model.hideEditor = { [weak self] in self?.hideEditorWindow() }
        model.showToolbox = { [weak self] in self?.showToolboxWindow() }
        model.beginSelection = { [weak self] translate in self?.beginSelection(translate: translate) }
        model.showCaptureOverlay = { [weak self] image, rect in self?.showCaptureOverlay(image: image, rect: rect) }
        model.closeCaptureOverlay = { [weak self] in self?.overlayWindow?.orderOut(nil) }
        model.pinImage = { [weak self] image, rect in self?.pin(image, at: rect) }
        model.restartApp = { [weak self] in self?.restart() }
        model.beginRecording = { [weak self] format, region in self?.beginRecording(format, region: region) }
        model.saveRecording = { [weak self] in self?.copyLastRecording() }
        model.beginScrollCapture = { [weak self] mode, region in self?.beginScrollCapture(mode, region: region) }
        model.showClipboard = { [weak self] in self?.showClipboardWindow() }
        model.translateSelection = { [weak self] in self?.translateSelection() }
        model.statusItemPreferencesChanged = { [weak self] in self?.applyStatusItemPreferences() }
        model.languageChanged = { [weak self] in self?.refreshLocalization() }
        model.loadStoredAIAPIKey()
        model.publishImage = { [unowned self] image in try self.clipboard.copyImage(image) }
        model.publishText = { [unowned self] text in try self.clipboard.copyText(text) }
        model.didCopyCapture = { [weak self] in self?.restoreCaptureApplication() }
        if let directory = model.store?.directory {
            let drafts = RecordingDraftStore(directory: directory.appendingPathComponent("PendingRecordings", isDirectory: true))
            recordingDraftStore = drafts
            pendingRecordings = drafts.loadAll()
            model.recordingReady = !pendingRecordings.isEmpty
        }
        // Page the Vision text models in while the app is idle: a cold first
        // recognition otherwise blocks for ~15s on the user's first capture.
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: .seconds(2))
            await OCRService.warmUp()
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, self.finderActions.cancel(in: event.window) { return nil }
            if event.keyCode == 53, let target = event.window,
               self.pinnedWindows.contains(where: { $0 === target }) {
                self.closePinnedWindow(target)
                return nil
            }
            if let quickToolWindow = self.quickToolWindow, quickToolWindow.isVisible,
               event.window === quickToolWindow, quickToolWindow.attachedSheet == nil,
               event.keyCode == 53 {
                self.closeQuickToolWindow()
                return nil
            }
            if let clipboardWindow = self.clipboardWindow, clipboardWindow.isVisible,
               event.window === clipboardWindow, clipboardWindow.attachedSheet == nil {
                switch event.keyCode {
                case 53: self.closeClipboardWindow(); return nil
                case 125: self.clipboard.moveSelection(1); return nil
                case 126: self.clipboard.moveSelection(-1); return nil
                case 36, 76: self.copySelectedClipboardEntry(); return nil
                case 51 where event.modifierFlags.contains(.command) && self.clipboard.search.isEmpty:
                    // With text in the search field, Cmd-Delete keeps its
                    // usual meaning and clears the query first.
                    if let id = self.clipboard.selectedID,
                       let entry = self.clipboard.entries.first(where: { $0.id == id }) {
                        self.clipboard.remove(entry)
                    }
                    return nil
                default: return event
                }
            }
            guard event.keyCode == 53 else { return event }
            if self.regionAction != nil {
                self.regionAction?.cancel(); self.regionAction = nil
                self.model.activity = nil
                self.model.discardDraft()
                return nil
            }
            if self.captureController?.isActive == true {
                self.captureController?.cancelByUser()
                return nil
            }
            if self.scrollCapture != nil {
                self.scrollCapture?.cancel()
                return nil
            }
            if event.window === self.recordingWindow {
                self.cancelRecording()
                return nil
            }
            if let active = event.window, active === self.editorWindow || active === self.overlayWindow {
                if active.attachedSheet != nil { return event }
                if let text = active.firstResponder as? NSTextView, text.isFieldEditor { return event }
                self.model.closeEditor()
                return nil
            }
            return event
        }
        setupStatusItem()
        model.refreshLaunchAtLoginState()
        setupHotkeys()
        model.hotkeysChanged = { [weak self] in self?.rebindHotkeys() }
        model.hotkeyCaptureChanged = { [weak self] active in self?.setHotkeyCaptureActive(active) }
        clipboard.start()
        finderActions.publishSettings()
        if let request = pendingFinderRequest {
            pendingFinderRequest = nil
            handleFinderRequest(request)
        } else if !FinderActionRequest.isFinderLaunch(ProcessInfo.processInfo.arguments), !launchedAtLogin {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            model.useDemo()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// macOS opens login items with an open-application event flagged as a
    /// login launch. Like other menu bar utilities, NookPup then starts
    /// quietly instead of opening Preferences on every login.
    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue ==
            OSType(keyAELaunchedAsLogInItem)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let request = urls.lazy.compactMap(FinderActionRequest.init(url:)).first,
              isFinderExtensionSender() else { return }
        if window == nil { pendingFinderRequest = request }
        else { handleFinderRequest(request) }
    }

    private func isFinderExtensionSender() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let token = event.attributeDescriptor(forKeyword: AEKeyword(keySenderAuditTokenAttr))?.data,
              let finderExtensionRequirement else { return false }
        var sender: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &sender) == errSecSuccess, let sender else {
            return false
        }
        return SecCodeCheckValidity(sender, [], finderExtensionRequirement) == errSecSuccess
    }

    private func handleFinderRequest(_ request: FinderActionRequest) {
        finderActions.handle(request) { try clipboard.copyText($0) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if captureController?.isActive == true { return false }
        let activeWindows: [NSWindow?] = [finderActions.window, quickToolWindow, quickActionsWindow, toolboxWindow, clipboardWindow,
                                          selectionTranslationPanel, recordingWindow, scrollPanel,
                                          overlayWindow, editorWindow]
        if let active = activeWindows.compactMap({ $0 }).first(where: { $0.isVisible }) {
            active.makeKeyAndOrderFront(nil)
            return false
        }
        showWorkspace()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboard.stop()
        regionAction?.cancel()
        captureController?.cancel()
        scrollCapture?.onCancel = nil
        scrollCapture?.cancel()
        if let scrollEscapeHotkey { UnregisterEventHotKey(scrollEscapeHotkey) }
        model.persistCurrent()
        for key in hotkeys { UnregisterEventHotKey(key) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let copying = recordingClipboardTask
        let fileOperation = finderActions.pendingFileOperation
        let recording = recorder
        copying?.cancel()
        regionAction?.cancel()
        guard recording != nil || copying != nil || fileOperation != nil else { return .terminateNow }
        if recording != nil {
            recordingSession?.cancel()
            recordingStartup?.cancel()
            closeRecordingWindows()
        }
        Task {
            await recording?.cancel()
            await copying?.value
            await fileOperation?.value
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshPermissionStatus()
        model.refreshLaunchAtLoginState()
        finderActions.refreshExtensionStatus()
    }

    func applicationWillResignActive(_ notification: Notification) {
        // hidesOnDeactivate only hides these panels, and AppKit orders them back
        // in on the next activation. For a menu bar app that is any feature
        // (capture, clipboard, translation...), so a launcher left by clicking
        // another app reappeared over every later feature. Leaving NookPup
        // dismisses them instead; the panels keep their state for next time.
        for panel in [quickToolWindow, clipboardWindow, quickActionsWindow, toolboxWindow] {
            panel?.orderOut(nil)
        }
        // The user chose where focus goes; don't send it back anywhere later.
        quickToolReturnApplication = nil
        quickToolReturnWindow = nil
        clipboardReturnApplication = nil
        clipboardReturnWindow = nil
        finderActions.dismissPrompts()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let launcher = quickToolWindow, notification.object as? NSWindow === launcher else { return }
        // Like Spotlight, the launcher only lives while it has focus: once
        // another NookPup window takes over (capture, clipboard, toolbox...),
        // close it rather than leave it floating over that feature. Switching
        // apps is handled in applicationWillResignActive.
        DispatchQueue.main.async { [weak self] in
            guard let self, let launcher = self.quickToolWindow, launcher.isVisible,
                  let key = NSApp.keyWindow, !Self.window(key, belongsTo: launcher) else { return }
            launcher.orderOut(nil)
            self.quickToolReturnApplication = nil
            self.quickToolReturnWindow = nil
        }
    }

    /// Sheets, popovers and other child windows keep their owner focused.
    private static func window(_ candidate: NSWindow, belongsTo owner: NSWindow) -> Bool {
        var current: NSWindow? = candidate
        while let window = current {
            if window === owner { return true }
            current = window.sheetParent ?? window.parent
        }
        return false
    }

    /// The NookPup window a transient panel hands focus back to: the one the
    /// user was working in when they opened it. Nil when they came from another
    /// app, so focus returns to that app instead.
    private func focusReturnWindow(frontmost: NSRunningApplication?) -> NSWindow? {
        guard frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
              let key = NSApp.keyWindow, key.isVisible else { return nil }
        let transient: [NSWindow?] = [window, quickToolWindow, clipboardWindow, quickActionsWindow]
        return transient.contains { $0 === key } ? nil : key
    }

    private func restoreFocus(to returnWindow: NSWindow?, or application: NSRunningApplication?) {
        if let returnWindow, returnWindow.isVisible {
            returnWindow.makeKeyAndOrderFront(nil)
        } else if let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            application.activate(options: [])
        }
    }

    @objc func showWorkspace() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func settingsContentController<Content: View>(rootView: Content) -> NSViewController {
        let hosting = NSHostingController(rootView: rootView)
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.title, .toolbars]

        let container = NSViewController()
        container.view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 620))
        container.addChild(hosting)
        hosting.view.frame = container.view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        container.view.addSubview(hosting.view)
        return container
    }

    @objc func capture() { model.capture() }
    @objc func translateCapture() { model.capture(translate: true) }
    @objc private func translateClipboard() { model.translateClipboard() }
    @objc private func translateSelection() {
        guard SelectedTextReader.isTrusted else {
            requestSelectionAccess(for: "划词翻译")
            return
        }
        guard let selection = SelectedTextReader.selection(
            applicationPID: lastExternalApplication?.processIdentifier
        ) else {
            let alert = NSAlert()
            alert.messageText = "没有读取到选中的文字"
            alert.informativeText = "请先在网页、文档或输入框中选中文字，再按划词翻译快捷键。"
            alert.addButton(withTitle: "知道了")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        presentSelectionTranslation(selection)
    }

    private func presentSelectionTranslation(_ selection: SelectedTextSelection) {
        if captureController?.isActive == true { captureController?.cancelByUser() }
        selectionTranslationPanel?.orderOut(nil)
        selectionTranslationReturnApplication = lastExternalApplication

        let panel = SelectionTranslationPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SelectionTranslationLayout.width,
                height: SelectionTranslationLayout.height
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: SelectionTranslationView(
            model: model,
            text: selection.text,
            onClose: { [weak self] in self?.closeSelectionTranslation() }
        ).environment(\.locale, model.appLanguage.locale))
        panel.onEscape = { [weak self] in self?.closeSelectionTranslation() }
        positionSelectionTranslation(panel, relativeTo: selection.bounds)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        selectionTranslationPanel = panel
    }

    private func positionSelectionTranslation(_ panel: NSPanel, relativeTo accessibilityBounds: CGRect?) {
        let mouse = NSEvent.mouseLocation
        let anchor = accessibilityBounds.map { rect -> CGRect in
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? rect.maxY
            return CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
        }
        let referencePoint = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? mouse
        let screen = NSScreen.screens.first(where: { $0.frame.contains(referencePoint) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        var x = (anchor?.minX ?? mouse.x) - 12
        var y = (anchor?.minY ?? mouse.y) - size.height - 10
        if let anchor, y < visible.minY + 8 {
            y = anchor.maxY + 10
        }
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        y = min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func closeSelectionTranslation() {
        selectionTranslationPanel?.orderOut(nil)
        selectionTranslationPanel?.contentView = nil
        selectionTranslationPanel = nil
        if let app = selectionTranslationReturnApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.activate(options: [])
        }
        selectionTranslationReturnApplication = nil
    }

    @objc private func showQuickToolWindow() {
        if quickToolWindow?.isKeyWindow == true {
            closeQuickToolWindow()
            return
        }
        if captureController?.isActive == true { captureController?.cancelByUser() }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        quickToolReturnApplication = front?.processIdentifier == ownPID ? lastExternalApplication : front
        quickToolReturnWindow = focusReturnWindow(frontmost: front)
        window?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)

        let panel: NSPanel
        if let existing = quickToolWindow {
            panel = existing
        } else {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0,
                                    width: QuickToolView.panelWidth,
                                    height: QuickToolView.collapsedHeight),
                styleMask: [.titled, .fullSizeContentView, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            created.title = "NookPup · \(L("启动台"))"
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.isReleasedWhenClosed = false
            created.isMovableByWindowBackground = true
            created.level = .floating
            created.hidesOnDeactivate = true
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = false
            created.delegate = self
            quickToolWindow = created
            panel = created
        }

        panel.setFrame(
            NSRect(origin: panel.frame.origin,
                   size: NSSize(width: QuickToolView.panelWidth,
                                height: QuickToolView.collapsedHeight)),
            display: false
        )
        panel.contentView = NSHostingView(rootView: QuickToolView(
            model: model,
            onCopy: { [weak self] text in
                guard let self else { return "应用已退出，无法复制。" }
                do {
                    try self.clipboard.copyText(
                        text,
                        successMessage: "已复制：\(String(text.prefix(60)))"
                    )
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            onClose: { [weak self] restoreFocus in self?.closeQuickToolWindow(restoringFocus: restoreFocus) },
            onHeightChange: { [weak self] height in
                Task { @MainActor in
                    self?.resizeQuickToolWindow(to: height)
                }
            }
        ).environment(\.locale, model.appLanguage.locale))
        positionQuickToolWindowAtTop(panel)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.orderOut(nil)
    }

    @objc private func showToolboxWindow() {
        window?.orderOut(nil)
        let panel: NSPanel
        if let existing = toolboxWindow {
            panel = existing
        } else {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            created.title = "NookPup · \(L("工具箱"))"
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.isReleasedWhenClosed = false
            created.isMovableByWindowBackground = true
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            created.backgroundColor = NSColor(hex: "F4F7FA")
            created.minSize = NSSize(width: 760, height: 520)
            created.contentView = NSHostingView(
                rootView: ToolboxView().environment(\.locale, AppLanguage.stored.locale)
            )
            created.center()
            toolboxWindow = created
            panel = created
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionQuickToolWindowAtTop(_ panel: NSPanel) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = panel.frame.size
        quickToolTopEdge = visible.maxY - 24
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: (quickToolTopEdge ?? visible.maxY - 24) - size.height
        ))
    }

    private func resizeQuickToolWindow(to contentHeight: CGFloat) {
        quickToolPendingHeight = contentHeight
        guard !quickToolResizeScheduled else { return }
        quickToolResizeScheduled = true
        // Coalesce the height updates SwiftUI emits during a single layout pass
        // so the panel resizes once instead of flickering between heights.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.quickToolResizeScheduled = false
            guard let height = self.quickToolPendingHeight else { return }
            self.quickToolPendingHeight = nil
            self.applyQuickToolWindowHeight(height)
        }
    }

    private func applyQuickToolWindowHeight(_ contentHeight: CGFloat) {
        guard let panel = quickToolWindow else { return }
        let targetSize = NSSize(
            width: QuickToolView.panelWidth,
            height: max(contentHeight, QuickToolView.collapsedHeight)
        )
        guard abs(panel.frame.width - targetSize.width) > 0.5 ||
              abs(panel.frame.height - targetSize.height) > 0.5 else { return }
        // Keep the top edge pinned; animated resizes stacked on fast typing made
        // the launcher visibly bounce up and down.
        if let expectedTop = quickToolTopEdge, abs(panel.frame.maxY - expectedTop) > 1 {
            // The user dragged the panel; follow its new position from now on.
            quickToolTopEdge = panel.frame.maxY
        }
        let top = quickToolTopEdge ?? panel.frame.maxY
        let midX = panel.frame.midX
        let targetFrame = NSRect(
            x: midX - targetSize.width / 2,
            y: top - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
        panel.setFrame(targetFrame, display: true)
    }

    private func closeQuickToolWindow(restoringFocus: Bool = true) {
        quickToolWindow?.orderOut(nil)
        window?.orderOut(nil)
        if restoringFocus { restoreFocus(to: quickToolReturnWindow, or: quickToolReturnApplication) }
        quickToolReturnApplication = nil
        quickToolReturnWindow = nil
    }

    private func requestSelectionAccess(for feature: String) {
        let alert = NSAlert()
        alert.messageText = "\(feature)需要辅助功能权限"
        alert.informativeText = "NookPup 只读取当前应用中被选中的文字，不记录其他输入内容。请在「系统设置 > 隐私与安全性 > 辅助功能」中允许 NookPup。"
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = SelectedTextReader.requestAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func importImage() { showWorkspace(); model.importImage() }
    @objc func pasteImage() { showWorkspace(); model.pasteImage() }
    @objc func preferences() { showWorkspace(); model.showsSettings = true }
    @objc func newText() { model.newText() }
    @objc func showTextTranslation() { model.startTextTranslation() }
    @objc func exportImage() { model.exportImage() }
    @objc func undoMark() { model.undo() }
    @objc func redoMark() { model.redo() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func recordVideo() { model.record(.video) }
    @objc func recordGIF() { model.record(.gif) }
    @objc func scrollAutomatic() { model.captureScrolling(.automatic) }
    @objc func scrollManual() { model.captureScrolling(.manual) }

    @objc private func showClipboardWindow() {
        if clipboardWindow?.isVisible == true { closeClipboardWindow(); return }
        presentClipboardWindow(section: .history)
    }

    private func presentClipboardWindow(section: ClipboardSection) {
        if clipboardWindow?.isVisible == true {
            clipboard.section = section
            clipboardWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if captureController?.isActive == true { captureController?.cancelByUser() }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication
        clipboardReturnApplication = front?.processIdentifier == ownPID ? lastExternalApplication : front
        clipboardReturnWindow = focusReturnWindow(frontmost: front)
        window?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        if section == .tools { clipboard.prepareForTools() }
        else { clipboard.prepareForDisplay() }
        if clipboardWindow == nil {
            let panel = ScrollCapturePanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 650),
                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "NookPup · \(L("剪贴板"))"
            panel.minSize = NSSize(width: 520, height: 460)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = NSColor(hex: "F4F7FA")
            panel.contentView = NSHostingView(rootView: ClipboardPanelView(history: clipboard,
                onCopy: { [weak self] entry in self?.copyClipboardEntry(entry) },
                onClose: { [weak self] in self?.closeClipboardWindow() })
                .environment(\.locale, AppLanguage.stored.locale))
            panel.center()
            clipboardWindow = panel
        }
        clipboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.orderOut(nil)
    }

    @objc private func showQuickActionsWindow() {
        if quickActionsWindow?.isVisible == true {
            quickActionsWindow?.orderOut(nil)
            return
        }
        if captureController?.isActive == true { captureController?.cancelByUser() }
        let panel: NSPanel
        if let existing = quickActionsWindow {
            panel = existing
        } else {
            let created = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            created.title = "NookPup · \(L("快捷操作"))"
            created.titleVisibility = .hidden
            created.titlebarAppearsTransparent = true
            created.isReleasedWhenClosed = false
            created.isMovableByWindowBackground = true
            created.hidesOnDeactivate = true
            created.level = .floating
            created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            created.backgroundColor = NSColor(hex: "F4F7FA")
            created.minSize = NSSize(width: 560, height: 520)
            created.contentView = NSHostingView(rootView: QuickActionsView(
                model: model,
                onCopyText: { [weak self] text in self?.copyGeneratedText(text) },
                onClose: { [weak self] in self?.quickActionsWindow?.orderOut(nil) }
            ).environment(\.locale, model.appLanguage.locale))
            created.center()
            quickActionsWindow = created
            panel = created
        }
        window?.orderOut(nil)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func copySelectedClipboardEntry() {
        guard let entry = clipboard.filteredEntries.first(where: { $0.id == clipboard.selectedID }) ?? clipboard.filteredEntries.first else { return }
        copyClipboardEntry(entry)
    }

    private func copyClipboardEntry(_ entry: ClipboardEntry) {
        do { try clipboard.copy(entry); closeClipboardWindow() }
        catch { clipboard.reportCopyError(error) }
    }

    private func copyGeneratedText(_ text: String) {
        do {
            try clipboard.copyText(text, successMessage: "已复制：\(String(text.prefix(48)))")
        } catch {
            clipboard.reportCopyError(error)
        }
    }

    private func closeClipboardWindow() {
        clipboardWindow?.orderOut(nil)
        window?.orderOut(nil)
        // Opened from a NookPup window (toolbox, editor...): go back there so a
        // paste lands where the user was working, not in the last other app.
        restoreFocus(to: clipboardReturnWindow, or: clipboardReturnApplication)
        clipboardReturnApplication = nil
        clipboardReturnWindow = nil
    }

    private func restoreCaptureApplication() {
        captureReturnApplication?.activate(options: [])
    }

    private func restart() {
        guard !isRestarting else { return }
        isRestarting = true
        model.showsPermissionHelp = false
        if let sheet = window?.attachedSheet { window.endSheet(sheet) }
        Task { @MainActor in
            // Let SwiftUI finish dismissing the sheet before requesting application termination.
            try? await Task.sleep(for: .milliseconds(200))
            do {
                try AppRelauncher.start(bundleURL: Bundle.main.bundleURL,
                                       parentPID: ProcessInfo.processInfo.processIdentifier)
                NSApp.terminate(nil)
            } catch {
                isRestarting = false
                model.errorMessage = "无法重启 NookPup：\(error.localizedDescription)"
                showWorkspace()
            }
        }
    }
    @objc func showEditorWindow() { showEditorWindowInternal() }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: L(title), action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func menuItem(_ title: String, action: Selector, key: String = "",
                          symbol: String) -> NSMenuItem {
        let item = menuItem(title, action: action, key: key)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func makeMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "NookPup", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(menuItem("关于 NookPup", action: #selector(about)))
        appMenu.addItem(menuItem("偏好设置…", action: #selector(preferences), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("退出 NookPup", action: #selector(quit), key: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let fileItem = NSMenuItem()
        let file = NSMenu(title: L("文件"))
        file.addItem(menuItem("区域截图", action: #selector(capture), key: "n"))
        file.addItem(menuItem("截图并翻译", action: #selector(translateCapture)))
        file.addItem(menuItem("录制 MP4 视频…", action: #selector(recordVideo)))
        file.addItem(menuItem("录制 GIF 动图…", action: #selector(recordGIF)))
        file.addItem(recordingDraftMenuItem())
        file.addItem(menuItem("自动长截图…", action: #selector(scrollAutomatic)))
        file.addItem(menuItem("手动长截图…", action: #selector(scrollManual)))
        file.addItem(menuItem("导入图片…", action: #selector(importImage), key: "o"))
        let paste = menuItem("粘贴图片", action: #selector(pasteImage), key: "v")
        paste.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(paste)
        file.addItem(menuItem("文字翻译", action: #selector(showTextTranslation), key: "t"))
        let clipboardTranslate = menuItem("翻译剪贴板", action: #selector(translateClipboard))
        clipboardTranslateMenuItem = clipboardTranslate
        file.addItem(clipboardTranslate)
        let selectionTranslate = menuItem("划词翻译", action: #selector(translateSelection))
        selectionTranslateMenuItem = selectionTranslate
        file.addItem(selectionTranslate)
        let variableName = menuItem("启动台", action: #selector(showQuickToolWindow))
        variableNameMenuItem = variableName
        file.addItem(variableName)
        file.addItem(menuItem("快捷操作", action: #selector(showQuickActionsWindow)))
        file.addItem(menuItem("工具箱", action: #selector(showToolboxWindow)))
        let clipboardItem = menuItem("剪贴板历史", action: #selector(showClipboardWindow))
        clipboardMenuItem = clipboardItem
        file.addItem(clipboardItem)
        fileItem.submenu = file
        main.addItem(fileItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: L("编辑"))
        for (title, action, key) in [
            ("撤销文字编辑", Selector(("undo:")), "z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            edit.addItem(NSMenuItem(title: L(title), action: action, keyEquivalent: key))
        }
        let undo = menuItem("撤销标注", action: #selector(undoMark), key: "z")
        undo.keyEquivalentModifierMask = [.command, .option]
        edit.addItem(undo)
        let redo = menuItem("重做标注", action: #selector(redoMark), key: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: L("窗口"))
        windowMenu.addItem(menuItem("设置", action: #selector(showWorkspace), key: "1"))
        windowMenu.addItem(menuItem("快速编辑", action: #selector(showEditorWindow)))
        windowMenu.addItem(menuItem("悬浮编辑", action: #selector(showFloatingEditor)))
        windowMenu.addItem(menuItem("快捷操作", action: #selector(showQuickActionsWindow)))
        windowMenu.addItem(menuItem("剪贴板历史", action: #selector(showClipboardWindow)))
        windowMenu.addItem(NSMenuItem(title: L("最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: L("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func about() {
        let credits = NSMutableAttributedString(
            string: "\(L("你的 Mac 菜单栏工具箱"))\n\(L("截图、录制、翻译、剪贴板与访达工具。"))\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
        )
        if let url = URL(string: "https://github.com/youcanyoudonocannobb/shiguang-screenshot") {
            credits.append(NSAttributedString(
                string: "GitHub  github.com/youcanyoudonocannobb/shiguang-screenshot",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .link: url
                ]
            ))
        }
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "NookPup",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            .credits: credits
        ])
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusMenu = makeStatusMenu()
        statusItem.menu = nil
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleStatusMenu)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyStatusItemPreferences()
    }

    /// Shows a global hotkey as the item's native, right-aligned key
    /// equivalent. The registered hotkey still handles the key press.
    private func applyHotkey(_ hotkey: HotkeySettings, to item: NSMenuItem?) {
        guard let item else { return }
        let key = hotkey.carbonModifiers == 0 ? "" : hotkey.menuKeyEquivalent
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = key.isEmpty ? [] : hotkey.cocoaModifiers
    }

    private func hotkeyMenuItem(_ title: String, action: Selector, symbol: String,
                                hotkey: HotkeySettings) -> NSMenuItem {
        let item = menuItem(title, action: action, symbol: symbol)
        applyHotkey(hotkey, to: item)
        return item
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(hotkeyMenuItem("区域截图", action: #selector(capture), symbol: "viewfinder",
                                    hotkey: model.captureHotkey))
        menu.addItem(hotkeyMenuItem("截图并翻译", action: #selector(translateCapture), symbol: "character.bubble",
                                    hotkey: model.translateHotkey))
        menu.addItem(hotkeyMenuItem("剪贴板历史", action: #selector(showClipboardWindow), symbol: "doc.on.clipboard",
                                    hotkey: model.clipboardHotkey))
        menu.addItem(hotkeyMenuItem("翻译剪贴板", action: #selector(translateClipboard),
                                    symbol: "character.book.closed", hotkey: model.clipboardTranslateHotkey))
        menu.addItem(hotkeyMenuItem("划词翻译", action: #selector(translateSelection), symbol: "text.cursor",
                                    hotkey: model.selectionTranslateHotkey))
        menu.addItem(hotkeyMenuItem("启动台", action: #selector(showQuickToolWindow), symbol: "textformat.abc",
                                    hotkey: model.variableNamingHotkey))
        menu.addItem(menuItem("快捷操作", action: #selector(showQuickActionsWindow), symbol: "bolt"))
        menu.addItem(.separator())
        menu.addItem(menuItem("录制 MP4 视频…", action: #selector(recordVideo), symbol: "record.circle"))
        menu.addItem(menuItem("录制 GIF 动图…", action: #selector(recordGIF), symbol: "photo.on.rectangle.angled"))
        menu.addItem(menuItem("自动长截图…", action: #selector(scrollAutomatic), symbol: "rectangle.expand.vertical"))
        menu.addItem(menuItem("手动长截图…", action: #selector(scrollManual), symbol: "hand.point.up"))
        menu.addItem(.separator())
        menu.addItem(menuItem("文字翻译", action: #selector(newText), symbol: "text.bubble"))
        menu.addItem(menuItem("工具箱", action: #selector(showToolboxWindow), symbol: "wrench.and.screwdriver"))
        menu.addItem(.separator())
        menu.addItem(menuItem("偏好设置…", action: #selector(preferences), symbol: "gearshape"))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 NookPup", action: #selector(quit), symbol: "power"))
        return menu
    }

    @objc private func toggleStatusMenu() {
        guard let menu = statusMenu, let button = statusItem.button else { return }
        let point = NSPoint(x: 0, y: button.bounds.height + 4)
        button.highlight(true)
        menu.popUp(positioning: nil, at: point, in: button)
        button.highlight(false)
    }

    private func applyStatusItemPreferences() {
        guard let statusItem else { return }
        statusItem.isVisible = model.showsMenuBarIcon
        statusItem.button?.image = BrandArtwork.menuBarImage(
            tintHex: model.menuBarIconStyle.colorHex,
            customImageData: model.menuBarIconStyle == .custom ? model.customMenuBarIconData : nil
        )
        statusItem.button?.toolTip = "NookPup · \(L("菜单栏工具箱"))"
        statusItem.button?.setAccessibilityLabel("NookPup \(L("菜单"))")
    }

    private func refreshLocalization() {
        finderActions.publishSettings()
        makeMenu()
        if statusItem != nil {
            statusMenu = makeStatusMenu()
            applyStatusItemPreferences()
        }
        window?.title = L("偏好设置")
        toolboxWindow?.orderOut(nil)
        toolboxWindow = nil
        quickToolWindow?.orderOut(nil)
        quickToolWindow = nil
        quickActionsWindow?.orderOut(nil)
        quickActionsWindow = nil
        clipboardWindow?.orderOut(nil)
        clipboardWindow = nil
    }

    private func setupHotkeys() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr else { return result }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            let id = identifier.id
            Task { @MainActor in
                if id == 3 || id == 4 {
                    if delegate.clipboardWindow?.isVisible == true { delegate.closeClipboardWindow() }
                    else if id == 3 { delegate.scrollCapture?.cancel() }
                    else { delegate.cancelRecording() }
                }
                else if id == 5 { delegate.showClipboardWindow() }
                else if id == 6 { delegate.translateClipboard() }
                else if id == 7 { delegate.captureController?.cancelByUser() }
                else if id == 8 { delegate.translateSelection() }
                else if id == 9 { delegate.showQuickToolWindow() }
                else { delegate.model.capture(translate: id == 2) }
            }
            return noErr
        }, 1, &eventType, pointer, &eventHandler)
        guard status == noErr else { model.hotkeyAvailable = false; return }
        registerHotkeys()
    }

    private func recordingDraftMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("复制之前的录制"), action: nil, keyEquivalent: "")
        let menu = NSMenu(title: L("复制之前的录制"))
        menu.delegate = self
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == L("复制之前的录制") else { return }
        menu.removeAllItems()
        if pendingRecordings.isEmpty {
            let empty = NSMenuItem(title: L("没有待保存的录制"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for draft in pendingRecordings {
            let item = menuItem("\(draft.format.title) · \(draft.createdAt.formatted(.dateTime.month().day().hour().minute().second()))",
                                action: #selector(saveRecordingItem(_:)))
            item.representedObject = draft.url
            menu.addItem(item)
        }
    }

    @objc private func saveRecordingItem(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL,
              let draft = pendingRecordings.first(where: { $0.url == url }) else { return }
        copyRecordingToClipboard(draft)
    }

    private func registerHotkeys() {
        model.hotkeyAvailable = true
        for (id, settings) in [
            (UInt32(1), model.captureHotkey),
            (UInt32(2), model.translateHotkey),
            (UInt32(5), model.clipboardHotkey),
            (UInt32(6), model.clipboardTranslateHotkey),
            (UInt32(8), model.selectionTranslateHotkey),
            (UInt32(9), model.variableNamingHotkey)
        ] {
            guard settings.carbonModifiers != 0 else {
                model.hotkeyAvailable = false
                continue
            }
            var ref: EventHotKeyRef?
            let keyID = EventHotKeyID(signature: OSType(0x53484747), id: id)
            let result = RegisterEventHotKey(settings.keyCode, settings.carbonModifiers, keyID, GetApplicationEventTarget(), 0, &ref)
            if result == noErr, let ref { hotkeys.append(ref) }
            else { model.hotkeyAvailable = false }
        }
        updateStatusMenuHotkeys()
    }

    private func updateStatusMenuHotkeys() {
        // Rebuild instead of rewriting titles, so the language and the
        // current shortcuts both stay correct.
        if statusItem != nil { statusMenu = makeStatusMenu() }
        applyHotkey(model.clipboardHotkey, to: clipboardMenuItem)
        applyHotkey(model.clipboardTranslateHotkey, to: clipboardTranslateMenuItem)
        applyHotkey(model.selectionTranslateHotkey, to: selectionTranslateMenuItem)
        applyHotkey(model.variableNamingHotkey, to: variableNameMenuItem)
    }

    private func rebindHotkeys() {
        for key in hotkeys { UnregisterEventHotKey(key) }
        hotkeys.removeAll()
        guard !hotkeyCaptureActive else { return }
        registerHotkeys()
    }

    private func setHotkeyCaptureActive(_ active: Bool) {
        guard hotkeyCaptureActive != active else { return }
        hotkeyCaptureActive = active
        for key in hotkeys { UnregisterEventHotKey(key) }
        hotkeys.removeAll()
        guard !active else { return }
        registerHotkeys()
    }

    private func showEditorWindowInternal() {
        overlayWindow?.orderOut(nil)
        model.activeEditor = "editor"
        if editorWindow == nil {
            let panel = CaptureEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
            panel.title = "NookPup · \(L("快速编辑"))"
            panel.backgroundColor = NSColor(hex: "F4F7FA")
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentView = NSHostingView(
                rootView: CaptureEditorView(model: model)
                    .environment(\.locale, model.appLanguage.locale)
            )
            panel.center()
            editorWindow = panel
        }
        let text = model.isTextWorkspace
        if text { window?.orderOut(nil) }
        editorWindow.title = model.editorMode == .recognition ? "NookPup · \(L("文字识别"))" :
            (text ? "NookPup · \(L("翻译"))" : "NookPup · \(L("快速编辑"))")
        editorWindow.minSize = text ? NSSize(width: model.editorMode == .recognition ? 760 : 700,
                                             height: model.editorMode == .recognition ? 500 : 440) :
            NSSize(width: AnnotationToolbar.minimumWidth, height: 400)
        editorWindow.setContentSize(text ? NSSize(width: model.editorMode == .recognition ? 960 : 860,
                                                  height: model.editorMode == .recognition ? 620 : 520) :
            NSSize(width: 980, height: 760))
        editorWindow.center()
        editorWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showFloatingEditor() {
        guard let image = model.image else { return }
        editorWindow?.orderOut(nil)
        if model.draftImage != nil, model.captureRect != nil, let screenRegionEditor {
            model.activeEditor = "overlay"
            overlayWindow = screenRegionEditor.window
            screenRegionEditor.show()
            return
        }
        let screen = editorWindow?.screen ?? NSScreen.main
        let available = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: min(800, image.size.width), height: min(500, image.size.height))
        showCaptureOverlay(image: image, rect: CGRect(x: available.midX - size.width / 2,
                                                      y: available.midY - size.height / 2,
                                                      width: size.width, height: size.height))
    }

    private func hideEditorWindow() {
        editorWindow?.orderOut(nil)
    }

    private func beginSelection(translate: Bool) {
        preparedCapture = nil
        regionAction?.cancel()
        regionAction = nil
        cancelRecording()
        captureController?.cancel()
        let wasEditorVisible = editorWindow?.isVisible == true
        let wasOverlayVisible = overlayWindow?.isVisible == true
        let restoreWindows = { [weak self] in
            guard let self else { return }
            if wasEditorVisible { self.editorWindow?.makeKeyAndOrderFront(nil) }
            if wasOverlayVisible { self.overlayWindow?.makeKeyAndOrderFront(nil) }
        }
        window?.orderOut(nil)
        hideEditorWindow()
        overlayWindow?.orderOut(nil)
        let controller = SelectionCaptureController { [weak self] image, rect in
            self?.model.activity = nil
            self?.model.acceptImage(image, title: "截图 \(Date().formatted(.dateTime.hour().minute()))",
                                    translate: translate, inlineRect: rect)
        } onCancel: { [weak self] in
            self?.model.captureCancelled()
            restoreWindows()
        } onError: { [weak self] error in
            restoreWindows()
            self?.model.captureFailed(error)
        }
        captureController = controller
        if !translate {
            controller.onScreenSelected = { [weak self] snapshot, screen, rect in
                guard let self else { return }
                let local = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
                guard let image = CaptureSelectionGeometry.crop(snapshot, rect: local, displaySize: screen.frame.size) else {
                    restoreWindows()
                    self.model.captureFailed(CaptureFailure.invalidSelection)
                    return
                }
                self.preparedCapture = (snapshot, screen)
                self.model.activity = nil
                self.model.acceptImage(image, title: "截图 \(Date().formatted(.dateTime.hour().minute()))", inlineRect: rect)
            }
        }
        controller.targetApplication = captureTargetApplication()
        captureReturnApplication = controller.targetApplication
        controller.begin()
    }

    private func captureTargetApplication() -> NSRunningApplication? {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier { return front }
        return lastExternalApplication
    }

    private func useCurrentRegion(_ rect: CGRect?, action: @escaping (NSScreen, CGRect, CGRect) -> Void) -> Bool {
        guard let rect, let screen = NSScreen.screens.first(where: { $0.frame.contains(rect) }) else { return false }
        let local = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        regionAction?.cancel()
        captureReturnApplication?.activate(options: [])
        model.activity = "正在准备选区…"
        regionAction = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            regionAction = nil
            action(screen, local, rect)
        }
        return true
    }

    private func showCaptureOverlay(image: NSImage, rect: NSRect) {
        model.activeEditor = "overlay"
        overlayWindow?.orderOut(nil)
        if let preparedCapture {
            self.preparedCapture = nil
            screenRegionEditor?.hide()
            let controller = ScreenRegionEditorController(snapshot: preparedCapture.snapshot,
                screen: preparedCapture.screen, selection: rect, model: model)
            screenRegionEditor = controller
            overlayWindow = controller.window
            controller.show()
            return
        }
        screenRegionEditor = nil
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let available = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 800)
        // Keep the single-row annotation controls visible without introducing a second row.
        let displayWidth = min(available.width - 24,
                               max(AnnotationToolbar.minimumWidth, min(rect.width + 24, 1000)))
        let displayHeight = min(max(210, rect.height), max(210, available.height - 280))
        let baseHeight = displayHeight + 72
        let panel = CaptureEditorWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: displayWidth, height: baseHeight)),
                             styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.title = "NookPup · \(L("悬浮编辑"))"
        panel.minSize = NSSize(width: min(AnnotationToolbar.minimumWidth, available.width - 24), height: 260)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .floating
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: CaptureEditorView(model: model, floating: true)
                .environment(\.locale, model.appLanguage.locale)
        )
        panel.setFrameOrigin(CGPoint(x: available.midX - displayWidth / 2, y: available.midY - baseHeight / 2))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        overlayWindow = panel
    }

    private func beginRecording(_ format: RecordingFormat, region: CGRect? = nil) {
        guard recordingSession == nil, recordingClipboardTask == nil else { return }
        captureController?.cancel()
        let wasEditorVisible = editorWindow?.isVisible == true
        let wasOverlayVisible = overlayWindow?.isVisible == true
        let restore = { [weak self] in
            guard let self else { return }
            if wasEditorVisible { self.editorWindow?.makeKeyAndOrderFront(nil) }
            if wasOverlayVisible { self.overlayWindow?.makeKeyAndOrderFront(nil) }
        }
        model.activity = "拖动选择\(format.title)录制区域 · Esc 取消"
        window?.orderOut(nil)
        editorWindow?.orderOut(nil)
        overlayWindow?.orderOut(nil)
        if useCurrentRegion(region, action: { [weak self] screen, local, global in
            self?.startRecording(screen: screen, local: local, global: global, format: format, autoStart: true)
        }) { return }
        let controller = SelectionCaptureController(onComplete: { _, _ in }, onCancel: { [weak self] in
            self?.model.activity = nil
            self?.model.notice = "已取消录制区域选择"
            restore()
        }, onError: { [weak self] error in
            self?.model.captureFailed(error)
            restore()
        })
        controller.onRegionSelected = { [weak self] screen, local, global in
            self?.startRecording(screen: screen, local: local, global: global, format: format)
        }
        captureController = controller
        controller.targetApplication = captureTargetApplication()
        captureReturnApplication = controller.targetApplication
        controller.begin()
    }

    private func beginScrollCapture(_ mode: ScrollCaptureMode, region: CGRect? = nil) {
        guard scrollCapture == nil, recordingSession == nil, recordingClipboardTask == nil else { return }
        if mode == .automatic && !CGPreflightPostEventAccess() {
            let alert = NSAlert()
            alert.messageText = "自动滚动需要辅助功能权限"
            alert.informativeText = "自动长截图需要向选中窗口发送滚轮操作。手动长截图只需已有的屏幕访问权限。"
            alert.addButton(withTitle: "使用手动长截图")
            alert.addButton(withTitle: "请求自动滚动权限")
            alert.addButton(withTitle: "取消")
            switch alert.runModal() {
            case .alertFirstButtonReturn: beginScrollCapture(.manual, region: region)
            case .alertSecondButtonReturn:
                if CGRequestPostEventAccess() { beginScrollCapture(.automatic, region: region) }
                else {
                    model.notice = "请在系统设置的「辅助功能」中允许 NookPup，再选择自动长截图。"
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            default: break
            }
            return
        }
        captureController?.cancel()
        if model.draftImage != nil { model.discardDraft() }
        model.activity = "选择长截图区域"
        let wasEditorVisible = editorWindow?.isVisible == true
        let wasOverlayVisible = overlayWindow?.isVisible == true
        let restore = { [weak self] in
            guard let self else { return }
            if wasEditorVisible { self.editorWindow?.makeKeyAndOrderFront(nil) }
            if wasOverlayVisible { self.overlayWindow?.makeKeyAndOrderFront(nil) }
        }
        window?.orderOut(nil)
        editorWindow?.orderOut(nil)
        overlayWindow?.orderOut(nil)
        if useCurrentRegion(region, action: { [weak self] screen, local, global in
            self?.startScrollCapture(mode, screen: screen, local: local, global: global, restore: {})
        }) { return }
        let selection = SelectionCaptureController(onComplete: { _, _ in }, onCancel: { [weak self] in
            self?.model.activity = nil
            restore()
        }, onError: { [weak self] error in
            restore()
            self?.model.captureFailed(error)
        })
        selection.onRegionSelected = { [weak self] screen, local, global in
            self?.startScrollCapture(mode, screen: screen, local: local, global: global, restore: restore)
        }
        captureController = selection
        selection.targetApplication = captureTargetApplication()
        captureReturnApplication = selection.targetApplication
        selection.begin()
    }

    private func startScrollCapture(_ mode: ScrollCaptureMode, screen: NSScreen, local: CGRect,
                                    global: CGRect, restore: @escaping () -> Void) {
        let capture = ScrollCaptureController(mode: mode)
        scrollCapture = capture
        model.activity = mode.title
        capture.onComplete = { [weak self] image in
            guard let self else { return }
            self.closeScrollCapture()
            self.model.acceptImage(image, title: "长截图 \(Date().formatted(.dateTime.hour().minute()))",
                                   inlineRect: global, presentEditor: false)
            self.model.confirmDraft()
        }
        capture.onCancel = { [weak self] in
            self?.closeScrollCapture()
            self?.model.notice = "已取消长截图"
            restore()
        }
        capture.onError = { [weak self] error in
            self?.closeScrollCapture()
            restore()
            self?.model.captureFailed(error)
        }
        let border = NSWindow(contentRect: global, styleMask: [.borderless], backing: .buffered, defer: false)
        border.backgroundColor = .clear
        border.isOpaque = false
        border.ignoresMouseEvents = true
        border.level = .floating
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.contentView = NSHostingView(rootView: Rectangle().stroke(Color.green.opacity(0.8), lineWidth: 2))
        border.orderFront(nil)
        scrollBorder = border
        let visible = screen.visibleFrame
        let panelSize = CGSize(width: 260, height: min(560, visible.height - 24))
        let panel = ScrollCapturePanel(contentRect: CGRect(origin: .zero, size: panelSize),
                                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "NookPup · \(L(mode.title))"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: ScrollCaptureStatusView(capture: capture)
                .environment(\.locale, AppLanguage.stored.locale)
        )
        let sideX = global.maxX + 8 + panelSize.width <= visible.maxX ? global.maxX + 8 :
            (global.minX - panelSize.width - 8 >= visible.minX ? global.minX - panelSize.width - 8 :
                visible.maxX - panelSize.width - 8)
        panel.setFrameOrigin(CGPoint(x: sideX, y: max(visible.minY + 8, min(global.maxY - panelSize.height,
                                                                          visible.maxY - panelSize.height - 8))))
        // Keep the finish control reachable even while the target app remains active.
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        scrollPanel = panel
        let keyID = EventHotKeyID(signature: OSType(0x53484747), id: 3)
        RegisterEventHotKey(53, 0, keyID, GetApplicationEventTarget(), 0, &scrollEscapeHotkey)
        capture.start(screen: screen, local: local, global: global)
    }

    private func closeScrollCapture() {
        if let scrollEscapeHotkey { UnregisterEventHotKey(scrollEscapeHotkey) }
        scrollEscapeHotkey = nil
        scrollPanel?.orderOut(nil)
        scrollPanel?.contentView = nil
        scrollPanel = nil
        scrollBorder?.orderOut(nil)
        scrollBorder = nil
        scrollCapture = nil
        model.activity = nil
    }

    private func startRecording(screen: NSScreen, local: CGRect, global: CGRect, format: RecordingFormat, autoStart: Bool = false) {
        let targetApplication = captureReturnApplication ?? captureTargetApplication()
        let recorder = ScreenRecorder()
        let session = RecordingSession(format: format)
        self.recorder = recorder
        recordingSession = session
        model.activity = "录制区域已选中"
        recorder.onStarted = { [weak self] in
            guard let self, self.recordingSession === session else { return }
            session.didStart()
            self.model.screenPermission.captureSucceeded()
            self.model.activity = "正在录制\(format.title)"
        }
        recorder.onPaused = { [weak self] in
            guard let self, self.recordingSession === session else { return }
            session.didPause()
            self.model.activity = "录制已暂停"
        }
        recorder.onFinished = { [weak self] result in
            guard let self, self.recordingSession === session, !session.cancelled else {
                recorder.discardTemporaryMovie()
                return
            }
            self.recordingBorder?.orderOut(nil)
            self.model.activity = nil
            switch result {
            case .success(let url):
                session.didFinish(url)
                _ = session.requestConfirmation()
                self.commitRecording(session)
            case .failure(let error):
                self.cancelRecording()
                if ScreenCaptureService.isPermissionError(error) { self.model.captureFailed(error) }
                else { self.model.errorMessage = "录制失败：\(error.localizedDescription)"; self.showWorkspace() }
            }
        }
        let border = NSWindow(contentRect: global, styleMask: [.borderless], backing: .buffered, defer: false)
        border.backgroundColor = .clear
        border.isOpaque = false
        border.ignoresMouseEvents = true
        border.level = .floating
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        border.contentView = NSHostingView(rootView: Rectangle().stroke(Color.red.opacity(0.8), lineWidth: 3).padding(1))
        border.orderFront(nil)
        recordingBorder = border
        let bar = ScrollCapturePanel(contentRect: CGRect(x: 0, y: 0, width: 400, height: 42),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        bar.title = "NookPup · \(L("录制"))"
        bar.backgroundColor = .clear
        bar.isOpaque = false
        bar.level = .floating
        bar.isMovableByWindowBackground = true
        bar.hidesOnDeactivate = false
        bar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        bar.contentView = NSHostingView(rootView: RecordingStatusView(session: session, recorder: recorder,
            onStart: { [weak self] in
                self?.runRecording(recorder, session: session, screen: screen, local: local,
                                   targetApplication: targetApplication)
            }, onStop: { [weak self] in self?.stopRecording() },
            onPause: { [weak self] in
                guard let self, self.recordingSession === session else { return }
                if session.phase == .paused {
                    self.runRecording(recorder, session: session, screen: screen, local: local,
                                      targetApplication: targetApplication, resume: true)
                } else if session.pause() {
                    self.model.activity = "正在暂停录制…"
                    Task { await recorder.pause() }
                }
            },
            onConfirm: { [weak self] in self?.confirmRecording() },
            onCancel: { [weak self] in self?.cancelRecording() })
            .environment(\.locale, AppLanguage.stored.locale))
        let visible = screen.visibleFrame
        let y = global.minY - 44 >= visible.minY ? global.minY - 44 : min(visible.maxY - 44, global.maxY + 2)
        bar.setFrameOrigin(CGPoint(x: max(visible.minX + 8, min(global.midX - 200, visible.maxX - 408)), y: y))
        bar.makeKeyAndOrderFront(nil)
        recordingWindow = bar
        let keyID = EventHotKeyID(signature: OSType(0x53484747), id: 4)
        RegisterEventHotKey(53, 0, keyID, GetApplicationEventTarget(), 0, &recordingEscapeHotkey)
        if autoStart { runRecording(recorder, session: session, screen: screen, local: local, targetApplication: targetApplication) }
    }

    private func runRecording(_ recorder: ScreenRecorder, session: RecordingSession, screen: NSScreen, local: CGRect,
                              targetApplication: NSRunningApplication?, resume: Bool = false) {
        guard recordingSession === session, resume ? session.resume() : session.begin() else { return }
        model.activity = "正在启动\(session.format.title)录制…"
        recordingStartup = Task {
            do {
                targetApplication?.activate(options: [])
                try await Task.sleep(for: .milliseconds(400))
                if resume { try await recorder.resume() }
                else { try await recorder.start(screen: screen, selection: local, format: session.format) }
            }
            catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, self.recordingSession === session else { return }
                self.cancelRecording()
                if ScreenCaptureService.isPermissionError(error) { self.model.captureFailed(error) }
                else { self.model.errorMessage = "无法开始录制：\(error.localizedDescription)" }
                self.showWorkspace()
            }
        }
    }

    private func stopRecording() {
        guard let recorder, let session = recordingSession, session.stop() else { return }
        Task { await recorder.stop() }
    }

    private func confirmRecording() {
        guard let session = recordingSession, session.requestConfirmation() else { return }
        if session.movieURL != nil { commitRecording(session) }
        else { stopRecording() }
    }

    private func commitRecording(_ session: RecordingSession) {
        guard recordingSession === session, let url = session.movieURL, session.beginCopy() else { return }
        // Committing is the end of the recording UI. Keep the copy task alive,
        // but remove the control bar immediately instead of flashing a status row.
        recordingWindow?.orderOut(nil)
        recordingBorder?.orderOut(nil)
        publishRecording(url, format: session.format, session: session)
    }

    private func showRecordingReview(_ session: RecordingSession) {
        guard recordingSession === session, let bar = recordingWindow else { return }
        var frame = bar.frame
        let visible = bar.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ??
            CGRect(x: 0, y: 0, width: 1000, height: 800)
        frame.size = CGSize(width: 560, height: 390)
        frame.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.minY, visible.maxY - frame.height))
        bar.setFrame(frame, display: true)
        bar.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func cancelRecording() {
        guard let session = recordingSession else { return }
        session.cancel()
        recordingStartup?.cancel()
        recordingClipboardTask?.cancel()
        if let recorder { Task { await recorder.cancel() } }
        closeRecordingWindows()
        model.notice = "已取消录制，未保存文件"
    }

    private func closeRecordingWindows() {
        if let recordingEscapeHotkey { UnregisterEventHotKey(recordingEscapeHotkey) }
        recordingEscapeHotkey = nil
        recordingStartup = nil
        recordingWindow?.orderOut(nil)
        recordingWindow?.contentView = nil
        recordingWindow = nil
        recordingBorder?.orderOut(nil)
        recordingBorder = nil
        recordingSession = nil
        recorder = nil
        model.activity = nil
    }

    @objc private func copyLastRecording() {
        guard let pending = pendingRecordings.first else { return }
        copyRecordingToClipboard(pending)
    }

    private func copyRecordingToClipboard(_ pending: RecordingDraft) {
        guard !model.isBusy, recordingClipboardTask == nil else { return }
        publishRecording(pending.url, format: pending.format)
    }

    private func publishRecording(_ source: URL, format: RecordingFormat, session: RecordingSession? = nil) {
        guard recordingClipboardTask == nil else { return }
        model.activity = format == .gif ? "正在生成 GIF 并复制…" : "正在复制视频…"
        let currentRecorder = recorder
        recordingClipboardTask = Task { @MainActor in
            var destination: URL?
            var published = false
            defer {
                if let destination, !published { clipboard.discardUnpublishedMedia(destination) }
                recordingClipboardTask = nil
                if session == nil { model.activity = nil }
            }
            do {
                let output = try clipboard.makeMediaURL(fileExtension: format.fileExtension)
                destination = output
                if format == .gif { try await RecordingExport.gif(from: source, to: output) }
                else {
                    try await Task.detached(priority: .userInitiated) {
                        try Task.checkCancellation()
                        let cloned = source.path.withCString { sourcePath in
                            output.path.withCString { outputPath in
                                clonefile(sourcePath, outputPath, 0)
                            }
                        }
                        if cloned != 0 {
                            try FileManager.default.copyItem(at: source, to: output)
                        }
                    }.value
                }
                try Task.checkCancellation()
                if let session {
                    guard recordingSession === session, !session.cancelled else { return }
                }
                try clipboard.copyMedia(output)
                published = true
                if let session {
                    session.didCommit()
                    currentRecorder?.discardTemporaryMovie()
                    closeRecordingWindows()
                    restoreCaptureApplication()
                }
                model.notice = "已复制\(format.title)到剪贴板，可按 ⌘V 粘贴。"
            } catch is CancellationError {
                return
            } catch {
                if let session, recordingSession === session, !session.cancelled {
                    model.activity = nil
                    session.failCopy(error)
                    showRecordingReview(session)
                } else if session == nil {
                    clipboard.reportCopyError(error)
                    model.notice = "复制录制失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// Pins an image. With a capture rect (global points) the pin lands exactly
    /// where the region was taken, at 100%, as Snipaste and PixPin do.
    private func pin(_ image: NSImage, at captureRect: CGRect?) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let ratio = image.size.height / image.size.width
        let screen = captureRect.flatMap { rect in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } ??
                NSScreen.screens.first { $0.frame.intersects(rect) }
        } ?? NSScreen.main
        let frame: CGRect
        let baseWidth: CGFloat
        if let captureRect, let screen {
            frame = CaptureSelectionGeometry.clamped(captureRect, to: screen.frame)
            baseWidth = captureRect.width
        } else {
            // Rendered images are measured in pixels; show them at their
            // actual size, capped to fit the screen.
            let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 750)
            let scale = max(1, screen?.backingScaleFactor ?? 2)
            let natural = CGSize(width: image.size.width / scale, height: image.size.height / scale)
            let fit = min(1, visible.width * 0.6 / natural.width, visible.height * 0.6 / natural.height)
            let size = CGSize(width: max(40, natural.width * fit), height: max(40, natural.width * fit) * ratio)
            frame = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                           width: size.width, height: size.height)
            baseWidth = natural.width
        }
        let panel = PinnedPanel(contentRect: frame,
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        func title(for width: CGFloat) -> String {
            "NookPup · \(L("贴图")) · \(Int((width / max(1, baseWidth) * 100).rounded()))%"
        }
        panel.title = title(for: frame.width)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.delegate = self
        let view = PinnedImageView(image: image)
        view.onZoom = { [weak panel] scale, anchor in
            guard let panel else { return }
            Self.resizePinnedWindow(panel, imageAspectRatio: ratio, scale: scale, anchor: anchor)
            panel.title = title(for: panel.contentRect(forFrameRect: panel.frame).width)
        }
        view.onCopy = { [weak self] in _ = try? self?.clipboard.copyImage(image) }
        panel.contentView = view
        panel.contentAspectRatio = NSSize(width: image.size.width, height: image.size.height)
        panel.setFrame(frame, display: false)
        pinnedWindows.append(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(view)
    }

    private func closePinnedWindow(_ window: NSWindow) {
        pinnedWindows.removeAll { $0 === window }
        window.orderOut(nil)
        window.close()
    }

    private static func resizePinnedWindow(_ panel: NSWindow, imageAspectRatio: CGFloat,
                                           scale: CGFloat, anchor: CGPoint) {
        let currentContent = panel.contentRect(forFrameRect: panel.frame)
        guard currentContent.width > 0, currentContent.height > 0 else { return }
        let screen = panel.screen ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let chromeHeight = max(0, panel.frame.height - currentContent.height)
        let targetSize = PinnedWindowGeometry.resizedContentSize(
            current: currentContent.size,
            imageAspectRatio: imageAspectRatio,
            scale: scale,
            chromeHeight: chromeHeight,
            visibleFrameSize: visibleFrame.size
        )
        let frame = PinnedWindowGeometry.anchoredFrame(
            currentFrame: panel.frame,
            currentContentSize: currentContent.size,
            targetContentSize: targetSize,
            anchorInContent: anchor,
            chromeHeight: chromeHeight,
            visibleFrame: visibleFrame
        )
        panel.setFrame(frame, display: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow else { return }
        pinnedWindows.removeAll { $0 === closed }
        if closed === editorWindow { model.closeEditor() }
    }
}

private final class PinnedPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            close()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

private final class PinnedImageView: NSView {
    private let image: NSImage
    private var imageAlpha: CGFloat = 1
    private var isHovering = false
    private var trackingAreaReference: NSTrackingArea?
    private var drag = ManualWindowDrag()
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    var onCopy: (() -> Void)?

    private lazy var closeButton: NSButton = controlButton(
        symbol: "xmark", label: L("关闭贴图"), action: #selector(closePinnedImage)
    )
    private lazy var opacityButton: NSButton = controlButton(
        symbol: "circle.lefthalf.filled", label: L("设置贴图透明度"), action: #selector(toggleOpacityControls)
    )
    private lazy var opacityLabel: NSTextField = {
        let label = NSTextField(labelWithString: "100%")
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        label.textColor = .white
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return label
    }()
    private lazy var opacitySlider: NSSlider = {
        let slider = NSSlider(value: 1, minValue: 0.2, maxValue: 1, target: self,
                              action: #selector(changeOpacity(_:)))
        slider.controlSize = .small
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 72).isActive = true
        slider.setAccessibilityLabel(L("贴图透明度"))
        return slider
    }()
    private lazy var opacityPanel: NSView = {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        panel.layer?.cornerRadius = 9
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        panel.layer?.borderWidth = 1
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        let stack = NSStackView(views: [opacityLabel, opacitySlider])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: panel.centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: 124),
            panel.heightAnchor.constraint(equalToConstant: 34)
        ])
        return panel
    }()

    init(image: NSImage) {
        self.image = image
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("NookPup · \(L("贴图"))")
        addSubview(closeButton)
        addSubview(opacityButton)
        addSubview(opacityPanel)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
            opacityButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            opacityButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            opacityButton.widthAnchor.constraint(equalToConstant: 28),
            opacityButton.heightAnchor.constraint(equalToConstant: 28),
            opacityPanel.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 6),
            opacityPanel.trailingAnchor.constraint(equalTo: closeButton.trailingAnchor)
        ])
        updateControlVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The first click on a pin behind another app's window must start a
    /// drag instead of only activating NookPup.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            window?.close()
            return
        }
        super.keyDown(with: event)
    }

    override func accessibilityChildren() -> [Any]? {
        [closeButton, opacityButton, opacitySlider]
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A small radius keeps the captured corners visible.
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: bounds, from: .zero, operation: .sourceOver,
                   fraction: imageAlpha, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.13).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateControlVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateControlVisibility()
    }

    override func mouseDown(with event: NSEvent) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        if let window { drag.begin(event, window: window) }
    }

    override func mouseDragged(with event: NSEvent) {
        if let window { drag.drag(event, window: window) }
    }

    override func mouseUp(with event: NSEvent) { drag.end() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: L("复制图片"), action: #selector(copy(_:)), keyEquivalent: "c")
        copy.target = self
        menu.addItem(copy)
        menu.addItem(.separator())
        let close = NSMenuItem(title: L("关闭贴图"), action: #selector(closePinnedImage), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        return menu
    }

    /// ⌘C copies the pinned image (sent through Edit > Copy).
    @objc func copy(_ sender: Any?) { onCopy?() }

    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > 0.001 else { return }
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.012 : 0.12
        let delta = min(0.35, max(-0.35, event.scrollingDeltaY * sensitivity))
        onZoom?(exp(delta), event.locationInWindow)
    }

    override func magnify(with event: NSEvent) {
        onZoom?(1 + min(0.35, max(-0.35, event.magnification)), event.locationInWindow)
    }

    private func controlButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.focusRingType = .none
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .white
        button.target = self
        button.action = action
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.58).cgColor
        button.layer?.cornerRadius = 14
        button.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        button.layer?.borderWidth = 1
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityLabel(label)
        return button
    }

    private func updateControlVisibility() {
        closeButton.alphaValue = isHovering ? 1 : 0
        opacityButton.alphaValue = isHovering ? 1 : 0
        closeButton.isEnabled = isHovering
        opacityButton.isEnabled = isHovering
        if !isHovering { opacityPanel.isHidden = true }
    }

    @objc private func closePinnedImage() {
        window?.close()
    }

    @objc private func toggleOpacityControls() {
        opacityPanel.isHidden.toggle()
    }

    @objc private func changeOpacity(_ sender: NSSlider) {
        imageAlpha = CGFloat(sender.doubleValue)
        opacityLabel.stringValue = "\(Int((imageAlpha * 100).rounded()))%"
        needsDisplay = true
        window?.invalidateShadow()
    }
}

final class CaptureEditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        // SwiftUI hover states and tooltips only work when the window forwards
        // mouse-moved events; without this the toolbar showed no hover label.
        acceptsMouseMovedEvents = true
    }
}

