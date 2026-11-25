import AppKit
import SwiftUI

enum ShiguangSettingsPage: String, CaseIterable, Identifiable {
    case general
    case screenshot
    case translation
    case clipboard
    case quickInput
    case finderActions = "finderMarkdown"
    case shortcuts
    case history
    case privacy
    case about

    var id: String { rawValue }

    static let groups: [SettingsSidebarGroup] = [
        SettingsSidebarGroup(title: nil, pages: [.general]),
        SettingsSidebarGroup(title: "功能", pages: [.screenshot, .translation, .clipboard, .quickInput, .finderActions]),
        SettingsSidebarGroup(title: "偏好", pages: [.shortcuts, .history, .privacy]),
        SettingsSidebarGroup(title: "应用", pages: [.about])
    ]

    var title: String {
        switch self {
        case .general: return "通用"
        case .screenshot: return "截图"
        case .translation: return "翻译"
        case .clipboard: return "剪贴板"
        case .quickInput: return "启动台"
        case .finderActions: return "超级右键"
        case .shortcuts: return "快捷键"
        case .history: return "历史记录"
        case .privacy: return "隐私与存储"
        case .about: return "关于"
        }
    }

    var summary: String {
        switch self {
        case .general: return "启动、菜单栏与显示样式"
        case .screenshot: return "截图流程、识别和历史记录"
        case .translation: return "翻译引擎、默认语言和 AI 接口"
        case .clipboard: return "系统剪贴板历史、快捷键和本机保存"
        case .quickInput: return "搜索应用与文件，快捷生成变量名和测试数据"
        case .finderActions: return "访达菜单、压缩和常用目录"
        case .shortcuts: return "区域截图、截图翻译和剪贴板快捷键"
        case .history: return "查看最近截图、识别文字和译文"
        case .privacy: return "屏幕访问、本机处理和本地数据"
        case .about: return "版本、开源地址和隐私说明"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .screenshot: return "rectangle.dashed"
        case .translation: return "character.bubble"
        case .clipboard: return "list.clipboard"
        case .quickInput: return "bolt.horizontal.circle"
        case .finderActions: return "cursorarrow.click"
        case .shortcuts: return "keyboard"
        case .history: return "clock.arrow.circlepath"
        case .privacy: return "lock.shield"
        case .about: return "info.circle"
        }
    }

    var keywords: [String] {
        switch self {
        case .general:
            return ["截图", "开始", "菜单栏", "状态", "权限", "剪贴板", "快捷键", "翻译",
                    "开机", "启动", "登录项", "颜色", "图标", "配置", "导出", "备份", "JSON", "export", "backup"]
        case .screenshot:
            return ["自动识别", "OCR", "文字识别", "自动翻译", "历史", "保存", "截图流程", "确认", "复制"]
        case .translation:
            return ["语言", "中文", "英文", "日文", "目标语言", "源语言", "Apple",
                    "AI", "API", "Key", "模型", "接口", "OpenAI", "Responses", "Claude",
                    "Anthropic", "Gemini", "文字翻译", "翻译剪贴板", "划词翻译", "选区"]
        case .clipboard:
            return ["历史", "系统剪贴板", "复制", "监听", "记录", "图片", "GIF", "视频", "文件",
                    "保留", "日期", "天数", "清除", "变量名", "驼峰", "随机", "姓名", "邮箱",
                    "地址", "IP", "身份证"]
        case .quickInput:
            return ["启动台", "启动器", "快捷输入", "搜索", "应用", "文件", "快捷键", "热键"]
        case .finderActions:
            return ["Finder", "访达", "右键", "Markdown", "新建", "文件夹", "路径", "终端", "移动", "压缩", "解压", "目录", "层数", "扩展", "授权", "完整磁盘访问",
                    "应用", "软件", "打开方式", "用应用打开"]
        case .shortcuts:
            return ["快捷键", "热键", "按键", "区域截图", "截图并翻译", "剪贴板历史",
                    "翻译剪贴板", "划词翻译", "变量名"]
        case .history:
            return ["历史", "截图历史", "搜索", "删除", "本地存储", "识别文字", "译文"]
        case .privacy:
            return ["隐私", "权限", "屏幕录制", "屏幕访问", "辅助功能", "划词翻译",
                    "Vision", "本机", "数据", "清空"]
        case .about:
            return ["版本", "关于", "GitHub", "开源", "菜单栏", "Dock", "隐私", "更新"]
        }
    }

    func matches(_ query: String) -> Bool {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        return ([title, summary] + keywords).contains {
            $0.localizedCaseInsensitiveContains(value)
        }
    }
}

struct SettingsSidebarGroup: Identifiable {
    let title: String?
    let pages: [ShiguangSettingsPage]
    var id: String { title ?? pages.first?.rawValue ?? "settings" }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clipboard: ClipboardHistory
    @ObservedObject var finderActions: FinderActionsCoordinator
    @AppStorage("settings.selectedPage") private var storedPageRaw = ShiguangSettingsPage.general.rawValue
    @StoredState private var selectedPage = ShiguangSettingsPage(
        rawValue: UserDefaults.standard.string(forKey: "settings.selectedPage") ?? ""
    ) ?? .general
    @StoredState private var query = ""

