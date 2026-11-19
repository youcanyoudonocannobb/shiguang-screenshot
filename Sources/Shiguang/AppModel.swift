import AppKit
import Combine
import NaturalLanguage
import ServiceManagement
import Translation
import UniformTypeIdentifiers

struct TranslationJob: Identifiable {
    let id = UUID()
    let documentID: UUID?
    let text: String
    let source: String
    let target: String
    let provider: TranslationProvider
}

struct OCRTimingPolicy {
    var initialTimeout: Duration = .seconds(120)
    var subsequentTimeout: Duration = .seconds(45)
    var preparationNoticeDelay: Duration = .seconds(3)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var records: [CaptureRecord] = []
    @Published var selectedID: UUID?
    @Published var image: NSImage?
    @Published var sourceText = ""
    @Published var translatedText = ""
    @Published var sourceLanguage = "auto"
    @Published var targetLanguage = "zh-Hans"
    @Published var translationProvider: TranslationProvider {
        didSet { preferences.set(translationProvider.rawValue, forKey: "translationProvider") }
    }
    @Published var aiAPI: AITranslationAPI = AITranslationAPI(
        rawValue: UserDefaults.standard.string(forKey: "aiAPI") ?? ""
    ) ?? .openAIChat {
        didSet {
            UserDefaults.standard.set(aiAPI.rawValue, forKey: "aiAPI")
            if !isApplyingDetectedAIAPI { resetAIModelDiscovery() }
        }
    }
    @Published var variableNamingStyle: VariableNamingStyle = VariableNamingStyle(
        rawValue: UserDefaults.standard.string(forKey: "variableNamingStyle") ?? ""
    ) ?? .lowerCamel {
        didSet { UserDefaults.standard.set(variableNamingStyle.rawValue, forKey: "variableNamingStyle") }
    }
    @Published var appLanguage: AppLanguage {
        didSet {
            preferences.set(appLanguage.rawValue, forKey: "appLanguage")
            languageChanged?()
        }
    }
    @Published var showsMenuBarIcon: Bool {
        didSet {
            preferences.set(showsMenuBarIcon, forKey: "showsMenuBarIcon")
            statusItemPreferencesChanged?()
        }
    }
    @Published var menuBarDogStyle: MenuBarDogStyle {
        didSet {
            preferences.set(menuBarDogStyle.rawValue, forKey: "menuBarDogStyle")
            statusItemPreferencesChanged?()
        }
    }
    @Published var customMenuBarIconData: Data? {
        didSet {
            if let customMenuBarIconData {
                preferences.set(customMenuBarIconData, forKey: "customMenuBarIconData")
            } else {
                preferences.removeObject(forKey: "customMenuBarIconData")
            }
            statusItemPreferencesChanged?()
        }
    }
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginRequiresApproval = false
    @Published private(set) var launchAtLoginMessage: String?
    @Published var aiBaseURL: String = UserDefaults.standard.string(forKey: "aiBaseURL")
        ?? AITranslationAPI(rawValue: UserDefaults.standard.string(forKey: "aiAPI") ?? "")?.defaultBaseURL
        ?? AITranslationConfiguration().baseURL {
        didSet {
            UserDefaults.standard.set(aiBaseURL, forKey: "aiBaseURL")
            resetAIModelDiscovery()
        }
    }
    @Published var aiModel: String = UserDefaults.standard.string(forKey: "aiModel")
        ?? AITranslationAPI(rawValue: UserDefaults.standard.string(forKey: "aiAPI") ?? "")?.defaultModel
        ?? AITranslationConfiguration().model {
        didSet { UserDefaults.standard.set(aiModel, forKey: "aiModel") }
    }
    @Published var aiModels: [AIModelOption] = []
    @Published var aiModelFetching = false
    @Published var aiModelFetchMessage: String?
    @Published var aiInstructions: String = UserDefaults.standard.string(forKey: "aiInstructions") ?? "" {
        didSet { UserDefaults.standard.set(aiInstructions, forKey: "aiInstructions") }
    }
    @Published var aiAPIKey: String = "" {
        didSet {
            guard !isSwitchingAIKey else { return }
            aiKeyLoadGeneration = UUID()
            scheduleAIKeySave()
            resetAIModelDiscovery()
        }
    }
    @Published var aiTesting = false
    @Published var aiTestMessage: String?
    @Published var marks: [Mark] = []
    @Published var tool: MarkTool = .pointer {
        didSet { if tool == .picker, oldValue != .picker { toolBeforePicker = oldValue } }
    }
    private var toolBeforePicker: MarkTool = .pointer
    @Published var markColor = "E45F3C"
    @Published var markLineWidthPoints = AnnotationSizeMetrics.defaultLineWidthPoints
    @Published var numberSizePoints = AnnotationSizeMetrics.defaultNumberSizePoints
    @Published var arrowDoubleHeaded = false
    @Published var textFontSize: Double = 20
    @Published var textPresentation: TextPresentation = .plain
    @Published var maskStyle: MaskStyle = .pixel
    @Published var maskSizePoints = AnnotationSizeMetrics.defaultMaskSizePoints
    @Published var spotlightStrength: SpotlightStrength = .light
    @Published var captureAspectRatio: CaptureAspectRatio = .free
    @Published var fillShapes: Bool {
        didSet { preferences.set(fillShapes, forKey: "fillShapes") }
    }
    @Published var zoomFactor: CGFloat = 1
    @Published var viewportResetID = UUID()
    @Published var recordingReady = false
    @Published var activity: String?
    @Published var notice = "随手一截，让灵感与理解同时发生。"
    @Published var errorMessage: String?
    @Published var translationJob: TranslationJob?
    @Published var showsSettings = false
    @Published var showsPermissionHelp = false
    @Published var screenPermission = ScreenCapturePermission()
    @Published var search = ""
    @Published var activeEditor: String = "editor"
    @Published var editorMode: EditorMode = .annotation
    @Published var draftImage: NSImage?
    @Published var ocrMode: OCRMode = .text
    @Published var ocrTable: OCRTable?
    @Published var ocrFormula = ""
    var finishPendingAnnotation: (() -> Void)?
    private(set) var captureRect: CGRect?
    @Published var autoOCR: Bool {
        didSet { preferences.set(autoOCR, forKey: "autoOCR.v2") }
    }
    @Published var autoTranslate: Bool {
        didSet { preferences.set(autoTranslate, forKey: "autoTranslate") }
    }
    @Published var keepHistory: Bool {
        didSet { preferences.set(keepHistory, forKey: "keepHistory") }
    }
    @Published var autoCleanHistory: Bool {
        didSet {
            preferences.set(autoCleanHistory, forKey: "history.autoCleanHistory30Days.v1")
            if autoCleanHistory { pruneExpiredHistory() }
        }
    }
    @Published var captureHotkey: HotkeySettings = AppModel.loadHotkey(prefix: "captureHotkey", defaultKey: "S") {
        didSet {
            AppModel.saveHotkey(captureHotkey, prefix: "captureHotkey")
            hotkeysChanged?()
        }
    }
    @Published var translateHotkey: HotkeySettings = AppModel.loadHotkey(prefix: "translateHotkey", defaultKey: "T") {
        didSet {
            AppModel.saveHotkey(translateHotkey, prefix: "translateHotkey")
            hotkeysChanged?()
        }
    }
    @Published var clipboardHotkey: HotkeySettings = AppModel.loadHotkey(prefix: "clipboardHotkey", defaultKey: "V") {
        didSet {
            AppModel.saveHotkey(clipboardHotkey, prefix: "clipboardHotkey")
            hotkeysChanged?()
        }
    }
    @Published var clipboardTranslateHotkey: HotkeySettings = AppModel.loadHotkey(prefix: "clipboardTranslateHotkey", defaultKey: "C") {
        didSet {
            AppModel.saveHotkey(clipboardTranslateHotkey, prefix: "clipboardTranslateHotkey")
            hotkeysChanged?()
        }
    }
    @Published var selectionTranslateHotkey: HotkeySettings = AppModel.loadHotkey(prefix: "selectionTranslateHotkey", defaultKey: "D") {
        didSet {
            AppModel.saveHotkey(selectionTranslateHotkey, prefix: "selectionTranslateHotkey")
            hotkeysChanged?()
        }
    }
    @Published var variableNamingHotkey: HotkeySettings = AppModel.loadHotkey(prefix: "variableNamingHotkey", defaultKey: "X") {
        didSet {
            AppModel.saveHotkey(variableNamingHotkey, prefix: "variableNamingHotkey")
            hotkeysChanged?()
        }
    }
    @Published var hotkeyAvailable = true
    var showWindow: (() -> Void)?
    var showWorkspace: (() -> Void)?
    var showEditor: (() -> Void)?
    var showFloatingEditor: (() -> Void)?
    var hideEditor: (() -> Void)?
    var showToolbox: (() -> Void)?
    var showCaptureOverlay: ((NSImage, NSRect) -> Void)?
    var beginSelection: ((Bool) -> Void)?
    var closeCaptureOverlay: (() -> Void)?
    /// Pins the rendered image; the rect is the on-screen capture area in
    /// global points so the pin can appear exactly where it was taken.
    var pinImage: ((NSImage, CGRect?) -> Void)?
    var hotkeysChanged: (() -> Void)?
    var hotkeyCaptureChanged: ((Bool) -> Void)?
    var languageChanged: (() -> Void)?
    var statusItemPreferencesChanged: (() -> Void)?
    var restartApp: (() -> Void)?
    var beginRecording: ((RecordingFormat, CGRect?) -> Void)?
    var saveRecording: (() -> Void)?
    var beginScrollCapture: ((ScrollCaptureMode, CGRect?) -> Void)?
    var showClipboard: (() -> Void)?
    var translateSelection: (() -> Void)?
    var didCopyCapture: (() -> Void)?
    var publishImage: (NSImage) throws -> Void = { image in
        guard let png = image.pngData else { throw LocalError.image }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = image.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([item]) else { throw LocalError.storage("无法写入系统剪贴板。") }
    }
    var publishText: (String) throws -> Void = { text in
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { throw LocalError.storage("无法写入系统剪贴板。") }
    }

