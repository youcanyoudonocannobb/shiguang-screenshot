import AppKit
import SwiftUI

enum ShiguangSettingsPage: String, CaseIterable, Identifiable {
    case general
    case screenshot
    case translation
    case clipboard
    case shortcuts
    case history
    case privacy
    case tools
    case about

    var id: String { rawValue }

    static let groups: [SettingsSidebarGroup] = [
        SettingsSidebarGroup(title: nil, pages: [.general]),
        SettingsSidebarGroup(title: "功能", pages: [.screenshot, .translation, .clipboard]),
        SettingsSidebarGroup(title: "偏好", pages: [.shortcuts, .history, .privacy]),
        SettingsSidebarGroup(title: "应用", pages: [.tools, .about])
    ]

    var title: String {
        switch self {
        case .general: return "通用"
        case .screenshot: return "截图"
        case .translation: return "翻译"
        case .clipboard: return "剪贴板"
        case .shortcuts: return "快捷键"
        case .history: return "历史记录"
        case .privacy: return "隐私与存储"
        case .tools: return "其他入口"
        case .about: return "关于"
        }
    }

    var summary: String {
        switch self {
        case .general: return "快速截图、运行状态和常用操作"
        case .screenshot: return "截图流程、识别和历史记录"
        case .translation: return "翻译引擎、默认语言和 AI 接口"
        case .clipboard: return "系统剪贴板历史、快捷键和本机保存"
        case .shortcuts: return "区域截图、截图翻译和剪贴板快捷键"
        case .history: return "查看最近截图、识别文字和译文"
        case .privacy: return "屏幕访问、本机处理和本地数据"
        case .tools: return "导入图片、文字翻译和体验示例"
        case .about: return "版本、运行方式和隐私说明"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .screenshot: return "rectangle.dashed"
        case .translation: return "character.bubble"
        case .clipboard: return "list.clipboard"
        case .shortcuts: return "keyboard"
        case .history: return "clock.arrow.circlepath"
        case .privacy: return "lock.shield"
        case .tools: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }

    var keywords: [String] {
        switch self {
        case .general:
            return ["截图", "开始", "菜单栏", "状态", "权限", "剪贴板", "快捷键", "翻译"]
        case .screenshot:
            return ["自动识别", "OCR", "文字识别", "自动翻译", "历史", "保存", "截图流程", "确认", "复制"]
        case .translation:
            return ["语言", "中文", "英文", "日文", "目标语言", "源语言", "Apple",
                    "AI", "API", "Key", "模型", "接口", "文字翻译", "翻译剪贴板"]
        case .clipboard:
            return ["历史", "系统剪贴板", "复制", "监听", "记录", "图片", "GIF", "视频", "文件", "100"]
        case .shortcuts:
            return ["快捷键", "热键", "按键", "区域截图", "截图并翻译", "剪贴板历史", "翻译剪贴板"]
        case .history:
            return ["历史", "截图历史", "搜索", "删除", "本地存储", "识别文字", "译文"]
        case .privacy:
            return ["隐私", "权限", "屏幕录制", "屏幕访问", "Vision", "本机", "数据", "清空"]
        case .tools:
            return ["导入图片", "文字翻译", "翻译剪贴板", "体验示例", "OCR", "工具"]
        case .about:
            return ["版本", "关于", "菜单栏", "Dock", "隐私", "更新"]
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
    @AppStorage("settings.selectedPage") private var selectedPageRaw = ShiguangSettingsPage.general.rawValue
    @StoredState private var query = ""

    private var selection: ShiguangSettingsPage {
        ShiguangSettingsPage(rawValue: selectedPageRaw) ?? .general
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 206)
            Rectangle().fill(Palette.line).frame(width: 1)
            SettingsDetailView(model: model, clipboard: clipboard, page: selection)
        }
        .navigationTitle(selection.title)
        .tint(Palette.accent)
        .foregroundStyle(Palette.ink)
        .preferredColorScheme(.light)
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
                selectedPageRaw = first.rawValue
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().scaledToFit().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("拾光截图").font(.system(size: 13.5, weight: .semibold))
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
                                    Text(title)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Palette.muted)
                                        .padding(.horizontal, 10)
                                        .padding(.bottom, 2)
                                }
                                ForEach(pages) { page in
                                    SettingsSidebarRow(page: page, isSelected: selection == page) {
                                        selectedPageRaw = page.rawValue
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
                Text("菜单栏常驻").font(.system(size: 10.5))
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
            Text("允许拾光访问屏幕").font(.system(size: 22, weight: .semibold))
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
                Button("重启拾光") { model.restartApp?() }
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
                Text(page.title)
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
        .accessibilityLabel(page.title)
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
    let page: ShiguangSettingsPage
    @StoredState private var revealsAIKey = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 13) {
                        SettingsSymbolTile(symbol: page.symbol, accented: true, size: 36)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(page.title).font(.system(size: 20, weight: .semibold))
                            Text(page.summary).font(.system(size: 12)).foregroundStyle(Palette.muted)
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
        .id(page)
        .background(Palette.background)
        .onChange(of: page) { _, _ in revealsAIKey = false }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general: generalContent
        case .screenshot: screenshotContent
        case .translation: translationContent
        case .clipboard: clipboardContent
        case .shortcuts: shortcutsContent
        case .history: historyContent
        case .privacy: privacyContent
        case .tools: toolsContent
        case .about: aboutContent
        }
    }

