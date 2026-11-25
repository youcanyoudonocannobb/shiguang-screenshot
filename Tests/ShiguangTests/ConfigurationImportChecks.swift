import AppKit
import SwiftUI

// Only FinderNameView's compile-time UI dependencies; the test never creates its window.
// Keep the application entry point and the rest of WorkspaceView out of this executable.
enum Palette {
    static let muted = Color.gray
    static let danger = Color.red
    static let background = Color.white
    static let accent = Color.blue
}
typealias StoredState<Value> = SwiftUI.State<Value>

private struct ImportCheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ImportCheckFailure(message: message) }
}

private func expectError(_ expected: ConfigurationFileError, _ message: String,
                         _ operation: () throws -> Void) throws {
    do { try operation() }
    catch let error as ConfigurationFileError {
        try require(error == expected, "\(message): expected \(expected), got \(error)")
        return
    }
    catch { throw ImportCheckFailure(message: "\(message): unexpected \(error)") }
    throw ImportCheckFailure(message: "\(message): invalid configuration was accepted")
}

private func mutate(_ object: [String: Any], at path: [String], value: Any?) -> [String: Any] {
    var result = object
    guard let key = path.first else { return result }
    if path.count == 1 { result[key] = value }
    else { result[key] = mutate(result[key] as? [String: Any] ?? [:], at: Array(path.dropFirst()), value: value) }
    return result
}

/// AppModel still stores AI settings and hotkeys in .standard. This standalone
/// executable has its own process preference domain; restore the exact keys as well.
private final class StandardPreferenceSnapshot {
    private let keys: [String]
    private let values: [String: Any]

    init() {
        let shortcutKeys = ["captureHotkey", "translateHotkey", "clipboardHotkey", "clipboardTranslateHotkey",
                            "selectionTranslateHotkey", "variableNamingHotkey"]
            .flatMap { prefix in ["key", "option", "shift", "control", "command"].map { "\(prefix).\($0)" } }
        keys = shortcutKeys + ["aiAPI", "aiBaseURL", "aiModel", "aiInstructions", "variableNamingStyle",
                               "finderMarkdown.folderGrant", "finderActions.allFoldersID", "finderActions.menuDepth",
                               "finderActions.favoriteFolders", "finderActions.openWithApps"]
        values = Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
    }

