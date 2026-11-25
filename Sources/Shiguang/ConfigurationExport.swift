import Foundation

/// An explicit snapshot of user settings. Never serialize the defaults domain:
/// it also holds authorization bookmarks, migrations, and transient UI state.
enum ConfigurationFileError: Error, Equatable {
    case tooLarge, invalidFormat, unsupportedVersion, invalidData
    case invalidValue(String)
}

struct ConfigurationExport: Codable {
    static let formatIdentifier = "dev.shiguang.screenshot.configuration"
    static let currentSchemaVersion = 1
    static let maximumFileSize = 8 * 1_024 * 1_024
    let format: String
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let buildNumber: String
    let settings: Settings

    struct Settings: Codable {
        let general: General
        let screenshot: Screenshot
        let translation: Translation
        let clipboard: Clipboard
        let shortcuts: Shortcuts
        let quickInput: QuickInput
        let finderActions: FinderActions
    }

    struct General: Codable {
        let appLanguage: String
        let launchAtLogin: Bool
        let showsMenuBarIcon: Bool
        let menuBarIconStyle: String
        /// JSONEncoder represents the normalized image bytes as Base64.
        let customMenuBarIconData: Data?
    }

    struct Screenshot: Codable {
        let autoOCR: Bool
        let autoTranslate: Bool
        let keepHistory: Bool
        let autoCleanHistory: Bool
        let fillShapes: Bool
    }

    struct Translation: Codable {
        let provider: String
        let sourceLanguage: String
        let targetLanguage: String
        let aiAPI: String
        let aiBaseURL: String
        let aiModel: String
        let aiInstructions: String
        // Separately stored API keys are deliberately absent from this type.
    }

    struct Clipboard: Codable {
        let monitorsSystem: Bool
        let retentionDays: Int
    }

    struct Shortcuts: Codable {
        let capture: HotkeySettings
        let translate: HotkeySettings
        let clipboard: HotkeySettings
        let clipboardTranslate: HotkeySettings
        let selectionTranslate: HotkeySettings
        let launcher: HotkeySettings
    }

    struct QuickInput: Codable {
        let variableNamingStyle: String
    }

    struct FinderActions: Codable {
        let coverage: String
        let selectedFolderPath: String?
        let menuDepth: Int
        let favoriteFolders: [FavoriteFolder]
        let openWithApps: [OpenWithApp]

        struct FavoriteFolder: Codable {
            let path: String
            let systemTitle: String?
            let symbol: String
        }

        struct OpenWithApp: Codable {
            let path: String
            let bundleIdentifier: String?
        }
    }

    init(settings: Settings, exportedAt: Date = Date(),
         appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
         buildNumber: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown") {
        self.format = Self.formatIdentifier
        self.schemaVersion = Self.currentSchemaVersion
        self.settings = settings
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.buildNumber = buildNumber
    }

    static func endpointContainsCredentials(_ value: String) -> Bool {
        guard let url = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        let credentialNames: Set<String> = ["key", "apikey", "api_key", "api-key", "token", "access_token", "auth", "authorization", "password", "secret"]
        return url.user != nil || url.password != nil ||
            url.queryItems?.contains(where: { credentialNames.contains($0.name.lowercased()) }) == true
    }

    func encoded() throws -> Data {
        guard !Self.endpointContainsCredentials(settings.translation.aiBaseURL) else {
            throw ConfigurationFileError.invalidValue("AI 地址中包含凭据，请移除后再导出")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        return try encoder.encode(self)
    }

    func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    static func decoded(from data: Data) throws -> Self {
        guard data.count <= maximumFileSize else { throw ConfigurationFileError.tooLarge }
        struct Header: Decodable {
            let format: String
            let schemaVersion: Int
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        let header: Header
        do { header = try decoder.decode(Header.self, from: data) }
        catch { throw ConfigurationFileError.invalidFormat }
        guard header.format == formatIdentifier else { throw ConfigurationFileError.invalidFormat }
        guard header.schemaVersion == currentSchemaVersion else { throw ConfigurationFileError.unsupportedVersion }
        do { return try decoder.decode(Self.self, from: data) }
        catch { throw ConfigurationFileError.invalidData }
    }

    static func read(from url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // Read at most one byte beyond the limit, even if the file grows or lies about its size.
        let data = try file.read(upToCount: maximumFileSize + 1) ?? Data()
        return try decoded(from: data)
    }

    static func suggestedFilename(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return "NookPup-configuration-\(formatter.string(from: date)).json"
    }
}