    private var generalContent: some View {
        Group {
            SettingsOverviewStrip(model: model, clipboard: clipboard)
            SettingsSection("常用操作") {
                SettingsActionRow(title: "区域截图", detail: "选中区域后，直接标注与编辑", symbol: "viewfinder",
                                  shortcut: model.captureHotkey.symbol) { model.capture() }
                SettingsSeparator()
                SettingsActionRow(title: "截图并翻译", detail: "框选文字，打开独立翻译窗口", symbol: "character.bubble",
                                  shortcut: model.translateHotkey.symbol) { model.capture(translate: true) }
                SettingsSeparator()
                SettingsActionRow(title: "剪贴板历史", detail: "找回并复制最近的内容", symbol: "list.clipboard",
                                  shortcut: model.clipboardHotkey.symbol) { model.showClipboard?() }
            }
            SettingsSection("使用方式") {
                SettingsRow("菜单栏运行", detail: "关闭窗口后仍可使用快捷键和菜单栏入口") {
                    Text("已启用").foregroundStyle(Palette.muted)
                }
                SettingsSeparator()
                PermissionActionRow(model: model)
            }
            SettingsFootnote("截图、视频与 GIF 在点击 ✓ 后复制到剪贴板。按 Esc 取消本次操作。",
                             symbol: "checkmark.circle")
        }
    }

    private var screenshotContent: some View {
        Group {
            SettingsSection("图片处理", footer: "自动处理仅用于导入图片。屏幕截图始终先进入编辑。") {
                SettingsToggle("自动识别文字", detail: "导入图片后，提取其中的文字", isOn: $model.autoOCR)
                SettingsSeparator()
                SettingsToggle("识别后自动翻译", detail: "使用当前选择的翻译引擎", isOn: $model.autoTranslate)
                SettingsSeparator()
                SettingsToggle("保留截图历史", detail: "本机保留最近 30 张截图、标注与译文", isOn: $model.keepHistory)
            }
            SettingsSection("开始截图") {
                SettingsActionRow(title: "截取屏幕区域", symbol: "viewfinder") { model.capture() }
                SettingsSeparator()
                SettingsActionRow(title: "导入图片", symbol: "photo.badge.plus") { model.importImage() }
            }
            SettingsFootnote("点击 ✓ 才复制并写入历史；点击 × 或按 Esc 丢弃本次草稿。", symbol: "cursorarrow.click")
        }
    }

