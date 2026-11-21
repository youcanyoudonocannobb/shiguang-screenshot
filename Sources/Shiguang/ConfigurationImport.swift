import AppKit
import ImageIO

/// A fully validated, side-effect-free plan. Selecting or cancelling a file never changes settings.
@MainActor
struct ConfigurationImport {
    let configuration: ConfigurationExport
    let appLanguage: AppLanguage
    let menuBarIconStyle: MenuBarDogStyle
    let provider: TranslationProvider
    let aiAPI: AITranslationAPI
    let namingStyle: VariableNamingStyle
    let coverage: FinderCoverage
    let menuDepth: FinderMenuDepth
    let favoriteFolders: [FinderFavorite]?
    let openWithApps: [FinderApp]?
    let unavailableItemCount: Int
    let hasConflictingShortcuts: Bool

    init(configuration: ConfigurationExport) throws {
        let settings = configuration.settings
        func value<T>(_ parsed: T?, _ field: String) throws -> T {
            guard let parsed else { throw ConfigurationFileError.invalidValue(field) }
            return parsed
        }
        appLanguage = try value(AppLanguage(rawValue: settings.general.appLanguage), "界面语言")
        menuBarIconStyle = try value(MenuBarDogStyle(rawValue: settings.general.menuBarIconStyle), "菜单栏图标")
        provider = try value(TranslationProvider(rawValue: settings.translation.provider), "翻译引擎")
        aiAPI = try value(AITranslationAPI(rawValue: settings.translation.aiAPI), "AI 接口")
        namingStyle = try value(VariableNamingStyle(rawValue: settings.quickInput.variableNamingStyle), "默认变量格式")
        coverage = try value(FinderCoverage(rawValue: settings.finderActions.coverage), "操作范围")
        menuDepth = try value(FinderMenuDepth(rawValue: settings.finderActions.menuDepth), "菜单层级")
        guard ClipboardHistory.retentionOptions.contains(settings.clipboard.retentionDays) else {
            throw ConfigurationFileError.invalidValue("剪贴板保留天数")
        }
        for (language, allowsAuto) in [(settings.translation.sourceLanguage, true), (settings.translation.targetLanguage, false)] {
            guard (allowsAuto && language == "auto") ||
                    language.range(of: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$"#, options: .regularExpression) != nil else {
                throw ConfigurationFileError.invalidValue("翻译语言")
            }
        }
        let endpoint = settings.translation.aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !endpoint.isEmpty {
            guard AITranslationService.endpoint(for: endpoint) != nil,
                  let url = URLComponents(string: endpoint), !ConfigurationExport.endpointContainsCredentials(endpoint),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                throw ConfigurationFileError.invalidValue("AI 接口地址")
            }
        }
        if let icon = settings.general.customMenuBarIconData {
            guard icon.count <= 1_024 * 1_024,
                  let source = CGImageSourceCreateWithData(icon as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...512).contains(width), (1...512).contains(height),
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw ConfigurationFileError.invalidValue("自定义图标")
            }
        } else if menuBarIconStyle == .custom {
            throw ConfigurationFileError.invalidValue("自定义图标")
        }
        let shortcuts = settings.shortcuts
        let hotkeys = [shortcuts.capture, shortcuts.translate, shortcuts.clipboard,
                       shortcuts.clipboardTranslate, shortcuts.selectionTranslate, shortcuts.launcher]
        guard hotkeys.allSatisfy(\.isValid) else { throw ConfigurationFileError.invalidValue("快捷键") }
        let combinations = Set(hotkeys.map { "\($0.keyCode):\($0.carbonModifiers)" })
        hasConflictingShortcuts = combinations.count != hotkeys.count

        func isAbsolutePath(_ path: String) -> Bool { path.hasPrefix("/") && !path.contains("\0") }
        let finder = settings.finderActions
        guard finder.favoriteFolders.count <= 1_000, finder.openWithApps.count <= 1_000,
              finder.selectedFolderPath.map(isAbsolutePath) ?? true,
              finder.favoriteFolders.allSatisfy({ isAbsolutePath($0.path) }),
              finder.openWithApps.allSatisfy({ isAbsolutePath($0.path) }) else {
            throw ConfigurationFileError.invalidValue("超级右键")
        }
        var skipped = 0
        var directories = Set<String>()
        var folders: [FinderFavorite] = []
        for folder in finder.favoriteFolders {
            let url = URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                skipped += 1
                continue
            }
            if directories.insert(url.path).inserted {
                folders.append(FinderFavorite(directory: url, systemTitle: folder.systemTitle, symbol: folder.symbol))
            }
        }
        var apps: [FinderApp] = []
        for item in finder.openWithApps {
            var candidate = item.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .flatMap(FinderApp.init(bundleAt:))
            if candidate == nil, let atPath = FinderApp(bundleAt: URL(fileURLWithPath: item.path)),
               item.bundleIdentifier == nil || atPath.bundleIdentifier == item.bundleIdentifier { candidate = atPath }
            guard let candidate else { skipped += 1; continue }
            if !apps.contains(where: { $0.isSameApp(as: candidate) }) { apps.append(candidate) }
        }
        // A backup from another Mac must not silently erase usable local lists.
        favoriteFolders = !finder.favoriteFolders.isEmpty && folders.isEmpty ? nil : folders
        openWithApps = !finder.openWithApps.isEmpty && apps.isEmpty ? nil : apps
        unavailableItemCount = skipped
        self.configuration = configuration
    }

    func changesAIEndpoint(in model: AppModel) -> Bool {
        model.aiAPI != aiAPI || model.aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) !=
            configuration.settings.translation.aiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Persist the ordinary settings together; system registration is handled separately below.
    func applyModelSettings(to model: AppModel, clipboard: ClipboardHistory) {
        let settings = configuration.settings
        model.performConfigurationUpdate {
            model.applyImportedAIConfiguration(api: aiAPI, baseURL: settings.translation.aiBaseURL,
                                               model: settings.translation.aiModel, instructions: settings.translation.aiInstructions)
            model.translationProvider = provider
            model.autoOCR = settings.screenshot.autoOCR
            model.autoTranslate = settings.screenshot.autoTranslate
            model.keepHistory = settings.screenshot.keepHistory
            model.fillShapes = settings.screenshot.fillShapes
            if model.autoCleanHistory != settings.screenshot.autoCleanHistory { model.autoCleanHistory = settings.screenshot.autoCleanHistory }
            if clipboard.monitorsSystem != settings.clipboard.monitorsSystem { clipboard.monitorsSystem = settings.clipboard.monitorsSystem }
            if clipboard.retentionDays != settings.clipboard.retentionDays { clipboard.retentionDays = settings.clipboard.retentionDays }
            model.restoreTranslationLanguageDefaults(source: settings.translation.sourceLanguage,
                                                     target: settings.translation.targetLanguage)
            model.variableNamingStyle = namingStyle
            model.captureHotkey = settings.shortcuts.capture
            model.translateHotkey = settings.shortcuts.translate
            model.clipboardHotkey = settings.shortcuts.clipboard
            model.clipboardTranslateHotkey = settings.shortcuts.clipboardTranslate
            model.selectionTranslateHotkey = settings.shortcuts.selectionTranslate
            model.variableNamingHotkey = settings.shortcuts.launcher
            model.customMenuBarIconData = settings.general.customMenuBarIconData
            model.menuBarDogStyle = menuBarIconStyle
            model.showsMenuBarIcon = settings.general.showsMenuBarIcon
            model.appLanguage = appLanguage
        }
    }

    /// The caller presents the validated snapshot and history policies before invoking this method.
    func apply(to model: AppModel, clipboard: ClipboardHistory, finderActions: FinderActionsCoordinator) throws -> [String] {
        guard !model.isBusy else { throw ConfigurationFileError.invalidValue("请等待当前任务完成后再导入") }
        let settings = configuration.settings
        let needsKey = changesAIEndpoint(in: model)
        // Encode the Finder data before changing other preferences.
        try finderActions.restoreConfiguration(coverage: coverage, menuDepth: menuDepth,
                                               favorites: favoriteFolders, apps: openWithApps)
        applyModelSettings(to: model, clipboard: clipboard)
        var notes: [String] = []
        if needsKey { notes.append(L("AI 接口已更改，请重新填写 API Key；本机保存的密钥未删除。")) }
        if unavailableItemCount > 0 { notes.append(L("未找到的目录或应用已跳过；整组都不可用时保留本机列表。")) }
        if coverage == .selectedFolder, let path = settings.finderActions.selectedFolderPath,
           finderActions.selectedFolder?.standardizedFileURL.path != URL(fileURLWithPath: path).standardizedFileURL.path {
            notes.append(L("操作文件夹保留本机授权；如需使用备份中的目录，请在超级右键中重新选择。"))
        }
        model.refreshLaunchAtLoginState()
        let loginEnabled = model.launchAtLoginEnabled || model.launchAtLoginRequiresApproval
        if loginEnabled != settings.general.launchAtLogin { model.setLaunchAtLogin(settings.general.launchAtLogin) }
        if let message = model.launchAtLoginMessage { notes.append(message) }
        if hasConflictingShortcuts || !model.hotkeyAvailable { notes.append(L("部分快捷键无法注册，请在快捷键设置中检查。")) }
        return notes
    }
}
