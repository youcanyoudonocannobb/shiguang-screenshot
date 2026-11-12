import AppKit
import Combine
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

enum ClipboardFailure: LocalizedError {
    case empty, write, missing
    var errorDescription: String? {
        switch self {
        case .empty: return "这条剪贴板内容无法读取。"
        case .write: return "无法写入系统剪贴板，请重试。"
        case .missing: return "原文件已被移动或删除，无法再次复制。"
        }
    }
}

struct ClipboardSnapshot: Codable {
    var items: [[String: Data]]
    static let maximumBytes = 64 * 1024 * 1024

    static func read(_ pasteboard: NSPasteboard) -> Self? {
        let change = pasteboard.changeCount
        let source = pasteboard.pasteboardItems ?? []
        let excluded = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"]
        guard !source.contains(where: { item in excluded.contains { item.types.contains(NSPasteboard.PasteboardType($0)) } }) else { return nil }
        var remaining = maximumBytes
        let items = source.compactMap { item -> [String: Data]? in
            var values: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type), !data.isEmpty, data.count <= remaining else { continue }
                values[type.rawValue] = data
                remaining -= data.count
            }
            return values.isEmpty ? nil : values
        }
        guard pasteboard.changeCount == change else { return nil }
        return items.isEmpty ? nil : Self(items: items)
    }

    var fingerprint: String {
        var hash = SHA256()
        for item in items {
            hash.update(data: Data([0]))
            for type in item.keys.sorted() {
                let data = item[type]!
                hash.update(data: Data("\(type.utf8.count):\(type):\(data.count):".utf8))
                hash.update(data: data)
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    var text: String? {
        for item in items {
            if let data = item[NSPasteboard.PasteboardType.string.rawValue], let value = String(data: data, encoding: .utf8) { return value }
        }
        return nil
    }

    var fileURLs: [URL] {
        items.flatMap { item -> [URL] in
            if let data = item[NSPasteboard.PasteboardType.fileURL.rawValue],
               let string = String(data: data, encoding: .utf8), let url = URL(string: string), url.isFileURL { return [url] }
            if let data = item["NSFilenamesPboardType"],
               let names = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                return names.map { URL(fileURLWithPath: $0) }
            }
            return []
        }
    }

    var imageData: Data? {
        for type in [UTType.gif.identifier, NSPasteboard.PasteboardType.png.rawValue, NSPasteboard.PasteboardType.tiff.rawValue] {
            if let data = items.first(where: { $0[type] != nil })?[type] { return data }
        }
        return nil
    }

    func write(to pasteboard: NSPasteboard) throws {
        guard !items.isEmpty else { throw ClipboardFailure.empty }
        guard fileURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { throw ClipboardFailure.missing }
        let objects = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects(objects) else { throw ClipboardFailure.write }
    }

    static func image(_ image: NSImage) throws -> Self {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { throw ClipboardFailure.empty }
        var values = [NSPasteboard.PasteboardType.png.rawValue: png]
        if cg.width * cg.height * 4 <= maximumBytes / 2, let tiff = image.tiffRepresentation {
            values[NSPasteboard.PasteboardType.tiff.rawValue] = tiff
        }
        return Self(items: [values])
    }

    static func file(_ url: URL) throws -> Self {
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { throw ClipboardFailure.missing }
        var values = [NSPasteboard.PasteboardType.fileURL.rawValue: Data(url.absoluteString.utf8)]
        if url.pathExtension.lowercased() == "gif" {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if data.count <= maximumBytes / 2 { values[UTType.gif.identifier] = data }
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let frame = CGImageSourceCreateImageAtIndex(source, 0, nil),
               let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) {
                values[NSPasteboard.PasteboardType.png.rawValue] = png
            }
        }
        return Self(items: [values])
    }
}

struct ClipboardEntry: Codable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case text, image, gif, video, files, other
        var title: String {
            switch self {
            case .text: return "文字"
            case .image: return "图片"
            case .gif: return "GIF"
            case .video: return "视频"
            case .files: return "文件"
            case .other: return "其他"
            }
        }
        var symbol: String {
            switch self {
            case .text: return "text.alignleft"
            case .image: return "photo"
            case .gif: return "photo.on.rectangle.angled"
            case .video: return "film"
            case .files: return "doc.on.doc"
            case .other: return "doc.on.clipboard"
            }
        }
    }
    let id: UUID
    var createdAt: Date
    let fingerprint: String
    let kind: Kind
    let summary: String
    let ownedFileName: String?

    init(snapshot: ClipboardSnapshot, ownedFileName: String? = nil) {
        id = UUID()
        createdAt = Date()
        fingerprint = snapshot.fingerprint
        self.ownedFileName = ownedFileName
        let urls = snapshot.fileURLs
        if snapshot.items.contains(where: { $0[UTType.gif.identifier] != nil }) || urls.first?.pathExtension.lowercased() == "gif" {
            kind = .gif
        } else if let url = urls.first, UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true {
            kind = .video
        } else if snapshot.imageData != nil { kind = .image }
        else if !urls.isEmpty { kind = .files }
        else if snapshot.text != nil { kind = .text }
        else { kind = .other }
        if !urls.isEmpty { summary = urls.map(\.lastPathComponent).joined(separator: "\n") }
        else if let text = snapshot.text { summary = String(text.prefix(1000)) }
        else { summary = kind == .image ? "截图与图片" : kind.title }
    }
}