    private var translationContent: some View {
        Group {
            SettingsSection("翻译方式", footer: model.translationProvider == .apple
                            ? "使用 Apple 系统翻译；首次使用某个语言对时，可能需要下载语言包。"
                            : "翻译内容会发送到你配置的 AI 服务。") {
                SettingsRow("翻译引擎") {
                    Picker("翻译引擎", selection: $model.translationProvider) {
                        ForEach(TranslationProvider.allCases) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 230)
                }
            }

            if model.translationProvider == .ai {
                SettingsSection("AI 服务", footer: "API Key 仅保存在 macOS 钥匙串。测试连接会发送一次 Hello 翻译请求。") {
                    SettingsFieldRow("接口地址") {
                        TextField("https://api.openai.com/v1", text: $model.aiBaseURL)
                            .accessibilityLabel("AI 接口地址")
                    }
                    SettingsSeparator()
                    SettingsFieldRow("模型") {
                        TextField("gpt-4o-mini", text: $model.aiModel).accessibilityLabel("AI 模型")
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
                        Button("测试连接") { model.testAITranslation() }.disabled(model.aiTesting)
                        if model.aiTesting { ProgressView().controlSize(.small) }
                        if let message = model.aiTestMessage {
                            Text(message).font(.system(size: 11)).foregroundStyle(Palette.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .controlSize(.small).padding(.horizontal, 16).padding(.vertical, 12)
                }
            }

            SettingsSection("语言", footer: "自动识别原文：中文默认译英语，其他语言默认译简体中文。") {
                SettingsRow("默认目标语言") {
                    Picker("目标语言", selection: Binding(get: { model.targetLanguage },
                                                        set: { model.languageEdited(target: $0) })) {
                        ForEach(LanguageChoice.targets) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 150)
                }
            }
            SettingsSection("快捷入口") {
                SettingsActionRow(title: "文字翻译", detail: "直接输入或粘贴原文", symbol: "text.bubble") {
                    model.startTextTranslation()
                }
                SettingsSeparator()
                SettingsActionRow(title: "翻译剪贴板", symbol: "doc.on.clipboard",
                                  shortcut: model.clipboardTranslateHotkey.symbol) { model.translateClipboard() }
            }
        }
    }

    private var clipboardContent: some View {
        Group {
            SettingsSection("系统剪贴板", footer: "历史仅保存在本机，标记为保密或临时的内容不会被记录。") {
                SettingsToggle("记录剪贴板历史", detail: "支持文字、图片、GIF、视频和文件", isOn: $clipboard.monitorsSystem)
                SettingsSeparator()
                SettingsRow("保留数量", detail: "相同内容自动去重") {
                    Text("最近 100 项").foregroundStyle(Palette.muted)
                }
                SettingsSeparator()
                SettingsRow("当前记录") {
                    Text("\(clipboard.entries.count) 项").foregroundStyle(Palette.muted)
                }
            }
            SettingsSection("快捷入口") {
                SettingsActionRow(title: "打开剪贴板历史", symbol: "list.clipboard",
                                  shortcut: model.clipboardHotkey.symbol) { model.showClipboard?() }
            }
        }
    }

    private var shortcutsContent: some View {
        Group {
            SettingsSection("全局快捷键", footer: "点击输入框后直接按下组合键，也可以手动输入 option+shift+s。按 Esc 取消录入。") {
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
                }
            }
            SettingsFootnote(model.hotkeyAvailable ? "所有快捷键已就绪，可在其他应用中使用。" : "部分快捷键已被占用，请更换组合键。",
                             symbol: model.hotkeyAvailable ? "checkmark.circle" : "exclamationmark.triangle",
                             tint: model.hotkeyAvailable ? Palette.success : Palette.warning)
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
                SettingsRow("本地存储") {
                    Button("在访达中打开") { openDataDirectory() }
                }
                SettingsSeparator()
                SettingsRow("清空截图历史", detail: "移除已保存的截图、识别文字和译文") {
                    Button("清空…", role: .destructive) { model.clearHistory() }.disabled(model.records.isEmpty)
                }
            }
        }
    }

    private var privacyContent: some View {
        Group {
            SettingsSection("屏幕访问", footer: "只在你主动截图、识别或录制时读取所选区域。") {
                PermissionActionRow(model: model)
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
                    Button("清空…", role: .destructive) { model.clearHistory() }.disabled(model.records.isEmpty)
                }
            }
        }
    }