    private var selection: ShiguangSettingsPage {
        selectedPage
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 206)
            Rectangle().fill(Palette.line).frame(width: 1)
            SettingsDetailView(model: model, clipboard: clipboard, finderActions: finderActions, page: selection)
        }
        .id(model.appLanguage)
        .navigationTitle(L(selection.title))
        .tint(Palette.accent)
        .foregroundStyle(Palette.ink)
        .preferredColorScheme(.light)
        .environment(\.locale, model.appLanguage.locale)
        .frame(minWidth: 780, minHeight: 560)
        .sheet(isPresented: $model.showsPermissionHelp) { permissionHelp }
        .alert("需要留意", isPresented: Binding(
            get: { !model.isTextWorkspace && model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: query) { _, value in
            let matches = ShiguangSettingsPage.allCases.filter { $0.matches(value) }
            if !matches.contains(selection), let first = matches.first {
                select(first)
            }
        }
        .onChange(of: selectedPage) { _, page in
            storedPageRaw = page.rawValue
        }
        .onChange(of: storedPageRaw) { _, raw in
            guard let page = ShiguangSettingsPage(rawValue: raw), page != selectedPage else { return }
            select(page)
        }
    }

    private func select(_ page: ShiguangSettingsPage) {
        guard page != selectedPage else { return }
        // Do not route a click through UserDefaults and a second SwiftUI update.
        // The selected page must be visible on the next display pass.
        withTransaction(Transaction(animation: nil)) {
            selectedPage = page
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                MenuBarBrandMark(style: model.menuBarIconStyle,
                                 customImageData: model.customMenuBarIconData,
                                 size: 38,
                                 language: model.appLanguage)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NookPup").font(.system(size: 13.5, weight: .semibold))
                    Text("偏好设置").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 16)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Palette.muted)
                TextField("搜索设置", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted)
                    }
                    .buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 10).frame(height: 30)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.line))
            .padding(.horizontal, 12).padding(.bottom, 12)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(ShiguangSettingsPage.groups) { group in
                        let pages = group.pages.filter { $0.matches(query) }
                        if !pages.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                if let title = group.title {
                                    Text(LocalizedStringKey(title))
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Palette.muted)
                                        .padding(.horizontal, 10)
                                        .padding(.bottom, 2)
                                }
                                ForEach(pages) { page in
                                    SettingsSidebarRow(page: page, isSelected: selection == page) {
                                        select(page)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .overlay {
                if ShiguangSettingsPage.allCases.allSatisfy({ !$0.matches(query) }) {
                    Text("没有匹配的设置").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
            }

            Rectangle().fill(Palette.line.opacity(0.75)).frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: "menubar.rectangle").font(.system(size: 11))
                Text(model.showsMenuBarIcon ? "菜单栏常驻" : "菜单栏已隐藏").font(.system(size: 10.5))
                Spacer(minLength: 0)
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-")")
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundStyle(Palette.muted)
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Palette.sidebar)
    }

    private var permissionHelp: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsSymbolTile(symbol: "lock.shield", accented: true, size: 40)
            Text("允许 NookPup 访问屏幕").font(.system(size: 22, weight: .semibold))
            Text(model.screenPermission.detail).font(.system(size: 13))
                .foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("授予屏幕权限") { model.requestPermission() }.buttonStyle(.borderedProminent)
                Button("打开系统设置") { model.openPermissionSettings() }
                Button("重新检查") { model.checkPermission() }
            }
            HStack {
                Button("稍后", role: .cancel) { model.showsPermissionHelp = false }
                Spacer()
                Button("重启 NookPup") { model.restartApp?() }
            }
        }
        .padding(28).frame(width: 480).background(Palette.background)
    }
}

private struct SettingsSidebarRow: View {
    let page: ShiguangSettingsPage
    let isSelected: Bool
    let action: () -> Void
    @StoredState private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsSymbolTile(symbol: page.symbol, selected: isSelected, size: 24)
                Text(LocalizedStringKey(page.title))
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.panel)
                        .shadow(color: Palette.shadow, radius: 2, y: 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Palette.line, lineWidth: 1)
                        )
                } else if hovered {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.ink.opacity(0.045))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(LocalizedStringKey(page.title)))
    }
}

private struct SettingsSymbolTile: View {
    let symbol: String
    var selected = false
    var accented = false
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(selected ? Color.white : accented ? Palette.accent : Palette.ink.opacity(0.78))
            .frame(width: size, height: size)
            .background(selected ? Palette.accent : accented ? Palette.accentSoft : Palette.ink.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .overlay {
                if accented && !selected {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(Palette.accent.opacity(0.16), lineWidth: 1)
                }
            }
            .accessibilityHidden(true)
    }
}