    func setHotkeyCaptureActive(_ active: Bool) {
        hotkeyCaptureChanged?(active)
    }
    private(set) var store: HistoryStore?
    private let preferences: UserDefaults
    private let recognizeImage: (CGImage) async throws -> String
    private let ocrTiming: OCRTimingPolicy
    private var hasCompletedOCR = false
    private var ocrTask: Task<Void, Never>?
    private var ocrWatchdog: Task<Void, Never>?
    private var ocrID: UUID?
    private var translationWatchdog: Task<Void, Never>?
    private var aiTranslationTask: Task<Void, Never>?
    private var aiTestTask: Task<Void, Never>?
    private var aiModelFetchTask: Task<Void, Never>?
    private var aiKeyLoadTask: Task<Void, Never>?
    private var aiKeySaveTask: Task<Void, Never>?
    private var aiKeyLoadGeneration = UUID()
    private var isSwitchingAIKey = false
    private var isApplyingDetectedAIAPI = false
    private var undoMarks: [[Mark]] = []
    private var redoMarks: [[Mark]] = []
    private var draftTitle = ""
    var isBusy: Bool { activity != nil }
    enum EditorMode {
        case annotation, recognition, text
    }
    var isTextWorkspace: Bool { editorMode != .annotation }
    var canTranslate: Bool { !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy }
    var aiConfiguration: AITranslationConfiguration {
        AITranslationConfiguration(baseURL: aiBaseURL, model: aiModel,
                                   instructions: aiInstructions, api: aiAPI)
    }
    var aiReady: Bool {
        aiConfiguration.isConfigured &&
            (aiConfiguration.allowsEmptyAPIKey ||
             !aiAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var currentRecord: CaptureRecord? { records.first { $0.id == selectedID } }
    var filteredRecords: [CaptureRecord] {
        search.isEmpty ? records : records.filter {
            $0.title.localizedCaseInsensitiveContains(search) || $0.text.localizedCaseInsensitiveContains(search)
        }
    }

    init(historyDirectory: URL? = nil, permission: ScreenCapturePermission = ScreenCapturePermission(),
         preferences: UserDefaults = .standard,
         recognizeImage: @escaping (CGImage) async throws -> String = OCRService.recognize,
         ocrTiming: OCRTimingPolicy = OCRTimingPolicy()) {
        self.preferences = preferences
        self.recognizeImage = recognizeImage
        self.ocrTiming = ocrTiming
        let initialTranslationProvider: TranslationProvider
        if preferences.bool(forKey: "translationProvider.defaultApple.v1") {
            initialTranslationProvider = TranslationProvider(
                rawValue: preferences.string(forKey: "translationProvider") ?? ""
            ) ?? .apple
        } else {
            initialTranslationProvider = .apple
            preferences.set(TranslationProvider.apple.rawValue, forKey: "translationProvider")
            preferences.set(true, forKey: "translationProvider.defaultApple.v1")
        }
        translationProvider = initialTranslationProvider
        showsMenuBarIcon = preferences.object(forKey: "showsMenuBarIcon") as? Bool ?? true
        appLanguage = AppLanguage(
            rawValue: preferences.string(forKey: "appLanguage") ?? ""
        ) ?? .simplifiedChinese
        let storedMenuBarStyle = MenuBarDogStyle(
            rawValue: preferences.string(forKey: "menuBarDogStyle") ?? ""
        ) ?? .system
        let storedCustomMenuBarIcon = preferences.data(forKey: "customMenuBarIconData")
        menuBarDogStyle = storedMenuBarStyle == .custom && storedCustomMenuBarIcon == nil
            ? .system : storedMenuBarStyle
        customMenuBarIconData = storedCustomMenuBarIcon
        autoOCR = preferences.object(forKey: "autoOCR.v2") as? Bool
            ?? preferences.object(forKey: "autoOCR") as? Bool ?? false
        autoTranslate = preferences.bool(forKey: "autoTranslate")
        keepHistory = preferences.object(forKey: "keepHistory") as? Bool ?? true
        autoCleanHistory = preferences.object(forKey: "history.autoCleanHistory30Days.v1") as? Bool ?? true
        fillShapes = preferences.bool(forKey: "fillShapes")
        screenPermission = permission
        screenPermission.refresh()
        do {
            let store = try HistoryStore(directory: historyDirectory)
            let saved = try store.load()
            self.store = store
            records = saved
            pruneExpiredHistory()
        } catch {
            errorMessage = "读取历史失败：\(error.localizedDescription)。原文件已保留。"
        }
    }

    func refreshLaunchAtLoginState() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginRequiresApproval = false
        case .requiresApproval:
            launchAtLoginEnabled = false
            launchAtLoginRequiresApproval = true
        case .notRegistered, .notFound:
            launchAtLoginEnabled = false
            launchAtLoginRequiresApproval = false
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginRequiresApproval = false
        }
        if launchAtLoginEnabled {
            launchAtLoginMessage = nil
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginMessage = nil
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else {
                    refreshLaunchAtLoginState()
                    return
                }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status != .notRegistered else {
                    refreshLaunchAtLoginState()
                    return
                }
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginMessage = "无法更新登录项：\(error.localizedDescription)"
        }
        refreshLaunchAtLoginState()
        if launchAtLoginRequiresApproval {
            launchAtLoginMessage = "已提交登录项，请在“系统设置 > 通用 > 登录项”中允许 PawShot。"
        }
    }

