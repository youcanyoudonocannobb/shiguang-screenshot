import Foundation

private struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw CheckFailure(message: message) }
}

private func object(_ value: Any?) throws -> [String: Any] {
    guard let object = value as? [String: Any] else { throw CheckFailure(message: "Expected JSON object") }
    return object
}

@main
struct ConfigurationExportChecks {
    static func fixture(icon: Data? = Data([0, 255, 137, 80])) -> ConfigurationExport {
        ConfigurationExport(settings: .init(
            general: .init(appLanguage: "ja", launchAtLogin: true, showsMenuBarIcon: false,
                           menuBarIconStyle: "custom", customMenuBarIconData: icon),
            screenshot: .init(autoOCR: false, autoTranslate: true, keepHistory: false,
                              autoCleanHistory: false, fillShapes: true),
            translation: .init(provider: "ai", sourceLanguage: "auto", targetLanguage: "en",
                               aiAPI: "openAIChat", aiBaseURL: "http://127.0.0.1:8080/v1",
                               aiModel: "local-model", aiInstructions: "保留术语、引号 \" 和换行\n第二行"),
            clipboard: .init(monitorsSystem: false, retentionDays: 7),
            shortcuts: .init(capture: .init(key: "F12", option: false, shift: false, control: true, command: true),
                             translate: .init(key: "T"), clipboard: .init(key: "V"),
                             clipboardTranslate: .init(key: "C"), selectionTranslate: .init(key: "D"),
                             launcher: .init(key: "SPACE", option: true, shift: false)),
            quickInput: .init(variableNamingStyle: "snake"),
            finderActions: .init(coverage: "selectedFolder", selectedFolderPath: "/Users/test/项目 空间",
                                 menuDepth: 2,
                                 favoriteFolders: [.init(path: "/Users/test/下载", systemTitle: "下载", symbol: "folder")],
                                 openWithApps: [.init(path: "/Applications/示例 App.app", bundleIdentifier: "dev.test.app")])
        ), exportedAt: Date(timeIntervalSince1970: 0), appVersion: "1.6.0", buildNumber: "60")
    }

    static func jsonContract() throws {
        let data = try fixture().encoded()
        let root = try object(JSONSerialization.jsonObject(with: data))
        try require(root["format"] as? String == "dev.shiguang.screenshot.configuration", "Recognizable export format")
        try require(root["schemaVersion"] as? Int == 1, "Versioned schema")
        try require(root["appVersion"] as? String == "1.6.0" && root["buildNumber"] as? String == "60", "App version metadata")
        try require(root["exportedAt"] as? String == "1970-01-01T00:00:00Z", "Portable ISO 8601 date")
        let settings = try object(root["settings"])
        try require(Set(settings.keys) == Set(["general", "screenshot", "translation", "clipboard", "shortcuts", "quickInput", "finderActions"]), "All settings groups exported")
        let general = try object(settings["general"])
        try require(general["showsMenuBarIcon"] as? Bool == false, "Explicit false settings are retained")
        try require(general["appLanguage"] as? String == "ja", "Current language is retained")
        let icon = (general["customMenuBarIconData"] as? String).flatMap { Data(base64Encoded: $0) }
        try require(icon == Data([0, 255, 137, 80]), "Binary custom icon survives JSON encoding")
        let translation = try object(settings["translation"])
        try require(translation["aiInstructions"] as? String == "保留术语、引号 \" 和换行\n第二行", "Unicode, quotes, and newlines survive encoding")
        try require(translation["aiBaseURL"] as? String == "http://127.0.0.1:8080/v1", "Local endpoint is preserved")
        let shortcuts = try object(settings["shortcuts"])
        try require(shortcuts.count == 6, "All six shortcuts are included")
        let decoder = JSONDecoder()
        let capture = try decoder.decode(HotkeySettings.self, from: JSONSerialization.data(withJSONObject: object(shortcuts["capture"])))
        try require(capture == fixture().settings.shortcuts.capture, "Function keys and every modifier survive export")
        let finder = try object(settings["finderActions"])
        try require(finder["selectedFolderPath"] as? String == "/Users/test/项目 空间", "Folder paths preserve spaces and Unicode")
        try require((finder["favoriteFolders"] as? [[String: Any]])?.first?["path"] as? String == "/Users/test/下载", "Favorite folders exported without grants")
        try require((finder["openWithApps"] as? [[String: Any]])?.first?["bundleIdentifier"] as? String == "dev.test.app", "Open-with application identity exported")
        let forbidden: Set<String> = ["aiAPIKey", "apiKey", "bookmark", "folderGrant", "allFoldersID", "records", "entries", "sourceText", "translatedText", "settings.selectedPage"]
        func checkKeys(_ value: Any) throws {
            if let object = value as? [String: Any] {
                try require(forbidden.isDisjoint(with: object.keys), "Secrets, permissions, content, and UI state must be absent")
                for child in object.values { try checkKeys(child) }
            } else if let array = value as? [Any] {
                for child in array { try checkKeys(child) }
            }
        }
        try checkKeys(root)
        let withoutIcon = try object(JSONSerialization.jsonObject(with: fixture(icon: nil).encoded()))
        let noIconGeneral = try object(object(withoutIcon["settings"])["general"])
        try require(noIconGeneral["customMenuBarIconData"] == nil, "Unused custom icon can be absent")
        let filename = ConfigurationExport.suggestedFilename(at: Date(timeIntervalSince1970: 0))
        try require(filename.range(of: #"^NookPup-configuration-\d{4}-\d{2}-\d{2}_\d{6}\.json$"#, options: .regularExpression) != nil, "Timestamped filename is safe across file systems")
    }

    static func fileWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PawShot-ConfigurationExportChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            // Only remove the unique test directory created above.
            if directory.lastPathComponent.hasPrefix("PawShot-ConfigurationExportChecks-"),
               directory.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let destination = directory.appendingPathComponent("配置 备份.json")
        try Data("previous file".utf8).write(to: destination)
        try fixture().write(to: destination)
        try require(Data(contentsOf: destination) == fixture().encoded(), "Existing files are replaced with complete, valid JSON")
        let protectedDirectory = directory.appendingPathComponent("existing-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: protectedDirectory, withIntermediateDirectories: false)
        let sentinel = protectedDirectory.appendingPathComponent("keep.txt")
        let original = Data("must survive".utf8)
        try original.write(to: sentinel)
        var failed = false
        do { try fixture().write(to: protectedDirectory) } catch { failed = true }
        try require(failed, "Invalid destination reports a write failure")
        try require(Data(contentsOf: sentinel) == original, "Failed export preserves existing data")
        let missingParent = directory.appendingPathComponent("missing/config.json")
        failed = false
        do { try fixture().write(to: missingParent) } catch { failed = true }
        try require(failed && !FileManager.default.fileExists(atPath: missingParent.path), "Missing destination fails without leaving a partial file")
    }

    static func main() throws {
        try jsonContract()
        print("PASS: JSON schema, settings, shortcuts, binary icon, Unicode, and excluded data")
        try fileWrites()
        print("PASS: atomic export, overwrite, error propagation, and original data preservation")
    }
}
