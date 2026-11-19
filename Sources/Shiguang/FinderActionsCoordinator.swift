import AppKit
import FinderSync
import SwiftUI
import UniformTypeIdentifiers

struct FinderFavorite: Codable, Identifiable {
    var id = UUID()
    let directory: URL
    var systemTitle: String?
    var symbol = "folder"

    var title: String { systemTitle.map { L($0) } ?? directory.lastPathComponent }
    var menuEntry: FinderMenuFavorite { FinderMenuFavorite(id: id, title: title, symbol: symbol) }

    static func standardDirectories() -> [Self] {
        let entries: [(FileManager.SearchPathDirectory, String, String, UUID)] = [
            (.desktopDirectory, "桌面", "desktopcomputer", UUID(uuidString: "90DDD032-249F-40C6-9965-0604C29B7553")!),
            (.documentDirectory, "文稿", "folder", UUID(uuidString: "90DDD032-249F-40C6-9965-0604C29B7554")!),
            (.downloadsDirectory, "下载", "arrow.down.circle", UUID(uuidString: "90DDD032-249F-40C6-9965-0604C29B7555")!),
        ]
        return entries.compactMap { kind, title, symbol, id in
            FileManager.default.urls(for: kind, in: .userDomainMask).first.map {
                Self(id: id, directory: $0, systemTitle: title, symbol: symbol)
            }
        }
    }
}

enum FinderCoverage: String, CaseIterable {
    case selectedFolder, allFolders

    var title: String { self == .allFolders ? "所有文件夹" : "指定文件夹" }
}