    func selectAIAPI(_ next: AITranslationAPI) {
        guard next != aiAPI else { return }
        let previous = aiAPI
        if aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            aiBaseURL == previous.defaultBaseURL {
            aiBaseURL = next.defaultBaseURL
        }
        if aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            aiModel == previous.defaultModel {
            aiModel = next.defaultModel
        }
        isSwitchingAIKey = true
        aiAPIKey = ""
        aiAPI = next
        isSwitchingAIKey = false
        aiTestMessage = nil
        resetAIModelDiscovery()
        loadStoredAIAPIKey(for: next)
    }

    func applyDetectedAIAPI(_ next: AITranslationAPI) {
        guard next != aiAPI else { return }
        let key = aiAPIKey
        isApplyingDetectedAIAPI = true
        aiAPI = next
        isApplyingDetectedAIAPI = false
        scheduleAIKeySave(key, for: next)
    }

    func loadStoredAIAPIKey() {
        loadStoredAIAPIKey(for: aiAPI)
    }

    private func loadStoredAIAPIKey(for api: AITranslationAPI) {
        let generation = UUID()
        aiKeyLoadGeneration = generation
        aiKeyLoadTask?.cancel()
        aiKeyLoadTask = Task { [weak self] in
            let key = await Task.detached(priority: .utility) {
                AITranslationKeychain.load(for: api)
            }.value
            guard let self, !Task.isCancelled,
                  self.aiKeyLoadGeneration == generation,
                  self.aiAPI == api else { return }
            self.isSwitchingAIKey = true
            self.aiAPIKey = key
            self.isSwitchingAIKey = false
            self.aiKeyLoadTask = nil
            self.resetAIModelDiscovery()
        }
    }