    func restore() {
        for key in keys {
            if let value = values[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}

@MainActor
private final class IsolatedEnvironment {
    let root: URL
    let suiteName = "PawShot.ConfigurationImportChecks.\(UUID().uuidString)"
    let defaults: UserDefaults
    let pasteboard: NSPasteboard

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PawShot-ConfigurationImportChecks-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: suiteName)!
        pasteboard = NSPasteboard(name: NSPasteboard.Name("PawShot.ConfigurationImportChecks.\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults.set(false, forKey: "history.autoCleanHistory30Days.v1")
        defaults.set(false, forKey: "clipboard.monitor")
        for api in AITranslationAPI.allCases {
            // No call to loadStoredAIAPIKey may reach the real key store.
            defaults.set(true, forKey: "aiKey.requiresManualEntry.\(api.rawValue)")
        }
    }

    func model(_ name: String) -> AppModel {
        AppModel(historyDirectory: root.appendingPathComponent(name, isDirectory: true),
                 permission: ScreenCapturePermission(preflight: { false }, request: { false }),
                 preferences: defaults,
                 recognizeImage: { _ in throw ImportCheckFailure(message: "OCR must not run during configuration tests") })
    }

    func clipboard(_ name: String) -> ClipboardHistory {
        ClipboardHistory(directory: root.appendingPathComponent(name, isDirectory: true),
                         pasteboard: pasteboard, preferences: defaults)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        pasteboard.releaseGlobally()
        // Verify the sole directory this test created before recursively removing it.
        if root.lastPathComponent.hasPrefix("PawShot-ConfigurationImportChecks-"),
           root.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

@main
@MainActor
struct ConfigurationImportChecks {
    private static func png(side: Int = 24) throws -> Data {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0), let pixels = bitmap.bitmapData else {
            throw ImportCheckFailure(message: "Could not create test icon")
        }
        pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ImportCheckFailure(message: "Could not encode test icon")
        }
        return data
    }

    private static func fixture(icon: Data? = nil, favorites: [ConfigurationExport.FinderActions.FavoriteFolder] = [],
                        apps: [ConfigurationExport.FinderActions.OpenWithApp] = [],
                        folder: String? = nil) throws -> ConfigurationExport {
        ConfigurationExport(settings: .init(
            general: .init(appLanguage: "ja", launchAtLogin: false, showsMenuBarIcon: false,
                           menuBarIconStyle: "custom", customMenuBarIconData: try icon ?? png()),
            screenshot: .init(autoOCR: true, autoTranslate: true, keepHistory: false,
                              autoCleanHistory: false, fillShapes: true),
            translation: .init(provider: "ai", sourceLanguage: "ja", targetLanguage: "en-US",
                               aiAPI: AITranslationAPI.anthropicMessages.rawValue,
                               aiBaseURL: "https://configuration-import.invalid/v1", aiModel: "fixture-model",
                               aiInstructions: "保留术语 \"配置\"\n第二行"),
            clipboard: .init(monitorsSystem: false, retentionDays: 7),
            shortcuts: .init(capture: .init(key: "F12", option: false, shift: false, control: true, command: true),
                             translate: .init(key: "T"), clipboard: .init(key: "V"),
                             clipboardTranslate: .init(key: "C"), selectionTranslate: .init(key: "D"),
                             launcher: .init(key: "Space", option: true, shift: false)),
            quickInput: .init(variableNamingStyle: "snakeCase"),
            finderActions: .init(coverage: "selectedFolder", selectedFolderPath: folder, menuDepth: 1,
                                 favoriteFolders: favorites, openWithApps: apps)
        ), exportedAt: Date(timeIntervalSince1970: 0), appVersion: "1.6.0", buildNumber: "60")
    }

    private static func json(_ configuration: ConfigurationExport) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: configuration.encoded()) as! [String: Any]
    }

    private static func changed(_ root: [String: Any], _ path: [String], _ value: Any?) throws -> ConfigurationExport {
        try ConfigurationExport.decoded(from: JSONSerialization.data(withJSONObject: mutate(root, at: path, value: value)))
    }

    private static func roundTrip(_ environment: IsolatedEnvironment) throws {
        let original = try fixture()
        let decoded = try ConfigurationExport.decoded(from: original.encoded())
        try require(decoded.encoded() == original.encoded(), "v1 JSON decode/encode preserves every setting and metadata")
        let plan = try ConfigurationImport(configuration: decoded)
        try require(plan.appLanguage == .japanese && plan.menuBarIconStyle == .custom, "Plan parses UI settings")
        try require(plan.aiAPI == .anthropicMessages && plan.provider == .ai && plan.namingStyle == .snakeCase,
                    "Plan parses translation and quick input enums")
        try require(plan.configuration.settings.shortcuts.capture.key == "F12", "Function key is retained")
        try require(plan.configuration.settings.general.customMenuBarIconData == original.settings.general.customMenuBarIconData,
                    "PNG custom icon survives Base64 round trip")
        let file = environment.root.appendingPathComponent("配置 备份.json")
        try original.write(to: file)
        try require(ConfigurationExport.read(from: file).encoded() == original.encoded(), "File import matches JSON import")
        let noIcon = try changed(json(original), ["settings", "general", "customMenuBarIconData"], nil)
        let noIconRoot = try json(noIcon)
        for (id, expected) in [("lake", MenuBarIconStyle.lake), ("cat", .system),
                               ("rabbit", .system), ("fox", .system), ("panda", .system)] {
            let backup = try changed(noIconRoot, ["settings", "general", "menuBarIconStyle"], id)
            let legacyPlan = try ConfigurationImport(configuration: backup)
            try require(legacyPlan.menuBarIconStyle == expected, "Legacy icon \(id) resolves without rejecting the backup")
        }
        print("PASS: v1 JSON/file round trip, Unicode, custom icon, enums, and legacy icons")
    }

    private static func invalidFiles(_ environment: IsolatedEnvironment) throws {
        let root = try json(fixture())
        for bad in [Data(), Data("not json".utf8), Data("[]".utf8), Data("null".utf8)] {
            try expectError(.invalidFormat, "Malformed header") { _ = try ConfigurationExport.decoded(from: bad) }
        }
        try expectError(.invalidFormat, "Wrong format identifier") {
            _ = try changed(root, ["format"], "unrelated.application")
        }
        for version in [0, -1, 2, 999] {
            try expectError(.unsupportedVersion, "Unsupported schema \(version)") {
                _ = try changed(root, ["schemaVersion"], version)
            }
        }
        try expectError(.invalidFormat, "Missing schema version") { _ = try changed(root, ["schemaVersion"], nil) }
        for field in [["settings"], ["exportedAt"], ["appVersion"], ["buildNumber"],
                      ["settings", "general"], ["settings", "screenshot", "autoOCR"],
                      ["settings", "translation", "aiModel"], ["settings", "clipboard", "retentionDays"],
                      ["settings", "shortcuts", "capture", "option"], ["settings", "finderActions", "favoriteFolders"]] {
            try expectError(.invalidData, "Missing required field \(field.joined(separator: "."))") {
                _ = try changed(root, field, nil)
            }
        }
        for (field, value) in [(["settings", "clipboard", "retentionDays"], "7" as Any),
                               (["settings", "clipboard", "retentionDays"], 7.5 as Any),
                               (["settings", "screenshot", "autoOCR"], 1 as Any),
                               (["settings", "general", "customMenuBarIconData"], "!not-base64!" as Any)] {
            try expectError(.invalidData, "Incorrect JSON field type") { _ = try changed(root, field, value) }
        }
        let oversized = Data(repeating: 32, count: ConfigurationExport.maximumFileSize + 1)
        try expectError(.tooLarge, "Oversized in-memory JSON") { _ = try ConfigurationExport.decoded(from: oversized) }
        let largeFile = environment.root.appendingPathComponent("oversized.json")
        try oversized.write(to: largeFile)
        try expectError(.tooLarge, "Oversized file") { _ = try ConfigurationExport.read(from: largeFile) }
        print("PASS: malformed JSON, format, version, required fields, field types, and file-size limit")
    }

    private static func invalidValues() throws {
        let root = try json(fixture())
        let invalid: [([String], Any, String)] = [
            (["general", "appLanguage"], "unknown", "界面语言"),
            (["general", "menuBarIconStyle"], "unknown", "菜单栏图标"),
            (["translation", "provider"], "unknown", "翻译引擎"),
            (["translation", "aiAPI"], "unknown", "AI 接口"),
            (["quickInput", "variableNamingStyle"], "unknown", "默认变量格式"),
            (["finderActions", "coverage"], "unknown", "操作范围"),
            (["finderActions", "menuDepth"], 0, "菜单层级"),
            (["finderActions", "menuDepth"], 3, "菜单层级"),
            (["clipboard", "retentionDays"], -1, "剪贴板保留天数"),
            (["clipboard", "retentionDays"], 0, "剪贴板保留天数"),
            (["clipboard", "retentionDays"], 365, "剪贴板保留天数"),
            (["translation", "sourceLanguage"], "", "翻译语言"),
            (["translation", "targetLanguage"], "auto", "翻译语言"),
            (["translation", "targetLanguage"], "../en", "翻译语言"),
            (["translation", "aiBaseURL"], "file:///tmp/model", "AI 接口地址"),
            (["translation", "aiBaseURL"], "https://user:password@example.invalid", "AI 接口地址"),
            (["translation", "aiBaseURL"], "https:///", "AI 接口地址"),
            (["translation", "aiBaseURL"], "http://remote.invalid/v1", "AI 接口地址"),
            (["translation", "aiBaseURL"], "https://example.invalid/v1?API_Key=excluded", "AI 接口地址"),
            (["finderActions", "selectedFolderPath"], "relative/folder", "超级右键"),
            (["finderActions", "selectedFolderPath"], "/tmp/bad\0path", "超级右键")
        ]
        for (path, value, field) in invalid {
            try expectError(.invalidValue(field), "Invalid \(path.joined(separator: "."))") {
                _ = try ConfigurationImport(configuration: changed(root, ["settings"] + path, value))
            }
        }
        for path in [["favoriteFolders"], ["openWithApps"]] {
            let item: [String: Any] = path[0] == "favoriteFolders"
                ? ["path": "relative", "symbol": "folder"] : ["path": "relative.app"]
            try expectError(.invalidValue("超级右键"), "Relative Finder item path") {
                _ = try ConfigurationImport(configuration: changed(root, ["settings", "finderActions"] + path, [item]))
            }
        }
        let manyFolders = Array(repeating: ["path": "/no-such-folder", "symbol": "folder"], count: 1_001)
        try expectError(.invalidValue("超级右键"), "Oversized Finder list") {
            _ = try ConfigurationImport(configuration: changed(root, ["settings", "finderActions", "favoriteFolders"], manyFolders))
        }
        for invalidIcon in [Data("not-an-image".utf8), Data(repeating: 0, count: 1_024 * 1_024 + 1), try png(side: 513)] {
            try expectError(.invalidValue("自定义图标"), "Invalid/oversized custom image") {
                _ = try ConfigurationImport(configuration: fixture(icon: invalidIcon))
            }
        }
        try expectError(.invalidValue("自定义图标"), "Custom style without icon") {
            _ = try ConfigurationImport(configuration: changed(root, ["settings", "general", "customMenuBarIconData"], nil))
        }
        let capture = try json(fixture())["settings"] as! [String: Any]
        let shortcuts = capture["shortcuts"] as! [String: Any]
        var duplicate = shortcuts["capture"] as! [String: Any]
        duplicate["key"] = "f12"
        let duplicatePlan = try ConfigurationImport(configuration: changed(root, ["settings", "shortcuts", "translate"], duplicate))
        try require(duplicatePlan.hasConflictingShortcuts, "Duplicate shortcuts can be restored with a conflict warning")
        var noModifier = ["key": "Q", "option": false, "shift": false, "control": false, "command": false] as [String: Any]
        try expectError(.invalidValue("快捷键"), "Shortcut without modifiers") {
            _ = try ConfigurationImport(configuration: changed(root, ["settings", "shortcuts", "capture"], noModifier))
        }
        noModifier["option"] = true
        for key in ["", "NotAKey", "F99"] {
            noModifier["key"] = key
            try expectError(.invalidValue("快捷键"), "Unknown shortcut key \(key)") {
                _ = try ConfigurationImport(configuration: changed(root, ["settings", "shortcuts", "capture"], noModifier))
            }
        }
        for parameter in ["key", "API_KEY", "token", "access_token"] {
            let sensitive = try changed(root, ["settings", "translation", "aiBaseURL"], "https://example.invalid/v1?\(parameter)=excluded")
            try expectError(.invalidValue("AI 地址中包含凭据，请移除后再导出"), "Secrets in URLs cannot be exported") {
                _ = try sensitive.encoded()
            }
        }
        _ = try ConfigurationImport(configuration: changed(root, ["settings", "translation", "aiBaseURL"], "http://127.0.0.1:8080/v1"))
        print("PASS: invalid values, URL credentials, unmodified/unknown shortcuts rejected; duplicate shortcuts warned")
    }

    private static func finderPlans(_ environment: IsolatedEnvironment) throws {
        let existing = environment.root.appendingPathComponent("目录 空间", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let app = environment.root.appendingPathComponent("Fixture.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let appURL = app.deletingLastPathComponent()
        let missing = environment.root.appendingPathComponent("missing", isDirectory: true)
        let missingApp = environment.root.appendingPathComponent("Missing.app")
        let missingFolders: [ConfigurationExport.FinderActions.FavoriteFolder] = [.init(path: missing.path, systemTitle: nil, symbol: "folder")]
        let missingApps: [ConfigurationExport.FinderActions.OpenWithApp] = [.init(path: missingApp.path, bundleIdentifier: nil)]
        let allInvalid = try ConfigurationImport(configuration: fixture(favorites: missingFolders, apps: missingApps, folder: missing.path))
        try require(allInvalid.favoriteFolders == nil && allInvalid.openWithApps == nil && allInvalid.unavailableItemCount == 2,
                    "Entirely unavailable groups yield nil so applying can preserve local lists")
        let mixed = try ConfigurationImport(configuration: fixture(
            favorites: [.init(path: existing.path, systemTitle: "测试", symbol: "folder"),
                        .init(path: existing.path + "/.", systemTitle: "重复", symbol: "folder")] + missingFolders,
            apps: [.init(path: appURL.path, bundleIdentifier: nil), .init(path: appURL.path, bundleIdentifier: nil)] + missingApps))
        try require(mixed.favoriteFolders?.count == 1 && mixed.openWithApps?.count == 1 && mixed.unavailableItemCount == 2,
                    "Available items survive; duplicates coalesce; missing items are skipped individually")
        try require(mixed.favoriteFolders?.first?.directory.standardizedFileURL.path == existing.standardizedFileURL.path,
                    "Favorite path preserves Unicode and spaces")
        let empty = try ConfigurationImport(configuration: fixture())
        try require(empty.favoriteFolders?.isEmpty == true && empty.openWithApps?.isEmpty == true,
                    "Explicit empty groups stay empty (distinct from all unavailable)")
        let root = try json(fixture(folder: existing.path))
        var withUnknownAuthorization = mutate(root, at: ["settings", "finderActions", "folderGrant"], value: "untrusted-grant")
        withUnknownAuthorization = mutate(withUnknownAuthorization, at: ["settings", "finderActions", "bookmark"], value: Data("untrusted-bookmark".utf8).base64EncodedString())
        let clean = try ConfigurationExport.decoded(from: JSONSerialization.data(withJSONObject: withUnknownAuthorization))
        let finderJSON = (try json(clean)["settings"] as! [String: Any])["finderActions"] as! [String: Any]
        try require(finderJSON["folderGrant"] == nil && finderJSON["bookmark"] == nil,
                    "Authorization objects are never retained by the configuration DTO")
        let plan = try ConfigurationImport(configuration: clean)
        try require(!Mirror(reflecting: plan).children.contains { ["grant", "bookmark", "folderGrant"].contains($0.label ?? "") },
                    "Import plan has no transferable authorization object")
        print("PASS: unavailable/mixed/empty Finder lists, deduplication, and no restored folder authorization")
    }

    private static func noMutation(_ environment: IsolatedEnvironment) throws {
        let model = environment.model("plan-history")
        let clipboard = environment.clipboard("plan-clipboard")
        model.sourceText = "existing text"
        model.translatedText = "existing translation"
        let beforePreferences = environment.defaults.dictionaryRepresentation() as NSDictionary
        let beforeStandard = UserDefaults.standard.dictionaryRepresentation() as NSDictionary
        let beforeValues = [model.appLanguage.rawValue, model.aiAPI.rawValue, model.aiBaseURL, model.sourceLanguage,
                            model.targetLanguage, model.sourceText, model.translatedText, model.captureHotkey.symbol]
        var callbacks = 0
        model.hotkeysChanged = { callbacks += 1 }
        model.languageChanged = { callbacks += 1 }
        model.statusItemPreferencesChanged = { callbacks += 1 }
        let plan = try ConfigurationImport(configuration: fixture(folder: environment.root.path))
        _ = plan.changesAIEndpoint(in: model)
        try require(beforePreferences.isEqual(environment.defaults.dictionaryRepresentation()), "Plan must not change isolated defaults")
        try require(beforeStandard.isEqual(UserDefaults.standard.dictionaryRepresentation()), "Plan must not change standard preferences")
        try require(beforeValues == [model.appLanguage.rawValue, model.aiAPI.rawValue, model.aiBaseURL, model.sourceLanguage,
                                     model.targetLanguage, model.sourceText, model.translatedText, model.captureHotkey.symbol],
                    "Building a plan must preserve model settings and in-progress text")
        try require(callbacks == 0 && clipboard.entries.isEmpty && model.records.isEmpty, "Plan must not notify or import history")
        // Reject a busy model before Finder restore, login items, or other effects.
        UserDefaults.standard.removeObject(forKey: "finderMarkdown.folderGrant")
        UserDefaults.standard.removeObject(forKey: "finderActions.allFoldersID")
        let finder = FinderActionsCoordinator()
        model.activity = "test busy"
        try expectError(.invalidValue("请等待当前任务完成后再导入"), "Busy model") {
            _ = try plan.apply(to: model, clipboard: clipboard, finderActions: finder)
        }
        try require(finder.selectedFolder == nil && callbacks == 0, "Rejected apply cannot restore folder authorization or notify")
        model.activity = nil
        print("PASS: planning is side-effect free and busy apply rejects before any mutations")
    }

    private static func modelPersistence(_ environment: IsolatedEnvironment) async throws {
        let model = environment.model("apply-history")
        let clipboard = environment.clipboard("apply-clipboard")
        let configuration = try fixture()
        let settings = configuration.settings
        model.applyImportedAIConfiguration(api: .openAIChat, baseURL: "https://initial-import.invalid/v1",
                                           model: "initial-model", instructions: "")
        let marker = "aiKey.requiresManualEntry.\(AITranslationAPI.anthropicMessages.rawValue)"
        let markers = AITranslationAPI.allCases.map { "aiKey.requiresManualEntry.\($0.rawValue)" }
        for key in markers { environment.defaults.removeObject(forKey: key) }
        try require(markers.allSatisfy { !environment.defaults.bool(forKey: $0) }, "All protocols start without manual-key markers")
        var hotkeys = 0
        var status = 0
        var language = 0
        model.hotkeysChanged = { hotkeys += 1 }
        model.statusItemPreferencesChanged = { status += 1 }
        model.languageChanged = { language += 1 }
        // Exercise the exact production settings apply path without Finder publishing or login-item registration.
        let plan = try ConfigurationImport(configuration: configuration)
        try require(plan.changesAIEndpoint(in: model), "Changed API/endpoint is detected before apply")
        plan.applyModelSettings(to: model, clipboard: clipboard)
        try require(!plan.changesAIEndpoint(in: model), "Applied API/endpoint is now current")
        try require(hotkeys == 1 && status == 1 && language == 1, "Each settings callback fires once for a complete update")
        model.performConfigurationUpdate { model.appLanguage = .japanese }
        try require(language == 1 && hotkeys == 2 && status == 2, "Unchanged language does not trigger a language rebuild")
        let restarted = environment.model("restart-history")
        let restartedClipboard = environment.clipboard("restart-clipboard")
        try require(restarted.appLanguage == .japanese && restarted.menuBarIconStyle == .custom && !restarted.showsMenuBarIcon,
                    "General settings persist across models")
        try require(restarted.customMenuBarIconData == settings.general.customMenuBarIconData, "Custom image persists")
        try require(restarted.autoOCR && restarted.autoTranslate && !restarted.keepHistory && !restarted.autoCleanHistory && restarted.fillShapes,
                    "Screenshot settings persist")
        try require(restarted.sourceLanguage == "ja" && restarted.targetLanguage == "en-US" && restarted.translationProvider == .ai,
                    "Translation defaults persist")
        try require(restarted.aiAPI == .anthropicMessages && restarted.aiBaseURL == settings.translation.aiBaseURL &&
                    restarted.aiModel == settings.translation.aiModel && restarted.aiInstructions == settings.translation.aiInstructions,
                    "AI configuration persists without setting any key")
        try require(restarted.variableNamingStyle == .snakeCase && restarted.captureHotkey == settings.shortcuts.capture &&
                    restarted.translateHotkey == settings.shortcuts.translate && restarted.clipboardHotkey == settings.shortcuts.clipboard &&
                    restarted.clipboardTranslateHotkey == settings.shortcuts.clipboardTranslate &&
                    restarted.selectionTranslateHotkey == settings.shortcuts.selectionTranslate &&
                    restarted.variableNamingHotkey == settings.shortcuts.launcher, "All six shortcuts and naming style persist")
        try require(!restartedClipboard.monitorsSystem && restartedClipboard.retentionDays == 7,
                    "Clipboard settings persist in isolated preferences")
        try require(environment.defaults.bool(forKey: marker), "Endpoint change creates and persists a manual-key marker")
        // The marker is checked immediately before the only key-loading call in this test.
        // This returns before scheduling any real key-store access.
        guard environment.defaults.bool(forKey: marker) else {
            throw ImportCheckFailure(message: "Refusing to call key loader without manual-entry marker")
        }
        restarted.loadStoredAIAPIKey()
        await Task.yield()
        try require(restarted.aiAPIKey.isEmpty && environment.defaults.bool(forKey: marker),
                    "A fresh model cannot automatically load an old key after endpoint change")
        try require(markers.allSatisfy { environment.defaults.bool(forKey: $0) },
                    "Import blocks automatic loading for every protocol before any switch")
        for api in AITranslationAPI.allCases where api != .anthropicMessages {
            // Every marker was verified above: protocol switches cannot read real keys.
            restarted.selectAIAPI(api)
            await Task.yield()
            try require(restarted.aiAPIKey.isEmpty && restarted.aiBaseURL == settings.translation.aiBaseURL,
                        "Switching protocols at the imported URL must not load a saved key")
        }
        model.applyImportedAIConfiguration(api: .anthropicMessages, baseURL: "https://second-import.invalid/v1",
                                           model: "second-model", instructions: "")
        try require(environment.defaults.bool(forKey: marker) && model.aiAPIKey.isEmpty, "Same API with a different endpoint still requires manual entry")
        try require(model.records.isEmpty && clipboard.entries.isEmpty && restarted.records.isEmpty,
                    "Configuration updates do not create imported screenshot or clipboard content")
        let automatic = try changed(try json(configuration), ["settings", "translation", "sourceLanguage"], "auto")
        let french = try changed(try json(automatic), ["settings", "translation", "targetLanguage"], "fr")
        try ConfigurationImport(configuration: french).applyModelSettings(to: model, clipboard: clipboard)
        model.translationProvider = .apple
        model.sourceText = "Hello world. This is a translation configuration check."
        // The Apple job is queued for the UI bridge, which is absent in this executable.
        model.requestTranslation()
        try require(model.translationJob?.target == "fr", "Auto-detection must honor an imported target language")
        try require(model.defaultSourceLanguage == "auto" && model.defaultTargetLanguage == "fr",
                    "Runtime language detection must not overwrite exported defaults")
        model.cancelTranslation()
        model.newText()
        try require(model.sourceLanguage == "auto" && model.targetLanguage == "fr", "New text uses restored defaults")
        model.languageEdited(target: "ja")
        try require(model.defaultTargetLanguage == "fr", "Editing a document's language must not change backup defaults")
        model.setDefaultTargetLanguage("es")
        try require(model.defaultTargetLanguage == "es" && model.targetLanguage == "es", "Settings can update the persisted default target")
        print("PASS: settings persistence, six shortcuts, batched callbacks, imported target, and restart/protocol-safe manual AI-key markers")
    }

    static func main() async throws {
        let standard = StandardPreferenceSnapshot()
        defer { standard.restore() }
        let environment = try IsolatedEnvironment()
        defer { environment.cleanUp() }
        try roundTrip(environment)
        try invalidFiles(environment)
        try invalidValues()
        try finderPlans(environment)
        try noMutation(environment)
        try await modelPersistence(environment)
        print("All configuration import checks passed; used only temporary history, a named pasteboard, and isolated preferences.")
        print("Full Finder/login-item apply intentionally not invoked; no shared Finder settings or API-key files accessed.")
    }
}
