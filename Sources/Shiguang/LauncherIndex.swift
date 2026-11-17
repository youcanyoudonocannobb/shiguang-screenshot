import AppKit
import Foundation

struct LauncherEntry: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case application
        case file
        case path

        var title: String {
            switch self {
            case .application: return "应用"
            case .file: return "文件"
            case .path: return "地址"
            }
        }
    }

    let kind: Kind
    let title: String
    let subtitle: String
    let url: URL
    var searchTerms: [String] = []

    var id: String { url.path }
}

@MainActor
final class LauncherIndex: ObservableObject {
    static let shared = LauncherIndex()

    @Published private(set) var applications: [LauncherEntry] = []
    private var isLoading = false

    private nonisolated static let roots = [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
        URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications/Utilities", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    ]

    func loadIfNeeded() {
        guard !isLoading, applications.isEmpty else { return }
        isLoading = true
        Task.detached(priority: .utility) {
            let entries = Self.scanApplications()
            await MainActor.run {
                self.applications = entries
                self.isLoading = false
            }
        }
    }

    private nonisolated static func scanApplications() -> [LauncherEntry] {
        var seen = Set<String>()
        var results: [LauncherEntry] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                let bundle = Bundle(url: url)
                let localizedName = Self.localizedDisplayName(for: url, bundle: bundle)
                let bundleName = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let pinyin = localizedName.applyingTransform(.mandarinToLatin, reverse: false)?
                    .applyingTransform(.stripDiacritics, reverse: false) ?? ""
                let compactPinyin = pinyin.replacingOccurrences(of: " ", with: "").lowercased()
                let initials = pinyin.split(whereSeparator: \.isWhitespace)
                    .compactMap { $0.first.map(String.init) }
                    .joined()
                    .lowercased()
                var terms = [localizedName, bundleName, url.deletingPathExtension().lastPathComponent,
                             compactPinyin, initials]
                if let identifier = bundle?.bundleIdentifier { terms.append(identifier) }
                switch bundle?.bundleIdentifier?.lowercased() {
                case "com.tencent.xinwechat", "com.tencent.wechat":
                    terms += ["微信", "wechat", "weixin", "wx"]
                default:
                    break
                }
                let searchTerms = Array(Set(terms.filter { !$0.isEmpty }.map { $0.lowercased() }))
                guard !localizedName.isEmpty else { continue }
                results.append(LauncherEntry(kind: .application,
                                             title: localizedName,
                                             subtitle: url.deletingLastPathComponent().path,
                                             url: url,
                                             searchTerms: searchTerms))
            }
        }
        return results.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private nonisolated static func localizedDisplayName(for url: URL, bundle: Bundle?) -> String {
        let resources = url.appendingPathComponent("Contents/Resources", isDirectory: true)
        for language in ["zh-Hans", "zh-Hant", "en"] {
            let file = resources.appendingPathComponent("\(language).lproj/InfoPlist.strings")
            if let values = NSDictionary(contentsOf: file) as? [String: String],
               let name = values["CFBundleDisplayName"] ?? values["CFBundleName"],
               !name.isEmpty {
                return name
            }
        }
        let candidates = [
            (try? url.resourceValues(forKeys: [.localizedNameKey]))?.localizedName,
            bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String,
            bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        ]
        for case let name? in candidates where !name.isEmpty {
            return name.replacingOccurrences(of: ".app", with: "")
        }
        return url.deletingPathExtension().lastPathComponent
    }

    func matchingApplications(_ query: String, limit: Int) -> [LauncherEntry] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return [] }
        let scored = applications.compactMap { entry -> (LauncherEntry, Int)? in
            let terms = entry.searchTerms.isEmpty ? [entry.title.lowercased()] : entry.searchTerms
            if terms.contains(where: { $0 == value }) { return (entry, 0) }
            if terms.contains(where: { $0.hasPrefix(value) }) { return (entry, 1) }
            if terms.contains(where: { $0.contains(value) }) { return (entry, 2) }
            if terms.contains(where: { $0.fuzzyContains(value) }) { return (entry, 3) }
            return nil
        }
        return scored.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.title < rhs.0.title : lhs.1 < rhs.1
        }.prefix(limit).map(\.0)
    }

    func suggestedApplications(limit: Int) -> [LauncherEntry] {
        Array(applications.prefix(limit))
    }

    nonisolated static func searchFiles(_ query: String, limit: Int) async -> [LauncherEntry] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2 else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-name", value]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        var results: [LauncherEntry] = []
        for line in output.split(separator: "\n") {
            let path = String(line)
            guard !path.isEmpty, path.hasPrefix("/"), !path.contains("/.Trash/") else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            guard !isDirectory.boolValue else { continue }
            let url = URL(fileURLWithPath: path)
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            let name = url.lastPathComponent
            results.append(LauncherEntry(kind: url.pathExtension.lowercased() == "app" ? .application : .file,
                                         title: name,
                                         subtitle: url.deletingLastPathComponent().path,
                                         url: url))
            if results.count >= limit { break }
        }
        return results
    }
}

private extension String {
    /// Cheap subsequence match so "gchrome" still finds "Google Chrome".
    func fuzzyContains(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var index = needle.startIndex
        for character in self {
            if character == needle[index] {
                index = needle.index(after: index)
                if index == needle.endIndex { return true }
            }
        }
        return false
    }
}

@MainActor
enum LauncherAction {
    static func open(_ entry: LauncherEntry) -> String? {
        switch entry.kind {
        case .path:
            return revealOrOpen(entry.url)
        case .application, .file:
            return NSWorkspace.shared.open(entry.url) ? nil : "无法打开 \(entry.title)"
        }
    }

    private static func revealOrOpen(_ url: URL) -> String? {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists {
            if isDirectory.boolValue {
                return NSWorkspace.shared.open(url) ? nil : "无法打开 \(url.path)"
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return nil
        }
        let parent = url.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            return "找不到路径：\(url.path)"
        }
        return NSWorkspace.shared.open(parent) ? nil : "无法打开 \(parent.path)"
    }

    static func icon(for entry: LauncherEntry) -> NSImage {
        NSWorkspace.shared.icon(forFile: entry.url.path)
    }
}