@MainActor
final class FinderActionsCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    private static let grantKey = "finderMarkdown.folderGrant"
    private static let allFoldersKey = "finderActions.allFoldersID"
    private static let menuDepthKey = "finderActions.menuDepth"
    private static let favoritesKey = "finderActions.favoriteFolders"
    private static let appsKey = "finderActions.openWithApps"

    @Published private var grant = UserDefaults.standard.data(forKey: grantKey)
        .flatMap { try? PropertyListDecoder().decode(FinderFolderGrant.self, from: $0) }
    @Published private var allFoldersID = UserDefaults.standard.string(forKey: allFoldersKey).flatMap(UUID.init(uuidString:))
    @Published private(set) var extensionEnabled = false
    @Published private(set) var settingsError: String?
    @Published var menuDepth = FinderMenuDepth(rawValue: UserDefaults.standard.integer(forKey: menuDepthKey)) ?? .two {
        didSet {
            guard menuDepth != oldValue else { return }
            UserDefaults.standard.set(menuDepth.rawValue, forKey: Self.menuDepthKey)
            publishSettings()
        }
    }
    @Published private(set) var favorites = UserDefaults.standard.data(forKey: favoritesKey)
        .flatMap { try? PropertyListDecoder().decode([FinderFavorite].self, from: $0) } ?? FinderFavorite.standardDirectories()
    @Published private(set) var apps = UserDefaults.standard.data(forKey: appsKey)
        .flatMap { try? PropertyListDecoder().decode([FinderApp].self, from: $0) } ?? []
    private var picker: NSOpenPanel?
    private(set) var window: NSPanel?
    private(set) var pendingFileOperation: Task<Void, Never>?

    var selectedFolder: URL? { grant?.scope.directory }
    var coverage: FinderCoverage { allFoldersID == nil ? .selectedFolder : .allFolders }
    private var activeScope: FinderScope? { allFoldersID.map(FinderScope.allFolders(id:)) ?? grant?.scope }

    func setCoverage(_ coverage: FinderCoverage) {
        guard coverage != self.coverage else { return }
        let id = coverage == .allFolders ? UUID() : nil
        UserDefaults.standard.set(id?.uuidString, forKey: Self.allFoldersKey)
        allFoldersID = id
        settingsError = nil
        publishSettings()
    }

    func openDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func activeGrant() throws -> FinderFolderGrant {
        if let allFoldersID { return try FinderFiles.allFoldersGrant(id: allFoldersID) }
        guard let grant else { throw FinderFileError.unavailableFolder }
        return grant
    }

    func refreshExtensionStatus() {
        let enabled = FIFinderSyncController.isExtensionEnabled
        if extensionEnabled != enabled { extensionEnabled = enabled }
    }

    func manageExtension() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    func publishSettings() {
        FinderMenuSettings(scope: activeScope, language: .stored, depth: menuDepth,
                           favorites: favorites.map(\.menuEntry), apps: apps.map(\.menuEntry)).publish()
    }

    func addFavorite() {
        chooseFolder(initial: selectedFolder, title: "常用目录", prompt: "添加目录", parent: NSApp.keyWindow) { [weak self] folder in
            guard let self else { return }
            let directory = folder.resolvingSymlinksInPath().standardizedFileURL
            guard !self.favorites.contains(where: { $0.directory.standardizedFileURL.path == directory.path }) else { return }
            self.saveFavorites(self.favorites + [FinderFavorite(directory: directory)])
        }
    }

    func removeFavorite(_ id: UUID) {
        saveFavorites(favorites.filter { $0.id != id })
    }

    private func saveFavorites(_ folders: [FinderFavorite]) {
        guard let data = try? PropertyListEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: Self.favoritesKey)
        favorites = folders
        publishSettings()
    }

    func addApps() {
        choose(title: "选择应用", prompt: "添加", parent: NSApp.keyWindow, configure: { panel in
            panel.allowedContentTypes = [.applicationBundle]
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        }) { [weak self] urls in
            guard let self else { return }
            var apps = self.apps
            for app in urls.compactMap(FinderApp.init(bundleAt:)) where !apps.contains(where: { $0.isSameApp(as: app) }) {
                apps.append(app)
            }
            self.saveApps(apps)
        }
    }

    func removeApp(_ id: UUID) {
        saveApps(apps.filter { $0.id != id })
    }

    private func saveApps(_ apps: [FinderApp]) {
        guard let data = try? PropertyListEncoder().encode(apps) else { return }
        UserDefaults.standard.set(data, forKey: Self.appsKey)
        self.apps = apps
        publishSettings()
    }

    func selectFolder() {
        chooseFolder(initial: selectedFolder, title: "操作文件夹", prompt: "授权此文件夹",
                     parent: NSApp.keyWindow) { [weak self] folder in
            guard let self else { return }
            do {
                let grant = try FinderFiles.grant(for: folder)
                let data = try PropertyListEncoder().encode(grant)
                UserDefaults.standard.set(data, forKey: Self.grantKey)
                self.grant = grant
                self.settingsError = nil
                self.publishSettings()
            } catch {
                self.settingsError = error.localizedDescription
            }
        }
    }

    func clearFolder() {
        UserDefaults.standard.removeObject(forKey: Self.grantKey)
        grant = nil
        settingsError = nil
        publishSettings()
    }

    func handle(_ request: FinderActionRequest, copyText: (String) throws -> Void) {
        guard request.scopeID == activeScope?.id, FIFinderSyncController.isExtensionEnabled else { return }
        do {
            let grant = try activeGrant()
            switch request.action {
            case .create(let format):
                let destination = try FinderFiles.destination(at: request.paths[0], in: grant)
                presentName(format: format, destination: destination)
            case .copyPaths, .copyNames:
                let items = try request.paths.map { try FinderFiles.item(at: $0, in: grant) }
                let lines = items.map { request.action == .copyPaths ? $0.url.path : $0.url.lastPathComponent }
                try copyText(lines.joined(separator: "\n"))
            case .openTerminal:
                let item = try FinderFiles.item(at: request.paths[0], in: grant)
                let folder = try FinderFiles.terminalFolder(for: item, in: grant)
                openTerminal(at: folder)
            case .transfer(let operation):
                let items = try request.paths.map { try FinderFiles.item(at: $0, in: grant) }
                presentTransfer(operation, items: items, source: grant)
            case .archive(let operation):
                let paths = request.paths
                performFileOperation {
                    let items = try paths.map { try FinderFiles.item(at: $0, in: grant) }
                    return try FinderFiles.archive(operation, items: items, in: grant)
                }
            case .openFavorite(let id):
                guard let folder = favorites.first(where: { $0.id == id })?.directory,
                      try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                      NSWorkspace.shared.open(folder) else {
                    presentError(L("常用目录已移动或不可用。"))
                    return
                }
            case .openWith(let id):
                guard let app = apps.first(where: { $0.id == id })?.resolvedURL() else {
                    throw FinderAppError.unavailable
                }
                let items = try request.paths.map { try FinderFiles.item(at: $0, in: grant).url }
                open(items, with: app, addsToRecentItems: true)
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    private func presentName(format: FinderFileFormat, destination: FinderDestination) {
        // A prompt left from an earlier request is bound to another folder or
        // format; replace it instead of bringing it back for this one.
        window?.close()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        panel.title = L(format.windowTitle)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FinderNameView(
            directory: destination.url,
            format: format,
            onCreate: { [weak self] input in
                guard let self, self.window != nil,
                      FIFinderSyncController.isExtensionEnabled else {
                    throw FinderFileError.unavailableFolder
                }
                let grant = try self.activeGrant()
                let file = try FinderFiles.create(named: input, format: format, at: destination, in: grant)
                self.window?.close()
                NSWorkspace.shared.activateFileViewerSelecting([file])
            },
            onCancel: { [weak self] in self?.window?.close() }
        ).environment(\.locale, AppLanguage.stored.locale))
        panel.center()
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openTerminal(at folder: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            presentError(L("找不到终端应用。"))
            return
        }
        open([folder], with: terminal, addsToRecentItems: false)
    }

    private func open(_ items: [URL], with app: URL, addsToRecentItems: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = addsToRecentItems
        NSWorkspace.shared.open(items, withApplicationAt: app, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.presentError(error.localizedDescription) }
        }
    }

    private func presentTransfer(_ operation: FinderTransfer, items: [FinderSelectedItem], source: FinderFolderGrant) {
        guard pendingFileOperation == nil, let first = items.first else {
            presentError(L("请等当前的文件操作完成。"))
            return
        }
        chooseFolder(initial: first.url.deletingLastPathComponent(), title: operation.pickerTitle,
                     prompt: operation.confirmationTitle, parent: nil) { [weak self] destination in
            guard let self else { return }
            guard self.activeScope?.id == source.scope.id, FIFinderSyncController.isExtensionEnabled else {
                self.presentError(FinderFileError.unavailableFolder.localizedDescription)
                return
            }
            self.performFileOperation {
                let target = try FinderFiles.grant(for: destination, localVolumeOnly: !source.scope.coversAllFolders)
                return try FinderFiles.transfer(operation, items: items, from: source, to: target)
            }
        }
    }

    private func performFileOperation(_ operation: @escaping @Sendable () throws -> [URL]) {
        guard pendingFileOperation == nil else {
            presentError(L("请等当前的文件操作完成。"))
            return
        }
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        pendingFileOperation = Task { [weak self] in
            let result = await worker.result
            guard let self else { return }
            self.pendingFileOperation = nil
            switch result {
            case .success(let urls):
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            case .failure(let error):
                self.presentError(error.localizedDescription)
            }
        }
    }

    private func chooseFolder(initial: URL?, title: String, prompt: String, parent: NSWindow?,
                              onSelection: @escaping (URL) -> Void) {
        choose(title: title, prompt: prompt, parent: parent, configure: { panel in
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.directoryURL = initial
        }) { urls in
            if let folder = urls.first { onSelection(folder) }
        }
    }

    /// Shows one open panel at a time; a second request brings back the first.
    private func choose(title: String, prompt: String, parent: NSWindow?, configure: (NSOpenPanel) -> Void,
                        onSelection: @escaping ([URL]) -> Void) {
        guard picker == nil else {
            picker?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSOpenPanel()
        configure(panel)
        panel.title = L(title)
        panel.prompt = L(prompt)
        picker = panel
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] result in
            let urls = panel?.urls ?? []
            self?.picker = nil
            if result == .OK, !urls.isEmpty { onSelection(urls) }
        }
        if let parent {
            panel.beginSheetModal(for: parent, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L("访达操作失败")
        alert.informativeText = message
        alert.addButton(withTitle: L("关闭"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func cancel(in eventWindow: NSWindow?) -> Bool {
        guard let window, window === eventWindow else { return false }
        window.close()
        return true
    }

    /// Called when PawShot loses focus. The name prompt would only be hidden
    /// and AppKit would show it again with the next unrelated feature, so the
    /// request is cancelled, like clicking outside a popover.
    func dismissPrompts() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct FinderNameView: View {
    let directory: URL
    let format: FinderFileFormat
    let onCreate: (String) throws -> Void
    let onCancel: () -> Void
    @StoredState private var name = ""
    @StoredState private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(directory.path, systemImage: "folder")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(directory.path)

            HStack(spacing: 8) {
                TextField("文件名", text: $name, prompt: Text("文件名"))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($nameFocused)
                    .onSubmit(create)
                    .onChange(of: name) { _, _ in errorMessage = nil }
                Text("." + format.rawValue)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.muted)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.danger)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("创建", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.background)
        .tint(Palette.accent)
        .onAppear { nameFocused = true }
    }

    private func create() {
        do { try onCreate(name) }
        catch {
            errorMessage = error.localizedDescription
            nameFocused = true
        }
    }
}