private struct SettingsDetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clipboard: ClipboardHistory
    @ObservedObject var finderActions: FinderActionsCoordinator
    let page: ShiguangSettingsPage
    @StoredState private var revealsAIKey = false
    @StoredState private var confirmsClearHistory = false
    @StoredState private var isExportingConfiguration = false
    @StoredState private var exportedConfigurationURL: URL?
    @StoredState private var configurationExportError: String?
    @StoredState private var isImportingConfiguration = false
    @StoredState private var pendingConfigurationImport: PendingConfigurationImport?
    @StoredState private var configurationImportError: String?
    @StoredState private var configurationImportNotes: [String]?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 13) {
                        SettingsSymbolTile(symbol: page.symbol, accented: true, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LocalizedStringKey(page.title)).font(.system(size: 20, weight: .semibold))
                            Text(LocalizedStringKey(page.summary)).font(.system(size: 12)).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    Rectangle().fill(Palette.line).frame(height: 1)
                }
                pageContent
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        // Keep the hosting ScrollView alive while switching pages. Recreating
        // every detail view (and all of its controls) is the expensive part.
        .animation(nil, value: page)
        .background(Palette.background)
        .onChange(of: page) { _, _ in revealsAIKey = false }
        .sheet(item: $pendingConfigurationImport, onDismiss: showConfigurationImportResult) { pending in
            ConfigurationImportConfirmation(pending: pending, model: model,
                onCancel: { pendingConfigurationImport = nil },
                onApply: { applyConfigurationImport(pending) })
        }
        .alert("清空全部截图历史？", isPresented: $confirmsClearHistory) {
            Button("取消", role: .cancel) {}
            Button("全部清除", role: .destructive) { model.clearHistory() }
        } message: {
            Text("这会删除本机保存的全部截图、标注、识别文字和译文。")
        }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general: generalContent
        case .screenshot: screenshotContent
        case .translation: translationContent
        case .clipboard: clipboardContent
        case .quickInput: quickInputContent
        case .finderActions: finderActionsContent
        case .shortcuts: shortcutsContent
        case .history: historyContent
        case .privacy: privacyContent
        case .about: aboutContent
        }
    }

    private var generalContent: some View {
        Group {
            SettingsSection("语言") {
                SettingsRow("界面语言", detail: "切换后菜单、窗口和设置会立即更新") {
                    Picker("界面语言", selection: $model.appLanguage) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.nativeTitle).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 120, alignment: .trailing)
                }
            }
            SettingsSection("启动与菜单栏",
                            status: model.launchAtLoginRequiresApproval ? nil : model.launchAtLoginMessage) {
                SettingsToggle(
                    "登录时自动启动",
                    detail: model.launchAtLoginRequiresApproval
                        ? "等待你在系统设置中允许 NookPup"
                        : "登录 Mac 后自动在菜单栏运行",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled || model.launchAtLoginRequiresApproval },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                if model.launchAtLoginRequiresApproval {
                    SettingsSeparator()
                    SettingsRow("系统登录项待确认", detail: "macOS 需要你手动允许一次") {
                        Button("打开设置") { model.openLoginItemsSettings() }
                    }
                }
                SettingsSeparator()
                SettingsToggle("显示菜单栏图标", detail: "关闭后仍可通过快捷键和重新打开应用使用",
                               isOn: $model.showsMenuBarIcon)
                SettingsSeparator()
                SettingsRow("菜单栏图标", detail: "选择单色、彩色或上传图片") {
                    MenuBarIconPicker(selection: $model.menuBarIconStyle,
                                      customImageData: $model.customMenuBarIconData,
                                      language: model.appLanguage)
                }
            }
            configurationExportContent
        }
    }

    private var configurationExportContent: some View {
        SettingsSection("配置备份") {
            SettingsActionRow(title: "导出配置",
                              detail: "保存当前设置，不含 API Key、历史内容和系统授权",
                              symbol: "square.and.arrow.up") { exportConfiguration() }
                .disabled(isExportingConfiguration || isImportingConfiguration || pendingConfigurationImport != nil)
            SettingsSeparator()
            SettingsActionRow(title: "导入配置",
                              detail: "读取 NookPup 配置备份，确认后恢复设置",
                              symbol: "square.and.arrow.down") { importConfiguration() }
                .disabled(isExportingConfiguration || isImportingConfiguration || pendingConfigurationImport != nil || model.isBusy)
            if let error = configurationImportError {
                SettingsSeparator()
                Text("\(L("配置导入失败"))：\(error)")
                    .font(.system(size: 11)).foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.vertical, 12)
            }
            if let url = exportedConfigurationURL {
                SettingsSeparator()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("配置已导出", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Palette.success)
                        Text(url.lastPathComponent).foregroundStyle(Palette.muted)
                            .textSelection(.enabled)
                    }
                    .font(.system(size: 11))
                    Spacer(minLength: 0)
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            if let error = configurationExportError {
                SettingsSeparator()
                Label {
                    Text("\(L("配置导出失败"))：\(error)")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .font(.system(size: 11)).foregroundStyle(Palette.danger)
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
        }
    }

    private var configurationSnapshot: ConfigurationExport {
        ConfigurationExport(settings: .init(
            general: .init(appLanguage: model.appLanguage.rawValue,
                           launchAtLogin: model.launchAtLoginEnabled || model.launchAtLoginRequiresApproval,
                           showsMenuBarIcon: model.showsMenuBarIcon,
                           menuBarIconStyle: model.menuBarIconStyle.rawValue,
                           customMenuBarIconData: model.customMenuBarIconData),
            screenshot: .init(autoOCR: model.autoOCR, autoTranslate: model.autoTranslate,
                              keepHistory: model.keepHistory, autoCleanHistory: model.autoCleanHistory,
                              fillShapes: model.fillShapes),
            translation: .init(provider: model.translationProvider.rawValue,
                               sourceLanguage: model.defaultSourceLanguage, targetLanguage: model.defaultTargetLanguage,
                               aiAPI: model.aiAPI.rawValue, aiBaseURL: model.aiBaseURL,
                               aiModel: model.aiModel, aiInstructions: model.aiInstructions),
            clipboard: .init(monitorsSystem: clipboard.monitorsSystem, retentionDays: clipboard.retentionDays),
            shortcuts: .init(capture: model.captureHotkey, translate: model.translateHotkey,
                             clipboard: model.clipboardHotkey, clipboardTranslate: model.clipboardTranslateHotkey,
                             selectionTranslate: model.selectionTranslateHotkey, launcher: model.variableNamingHotkey),
            quickInput: .init(variableNamingStyle: model.variableNamingStyle.rawValue),
            finderActions: .init(coverage: finderActions.coverage.rawValue,
                                 selectedFolderPath: finderActions.selectedFolder?.path,
                                 menuDepth: finderActions.menuDepth.rawValue,
                                 favoriteFolders: finderActions.favorites.map {
                                     .init(path: $0.directory.path, systemTitle: $0.systemTitle, symbol: $0.symbol)
                                 },
                                 openWithApps: finderActions.apps.map {
                                     .init(path: $0.url.path, bundleIdentifier: $0.bundleIdentifier)
                                 })
        ))
    }

    private func importConfiguration() {
        guard !isImportingConfiguration, !isExportingConfiguration, !model.isBusy else { return }
        isImportingConfiguration = true
        configurationImportError = nil
        let panel = NSOpenPanel()
        panel.title = L("导入配置")
        panel.prompt = L("选择")
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            isImportingConfiguration = false
            guard response == .OK, let url = panel.url else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let plan = try ConfigurationImport(configuration: ConfigurationExport.read(from: url))
                pendingConfigurationImport = PendingConfigurationImport(url: url, plan: plan)
            } catch { configurationImportError = importErrorDescription(error) }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func applyConfigurationImport(_ pending: PendingConfigurationImport) {
        do {
            // Recheck local paths immediately before commit, using the exact approved snapshot.
            let plan = try ConfigurationImport(configuration: pending.plan.configuration)
            configurationImportNotes = try plan.apply(to: model, clipboard: clipboard, finderActions: finderActions)
            configurationImportError = nil
            pendingConfigurationImport = nil
        } catch {
            pendingConfigurationImport = nil
            configurationImportError = importErrorDescription(error)
        }
    }

    private func showConfigurationImportResult() {
        guard let notes = configurationImportNotes else { return }
        configurationImportNotes = nil
        let alert = NSAlert()
        alert.messageText = L("配置已导入")
        alert.informativeText = ([L("设置已恢复并保存，无需重新启动。")] + notes).joined(separator: "\n\n")
        alert.addButton(withTitle: L("好"))
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func importErrorDescription(_ error: Error) -> String {
        guard let error = error as? ConfigurationFileError else { return error.localizedDescription }
        switch error {
        case .tooLarge: return L("配置文件超过 8 MB，请选择 NookPup 导出的 JSON 文件。")
        case .invalidFormat: return L("这不是有效的 NookPup 配置备份。")
        case .unsupportedVersion: return L("暂不支持此配置版本，请使用兼容版本的 NookPup。")
        case .invalidData: return L("配置内容缺失或损坏，当前设置未更改。")
        case .invalidValue(let field): return "\(L("配置值无效"))：\(L(field))"
        }
    }

    private func exportConfiguration() {
        guard !isExportingConfiguration else { return }
        isExportingConfiguration = true
        let panel = NSSavePanel()
        panel.title = L("导出配置")
        panel.prompt = L("导出")
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = ConfigurationExport.suggestedFilename()
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            isExportingConfiguration = false
            guard response == .OK, let url = panel.url else { return }
            exportedConfigurationURL = nil
            configurationExportError = nil
            do {
                try configurationSnapshot.write(to: url)
                exportedConfigurationURL = url
            } catch {
                configurationExportError = importErrorDescription(error)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private var screenshotContent: some View {
        Group {
            SettingsSection("图片处理") {
                SettingsToggle("自动识别文字", detail: "导入图片后，提取其中的文字", isOn: $model.autoOCR)
                SettingsSeparator()
                SettingsToggle("识别后自动翻译", detail: "使用当前选择的翻译引擎", isOn: $model.autoTranslate)
                SettingsSeparator()
                SettingsToggle("保留截图历史", detail: "本机保存截图、标注与译文，默认保留 30 天", isOn: $model.keepHistory)
            }
            SettingsSection("开始截图") {
                SettingsActionRow(title: "截取屏幕区域", symbol: "viewfinder") { model.capture() }
                SettingsSeparator()
                SettingsActionRow(title: "导入图片", symbol: "photo.badge.plus") { model.importImage() }
            }
        }
    }

    private var translationContent: some View {
        Group {
            SettingsSection("翻译方式") {
                SettingsRow("翻译引擎") {
                    Picker("翻译引擎", selection: $model.translationProvider) {
                        ForEach(TranslationProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 230, alignment: .trailing)
                    .animation(nil, value: model.translationProvider)
                }
            }

            if model.translationProvider == .ai {
                SettingsSection("AI 服务") {
                    SettingsRow("协议") {
                        Picker("AI 协议", selection: Binding(
                            get: { model.aiAPI },
                            set: { model.selectAIAPI($0) }
                        )) {
                            ForEach(AITranslationAPI.allCases) { api in
                                Text(api.title).tag(api)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 210, alignment: .trailing)
                    }
                    SettingsSeparator()
                    SettingsFieldRow("接口地址") {
                        TextField(model.aiAPI.defaultBaseURL, text: $model.aiBaseURL)
                            .accessibilityLabel("AI 接口地址")
                    }
                    SettingsSeparator()
                    SettingsFieldRow("模型") {
                        aiModelField
                    }
                    if let message = model.aiModelFetchMessage {
                        HStack(spacing: 6) {
                            Image(systemName: message.hasPrefix("已获取")
                                  ? "checkmark.circle"
                                  : message.hasPrefix("正在") ? "arrow.clockwise" : "exclamationmark.circle")
                            Text(message)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(message.hasPrefix("已获取")
                                         ? Palette.success
                                         : message.hasPrefix("正在") ? Palette.muted : Palette.danger)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    }
                    SettingsSeparator()
                    SettingsFieldRow("API Key") {
                        HStack(spacing: 8) {
                            Group {
                                if revealsAIKey { TextField("输入 API Key", text: $model.aiAPIKey) }
                                else { SecureField("输入 API Key", text: $model.aiAPIKey) }
                            }
                            .accessibilityLabel("AI API Key")
                            Button { revealsAIKey.toggle() } label: {
                                Image(systemName: revealsAIKey ? "eye.slash" : "eye")
                                    .foregroundStyle(Palette.muted)
                            }
                            .buttonStyle(.plain)
                            .help(revealsAIKey ? "隐藏 API Key" : "显示 API Key")
                            .accessibilityLabel(revealsAIKey ? "隐藏 API Key" : "显示 API Key")
                        }
                    }
                    SettingsSeparator()
                    SettingsFieldRow("附加要求") {
                        TextField("可选：术语、语气或专有名词", text: $model.aiInstructions)
                            .accessibilityLabel("AI 翻译附加要求")
                    }
                    SettingsSeparator()
                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        if let message = model.aiTestMessage {
                            Text(message).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if model.aiTesting { ProgressView().controlSize(.small) }
                        Button("测试连接") { model.testAITranslation() }.disabled(model.aiTesting)
                    }
                    .controlSize(.small).padding(.horizontal, 16).padding(.vertical, 12)
                }
            }

            SettingsSection("语言") {
                SettingsRow("默认目标语言") {
                    Picker("目标语言", selection: Binding(get: { model.defaultTargetLanguage },
                                                        set: { model.setDefaultTargetLanguage($0) })) {
                        ForEach(LanguageChoice.targets) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 150, alignment: .trailing)
                }
            }
            SettingsSection("快捷入口") {
                SettingsActionRow(title: "文字翻译", detail: "直接输入或粘贴原文", symbol: "text.bubble") {
                    model.startTextTranslation()
                }
                SettingsSeparator()
                SettingsActionRow(title: "翻译剪贴板", symbol: "doc.on.clipboard",
                                  shortcut: model.clipboardTranslateHotkey.symbol) { model.translateClipboard() }
                SettingsSeparator()
                SettingsActionRow(title: "划词翻译", detail: "读取其他应用选中的文字并翻译", symbol: "text.cursor",
                                  shortcut: model.selectionTranslateHotkey.symbol) { model.translateSelection?() }
            }
        }
    }

    private var aiModelField: some View {
        HStack(spacing: 7) {
            TextField(model.aiAPI.defaultModel, text: $model.aiModel)
                .accessibilityLabel("AI 模型")
                .layoutPriority(1)

            if !model.aiModels.isEmpty {
                Menu {
                    ForEach(model.aiModels) { option in
                        Button {
                            model.aiModel = option.id
                        } label: {
                            if option.title == option.id {
                                Text(option.id)
                            } else {
                                Text("\(option.title) · \(option.id)")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 24, height: 24)
                        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line))
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("选择已获取的模型")
                .accessibilityLabel("选择已获取的模型")
            }

            Button { model.fetchAIModels() } label: {
                HStack(spacing: 5) {
                    if model.aiModelFetching {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    Text(model.aiModelFetching ? "获取中" : "获取模型")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(model.aiModelFetching)
            .help("从当前接口获取可用模型")
            .accessibilityLabel("获取 AI 模型列表")
        }
    }

    private var clipboardContent: some View {
        SettingsSection("系统剪贴板") {
            SettingsToggle("记录剪贴板历史", detail: "支持文字、图片、GIF、视频和文件", isOn: $clipboard.monitorsSystem)
            SettingsSeparator()
            SettingsRow("保留时间", detail: "超过所选日期的记录会自动删除") {
                Picker("保留时间", selection: $clipboard.retentionDays) {
                    ForEach(ClipboardHistory.retentionOptions, id: \.self) { days in
                            Text(L("\(days) 天")).tag(days)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 94, alignment: .trailing)
            }
            SettingsSeparator()
            SettingsRow("清除记录", detail: "删除本机保存的全部剪贴板历史") {
                Button("清除记录", role: .destructive) { clipboard.clear() }
                    .disabled(clipboard.entries.isEmpty)
            }
        }
    }

    private var quickInputContent: some View {
        Group {
            SettingsSection("全局快捷键", status: model.hotkeyAvailable ? nil : "部分快捷键已被占用，请更换组合键。") {
                HotkeyRow(title: "启动台", settings: $model.variableNamingHotkey,
                          onRecordingChanged: model.setHotkeyCaptureActive)
            }

            SettingsSection("使用方法") {
                QuickInputGuideRow(
                    symbol: "magnifyingglass",
                    title: "搜索应用与文件",
                    detail: "输入应用名即可打开；也可以搜索本机文件并用访达显示。",
                    example: "Safari / 访达 / 项目文档"
                )
                SettingsSeparator()
                QuickInputGuideRow(
                    symbol: "textformat.abc",
                    title: "直接生成变量名",
                    detail: "输入中文或英文名称，选择小驼峰、大驼峰、下划线、短横线或常量格式。",
                    example: "用户登录 → userLogin / UserLogin / user_login"
                )
                SettingsSeparator()
                QuickInputGuideRow(
                    symbol: "chevron.left.forwardslash.chevron.right",
                    title: "用快捷语指定格式",
                    detail: "在内容前加入 xt、dt、snake、kebab 或 const，快速选择命名方式。",
                    example: "xt 用户登录 → userLogin"
                )
                SettingsSeparator()
                QuickInputGuideRow(
                    symbol: "wand.and.stars",
                    title: "生成随机测试数据",
                    detail: "输入姓名、邮箱、地址、手机号、IP、身份证、UUID 或密码即可生成。",
                    example: "姓名 / 邮箱 / 地址 / IP / UUID / 密码"
                )
            }

            SettingsSection("工具箱") {
                SettingsActionRow(title: "打开工具箱", detail: "JSON、Base64、URL 与编码转换",
                                  symbol: "wrench.and.screwdriver") {
                    model.showToolbox?()
                }
            }
        }
    }

    private var finderActionsContent: some View {
        Group {
            SettingsSection("访达扩展") {
                SettingsRow("超级右键", detail: finderActions.extensionEnabled ? "已启用" : "未启用") {
                    Button("系统设置") { finderActions.manageExtension() }
                }
                SettingsSeparator()
                SettingsRow("菜单层数", detail: finderActions.menuDepth == .two ? "新建文件、应用和常用目录按类展开" : "操作直接显示在右键菜单") {
                    Picker("菜单层数", selection: $finderActions.menuDepth) {
                        ForEach(FinderMenuDepth.allCases, id: \.rawValue) { depth in
                            Text(LocalizedStringKey(depth.title)).tag(depth)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                SettingsSeparator()
                SettingsRow("操作范围") {
                    Picker("操作范围", selection: Binding(
                        get: { finderActions.coverage },
                        set: { finderActions.setCoverage($0) }
                    )) {
                        ForEach(FinderCoverage.allCases, id: \.rawValue) { coverage in
                            Text(LocalizedStringKey(coverage.title)).tag(coverage)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                SettingsSeparator()
                if finderActions.coverage == .allFolders {
                    SettingsRow("完整磁盘访问", detail: "使用系统保护的目录时，为 NookPup 授权一次") {
                        Button("打开系统设置") { finderActions.openDiskAccessSettings() }
                    }
                } else {
                    SettingsRow("操作文件夹", detail: finderActions.selectedFolder?.path ?? "尚未选择文件夹") {
                        HStack(spacing: 8) {
                            if finderActions.selectedFolder != nil {
                                Button("取消选择") { finderActions.clearFolder() }
                            }
                            Button("选择文件夹…") { finderActions.selectFolder() }
                        }
                    }
                }
            }
            SettingsSection("用应用打开") {
                ForEach(finderActions.apps) { app in
                    FinderAppRow(app: app) { finderActions.removeApp(app.id) }
                    SettingsSeparator()
                }
                SettingsActionRow(title: "添加应用", symbol: "plus.app") {
                    finderActions.addApps()
                }
            }
            SettingsSection("常用目录") {
                ForEach(finderActions.favorites) { favorite in
                    SettingsRow(favorite.title, detail: favorite.directory.path) {
                        Button {
                            finderActions.removeFavorite(favorite.id)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .accessibilityLabel(Text("移除常用目录"))
                    }
                    SettingsSeparator()
                }
                SettingsActionRow(title: "添加目录", symbol: "folder.badge.plus") {
                    finderActions.addFavorite()
                }
            }
            if let error = finderActions.settingsError {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.danger)
            }
        }
        .onAppear { finderActions.refreshExtensionStatus() }
    }

    private var shortcutsContent: some View {
        Group {
            SettingsSection("全局快捷键", status: model.hotkeyAvailable ? nil : "部分快捷键已被占用，请更换组合键。") {
                VStack(spacing: 0) {
                    HotkeyRow(title: "区域截图", settings: $model.captureHotkey,
                              onRecordingChanged: model.setHotkeyCaptureActive)
                    SettingsSeparator()
                    HotkeyRow(title: "截图并翻译", settings: $model.translateHotkey,
                              onRecordingChanged: model.setHotkeyCaptureActive)
                    SettingsSeparator()
                    HotkeyRow(title: "剪贴板历史", settings: $model.clipboardHotkey,
                              onRecordingChanged: model.setHotkeyCaptureActive)
                    SettingsSeparator()
                    HotkeyRow(title: "翻译剪贴板", settings: $model.clipboardTranslateHotkey,
                              onRecordingChanged: model.setHotkeyCaptureActive)
                    SettingsSeparator()
                    HotkeyRow(title: "划词翻译", settings: $model.selectionTranslateHotkey,
                              onRecordingChanged: model.setHotkeyCaptureActive)
                    SettingsSeparator()
                    HotkeyRow(title: "启动台", settings: $model.variableNamingHotkey,
                              onRecordingChanged: model.setHotkeyCaptureActive)
                }
            }
        }
    }

    private var historyContent: some View {
        Group {
            SettingsSection("最近截图") {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField("搜索标题或识别文字", text: $model.search).textFieldStyle(.plain)
                        .accessibilityLabel("搜索截图历史")
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("清除历史搜索")
                    }
                    if !model.records.isEmpty {
                        Divider().frame(height: 14)
                        Button { confirmsClearHistory = true } label: {
                            Label("全部清除", systemImage: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.danger)
                        .accessibilityLabel("全部清除")
                    }
                }
                .font(.system(size: 12)).padding(16)
                SettingsSeparator()
                if model.filteredRecords.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle").font(.system(size: 24, weight: .light))
                        Text(model.records.isEmpty ? "暂无截图历史" : "没有匹配的记录").font(.system(size: 12))
                    }
                    .foregroundStyle(Palette.muted).frame(maxWidth: .infinity).padding(.vertical, 32)
                } else {
                    ForEach(model.filteredRecords) { record in
                        SettingsHistoryRow(model: model, record: record)
                        if record.id != model.filteredRecords.last?.id { SettingsSeparator() }
                    }
                }
            }
            SettingsSection("管理记录") {
                SettingsToggle("30 天自动清理", detail: "自动删除超过 30 天的截图、标注、识别文字和译文", isOn: $model.autoCleanHistory)
                SettingsSeparator()
                SettingsRow("本地存储") {
                    Button("在访达中打开") { openDataDirectory() }
                }
                SettingsSeparator()
                SettingsRow("清空截图历史", detail: "移除已保存的截图、识别文字和译文") {
                    Button("全部清除", role: .destructive) { confirmsClearHistory = true }
                        .disabled(model.records.isEmpty)
                }
            }
        }
    }

    private var privacyContent: some View {
        Group {
            SettingsSection("屏幕访问") {
                PermissionActionRow(model: model)
            }
            SettingsSection("划词翻译") {
                SettingsRow("辅助功能访问",
                            detail: SelectedTextReader.isTrusted ? "已授权，可读取其他应用的选中文字" : "需要在系统设置中允许 NookPup 读取选中文字") {
                    HStack(spacing: 10) {
                        Text(SelectedTextReader.isTrusted ? "已授权" : "待授权")
                            .foregroundStyle(SelectedTextReader.isTrusted ? Palette.success : Palette.warning)
                        Button("系统设置") {
                            _ = SelectedTextReader.requestAccess()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            SettingsSection("数据处理") {
                SettingsRow("文字识别", detail: "通过 Apple Vision 在本机提取文字") { Text("本机").foregroundStyle(Palette.muted) }
                SettingsSeparator()
                SettingsRow("翻译", detail: model.translationProvider == .ai ? "文字发送到你配置的 AI 服务" : "通过 Apple 系统翻译框架处理") {
                    Text(model.translationProvider.title).foregroundStyle(Palette.muted)
                }
                SettingsSeparator()
                SettingsRow("统计与账号", detail: "没有统计 SDK、自建服务器或账号系统") { Text("无").foregroundStyle(Palette.muted) }
            }
            SettingsSection("本地数据") {
                SettingsRow("应用数据目录") { Button("在访达中打开") { openDataDirectory() } }
                SettingsSeparator()
                SettingsRow("截图历史") {
                    Button("全部清除", role: .destructive) { confirmsClearHistory = true }
                        .disabled(model.records.isEmpty)
                }
            }
        }
    }

    private var aboutContent: some View {
        Group {
            HStack(spacing: 18) {
                MenuBarBrandMark(style: model.menuBarIconStyle,
                                 customImageData: model.customMenuBarIconData,
                                 size: 72,
                                 language: model.appLanguage)
                VStack(alignment: .leading, spacing: 5) {
                    Text("NookPup").font(.system(size: 20, weight: .semibold))
                    Text("你的 Mac 菜单栏工具箱").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    (Text("版本") + Text(verbatim: " \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"))"))
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            SettingsSection("项目") {
                SettingsActionRow(
                    title: "GitHub",
                    detail: "github.com/youcanyoudonocannobb/shiguang-screenshot",
                    symbol: "link"
                ) {
                    if let url = URL(string: "https://github.com/youcanyoudonocannobb/shiguang-screenshot") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            SettingsSection("运行方式") {
                SettingsRow("菜单栏常驻", detail: "关闭窗口后继续运行，Dock 中不显示图标") {
                    Text(LocalizedStringKey(model.showsMenuBarIcon ? model.menuBarIconStyle.titleKey : "已隐藏"))
                        .foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func openDataDirectory() {
        if let directory = model.store?.directory { NSWorkspace.shared.open(directory) }
    }
}

private struct MenuBarBrandMark: View {
    let style: MenuBarIconStyle
    let customImageData: Data?
    let size: CGFloat
    let language: AppLanguage

    private var image: NSImage {
        BrandArtwork.menuBarImage(
            tintHex: style.colorHex,
            customImageData: style == .custom ? customImageData : nil,
            size: NSSize(width: size, height: size)
        )
    }

    var body: some View {
        let artwork = image
        Image(nsImage: artwork)
            .resizable()
            .renderingMode(artwork.isTemplate ? .template : .original)
            .scaledToFit()
            .foregroundStyle(Palette.ink)
            .frame(width: size, height: size)
            .accessibilityLabel(
                Text(AppLocalization.text("当前菜单栏图标：", language: language))
                    + Text(verbatim: AppLocalization.text(style.titleKey, language: language))
            )
    }
}

private struct PendingConfigurationImport: Identifiable {
    let id = UUID()
    let url: URL
    let plan: ConfigurationImport
}

private struct ConfigurationImportConfirmation: View {
    let pending: PendingConfigurationImport
    @ObservedObject var model: AppModel
    let onCancel: () -> Void
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("导入配置", systemImage: "square.and.arrow.down")
                .font(.system(size: 18, weight: .semibold))
            Text("请核对备份信息，确认后将覆盖当前设置。")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        previewRow("备份文件", pending.url.lastPathComponent)
                        previewRow("导出时间", pending.plan.configuration.exportedAt.formatted(date: .abbreviated, time: .shortened))
                        previewRow("备份版本", "NookPup \(pending.plan.configuration.appVersion) (\(pending.plan.configuration.buildNumber))")
                        previewRow("界面语言", pending.plan.appLanguage.nativeTitle)
                        previewRow("翻译引擎", pending.plan.provider.title)
                        previewRow("AI 接口", pending.plan.aiAPI.title)
                        previewRow("AI 接口地址", pending.plan.configuration.settings.translation.aiBaseURL)
                        previewRow("剪贴板保留天数", String(pending.plan.configuration.settings.clipboard.retentionDays))
                        previewRow("操作范围", L(pending.plan.coverage.title))
                        if let path = pending.plan.configuration.settings.finderActions.selectedFolderPath {
                            previewRow("备份操作文件夹", path)
                        }
                    }
                    Divider()
                    Text("将恢复通用、截图、翻译、剪贴板、六组快捷键、启动台和超级右键设置。")
                    Text("历史保留策略会立即生效，过期的截图或剪贴板记录可能被清理。")
                        .foregroundStyle(Palette.danger)
                    Text("系统授权保留本机状态；操作文件夹需在超级右键中重新选择并授权。")
                    if pending.plan.coverage == .allFolders {
                        Text("备份将启用所有文件夹范围，超级右键菜单会出现在本机有权访问的所有目录中。")
                    }
                    if pending.plan.changesAIEndpoint(in: model) {
                        Text("AI 接口已更改，请重新填写 API Key；本机保存的密钥未删除。")
                    }
                    if pending.plan.hasConflictingShortcuts {
                        Text("备份中的快捷键存在重复，导入后请在快捷键设置中调整。")
                            .foregroundStyle(Palette.danger)
                    }
                    if pending.plan.unavailableItemCount > 0 {
                        Text("未找到的目录或应用已跳过；整组都不可用时保留本机列表。")
                    }
                }
                .font(.system(size: 12)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 380)
            Divider()
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("确认导入", action: onApply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy)
            }
        }
        .padding(24).frame(width: 520)
    }

    private func previewRow(_ title: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(LocalizedStringKey(title)).foregroundStyle(Palette.muted)
            Text(verbatim: value).frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MenuBarIconPicker: View {
    @Binding var selection: MenuBarIconStyle
    @Binding var customImageData: Data?
    let language: AppLanguage
    @StoredState private var showsPicker = false
    @StoredState private var showsImporter = false
    @StoredState private var errorMessage: String?

    var body: some View {
        Button { showsPicker.toggle() } label: {
            HStack(spacing: 8) {
                iconPreview(selection)
                    .frame(width: 20, height: 18)
                    .frame(width: 26, height: 26)
                Text(AppLocalization.text(selection.titleKey, language: language))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("选择菜单栏图标")
        .accessibilityLabel(
            Text(AppLocalization.text("菜单栏图标：", language: language))
                + Text(verbatim: AppLocalization.text(selection.titleKey, language: language))
        )
        .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
            pickerPanel
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.image],
                      allowsMultipleSelection: false, onCompletion: importCustomIcon)
    }

    private var pickerPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("菜单栏图标")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 7) {
                ForEach(MenuBarIconStyle.allCases.filter { $0 != .custom }) { style in
                    styleButton(style)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    errorMessage = nil
                    showsImporter = true
                } label: {
                    Label(customImageData == nil ? "上传图标图片…" : "更换图标图片…",
                          systemImage: "square.and.arrow.up")
                }
                Spacer(minLength: 0)
                if customImageData != nil {
                    Button(selection == .custom ? "正在使用" : "使用图片") {
                        selection = .custom
                        showsPicker = false
                    }
                    .disabled(selection == .custom)
                    Button {
                        customImageData = nil
                        if selection == .custom { selection = .system }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("移除自定义图标")
                    .accessibilityLabel("移除自定义菜单栏图标")
                }
            }
            .controlSize(.small)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 318)
        .background(Palette.panel)
    }

    private func styleButton(_ style: MenuBarIconStyle) -> some View {
        Button {
            selection = style
            showsPicker = false
        } label: {
            VStack(spacing: 5) {
                iconPreview(style)
                    .frame(width: 20, height: 18)
                Text(AppLocalization.text(style.titleKey, language: language))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(selection == style ? Palette.accent : Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(width: 48, height: 52)
            .background(
                previewTint(style).opacity(selection == style ? 0.16 : 0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selection == style ? Palette.accent : Palette.line,
                            lineWidth: selection == style ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(AppLocalization.text(style.titleKey, language: language)))
        .accessibilityLabel(Text(AppLocalization.text(style.titleKey, language: language)))
        .accessibilityAddTraits(selection == style ? .isSelected : [])
    }

    private func iconPreview(_ style: MenuBarIconStyle) -> some View {
        let image = BrandArtwork.menuBarImage(tintHex: style.colorHex,
                                              customImageData: style == .custom ? customImageData : nil)
        return Image(nsImage: image)
            .resizable()
            .renderingMode(image.isTemplate ? .template : .original)
            .scaledToFit()
            .foregroundStyle(Palette.ink)
    }

    private func importCustomIcon(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard let normalized = BrandArtwork.normalizedMenuBarIconData(from: data) else {
                    errorMessage = "无法读取这张图片，请改用 PNG、JPG、HEIC 或 TIFF。"
                    return
                }
                customImageData = normalized
                selection = .custom
                errorMessage = nil
                showsPicker = false
            } catch {
                errorMessage = "读取图片失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            errorMessage = "选择图片失败：\(error.localizedDescription)"
        }
    }

    private func previewTint(_ style: MenuBarIconStyle) -> Color {
        style.colorHex.map(Color.init(hex:)) ?? Palette.ink
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    /// A problem the user must act on, such as a hotkey conflict. Sections
    /// carry no explanatory footers.
    var status: String?
    @ViewBuilder var content: Content

    init(_ title: String, status: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.status = status
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringKey(title)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.muted)
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.line, lineWidth: 1))
            if let status {
                Label {
                    Text(L(status)).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.warning)
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct SettingsSeparator: View {
    var body: some View {
        Rectangle().fill(Palette.line.opacity(0.8)).frame(height: 1).padding(.horizontal, 16)
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 16) {
            SettingsRowLabel(title: title, detail: detail)
            Spacer(minLength: 0)
            control.fixedSize(horizontal: true, vertical: false).controlSize(.small)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.vertical, 13)
        .frame(minHeight: 50)
    }
}

private struct SettingsToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        SettingsRow(title, detail: detail) {
            Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch)
                .accessibilityLabel(Text(LocalizedStringKey(title)))
        }
    }
}

private struct SettingsFieldRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 16) {
            Text(LocalizedStringKey(title)).font(.system(size: 12.5, weight: .medium)).frame(width: 72, alignment: .leading)
            content.textFieldStyle(.plain).font(.system(size: 12)).multilineTextAlignment(.leading)
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

private struct SettingsRowLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title)).font(.system(size: 12.5, weight: .medium))
            if let detail {
                Text(LocalizedStringKey(detail)).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsActionRow: View {
    let title: String
    var detail: String?
    let symbol: String
    var shortcut: String?
    let action: () -> Void
    @StoredState private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SettingsSymbolTile(symbol: symbol, accented: true, size: 30)
                SettingsRowLabel(title: title, detail: detail)
                Spacer(minLength: 0)
                if let shortcut { SettingsKeycap(text: shortcut) }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.muted.opacity(0.7))
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
            .background(hovered ? Palette.accent.opacity(0.035) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(LocalizedStringKey(title)))
    }
}

/// An app the Finder menu can open items with, shown with its own icon.
private struct FinderAppRow: View {
    let app: FinderApp
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // App icons carry their own margins, so 32 pt lines up with the 30 pt tiles.
            Image(nsImage: app.icon).resizable().interpolation(.high).frame(width: 32, height: 32)
                .padding(-1)
                .accessibilityHidden(true)
            SettingsRowLabel(title: app.title, detail: app.resolvedURL()?.path ?? "找不到应用")
            Spacer(minLength: 0)
            Button(action: onRemove) { Image(systemName: "minus.circle") }
                .controlSize(.small)
                .accessibilityLabel(Text("移除应用"))
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(minHeight: 54)
    }
}

private struct QuickInputGuideRow: View {
    let symbol: String
    let title: String
    let detail: String
    let example: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsSymbolTile(symbol: symbol, accented: true, size: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 12.5, weight: .medium))
                Text(LocalizedStringKey(detail))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(LocalizedStringKey(example))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 68)
    }
}

private struct SettingsKeycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.muted).padding(.horizontal, 7).frame(height: 23)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line))
    }
}

private struct PermissionActionRow: View {
    @ObservedObject var model: AppModel
    var body: some View {
        SettingsRow("屏幕访问", detail: model.screenPermission.isGranted ? "已授权，可开始截图与录制" : "截图与录制需要屏幕访问权限") {
            HStack(spacing: 10) {
                if !model.screenPermission.isGranted {
                    Button("授予权限") { model.requestPermission() }
                }
                Button("检查") { model.checkPermission() }
                Button("系统设置") { model.openPermissionSettings() }
            }
        }
    }
}

private struct SettingsHistoryRow: View {
    @ObservedObject var model: AppModel
    let record: CaptureRecord
    @Environment(\.locale) private var locale

    private var localizedTitle: String {
        for prefix in ["长截图", "截图"] where record.title.hasPrefix(prefix) {
            return L(prefix) + String(record.title.dropFirst(prefix.count))
        }
        return record.title
    }

    var body: some View {
        HStack(spacing: 12) {
            if let image = model.store?.image(for: record) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 48, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                SettingsSymbolTile(symbol: "photo", size: 38)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(localizedTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(record.createdAt.formatted(
                    .dateTime.month().day().hour().minute().locale(locale)
                ))
                    .font(.system(size: 10.5)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            Button { model.select(record) } label: { Image(systemName: "arrow.up.right") }
                .buttonStyle(.borderless).help("打开截图").accessibilityLabel("打开截图")
            Button(role: .destructive) { model.delete(record) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("删除截图").accessibilityLabel("删除截图")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
