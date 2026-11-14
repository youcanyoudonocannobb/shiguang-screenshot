import AppKit
import Carbon
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
    private var window: NSWindow!
    private var editorWindow: NSWindow!
    private var statusItem: NSStatusItem!
    private var pinnedWindows: [NSWindow] = []
    private var captureController: SelectionCaptureController?
    private var overlayWindow: NSWindow?
    private var screenRegionEditor: ScreenRegionEditorController?
    private var preparedCapture: (snapshot: NSImage, screen: NSScreen)?
    private var hotkeys: [EventHotKeyRef] = []
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
    private var clipboardReturnApplication: NSRunningApplication?
    private weak var clipboardReturnWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        window.title = "拾光截图"
        window.toolbarStyle = .unified
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(hex: "FAF9F6")
        window.contentMinSize = NSSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = settingsContentController(
            rootView: SettingsView(model: model, clipboard: clipboard)
        )
        window.center()
        window.setFrameAutosaveName("ShiguangSettingsV3")
        self.window = window
        model.showWindow = { [weak self] in self?.showWorkspace() }
        model.showEditor = { [weak self] in self?.showEditorWindow() }
        model.showWorkspace = { [weak self] in self?.showWorkspace() }
        model.showFloatingEditor = { [weak self] in self?.showFloatingEditor() }
        model.hideEditor = { [weak self] in self?.hideEditorWindow() }
        model.beginSelection = { [weak self] translate in self?.beginSelection(translate: translate) }
        model.showCaptureOverlay = { [weak self] image, rect in self?.showCaptureOverlay(image: image, rect: rect) }
        model.closeCaptureOverlay = { [weak self] in self?.overlayWindow?.orderOut(nil) }
        model.pinImage = { [weak self] image in self?.pin(image) }
        model.restartApp = { [weak self] in self?.restart() }
        model.beginRecording = { [weak self] format, region in self?.beginRecording(format, region: region) }
        model.saveRecording = { [weak self] in self?.copyLastRecording() }
        model.beginScrollCapture = { [weak self] mode, region in self?.beginScrollCapture(mode, region: region) }
        model.showClipboard = { [weak self] in self?.showClipboardWindow() }
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
            if let clipboardWindow = self.clipboardWindow, clipboardWindow.isVisible,
               event.window === clipboardWindow, clipboardWindow.attachedSheet == nil {
                switch event.keyCode {
                case 53: self.closeClipboardWindow(); return nil
                case 125: self.clipboard.moveSelection(1); return nil
                case 126: self.clipboard.moveSelection(-1); return nil
                case 36, 76: self.copySelectedClipboardEntry(); return nil
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
        setupHotkeys()
        model.hotkeysChanged = { [weak self] in self?.rebindHotkeys() }
        clipboard.start()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            model.useDemo()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if captureController?.isActive == true { return false }
        let activeWindows: [NSWindow?] = [clipboardWindow, recordingWindow, scrollPanel, overlayWindow, editorWindow]
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
        copying?.cancel()
        regionAction?.cancel()
        guard let recorder else {
            guard let copying else { return .terminateNow }
            Task { await copying.value; NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        recordingSession?.cancel()
        recordingStartup?.cancel()
        closeRecordingWindows()
        Task {
            await recorder.cancel()
            await copying?.value
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refreshPermissionStatus()
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
        if captureController?.isActive == true { captureController?.cancelByUser() }
        clipboardReturnApplication = NSWorkspace.shared.frontmostApplication
        clipboardReturnWindow = NSApp.keyWindow
        NSApp.activate(ignoringOtherApps: true)
        clipboard.prepareForDisplay()
        if clipboardWindow == nil {
            let panel = ScrollCapturePanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 650),
                styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
            panel.title = "拾光截图 · 剪贴板"
            panel.minSize = NSSize(width: 520, height: 460)
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = NSColor(hex: "FAF9F6")
            panel.contentView = NSHostingView(rootView: ClipboardView(history: clipboard,
                onCopy: { [weak self] entry in self?.copyClipboardEntry(entry) },
                onClose: { [weak self] in self?.closeClipboardWindow() }))
            panel.center()
            clipboardWindow = panel
        }
        clipboardWindow?.makeKeyAndOrderFront(nil)
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

    private func closeClipboardWindow() {
        clipboardWindow?.orderOut(nil)
        if let app = clipboardReturnApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app.activate(options: [])
        } else { clipboardReturnWindow?.makeKeyAndOrderFront(nil) }
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
                model.errorMessage = "无法重启拾光：\(error.localizedDescription)"
                showWorkspace()
            }
        }
    }
    @objc func showEditorWindow() { showEditorWindowInternal() }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
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
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(menuItem("关于拾光截图", action: #selector(about)))
        appMenu.addItem(menuItem("偏好设置…", action: #selector(preferences), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(menuItem("退出拾光截图", action: #selector(quit), key: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "文件")
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
        let clipboardItem = menuItem("剪贴板历史", action: #selector(showClipboardWindow))
        clipboardMenuItem = clipboardItem
        file.addItem(clipboardItem)
        fileItem.submenu = file
        main.addItem(fileItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("撤销文字编辑", Selector(("undo:")), "z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
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
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(menuItem("设置", action: #selector(showWorkspace), key: "1"))
        windowMenu.addItem(menuItem("快速编辑", action: #selector(showEditorWindow)))
        windowMenu.addItem(menuItem("悬浮编辑", action: #selector(showFloatingEditor)))
        windowMenu.addItem(menuItem("剪贴板历史", action: #selector(showClipboardWindow)))
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "拾光截图",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            .credits: NSAttributedString(string: "截取片刻，读懂世界。\n原生 macOS 截图、文字识别与翻译。")
        ])
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        if let image = NSImage(systemSymbolName: "viewfinder.circle", accessibilityDescription: "拾光截图") {
            image.isTemplate = true
            statusItem.button?.image = image
            statusItem.button?.toolTip = "拾光截图 · 截图、识别与剪贴板"
            statusItem.button?.setAccessibilityLabel("拾光截图菜单")
        } else {
            // Keep an actionable entry point even if the symbol asset is unavailable.
            statusItem.button?.title = "拾光"
            statusItem.length = NSStatusItem.variableLength
        }
        let menu = NSMenu()
        menu.addItem(menuItem("区域截图                  \(model.captureHotkey.symbol)",
                              action: #selector(capture), symbol: "viewfinder"))
        menu.addItem(menuItem("截图并翻译              \(model.translateHotkey.symbol)",
                              action: #selector(translateCapture), symbol: "character.bubble"))
        menu.addItem(menuItem("剪贴板历史              \(model.clipboardHotkey.symbol)",
                              action: #selector(showClipboardWindow), symbol: "doc.on.clipboard"))
        menu.addItem(menuItem("翻译剪贴板              \(model.clipboardTranslateHotkey.symbol)",
                              action: #selector(translateClipboard), symbol: "character.book.closed"))
        menu.addItem(.separator())
        menu.addItem(menuItem("录制 MP4 视频…", action: #selector(recordVideo), symbol: "record.circle"))
        menu.addItem(menuItem("录制 GIF 动图…", action: #selector(recordGIF), symbol: "photo.on.rectangle.angled"))
        menu.addItem(recordingDraftMenuItem())
        menu.addItem(menuItem("自动长截图…", action: #selector(scrollAutomatic), symbol: "rectangle.expand.vertical"))
        menu.addItem(menuItem("手动长截图…", action: #selector(scrollManual), symbol: "hand.point.up"))
        menu.addItem(.separator())
        menu.addItem(menuItem("快速编辑", action: #selector(showEditorWindow), symbol: "macwindow"))
        menu.addItem(menuItem("导入图片…", action: #selector(importImage), symbol: "photo.badge.plus"))
        menu.addItem(menuItem("文字翻译", action: #selector(newText), symbol: "text.bubble"))
        menu.addItem(.separator())
        menu.addItem(menuItem("偏好设置…", action: #selector(preferences), symbol: "gearshape"))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出拾光截图", action: #selector(quit), symbol: "power"))
        statusItem.menu = menu
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
                else { delegate.model.capture(translate: id == 2) }
            }
            return noErr
        }, 1, &eventType, pointer, &eventHandler)
        guard status == noErr else { model.hotkeyAvailable = false; return }
        registerHotkeys()
    }

    private func recordingDraftMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "复制之前的录制", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "复制之前的录制")
        menu.delegate = self
        item.submenu = menu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "复制之前的录制" else { return }
        menu.removeAllItems()
        if pendingRecordings.isEmpty {
            let empty = NSMenuItem(title: "没有待保存的录制", action: nil, keyEquivalent: "")
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
            (UInt32(6), model.clipboardTranslateHotkey)
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
        guard let menu = statusItem?.menu, menu.items.count >= 3 else { return }
        menu.items[0].title = "区域截图                  \(model.captureHotkey.symbol)"
        menu.items[1].title = "截图并翻译              \(model.translateHotkey.symbol)"
        menu.items[2].title = "剪贴板历史              \(model.clipboardHotkey.symbol)"
        menu.items[3].title = "翻译剪贴板              \(model.clipboardTranslateHotkey.symbol)"
        clipboardMenuItem?.keyEquivalent = model.clipboardHotkey.carbonModifiers == 0 ? "" : model.clipboardHotkey.key.lowercased()
        clipboardMenuItem?.keyEquivalentModifierMask = model.clipboardHotkey.cocoaModifiers
        clipboardTranslateMenuItem?.keyEquivalent =
            model.clipboardTranslateHotkey.carbonModifiers == 0 ? "" : model.clipboardTranslateHotkey.key.lowercased()
        clipboardTranslateMenuItem?.keyEquivalentModifierMask = model.clipboardTranslateHotkey.cocoaModifiers
    }

    private func rebindHotkeys() {
        for key in hotkeys { UnregisterEventHotKey(key) }
        hotkeys.removeAll()
        registerHotkeys()
    }

    private func showEditorWindowInternal() {
        overlayWindow?.orderOut(nil)
        model.activeEditor = "editor"
        if editorWindow == nil {
            let panel = CaptureEditorWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
            panel.title = "拾光截图 · 快速编辑"
            panel.backgroundColor = NSColor(hex: "FAF9F6")
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: CaptureEditorView(model: model))
            panel.center()
            editorWindow = panel
        }
        let text = model.isTextWorkspace
        if text { window?.orderOut(nil) }
        editorWindow.title = model.editorMode == .recognition ? "拾光截图 · 文字识别" :
            (text ? "拾光截图 · 翻译" : "拾光截图 · 快速编辑")
        editorWindow.minSize = text ? NSSize(width: model.editorMode == .recognition ? 500 : 700,
                                             height: model.editorMode == .recognition ? 340 : 440) :
            NSSize(width: 700, height: 400)
        editorWindow.setContentSize(text ? NSSize(width: model.editorMode == .recognition ? 600 : 860,
                                                  height: model.editorMode == .recognition ? 430 : 520) :
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
        let wasSettingsVisible = window?.isVisible == true
        let restoreWindows = { [weak self] in
            guard let self else { return }
            if wasSettingsVisible { self.window?.makeKeyAndOrderFront(nil) }
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
        // The single-row toolbar needs ~670pt; never open narrower than that or ✔/✘ get clipped.
        let displayWidth = min(available.width - 24, max(700, min(rect.width + 24, 1000)))
        let displayHeight = min(max(210, rect.height), max(210, available.height - 280))
        let baseHeight = displayHeight + 72
        let panel = CaptureEditorWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: displayWidth, height: baseHeight)),
                             styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        panel.title = "拾光截图 · 悬浮编辑"
        panel.minSize = NSSize(width: min(700, available.width - 24), height: 260)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .floating
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CaptureEditorView(model: model, floating: true))
        panel.setFrameOrigin(CGPoint(x: available.midX - displayWidth / 2, y: available.midY - baseHeight / 2))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        overlayWindow = panel
    }

    private func beginRecording(_ format: RecordingFormat, region: CGRect? = nil) {
        guard recordingSession == nil, recordingClipboardTask == nil else { return }
        captureController?.cancel()
        let restore = { [weak self] in
            guard let self else { return }
            if self.model.image != nil { self.showEditorWindowInternal() } else { self.showWorkspace() }
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
        controller.prompt = "拖动选择\(format.title)区域 · 无声录制 · Esc 取消"
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
                    model.notice = "请在系统设置的「辅助功能」中允许拾光，再选择自动长截图。"
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
        let restore = { [weak self] in
            guard let self else { return }
            if self.model.image != nil { self.showFloatingEditor() } else { self.showWorkspace() }
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
        selection.prompt = "\(mode.title)：框选可滚动内容，避开工具栏 · Esc 取消"
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
            self.model.acceptImage(image, title: "长截图 \(Date().formatted(.dateTime.hour().minute()))", inlineRect: global)
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
        panel.title = "拾光截图 · \(mode.title)"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScrollCaptureStatusView(capture: capture))
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
                self.model.notice = "录制草稿 · 点击 ✅ 复制到剪贴板，❌ 放弃"
                if session.confirmRequested { self.commitRecording(session) }
                else { self.showRecordingReview(session) }
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
        bar.title = "拾光截图 · 录制"
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
            onCancel: { [weak self] in self?.cancelRecording() }))
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
                        try FileManager.default.copyItem(at: source, to: output)
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

    private func pin(_ image: NSImage) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let ratio = image.size.height / image.size.width
        let maxSize = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1000, height: 750)
        let width = min(460, maxSize.width * 0.6)
        let height = min(width * ratio, maxSize.height * 0.7)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "拾光贴图 · 关闭以取消置顶"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let view = NSImageView()
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        panel.contentView = view
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        pinnedWindows.append(panel)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow else { return }
        pinnedWindows.removeAll { $0 === closed }
        if closed === editorWindow { model.closeEditor() }
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