    private func scheduleAIKeySave(_ value: String? = nil,
                                   for api: AITranslationAPI? = nil) {
        let key = value ?? aiAPIKey
        let target = api ?? aiAPI
        aiKeySaveTask?.cancel()
        aiKeySaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            let message: String? = await Task.detached(priority: .utility) {
                do {
                    try AITranslationKeychain.save(key, for: target)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            if let message { self.errorMessage = message }
            if self.aiAPI == target, self.aiAPIKey == key {
                self.aiKeySaveTask = nil
            }
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func loadHotkey(prefix: String, defaultKey: String) -> HotkeySettings {
        let key = UserDefaults.standard.string(forKey: "\(prefix).key") ?? defaultKey
        let option = UserDefaults.standard.object(forKey: "\(prefix).option") as? Bool ?? true
        let shift = UserDefaults.standard.object(forKey: "\(prefix).shift") as? Bool ?? true
        let control = UserDefaults.standard.object(forKey: "\(prefix).control") as? Bool ?? false
        let command = UserDefaults.standard.object(forKey: "\(prefix).command") as? Bool ?? false
        return HotkeySettings(key: key, option: option, shift: shift, control: control, command: command)
    }

    private static func saveHotkey(_ hotkey: HotkeySettings, prefix: String) {
        UserDefaults.standard.set(hotkey.key, forKey: "\(prefix).key")
        UserDefaults.standard.set(hotkey.option, forKey: "\(prefix).option")
        UserDefaults.standard.set(hotkey.shift, forKey: "\(prefix).shift")
        UserDefaults.standard.set(hotkey.control, forKey: "\(prefix).control")
        UserDefaults.standard.set(hotkey.command, forKey: "\(prefix).command")
    }

    func persistCurrent() {
        guard draftImage == nil, let id = selectedID,
              let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].text = sourceText
        records[index].translation = translatedText
        records[index].sourceLanguage = sourceLanguage
        records[index].targetLanguage = targetLanguage
        records[index].marks = marks
        saveIndex()
    }

    private func saveIndex() {
        do { try store?.save(records) }
        catch { errorMessage = "保存历史失败：\(error.localizedDescription)" }
    }

    func select(_ record: CaptureRecord) {
        guard !isBusy else { return }
        persistCurrent()
        guard let loaded = store?.image(for: record) else {
            errorMessage = "这张截图的本地文件已丢失。"
            return
        }
        selectedID = record.id
        draftImage = nil
        captureRect = nil
        editorMode = .annotation
        image = loaded
        zoomFactor = 1
        sourceText = record.text
        translatedText = record.translation
        sourceLanguage = record.sourceLanguage
        targetLanguage = record.targetLanguage
        marks = record.marks
        undoMarks = []
        redoMarks = []
        tool = .pointer
        notice = "已打开 \(record.title)"
        showEditor?()
    }

    func newText() {
        guard !isBusy else { return }
        persistCurrent()
        selectedID = nil
        draftImage = nil
        captureRect = nil
        errorMessage = nil
        editorMode = .text
        image = nil
        sourceText = ""
        translatedText = ""
        marks = []
        undoMarks = []
        redoMarks = []
        notice = "文字翻译 · 草稿不保存到历史"
        showEditor?()
    }

    func importImage() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp]
        panel.allowsMultipleSelection = false
        panel.message = "选择一张图片，识别其中的文字"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.openImage(url) }
        }
    }

    func openImage(_ url: URL) {
        guard !isBusy else { return }
        guard let image = NSImage(contentsOf: url), let cg = image.cgImageValue,
              cg.width > 0, cg.height > 0 else { errorMessage = LocalError.image.localizedDescription; return }
        acceptImage(image, title: url.deletingPathExtension().lastPathComponent)
    }

    func pasteImage() {
        guard !isBusy else { return }
        guard let image = NSImage(pasteboard: .general) else {
            errorMessage = "剪贴板中没有图片。文字可以直接粘贴到原文输入框。"
            return
        }
        acceptImage(image, title: "剪贴板图片")
    }

    func useDemo() {
        guard !isBusy else { return }
        acceptImage(DemoImage.make(), title: "灵感卡片 · 示例")
    }

    func acceptImage(_ newImage: NSImage, title: String, translate: Bool = false,
                     inlineRect: NSRect? = nil, presentEditor: Bool = true) {
        if isRecognizing { cancelRecognition() }
        if translationJob != nil { cancelTranslation() }
        activity = nil
        errorMessage = nil
        if inlineRect != nil { screenPermission.captureSucceeded() }
        persistCurrent()
        selectedID = nil
        draftImage = newImage
        captureRect = inlineRect
        draftTitle = title
        image = newImage
        editorMode = .annotation
        zoomFactor = 1
        sourceText = ""
        translatedText = ""
        sourceLanguage = "auto"
        targetLanguage = "zh-Hans"
        marks = []
        undoMarks = []
        redoMarks = []
        tool = .pointer
        captureAspectRatio = .free
        notice = "编辑中 · 点击 ✅ 复制到剪贴板"
        guard presentEditor else { return }
        let automatic = inlineRect == nil && (autoTranslate || autoOCR)
        if translate || automatic {
            presentTextWorkspace(translate || autoTranslate ? .text : .recognition)
            recognize(thenTranslate: translate || autoTranslate)
        } else {
            if let inlineRect { showCaptureOverlay?(newImage, inlineRect) }
            else { showEditor?() }
        }
    }

    func updateCaptureRegion(_ newImage: NSImage, rect: CGRect, remap: (Mark) -> Mark) {
        guard draftImage != nil, editorMode == .annotation, !isBusy else { return }
        let mappedMarks = marks.map(remap)
        let mappedUndo = undoMarks.map { $0.map(remap) }
        let mappedRedo = redoMarks.map { $0.map(remap) }
        if mappedMarks != marks { marks = mappedMarks }
        if mappedUndo != undoMarks { undoMarks = mappedUndo }
        if mappedRedo != redoMarks { redoMarks = mappedRedo }
        if image !== newImage { image = newImage }
        if draftImage !== newImage { draftImage = newImage }
        captureRect = rect
        if !sourceText.isEmpty { sourceText = "" }
        if !translatedText.isEmpty { translatedText = "" }
        if zoomFactor != 1 { zoomFactor = 1 }
        let selectionNotice = "调整选区 · 点击 ✅ 复制到剪贴板"
        if notice != selectionNotice { notice = selectionNotice }
    }

    func acceptDraft() {
        guard let newImage = draftImage else { return }
        let title = draftTitle.isEmpty ? "截图 \(Date().formatted(.dateTime.hour().minute()))" : draftTitle
        guard keepHistory else {
            draftImage = nil
            selectedID = nil
            notice = "已确认截图"
            return
        }
        guard let store else {
            errorMessage = "本地存储不可用，截图草稿已保留。请修复存储位置后重试。"
            return
        }
        do {
            var record = try store.add(newImage, title: title)
            record.text = sourceText
            record.translation = translatedText
            record.sourceLanguage = sourceLanguage
            record.targetLanguage = targetLanguage
            record.marks = marks
            var updated = [record] + records
            if autoCleanHistory {
                updated = updated.filter { $0.createdAt >= screenshotRetentionCutoff() }
            }
            let retainedIDs = Set(updated.map(\.id))
            let expired = records.filter { !retainedIDs.contains($0.id) }
            // Commit the index before pruning images so a failed write cannot break existing history.
            do { try store.save(updated) }
            catch {
                try? store.removeImage(record)
                throw error
            }
            records = updated
            selectedID = record.id
            draftImage = nil
            for old in expired { try store.removeImage(old) }
            notice = "已保存到本地"
        } catch { errorMessage = error.localizedDescription }
    }

    func confirmDraft() {
        finishPendingAnnotation?()
        guard draftImage != nil, let output = renderedImage() else { return }
        do { try publishImage(output) }
        catch { errorMessage = "复制失败：\(error.localizedDescription)"; return }
        acceptDraft()
        let historyFailed = draftImage != nil
        if historyFailed { draftImage = nil; selectedID = nil; errorMessage = nil }
        captureRect = nil
        hideEditor?()
        closeCaptureOverlay?()
        notice = historyFailed ? "已复制到剪贴板，截图历史未能保存。" : "已复制到剪贴板，可按 ⌘V 粘贴。"
        didCopyCapture?()
    }

    func discardDraft() {
        guard draftImage != nil || image != nil else { return }
        if isRecognizing { cancelRecognition() }
        if translationJob != nil { cancelTranslation() }
        // Hide both hosts before clearing the image so cancellation cannot expose a text editor.
        hideEditor?()
        closeCaptureOverlay?()
        draftImage = nil
        captureRect = nil
        draftTitle = ""
        image = nil
        selectedID = nil
        sourceText = ""
        translatedText = ""
        marks = []
        undoMarks = []
        redoMarks = []
        tool = .pointer
        captureAspectRatio = .free
        editorMode = .annotation
        errorMessage = nil
        notice = "已取消本次截图"
    }

    func clearDocument() {
        guard !isBusy else { return }
        if isRecognizing { cancelRecognition() }
        if translationJob != nil { cancelTranslation() }
        persistCurrent()
        draftImage = nil
        captureRect = nil
        draftTitle = ""
        image = nil
        selectedID = nil
        sourceText = ""
        translatedText = ""
        ocrTable = nil
        ocrFormula = ""
        marks = []
        undoMarks = []
        redoMarks = []
        errorMessage = nil
        notice = "已清空当前图片"
    }

    func captureCancelled() {
        activity = nil
        errorMessage = nil
        notice = "已取消截图"
    }

    func startTextTranslation() {
        newText()
    }

    func translateSelectedText(_ text: String) {
        guard let text = SelectedTextReader.normalized(text) else { return }
        guard !isBusy else {
            errorMessage = "当前有正在进行的识别、翻译或录制，完成后再使用划词翻译。"
            return
        }
        newText()
        sourceText = text
        translatedText = ""
        sourceLanguage = "auto"
        notice = "划词翻译 · 已读取当前选中的文字"
        requestTranslation()
    }

    func translateClipboard(from pasteboard: NSPasteboard = .general) {
        translateClipboardContent(image: NSImage(pasteboard: pasteboard),
                                  text: pasteboard.string(forType: .string))
    }

    func translateClipboardContent(image clipboardImage: NSImage?, text clipboardText: String?) {
        guard !isBusy else { return }
        if let image = clipboardImage {
            acceptImage(image, title: "剪贴板图片", translate: true)
            return
        }
        if let text = clipboardText?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            newText()
            sourceText = text
            translatedText = ""
            sourceLanguage = "auto"
            requestTranslation()
            return
        }
        errorMessage = "剪贴板中没有可翻译的文字或图片。"
    }

    func closeEditor() {
        if isRecognizing { cancelRecognition() }
        if translationJob != nil { cancelTranslation() }
        if draftImage != nil {
            discardDraft()
            return
        }
        persistCurrent()
        notice = "编辑器已关闭"
        hideEditor?()
        closeCaptureOverlay?()
    }

    func record(_ format: RecordingFormat) {
        guard !isBusy || isRecognizing || translationJob != nil else { return }
        if isRecognizing { cancelRecognition() }
        if translationJob != nil { cancelTranslation() }
        persistCurrent()
        let region = captureRect
        if draftImage != nil { discardDraft() }
        beginRecording?(format, region)
    }

    func recognizeInWindow() {
        guard !isBusy, image != nil else { return }
        finishPendingAnnotation?()
        presentTextWorkspace(.recognition)
        runOCR(mode: ocrMode, thenTranslate: false)
    }

    private func presentTextWorkspace(_ mode: EditorMode) {
        editorMode = mode
        hideEditor?()
        closeCaptureOverlay?()
        showEditor?()
    }

    func translateImage() {
        guard !isBusy else { return }
        finishPendingAnnotation?()
        presentTextWorkspace(.text)
        if sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recognize(thenTranslate: true)
        } else {
            requestTranslation()
        }
    }

    func resetViewport() {
        zoomFactor = 1
        viewportResetID = UUID()
    }

    func captureScrolling(_ mode: ScrollCaptureMode) {
        guard !isBusy || isRecognizing || translationJob != nil else { return }
        if isRecognizing { cancelRecognition() }
        if translationJob != nil { cancelTranslation() }
        persistCurrent()
        beginScrollCapture?(mode, captureRect)
    }

    func capture(translate: Bool = false) {
        guard !isBusy || isRecognizing else { return }
        if isRecognizing { cancelRecognition() }
        // Legacy preflight can report false even when the System Settings switch is on.
        // Let ScreenCaptureKit attempt the user-requested capture and report actual denial.
        // Preserve the current document until a new capture succeeds.
        persistCurrent()
        errorMessage = nil
        activity = "正在截图 · 拖动选择区域，Esc 取消"
        beginSelection?(translate)
    }

    func presentPermissionHelp() {
        showsSettings = true
        showsPermissionHelp = true
        showWindow?()
    }

    func requestPermission() {
        if screenPermission.authorize() { showsPermissionHelp = false }
        else if !screenPermission.requestAccepted { openPermissionSettings() }
        notice = screenPermission.detail
    }

    func checkPermission() {
        refreshPermissionStatus()
        notice = screenPermission.detail
    }

    func refreshPermissionStatus() {
        if screenPermission.refresh() { showsPermissionHelp = false }
    }

    func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
              NSWorkspace.shared.open(url) else {
            errorMessage = "无法打开系统设置。请手动前往“隐私与安全性 → 屏幕与系统音频录制”。"
            return
        }
    }

    func captureFailed(_ error: Error) {
        activity = nil
        if ScreenCaptureService.isPermissionError(error) {
            screenPermission.captureDenied()
            // Do not throw a blocking authorization sheet on every transient
            // ScreenCaptureKit failure. The system switch may already be on;
            // show the settings window with a retry hint instead.
            errorMessage = screenPermission.refresh()
                ? "屏幕访问暂时不可用，请再试一次。"
                : "屏幕访问尚未生效。请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」中确认 PawShot 已开启，然后重启 PawShot。"
            showWindow?()
        } else {
            errorMessage = "截图失败：\(error.localizedDescription)"
            showWindow?()
        }
    }

    func recognize(thenTranslate: Bool = false) {
        runOCR(mode: .text, thenTranslate: thenTranslate)
    }

    func recognizeCurrentMode() {
        runOCR(mode: ocrMode, thenTranslate: false)
    }

    func switchOCRMode(_ mode: OCRMode) {
        guard ocrMode != mode else { return }
        ocrMode = mode
        guard image != nil, !isBusy else { return }
        runOCR(mode: mode, thenTranslate: false)
    }

    private func runOCR(mode: OCRMode, thenTranslate: Bool) {
        guard !isBusy, let cg = renderedImage()?.cgImageValue else { return }
        let id = UUID()
        ocrID = id
        ocrTable = nil
        ocrFormula = ""
        activity = mode == .text ? "正在设备上识别文字…" :
            (mode == .table ? "正在识别表格结构…" : "正在识别公式…")
        ocrTask = Task {
            do {
                let result: String
                switch mode {
                case .text:
                    result = try await recognizeImage(cg)
                case .table:
                    let table = try await OCRTools.table(in: cg)
                    guard ocrID == id else { return }
                    ocrTable = table
                    result = table.markdown
                case .formula:
                    let latex = try await OCRTools.formula(in: cg)
                    guard ocrID == id else { return }
                    ocrFormula = latex
                    result = latex
                }
                guard ocrID == id else { return }
                ocrWatchdog?.cancel()
                ocrWatchdog = nil
                ocrTask = nil
                ocrID = nil
                hasCompletedOCR = true
                if mode == .text { sourceText = result }
                if mode == .table, result.isEmpty { ocrTable = nil }
                if mode == .formula { ocrFormula = result }
                activity = nil
                notice = result.isEmpty
                    ? "没有识别到内容。可以换一张更清晰的图片，或直接输入原文。"
                    : "识别完成 · \(result.count) 个字符"
                if mode == .text { persistCurrent() }
                if thenTranslate && !result.isEmpty { requestTranslation() }
            } catch {
                guard ocrID == id else { return }
                ocrWatchdog?.cancel()
                ocrWatchdog = nil
                ocrTask = nil
                ocrID = nil
                activity = nil
                errorMessage = "\(mode.title)失败：\(error.localizedDescription)"
            }
        }
        let isInitialRecognition = !hasCompletedOCR
        let timeout = isInitialRecognition ? ocrTiming.initialTimeout : ocrTiming.subsequentTimeout
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let modeTitle = mode.title
        ocrWatchdog = Task {
            do {
                if isInitialRecognition && ocrTiming.preparationNoticeDelay < timeout {
                    try await Task.sleep(for: ocrTiming.preparationNoticeDelay)
                    guard ocrID == id else { return }
                    activity = "首次\(modeTitle)仍在进行，请稍候；可取消或开始新截图。"
                }
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch { return }
            guard ocrID == id else { return }
            cancelRecognition()
            errorMessage = "\(modeTitle)耗时过长，已停止等待。可以重试或换一张较小的图片，也可以直接粘贴原文进行翻译。"
        }
    }

    var isRecognizing: Bool { ocrID != nil && activity != nil }

    func cancelRecognition() {
        guard ocrID != nil else { return }
        ocrID = nil
        ocrWatchdog?.cancel()
        ocrTask?.cancel()
        ocrWatchdog = nil
        ocrTask = nil
        activity = nil
        errorMessage = nil
        notice = "已取消文字识别。"
    }

    func requestTranslation() {
        guard canTranslate else { return }
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if editorMode != .text { presentTextWorkspace(.text) }
        var source = sourceLanguage
        if source == "auto" {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            source = recognizer.dominantLanguage?.rawValue ?? "auto"
            sourceLanguage = source
            targetLanguage = source.hasPrefix("zh") ? "en" : "zh-Hans"
        }
        let target = targetLanguage
        let sourceBase = source.split(separator: "-").first
        let targetBase = target.split(separator: "-").first
        if sourceBase == targetBase && source != "auto" {
            errorMessage = "检测到原文与目标语言相同。请调整语言；这个初版不提供简繁转换。"
            return
        }
        let provider = translationProvider
        if provider == .ai {
            guard aiConfiguration.isConfigured else {
                errorMessage = "请先在设置中填写 AI 接口地址和模型名称。"
                return
            }
            guard aiReady else {
                errorMessage = "请先在设置中填写 AI 服务的 API Key。"
                return
            }
        }
        activity = provider == .ai
            ? "正在使用 \(aiAPI.title) 翻译 · \(aiModel)"
            : "正在翻译 · 首次使用可能需要下载语言包"
        let job = TranslationJob(documentID: selectedID, text: text,
                                 source: source, target: target, provider: provider)
        translationJob = job
        translationWatchdog = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            guard translationJob?.id == job.id else { return }
            cancelTranslation()
            errorMessage = job.provider == .ai
                ? "AI 翻译等待超时。请检查网络、接口地址和模型状态后重试。"
                : "系统翻译服务等待超时。若正在下载语言包，请等待下载完成后重试。"
        }
        if provider == .ai {
            startAITranslation(job)
        }
    }

    private func startAITranslation(_ job: TranslationJob) {
        aiTranslationTask?.cancel()
        let configuration = aiConfiguration
        let apiKey = aiAPIKey
        aiTranslationTask = Task { [weak self] in
            do {
                let result = try await AITranslationService().translateWithProtocolFallback(
                    text: job.text,
                    source: job.source,
                    target: job.target,
                    configuration: configuration,
                    apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                self?.applyDetectedAIAPI(result.api)
                self?.finishTranslation(job, text: result.text)
                if result.usedFallback {
                    self?.notice = "翻译完成 · 已自动切换到 \(result.api.title)"
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.failTranslation(job, error: error)
            }
        }
    }

    func finishTranslation(_ job: TranslationJob, text: String) {
        guard translationJob?.id == job.id else { return }
        translationWatchdog?.cancel()
        translatedText = text
        activity = nil
        translationJob = nil
        aiTranslationTask = nil
        notice = job.provider == .ai
            ? "翻译完成 · 由已配置的 AI 服务处理"
            : "翻译完成 · 由 Apple 翻译在设备上处理"
        persistCurrent()
    }

    func failTranslation(_ job: TranslationJob, error: Error) {
        guard translationJob?.id == job.id else { return }
        translationWatchdog?.cancel()
        activity = nil
        translationJob = nil
        aiTranslationTask = nil
        let cocoaError = error as NSError
        if error is CancellationError || (cocoaError.domain == NSCocoaErrorDomain && cocoaError.code == NSUserCancelledError) {
            notice = "翻译已取消。"
        } else {
            errorMessage = job.provider == .ai
                ? "AI 翻译未完成：\(error.localizedDescription)\n请检查接口地址、模型、API Key 和网络连接。"
                : "翻译未完成：\(error.localizedDescription)\n首次使用请联网下载语言包，并确认系统支持所选语言。"
        }
    }

    func cancelTranslation() {
        translationWatchdog?.cancel()
        aiTranslationTask?.cancel()
        aiTranslationTask = nil
        translationJob = nil
        activity = nil
        errorMessage = nil
        notice = "已取消翻译。"
    }

    func testAITranslation() {
        guard !aiTesting else { return }
        guard aiConfiguration.isConfigured else {
            aiTestMessage = "请先填写接口地址和模型名称。"
            return
        }
        guard aiReady else {
            aiTestMessage = "请先填写 API Key。"
            return
        }
        aiTesting = true
        aiTestMessage = "正在连接 AI 服务…"
        let configuration = aiConfiguration
        let apiKey = aiAPIKey
        aiTestTask?.cancel()
        aiTestTask = Task { [weak self] in
            do {
                let result = try await AITranslationService().translateWithProtocolFallback(
                    text: "Hello",
                    source: "en",
                    target: "zh-Hans",
                    configuration: configuration,
                    apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                self?.applyDetectedAIAPI(result.api)
                self?.aiTesting = false
                let prefix = result.usedFallback ? "已自动切换为 \(result.api.title) · " : ""
                self?.aiTestMessage = "\(prefix)连接成功 · 返回“\(result.text.prefix(24))”"
            } catch {
                guard !Task.isCancelled else { return }
                self?.aiTesting = false
                self?.aiTestMessage = error.localizedDescription
            }
        }
    }

    func fetchAIModels() {
        guard !aiModelFetching else { return }
        let configuration = aiConfiguration
        let apiKey = aiAPIKey
        guard !configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            aiModelFetchMessage = "请先填写接口地址。"
            return
        }
        guard configuration.allowsEmptyAPIKey ||
                !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            aiModelFetchMessage = "请先填写 API Key。"
            return
        }

        aiModelFetching = true
        aiModelFetchMessage = "正在获取模型列表…"
        aiModelFetchTask?.cancel()
        aiModelFetchTask = Task { [weak self] in
            do {
                let models = try await AITranslationService().fetchModels(
                    configuration: configuration,
                    apiKey: apiKey
                )
                guard !Task.isCancelled else { return }
                self?.aiModels = models
                self?.aiModelFetching = false
                if self?.aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true,
                   let first = models.first {
                    self?.aiModel = first.id
                }
                self?.aiModelFetchMessage = "已获取 \(models.count) 个模型，可从右侧列表选择。"
            } catch {
                guard !Task.isCancelled else { return }
                self?.aiModels = []
                self?.aiModelFetching = false
                self?.aiModelFetchMessage = error.localizedDescription
            }
        }
    }

    private func resetAIModelDiscovery() {
        aiModelFetchTask?.cancel()
        aiModelFetchTask = nil
        aiModelFetching = false
        aiModels = []
        aiModelFetchMessage = nil
    }

    func sourceEdited(_ value: String) {
        sourceText = value
        translatedText = ""
        persistCurrent()
    }

    func languageEdited(source: String? = nil, target: String? = nil) {
        if let source { sourceLanguage = source }
        if let target { targetLanguage = target }
        translatedText = ""
        persistCurrent()
    }

    func swapTranslationLanguages() {
        guard editorMode == .text else { return }
        var effectiveSource = sourceLanguage
        if effectiveSource == "auto" {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sourceText)
            effectiveSource = recognizer.dominantLanguage?.rawValue ?? "en"
        }
        let previousTarget = targetLanguage
        sourceLanguage = previousTarget
        targetLanguage = effectiveSource == previousTarget
            ? (previousTarget.hasPrefix("zh") ? "en" : "zh-Hans")
            : effectiveSource
        translatedText = ""
        persistCurrent()
    }

    func addMark(_ mark: Mark) {
        undoMarks.append(marks)
        marks.append(mark)
        redoMarks = []
        persistCurrent()
    }

    func beginEditingMark(_ id: UUID) {
        guard marks.contains(where: { $0.id == id }) else { return }
        undoMarks.append(marks)
        redoMarks = []
    }

    func updateMark(_ mark: Mark) {
        guard let index = marks.firstIndex(where: { $0.id == mark.id }) else { return }
        marks[index] = mark
    }

    func finishEditingMark() {
        persistCurrent()
    }

    func deleteMark(_ id: UUID) {
        guard let index = marks.firstIndex(where: { $0.id == id }) else { return }
        undoMarks.append(marks)
        marks.remove(at: index)
        redoMarks = []
        persistCurrent()
    }

    /// Mirrors a selected mark's style in the toolbar so its controls show, and
    /// then edit, that mark. While drawing, the active tool follows the
    /// selection the way CleanShot X and Snipaste do.
    func adoptStyle(of mark: Mark, imagePointSize size: CGSize) {
        let shortestSide = min(size.width, size.height)
        if mark.tool.usesColor, markColor.uppercased() != mark.colorHex.uppercased() {
            markColor = mark.colorHex
        }
        if mark.tool == .rectangle || mark.tool == .ellipse, fillShapes != (mark.filled == true) {
            fillShapes = mark.filled == true
        }
        if mark.tool.usesStroke, let width = mark.lineWidth {
            let points = AnnotationSizeMetrics.points(fromFraction: width, base: shortestSide,
                                                      within: AnnotationSizeMetrics.lineWidthRange)
            if markLineWidthPoints != points { markLineWidthPoints = points }
        }
        if mark.tool == .number, let numberSize = mark.numberSize {
            let points = AnnotationSizeMetrics.points(fromFraction: numberSize, base: shortestSide,
                                                      within: AnnotationSizeMetrics.numberSizeRange)
            if numberSizePoints != points { numberSizePoints = points }
        }
        if mark.tool == .arrow, arrowDoubleHeaded != (mark.arrowDoubleHeaded == true) {
            arrowDoubleHeaded = mark.arrowDoubleHeaded == true
        }
        if mark.tool == .text {
            if let fontSize = mark.fontSize {
                let points = AnnotationSizeMetrics.points(fromFraction: fontSize, base: size.height,
                                                          within: AnnotationSizeMetrics.textSizeRange)
                if textFontSize != points { textFontSize = points }
            }
            let presentation = mark.textPresentation ?? .plain
            if textPresentation != presentation { textPresentation = presentation }
        }
        if mark.tool == .mosaic {
            let style = mark.maskStyle ?? .pixel
            if maskStyle != style { maskStyle = style }
            if let maskSize = mark.maskSize {
                let points = AnnotationSizeMetrics.points(fromFraction: maskSize, base: shortestSide,
                                                          within: AnnotationSizeMetrics.maskSizeRange)
                if maskSizePoints != points { maskSizePoints = points }
            }
        }
        if tool != .pointer, tool != .picker, tool != mark.tool,
           ![.pointer, .picker, .spotlight].contains(mark.tool) {
            tool = mark.tool
        }
    }

    /// The eyedropper returns to the tool it was opened from, so the picked
    /// color can be used (or applied to the selected mark) without re-choosing it.
    func applyPickedColor(_ hex: String) {
        markColor = hex
        tool = toolBeforePicker == .picker ? .pointer : toolBeforePicker
    }

    func undo() {
        guard !isBusy, let previous = undoMarks.popLast() else { return }
        redoMarks.append(marks)
        marks = previous
        persistCurrent()
    }

    var canUndo: Bool { !undoMarks.isEmpty && !isBusy }

    func redo() {
        guard !isBusy, let next = redoMarks.popLast() else { return }
        undoMarks.append(marks)
        marks = next
        persistCurrent()
    }

    var canRedo: Bool { !redoMarks.isEmpty && !isBusy }

    func clearMarks() {
        guard !marks.isEmpty else { return }
        undoMarks.append(marks)
        redoMarks = []
        marks = []
        persistCurrent()
    }

    func renderedImage() -> NSImage? {
        guard let image else { return nil }
        return ImageRenderer.render(image, marks: marks)
    }

    func copyImage() {
        if draftImage != nil {
            confirmDraft()
            return
        }
        guard let output = renderedImage() else { return }
        do { try publishImage(output); notice = "已复制图片（包含标注和遮盖）" }
        catch { errorMessage = "复制失败：\(error.localizedDescription)" }
    }

    func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        do { try publishText(text); notice = "已复制文字" }
        catch { errorMessage = "复制失败：\(error.localizedDescription)" }
    }

    func exportImage() {
        if draftImage != nil {
            notice = "点击 ✅ 复制图片；需要文件时可从截图历史单独导出。"
            return
        }
        guard let output = renderedImage(), let data = output.pngData else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let title = (currentRecord?.title ?? "PawShot")
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(title).png"
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            do {
                try data.write(to: url, options: .atomic)
                Task { @MainActor in self?.notice = "已导出 \(url.lastPathComponent)" }
            } catch {
                Task { @MainActor in self?.errorMessage = "导出失败：\(error.localizedDescription)" }
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func requestPin() {
        finishPendingAnnotation?()
        guard let output = renderedImage(), let pinImage else { return }
        // Read the on-screen area before discarding the draft clears it.
        let pinRect = draftImage != nil ? captureRect : nil
        let wasDraft = draftImage != nil
        if wasDraft { discardDraft() }
        // Create the pinned panel after dismissing the editor so the panel
        // receives key focus and can handle Esc immediately.
        pinImage(output, pinRect)
        if wasDraft { notice = "已钉住到桌面" }
    }

    func delete(_ record: CaptureRecord) {
        guard !isBusy, let store else { return }
        do {
            let updated = records.filter { $0.id != record.id }
            try store.save(updated)
            records = updated
            if selectedID == record.id {
                selectedID = nil
                image = nil
                sourceText = ""
                translatedText = ""
                marks = []
                undoMarks = []
                redoMarks = []
            }
            try store.removeImage(record)
        } catch { errorMessage = "删除失败：\(error.localizedDescription)" }
    }

    func clearHistory() {
        guard !isBusy, let store else { return }
        do {
            let old = records
            try store.save([])
            records = []
            selectedID = nil
            image = nil
            sourceText = ""
            translatedText = ""
            marks = []
            undoMarks = []
            redoMarks = []
            for record in old { try store.removeImage(record) }
            notice = "本地截图历史已清空。"
        } catch { errorMessage = "清理失败：\(error.localizedDescription)" }
    }

    private func screenshotRetentionCutoff(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
    }

    private func pruneExpiredHistory(now: Date = Date()) {
        guard autoCleanHistory, let store, !records.isEmpty else { return }
        let cutoff = screenshotRetentionCutoff(now: now)
        let retained = records.filter { $0.createdAt >= cutoff }
        guard retained.count != records.count else { return }
        let retainedIDs = Set(retained.map(\.id))
        let expired = records.filter { !retainedIDs.contains($0.id) }
        do {
            // Save the new index first so a write failure never deletes still-indexed files.
            try store.save(retained)
            records = retained
            if let selectedID, !retainedIDs.contains(selectedID) {
                self.selectedID = retained.first?.id
                image = nil
                sourceText = ""
                translatedText = ""
                marks = []
                undoMarks = []
                redoMarks = []
            }
            for record in expired { try store.removeImage(record) }
        } catch {
            errorMessage = "截图历史自动清理失败：\(error.localizedDescription)"
        }
    }
}