@MainActor
final class ClipboardHistory: ObservableObject {
    @Published private(set) var entries: [ClipboardEntry] = []
    @Published private(set) var message = "复制的内容会显示在这里。"
    @Published var search = ""
    @Published var filter: ClipboardEntry.Kind?
    @Published var selectedID: UUID?
    @Published var monitorsSystem: Bool {
        didSet { preferences.set(monitorsSystem, forKey: "clipboard.monitor"); observedChange = pasteboard.changeCount }
    }
    private let directory: URL
    private let pasteboard: NSPasteboard
    private let preferences: UserDefaults
    private let limit: Int
    private var observedChange: Int
    private var lastPublishedChange: Int?
    private var timer: Timer?
    private var storageAvailable = true
    private var previews: [UUID: NSImage] = [:]
    private var reservedMedia: Set<String> = []
    private var indexURL: URL { directory.appendingPathComponent("history.json") }
    private var mediaDirectory: URL { directory.appendingPathComponent("Media", isDirectory: true) }
    var canReadInBackground: Bool {
        if #available(macOS 15.4, *), pasteboard.name == NSPasteboard.general.name {
            return pasteboard.accessBehavior == .alwaysAllow
        }
        return true
    }
    var filteredEntries: [ClipboardEntry] {
        entries.filter { entry in
            (filter == nil || entry.kind == filter) &&
                (search.isEmpty || entry.summary.localizedCaseInsensitiveContains(search) || entry.kind.title.localizedCaseInsensitiveContains(search))
        }
    }

    func prepareForDisplay() {
        captureCurrent()
        search = ""
        filter = nil
        selectedID = entries.first?.id
    }

    func moveSelection(_ delta: Int) {
        let rows = filteredEntries
        guard !rows.isEmpty else { selectedID = nil; return }
        let current = rows.firstIndex(where: { $0.id == selectedID }) ?? (delta > 0 ? -1 : rows.count)
        selectedID = rows[min(rows.count - 1, max(0, current + delta))].id
    }

    init(directory: URL, pasteboard: NSPasteboard = .general, preferences: UserDefaults = .standard, limit: Int = 100) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.pasteboard = pasteboard
        self.preferences = preferences
        self.limit = max(1, limit)
        monitorsSystem = preferences.object(forKey: "clipboard.monitor") as? Bool ?? true
        observedChange = pasteboard.changeCount
        do {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: indexURL.path) {
                entries = try JSONDecoder().decode([ClipboardEntry].self, from: Data(contentsOf: indexURL))
                    .filter { FileManager.default.fileExists(atPath: payloadURL($0).path) }
            }
        } catch {
            storageAvailable = false
            message = "剪贴板历史读取失败，原文件已保留；仍可复制新内容。"
        }
    }

    func start() {
        guard timer == nil else { return }
        if monitorsSystem && canReadInBackground { captureCurrent() }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }
    func reportCopyError(_ error: Error) { message = "复制失败：\(error.localizedDescription)" }

    func poll() {
        guard pasteboard.changeCount != observedChange else { return }
        guard canReadInBackground else {
            let notice = "系统尚未允许后台读取；打开面板可读取当前内容，允许系统剪贴板访问后可自动记录。"
            if monitorsSystem && message != notice { message = notice }
            return
        }
        observedChange = pasteboard.changeCount
        if monitorsSystem { captureCurrent() }
    }

    func captureCurrent() {
        observedChange = pasteboard.changeCount
        guard let snapshot = ClipboardSnapshot.read(pasteboard) else { return }
        record(snapshot)
    }

    func copyImage(_ image: NSImage) throws { try publish(ClipboardSnapshot.image(image)) }
    func copyText(_ text: String) throws {
        try publish(ClipboardSnapshot(items: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]]))
    }

    func makeMediaURL(fileExtension: String) throws -> URL {
        guard ["mp4", "gif"].contains(fileExtension) else { throw ClipboardFailure.empty }
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = mediaDirectory.appendingPathComponent("Shiguang-\(UUID().uuidString).\(fileExtension)")
        reservedMedia.insert(url.lastPathComponent)
        return url
    }

    func copyMedia(_ url: URL) throws {
        guard ownedMediaURL(url.lastPathComponent) == url.standardizedFileURL.resolvingSymlinksInPath() else { throw ClipboardFailure.missing }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try publish(ClipboardSnapshot.file(url), ownedFileName: url.lastPathComponent)
        reservedMedia.remove(url.lastPathComponent)
    }

    func discardUnpublishedMedia(_ url: URL) {
        guard let owned = ownedMediaURL(url.lastPathComponent), owned == url.standardizedFileURL.resolvingSymlinksInPath(),
              !entries.contains(where: { $0.ownedFileName == owned.lastPathComponent }) else { return }
        if canReadInBackground || lastPublishedChange == pasteboard.changeCount {
            guard !(ClipboardSnapshot.read(pasteboard).map({ $0.fileURLs.contains(owned) }) ?? false) else { return }
        }
        reservedMedia.remove(url.lastPathComponent)
        try? FileManager.default.removeItem(at: owned)
    }

    func copy(_ entry: ClipboardEntry) throws {
        let snapshot = try load(entry)
        try snapshot.write(to: pasteboard)
        observedChange = pasteboard.changeCount
        lastPublishedChange = observedChange
        record(snapshot, ownedFileName: entry.ownedFileName)
        message = "已复制\(entry.kind.title)，可按 ⌘V 粘贴。"
    }

    func preview(_ entry: ClipboardEntry) -> NSImage? {
        if let cached = previews[entry.id] { return cached }
        guard entry.kind == .image || entry.kind == .gif, let snapshot = try? load(entry) else { return nil }
        let source: CGImageSource?
        if let data = snapshot.imageData { source = CGImageSourceCreateWithData(data as CFData, nil) }
        else if let url = snapshot.fileURLs.first { source = CGImageSourceCreateWithURL(url as CFURL, nil) }
        else { source = nil }
        guard let source, let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: thumbnail, size: CGSize(width: thumbnail.width, height: thumbnail.height))
        previews[entry.id] = image
        return image
    }

    func clear() {
        do {
            try saveIndex([])
            let old = entries
            entries = []
            selectedID = nil
            storageAvailable = true
            previews = [:]
            for entry in old { try? FileManager.default.removeItem(at: payloadURL(entry)) }
            pruneMedia()
            message = "剪贴板历史已清空，系统当前内容仍可粘贴。"
        } catch { message = "清空失败：\(error.localizedDescription)" }
    }

    private func publish(_ snapshot: ClipboardSnapshot, ownedFileName: String? = nil) throws {
        try snapshot.write(to: pasteboard)
        observedChange = pasteboard.changeCount
        lastPublishedChange = observedChange
        record(snapshot, ownedFileName: ownedFileName)
        message = "已复制到剪贴板，可按 ⌘V 粘贴。"
    }

    private func record(_ snapshot: ClipboardSnapshot, ownedFileName: String? = nil) {
        guard storageAvailable else { return }
        if let index = entries.firstIndex(where: { $0.fingerprint == snapshot.fingerprint }) {
            var updated = entries
            var existing = updated.remove(at: index)
            existing.createdAt = Date()
            updated.insert(existing, at: 0)
            do { try saveIndex(updated); entries = updated }
            catch { message = "已复制，历史保存失败：\(error.localizedDescription)" }
            return
        }
        let owned = ownedFileName ?? snapshot.fileURLs.first(where: {
            ownedMediaURL($0.lastPathComponent) == $0.standardizedFileURL.resolvingSymlinksInPath()
        })?.lastPathComponent
        let entry = ClipboardEntry(snapshot: snapshot, ownedFileName: owned)
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(snapshot).write(to: payloadURL(entry), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: payloadURL(entry).path)
            let all = [entry] + entries
            let updated = Array(all.prefix(limit))
            do { try saveIndex(updated) }
            catch { try? FileManager.default.removeItem(at: payloadURL(entry)); throw error }
            entries = updated
            for expired in all.dropFirst(limit) {
                previews[expired.id] = nil
                try? FileManager.default.removeItem(at: payloadURL(expired))
            }
            pruneMedia()
        } catch { message = "已复制，历史保存失败：\(error.localizedDescription)" }
    }

    private func load(_ entry: ClipboardEntry) throws -> ClipboardSnapshot {
        try PropertyListDecoder().decode(ClipboardSnapshot.self, from: Data(contentsOf: payloadURL(entry)))
    }

    private func payloadURL(_ entry: ClipboardEntry) -> URL { directory.appendingPathComponent("\(entry.id.uuidString).plist") }
    private func saveIndex(_ entries: [ClipboardEntry]) throws {
        try JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    private func ownedMediaURL(_ name: String) -> URL? {
        let file = URL(fileURLWithPath: name)
        guard file.lastPathComponent == name, name.hasPrefix("Shiguang-"),
              ["mp4", "gif"].contains(file.pathExtension),
              UUID(uuidString: String(file.deletingPathExtension().lastPathComponent.dropFirst(9))) != nil else { return nil }
        let url = mediaDirectory.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
        return url.deletingLastPathComponent() == mediaDirectory.standardizedFileURL.resolvingSymlinksInPath() ? url : nil
    }

    private func pruneMedia() {
        guard canReadInBackground || lastPublishedChange == pasteboard.changeCount else { return }
        let current = Set(ClipboardSnapshot.read(pasteboard)?.fileURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath() } ?? [])
        let kept = Set(entries.compactMap(\.ownedFileName))
        let files = (try? FileManager.default.contentsOfDirectory(at: mediaDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            guard let url = ownedMediaURL(file.lastPathComponent), !current.contains(url),
                  !reservedMedia.contains(file.lastPathComponent), !kept.contains(file.lastPathComponent) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