    private var toolsContent: some View {
        SettingsSection("快捷入口") {
            SettingsActionRow(title: "导入图片", detail: "提取已有图片中的文字", symbol: "photo.badge.plus") { model.importImage() }
            SettingsSeparator()
            SettingsActionRow(title: "文字翻译", detail: "直接输入或粘贴原文", symbol: "text.bubble") { model.startTextTranslation() }
            SettingsSeparator()
            SettingsActionRow(title: "翻译剪贴板", symbol: "doc.on.clipboard") { model.translateClipboard() }
            SettingsSeparator()
            SettingsActionRow(title: "体验示例", detail: "用内置示例检查识别效果", symbol: "sparkles") { model.useDemo() }
        }
    }

    private var aboutContent: some View {
        Group {
            HStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 5) {
                    Text("拾光截图").font(.system(size: 20, weight: .semibold))
                    Text("截取片刻，读懂世界。").font(.system(size: 12)).foregroundStyle(Palette.muted)
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"))")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            SettingsSection("运行方式") {
                SettingsRow("菜单栏常驻", detail: "关闭窗口后继续运行，Dock 中不显示图标") {
                    Text("已启用").foregroundStyle(Palette.muted)
                }
            }
            SettingsFootnote("文字识别在本机处理。Apple 与 AI 翻译可在翻译设置中选择；使用 AI 时，文字会发送到你配置的服务。",
                             symbol: "hand.raised")
        }
    }

    private func openDataDirectory() {
        if let directory = model.store?.directory { NSWorkspace.shared.open(directory) }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.muted)
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.line, lineWidth: 1))
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
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
                .accessibilityLabel(title)
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
            Text(title).font(.system(size: 12.5, weight: .medium)).frame(width: 72, alignment: .leading)
            content.textFieldStyle(.plain).font(.system(size: 12)).multilineTextAlignment(.leading)
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

private struct SettingsOverviewStrip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clipboard: ClipboardHistory

    var body: some View {
        HStack(spacing: 0) {
            metric(
                label: "屏幕权限",
                value: model.screenPermission.isGranted ? "已授权" : "待授权",
                dot: model.screenPermission.isGranted ? Palette.success : Palette.warning
            )
            divider
            metric(
                label: "翻译引擎",
                value: model.translationProvider.title,
                dot: Palette.accent
            )
            divider
            metric(
                label: "剪贴板记录",
                value: "\(clipboard.entries.count) / 100 项",
                dot: clipboard.monitorsSystem ? Palette.success : Palette.muted
            )
        }
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.line, lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(Palette.line).frame(width: 1, height: 34)
    }

    private func metric(label: String, value: String, dot: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11)).foregroundStyle(Palette.muted)
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsRowLabel: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12.5, weight: .medium))
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
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
        .accessibilityLabel(title)
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

private struct SettingsFootnote: View {
    let text: String
    let symbol: String
    var tint: Color = Palette.muted

    init(_ text: String, symbol: String, tint: Color = Palette.muted) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 14)
            Text(text).foregroundStyle(Palette.muted).lineSpacing(3)
        }
        .font(.system(size: 11))
        .fixedSize(horizontal: false, vertical: true)
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
    var body: some View {
        HStack(spacing: 12) {
            if let image = model.store?.image(for: record) {
                Image(nsImage: image).resizable().scaledToFill().frame(width: 48, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                SettingsSymbolTile(symbol: "photo", size: 38)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(record.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(record.createdAt.formatted(.dateTime.month().day().hour().minute()))
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
