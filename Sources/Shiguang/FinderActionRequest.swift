import Foundation

enum FinderFileFormat: String, CaseIterable, Sendable {
    case text = "txt"
    case markdown = "md"
    case json, csv

    var menuTitle: String {
        switch self {
        case .text: return "纯文本 (.txt)"
        case .markdown: return "Markdown (.md)"
        case .json: return "JSON (.json)"
        case .csv: return "CSV (.csv)"
        }
    }

    var windowTitle: String {
        switch self {
        case .text: return "新建纯文本"
        case .markdown: return "新建 Markdown"
        case .json: return "新建 JSON"
        case .csv: return "新建 CSV"
        }
    }

    var initialContents: Data { self == .json ? Data("{}\n".utf8) : Data() }
}

enum FinderTransfer: String, Sendable {
    case copy, move

    var pickerTitle: String { self == .copy ? "选择复制到的文件夹" : "选择移动到的文件夹" }
    var confirmationTitle: String { self == .copy ? "复制到这里" : "移动到这里" }
}

enum FinderArchiveOperation: String, Sendable {
    case compress = "compress-zip"
    case extract = "extract-archive"

    static func suffix(for name: String) -> String? {
        [".tar.gz", ".tar.bz2", ".tar.xz", ".zip", ".tgz", ".tbz2", ".txz", ".tar", ".7z", ".rar"]
            .first { name.lowercased().hasSuffix($0) && name.count > $0.count }
    }
}

enum FinderAction: Equatable {
    case create(FinderFileFormat)
    case copyPaths, copyNames, openTerminal
    case transfer(FinderTransfer)
    case archive(FinderArchiveOperation)
    case openFavorite(UUID)
    /// Opens the selection with an app the user added in Settings.
    case openWith(UUID)

    var needsInteraction: Bool {
        switch self {
        case .create, .transfer: return true
        default: return false
        }
    }

    fileprivate var route: String {
        switch self {
        case .create(let format): return "new-" + format.rawValue
        case .copyPaths: return "copy-paths"
        case .copyNames: return "copy-names"
        case .openTerminal: return "open-terminal"
        case .transfer(let operation): return operation.rawValue + "-into"
        case .archive(let operation): return operation.rawValue
        case .openFavorite(let id): return "favorite-" + id.uuidString.lowercased()
        case .openWith(let id): return "open-with-" + id.uuidString.lowercased()
        }
    }

    fileprivate init?(route: String) {
        switch route {
        case "new-markdown": self = .create(.markdown)
        case "copy-paths": self = .copyPaths
        case "copy-names": self = .copyNames
        case "open-terminal": self = .openTerminal
        case "copy-into": self = .transfer(.copy)
        case "move-into": self = .transfer(.move)
        default:
            if let operation = FinderArchiveOperation(rawValue: route) {
                self = .archive(operation)
            } else if let id = Self.id(in: route, after: "favorite-") {
                self = .openFavorite(id)
            } else if let id = Self.id(in: route, after: "open-with-") {
                self = .openWith(id)
            } else {
                guard route.hasPrefix("new-"),
                      let format = FinderFileFormat(rawValue: String(route.dropFirst(4))) else { return nil }
                self = .create(format)
            }
        }
    }

    private static func id(in route: String, after prefix: String) -> UUID? {
        guard route.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(route.dropFirst(prefix.count)))
    }
}

struct FinderRelativePath: Hashable, Sendable {
    let components: [String]
    static let root = FinderRelativePath(components: [])

    private init(components: [String]) { self.components = components }

    init?(relativeString: String) {
        let components = relativeString.isEmpty ? [] : relativeString.components(separatedBy: "/")
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0)
        }) else { return nil }
        self.init(components: components)
    }

    var relativeString: String { components.joined(separator: "/") }
    var parent: Self? {
        guard !components.isEmpty else { return nil }
        return Self(components: Array(components.dropLast()))
    }
    var name: String? { components.last }
}

struct FinderScope: Codable, Equatable, Sendable {
    let id: UUID
    let directory: URL

    static func allFolders(id: UUID) -> Self {
        Self(id: id, directory: URL(fileURLWithPath: "/", isDirectory: true))
    }

    var coversAllFolders: Bool { directory.standardizedFileURL.path == "/" }

    func relativePath(to item: URL) -> FinderRelativePath? {
        guard item.isFileURL, item.host == nil || item.host == "" || item.host == "localhost" else { return nil }
        let root = directory.standardizedFileURL.pathComponents
        let path = item.standardizedFileURL.pathComponents
        guard path.starts(with: root) else { return nil }
        return FinderRelativePath(relativeString: path.dropFirst(root.count).joined(separator: "/"))
    }

