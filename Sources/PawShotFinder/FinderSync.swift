import AppKit
import FinderSync
import os

@objc(PawShotFinderSync)
final class PawShotFinderSync: FIFinderSync {
    private let controller = FIFinderSyncController.default()
    private let logger = Logger(subsystem: "dev.shiguang.screenshot.finder", category: "menu")
    private let signposter = OSSignposter(subsystem: "dev.shiguang.screenshot.finder", category: "menu")
    private var scope: FinderScope?
    private var depth: FinderMenuDepth = .two
    private var favorites: [FinderMenuFavorite] = []
    private var favoriteTags: [UUID: Int] = [:]
    private var nextFavoriteTag = 1
    private var titles: [String: String] = [:]
    private var icons: [String: NSImage] = [:]
    private var iconAppearance: NSAppearance?

    override init() {
        super.init()
        reloadSettings()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(settingsDidChange(_:)),
            name: FinderMenuSettings.didChange, object: nil
        )
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(volumesDidChange(_:)), name: NSWorkspace.didMountNotification, object: nil)
        workspace.addObserver(self, selector: #selector(volumesDidChange(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func settingsDidChange(_ notification: Notification) {
        reloadSettings()
    }

    @objc private func volumesDidChange(_ notification: Notification) {
        if scope?.coversAllFolders == true { updateDirectoryURLs() }
    }

    private func reloadSettings() {
        let settings = FinderMenuSettings.load()
        scope = settings?.scope
        depth = settings?.depth ?? .two
        favorites = settings?.favorites ?? []
        let favoriteIDs = Set(favorites.map(\.id))
        favoriteTags = favoriteTags.filter { favoriteIDs.contains($0.key) }
        let keys = ["新建文件", "复制路径", "复制文件名", "在终端中打开", "复制到…", "移动到…",
                    "常用目录", "打开「%@」", "压缩为 ZIP", "解压到此处"] +
            FinderFileFormat.allCases.flatMap { [$0.menuTitle, $0.windowTitle] }
        let bundle = Bundle(url: containingApp) ?? .main
        titles = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, AppLocalization.text($0, language: settings?.language ?? .simplifiedChinese, bundle: bundle))
        })
        updateDirectoryURLs()
    }

    private func updateDirectoryURLs() {
        var directories = Set(scope.map { [$0.directory] } ?? [])
        if scope?.coversAllFolders == true {
            // Finder watches each mounted volume separately from the startup disk.
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: .skipHiddenVolumes)
            directories.formUnion(volumes ?? [])
        }
        if controller.directoryURLs != directories { controller.directoryURLs = directories }
    }

    private var containingApp: URL {
        Bundle(for: PawShotFinderSync.self).bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let interval = signposter.beginInterval("BuildFinderMenu")
        defer { signposter.endInterval("BuildFinderMenu", interval) }
        guard let scope else { return nil }
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)
        if iconAppearance?.name != appearance?.name {
            iconAppearance = appearance
            icons.removeAll()
        }
        let actions = NSMenu()
        switch menuKind {
        case .contextualMenuForContainer:
            guard let folder = controller.targetedURL(), scope.relativePath(to: folder) != nil else { return nil }
            addNewFiles(to: actions)
            add("复制路径", icon: "link", #selector(copyFolderPath(_:)), to: actions)
            add("在终端中打开", icon: "terminal", #selector(openFolderTerminal(_:)), to: actions)
        case .contextualMenuForItems:
            let selected = selection()
            guard let request = scope.request(.copyPaths, for: selected) else { return nil }
            let volumeRoots = Set((controller.directoryURLs ?? []).map { $0.standardizedFileURL.path })
            let canTransfer = !request.paths.contains(.root) &&
                !selected.contains { volumeRoots.contains($0.standardizedFileURL.path) }
            if request.paths.allSatisfy({ $0.name.flatMap(FinderArchiveOperation.suffix(for:)) != nil }) {
                add("解压到此处", icon: "tray.and.arrow.up", #selector(extract(_:)), to: actions)
            }
            if canTransfer, request.paths.allSatisfy({ $0.parent == request.paths.first?.parent }) {
                add("压缩为 ZIP", icon: "archivebox", #selector(compress(_:)), to: actions)
            }
            add("复制路径", icon: "link", #selector(copySelectedPaths(_:)), to: actions)
            add("复制文件名", icon: "textformat", #selector(copySelectedNames(_:)), to: actions)
            if selected.count == 1 {
                add("在终端中打开", icon: "terminal", #selector(openSelectedTerminal(_:)), to: actions)
            }
            if canTransfer {
                add("复制到…", icon: "doc.on.doc", #selector(copyInto(_:)), to: actions)
                add("移动到…", icon: "arrow.right.to.line", #selector(moveInto(_:)), to: actions)
            }
        default:
            return nil
        }
        addFavorites(to: actions)
        return actions
    }

    private func addNewFiles(to menu: NSMenu) {
        let formats = actionGroup("新建文件", icon: "doc.badge.plus", in: menu)
        let entries: [(FinderFileFormat, String, Selector)] = [
            (.text, "doc.text", #selector(newText(_:))),
            (.markdown, "doc.richtext", #selector(newMarkdown(_:))),
            (.json, "curlybraces", #selector(newJSON(_:))),
            (.csv, "tablecells", #selector(newCSV(_:))),
        ]
        for (format, icon, action) in entries {
            add(depth == .one ? format.windowTitle : format.menuTitle, icon: icon, action, to: formats)
        }
    }

    private func addFavorites(to menu: NSMenu) {
        guard !favorites.isEmpty else { return }
        let list = actionGroup("常用目录", icon: "star", in: menu)
        for favorite in favorites {
            let title = depth == .one ? String(format: label("打开「%@」"), favorite.title) : favorite.title
            let item = list.addItem(withTitle: title, action: #selector(openFavorite(_:)), keyEquivalent: "")
            // Finder copies the menu item across processes and preserves its integer tag.
            if favoriteTags[favorite.id] == nil {
                favoriteTags[favorite.id] = nextFavoriteTag
                nextFavoriteTag += 1
            }
            item.tag = favoriteTags[favorite.id] ?? 0
            setImage(favorite.symbol, on: item)
        }
    }

    private func actionGroup(_ key: String, icon: String, in menu: NSMenu) -> NSMenu {
        guard depth == .two else { return menu }
        let group = menu.addItem(withTitle: label(key), action: nil, keyEquivalent: "")
        setImage(icon, on: group)
        let contents = NSMenu(title: group.title)
        group.submenu = contents
        return contents
    }

    private func label(_ key: String) -> String { titles[key] ?? key }

    private func add(_ key: String, icon: String, _ action: Selector, to menu: NSMenu) {
        let item = menu.addItem(withTitle: label(key), action: action, keyEquivalent: "")
        setImage(icon, on: item)
    }

    private func setImage(_ symbol: String, on item: NSMenuItem) {
        if icons[symbol] == nil { icons[symbol] = makeIcon(symbol) }
        item.image = icons[symbol]
        // The public property was added in macOS 27. Use its setter so older SDKs can build the extension.
        if item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) {
            item.setValue(1, forKey: "preferredImageVisibility") // NSMenuItem.ImageVisibility.visible
        }
    }

    private func makeIcon(_ symbol: String) -> NSImage? {
        let size = NSSize(width: 16, height: 16)
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)),
              let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        pixels.size = size
        let scale = min(1, size.width / glyph.size.width, size.height / glyph.size.height)
        let width = glyph.size.width * scale
        let height = glyph.size.height * scale
        let rect = NSRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
        glyph.draw(in: rect)
        let color = iconColor(for: symbol)
        let dark = iconAppearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var tint = color
        iconAppearance?.performAsCurrentDrawingAppearance {
            let resolved = color.usingColorSpace(.sRGB) ?? color
            tint = resolved.blended(withFraction: dark ? 0.40 : 0.26, of: dark ? .white : .black) ?? resolved
        }
        tint.setFill()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(pixels)
        return image
    }

    private func iconColor(for symbol: String) -> NSColor {
        switch symbol {
        case "archivebox", "star", "curlybraces": return .systemOrange
        case "tray.and.arrow.up", "tablecells", "arrow.down.circle": return .systemGreen
        case "doc.badge.plus", "doc.richtext", "textformat", "arrow.right.to.line": return .systemPurple
        case "terminal", "desktopcomputer": return .systemIndigo
        case "link": return .systemTeal
        default: return NSColor(srgbRed: 0.07, green: 0.25, blue: 0.68, alpha: 1)
        }
    }

    private func selection() -> [URL] {
        if let selected = controller.selectedItemURLs(), !selected.isEmpty { return selected }
        return targetedFolder()
    }

    private func targetedFolder() -> [URL] { controller.targetedURL().map { [$0] } ?? [] }

    @objc func newText(_ sender: Any?) { send(.create(.text), for: targetedFolder()) }
    @objc func newMarkdown(_ sender: Any?) { send(.create(.markdown), for: targetedFolder()) }
    @objc func newJSON(_ sender: Any?) { send(.create(.json), for: targetedFolder()) }
    @objc func newCSV(_ sender: Any?) { send(.create(.csv), for: targetedFolder()) }
    @objc func copyFolderPath(_ sender: Any?) { send(.copyPaths, for: targetedFolder()) }
    @objc func copySelectedPaths(_ sender: Any?) { send(.copyPaths, for: selection()) }
    @objc func copySelectedNames(_ sender: Any?) { send(.copyNames, for: selection()) }
    @objc func openFolderTerminal(_ sender: Any?) { send(.openTerminal, for: targetedFolder()) }
    @objc func openSelectedTerminal(_ sender: Any?) { send(.openTerminal, for: selection()) }
    @objc func copyInto(_ sender: Any?) { send(.transfer(.copy), for: selection()) }
    @objc func moveInto(_ sender: Any?) { send(.transfer(.move), for: selection()) }
    @objc func compress(_ sender: Any?) { send(.archive(.compress), for: selection()) }
    @objc func extract(_ sender: Any?) { send(.archive(.extract), for: selection()) }

    @objc func openFavorite(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let id = favoriteTags.first(where: { $0.value == item.tag })?.key,
              let source = controller.targetedURL() ?? selection().first else { return }
        send(.openFavorite(id), for: [source])
    }

    private func send(_ action: FinderAction, for urls: [URL]) {
        guard let request = scope?.request(action, for: urls)?.url else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = [FinderActionRequest.launchArgument]
        configuration.activates = action.needsInteraction
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([request], withApplicationAt: containingApp, configuration: configuration) {
            [logger] _, error in
            if let error = error as NSError? {
                logger.error("Could not open PawShot for Finder action: \(error.domain, privacy: .public) \(error.code)")
            }
        }
    }
}