    func request(_ action: FinderAction, for urls: [URL]) -> FinderActionRequest? {
        let paths = urls.compactMap { relativePath(to: $0) }
        guard paths.count == urls.count else { return nil }
        return FinderActionRequest(scopeID: id, action: action, paths: paths)
    }
}

struct FinderActionRequest: Equatable {
    static let scheme = "pawshot-finder"
    static let launchArgument = "--finder-actions"
    let scopeID: UUID
    let action: FinderAction
    let paths: [FinderRelativePath]

    static func isFinderLaunch(_ arguments: [String]) -> Bool {
        arguments.contains(launchArgument) || arguments.contains("--finder-markdown")
    }

    fileprivate init?(scopeID: UUID, action: FinderAction, paths: [FinderRelativePath]) {
        guard !paths.isEmpty, paths.count <= 512, Set(paths).count == paths.count else { return nil }
        switch action {
        case .create, .openTerminal, .openFavorite:
            guard paths.count == 1 else { return nil }
        case .transfer, .archive:
            guard !paths.contains(.root) else { return nil }
        default: break
        }
        self.scopeID = scopeID
        self.action = action
        self.paths = paths
    }

    init?(url: URL) {
        guard url.absoluteString.utf8.count <= 524_288,
              let route = URLComponents(url: url, resolvingAgainstBaseURL: false),
              route.scheme == Self.scheme, let host = route.host, let action = FinderAction(route: host),
              route.path.isEmpty, route.user == nil, route.password == nil, route.port == nil, route.fragment == nil,
              let items = route.queryItems, (2...513).contains(items.count),
              let scope = items.first, scope.name == "scope",
              let id = scope.value.flatMap(UUID.init(uuidString:)) else { return nil }

        // Finder may still have the previous extension process while PawShot updates.
        let pathKey = host == "new-markdown" ? "folder" : "item"
        let paths = items.dropFirst().compactMap { item -> FinderRelativePath? in
            guard item.name == pathKey, let value = item.value else { return nil }
            return FinderRelativePath(relativeString: value)
        }
        guard paths.count == items.count - 1 else { return nil }
        self.init(scopeID: id, action: action, paths: paths)
    }

    var url: URL? {
        var route = URLComponents()
        route.scheme = Self.scheme
        route.host = action.route
        route.queryItems = [URLQueryItem(name: "scope", value: scopeID.uuidString)] +
            paths.map { URLQueryItem(name: "item", value: $0.relativeString) }
        guard let url = route.url, url.absoluteString.utf8.count <= 524_288 else { return nil }
        return url
    }
}

enum FinderMenuDepth: Int, CaseIterable, Codable {
    case one = 1
    case two = 2

    var title: String { self == .one ? "一层" : "两层" }
}

struct FinderMenuFavorite: Codable, Equatable {
    let id: UUID
    let title: String
    let symbol: String
}

/// An app the Finder menu offers to open the selection with. PawShot renders
/// the icon, so the sandboxed extension never reads other app bundles.
struct FinderMenuApp: Codable, Equatable {
    let id: UUID
    let title: String
    /// A 16 pt PNG at 2x.
    let icon: Data?
}

// Keep the existing preference domain so installed extensions retain the selected folder.
struct FinderMenuSettings: Codable {
    static let domain = "dev.shiguang.screenshot.finder-menu"
    static let didChange = Notification.Name("\(domain).did-change")
    private static let key = "settings"

    let scope: FinderScope?
    let language: AppLanguage
    let depth: FinderMenuDepth
    let favorites: [FinderMenuFavorite]
    let apps: [FinderMenuApp]

    init(scope: FinderScope?, language: AppLanguage, depth: FinderMenuDepth, favorites: [FinderMenuFavorite],
         apps: [FinderMenuApp] = []) {
        self.scope = scope
        self.language = language
        self.depth = depth
        self.favorites = favorites
        self.apps = apps
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        scope = try values.decodeIfPresent(FinderScope.self, forKey: .scope)
        language = try values.decode(AppLanguage.self, forKey: .language)
        let storedDepth = try values.decodeIfPresent(Int.self, forKey: .depth)
        depth = storedDepth.flatMap(FinderMenuDepth.init(rawValue:)) ?? .two
        favorites = try values.decodeIfPresent([FinderMenuFavorite].self, forKey: .favorites) ?? []
        apps = try values.decodeIfPresent([FinderMenuApp].self, forKey: .apps) ?? []
    }

    static func load() -> Self? {
        guard let data = UserDefaults(suiteName: domain)?.data(forKey: key) else { return nil }
        return try? PropertyListDecoder().decode(Self.self, from: data)
    }

    func publish() {
        guard let defaults = UserDefaults(suiteName: Self.domain),
              let data = try? PropertyListEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(
            Self.didChange, object: nil, userInfo: nil, deliverImmediately: true
        )
    }
}
