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
        case .translation: return "原文语种、默认目标语言和翻译入口"
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
        case .screenshot: return "viewfinder"
        case .translation: return "character.bubble.fill"
        case .clipboard: return "clipboard.fill"
        case .shortcuts: return "command"
        case .history: return "clock.arrow.circlepath"
        case .privacy: return "lock.shield.fill"
        case .tools: return "wrench.and.screwdriver.fill"
        case .about: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .general: return Color(hex: "66736D")
        case .screenshot: return Color(hex: "D45D3C")
        case .translation: return Color(hex: "2F795E")
        case .clipboard: return Color(hex: "B97832")
        case .shortcuts: return Color(hex: "596FA8")
        case .history: return Color(hex: "8A7131")
        case .privacy: return Color(hex: "456D60")
        case .tools: return Color(hex: "806855")
        case .about: return Color(hex: "314139")
        }
    }

    var keywords: [String] {
        switch self {
        case .general:
            return ["截图", "开始", "菜单栏", "状态", "权限", "剪贴板", "快捷键", "翻译"]
        case .screenshot:
            return ["自动识别", "OCR", "文字识别", "自动翻译", "历史", "保存", "截图流程", "确认", "复制"]
        case .translation:
            return ["语言", "中文", "英文", "日文", "目标语言", "源语言", "Apple", "文字翻译", "翻译剪贴板"]
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
        HSplitView {
            sidebar
                .frame(minWidth: 172, idealWidth: 196, maxWidth: 230)
            SettingsDetailView(model: model, clipboard: clipboard, page: selection)
        }
        .navigationTitle(selection.title)
        .tint(Palette.accent)
        .preferredColorScheme(.light)
        .frame(minWidth: 760, minHeight: 540)
        .sheet(isPresented: $model.showsPermissionHelp) {
            permissionHelp
        }
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
            brandHeader
            searchBar
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 9)

            List(selection: selectionBinding) {
                ForEach(ShiguangSettingsPage.groups) { group in
                    let pages = group.pages.filter { $0.matches(query) }
                    if !pages.isEmpty {
                        if let title = group.title {
                            Section(title) {
                                rows(pages)
                            }
                        } else {
                            Section {
                                rows(pages)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // Keep the sidebar on the app's cream surface; the default sidebar
            // material made the list look like a separate grey panel.
            .scrollContentBackground(.hidden)
            .overlay {
                if ShiguangSettingsPage.allCases.allSatisfy({ !$0.matches(query) }) {
                    Text("没有匹配的设置")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            sidebarFooter
        }
        .background(SettingsSidebarBackdrop())
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 34, height: 34)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Palette.line.opacity(0.9))
                }
                .shadow(color: Palette.shadow, radius: 4, y: 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("拾光截图")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.ink)
                Text("截图、识别与剪贴板")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.muted)
            TextField("搜索设置", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.panel.opacity(0.96))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Palette.line.opacity(query.isEmpty ? 0.9 : 0.35))
        }
        .shadow(color: Palette.shadow.opacity(0.65), radius: 4, y: 1)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Color(hex: "4E9A72"))
                .frame(width: 7, height: 7)
                .shadow(color: Color(hex: "4E9A72").opacity(0.3), radius: 2)
            Text("菜单栏运行中")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.muted)
            Spacer(minLength: 4)
            Text(versionLabel)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.muted.opacity(0.8))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(alignment: .top) {
            Rectangle()
                .fill(Palette.line.opacity(0.65))
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        return "v\(version)"
    }

    private func rows(_ pages: [ShiguangSettingsPage]) -> some View {
        ForEach(pages) { page in
            SettingsSidebarRow(page: page, isSelected: selection == page)
        }
    }

    private var selectionBinding: Binding<ShiguangSettingsPage?> {
        Binding {
            selection
        } set: {
            if let page = $0 { selectedPageRaw = page.rawValue }
        }
    }

    private var permissionHelp: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                SettingsKindTile(symbol: "lock.shield.fill", color: ShiguangSettingsPage.privacy.color, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("允许拾光访问屏幕").font(.title2.weight(.semibold))
                    Text("仅在你主动截图、识别或录制时使用。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Text(model.screenPermission.title).font(.headline)
            Text(model.screenPermission.detail)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("授予屏幕权限") { model.requestPermission() }
                    .buttonStyle(.borderedProminent)
                Button("打开系统设置") { model.openPermissionSettings() }
                Button("重新检查") { model.checkPermission() }
            }
            HStack {
                Button("稍后", role: .cancel) { model.showsPermissionHelp = false }
                Spacer()
                Button("重启拾光") { model.restartApp?() }
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct SettingsSidebarRow: View {
    let page: ShiguangSettingsPage
    let isSelected: Bool

    var body: some View {
        Label {
            Text(page.title)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Palette.ink : .primary)
        } icon: {
            SettingsKindTile(symbol: page.symbol, color: page.color, size: 24, prominent: isSelected)
        }
        .tag(page)
        .padding(.vertical, 1)
        .background(SidebarHighlightDisabler())
        .listRowBackground(highlight)
    }

    @ViewBuilder
    private var highlight: some View {
        if isSelected {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(page.color.opacity(0.11))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(page.color.opacity(0.16))
                    }
                Capsule()
                    .fill(page.color)
                    .frame(width: 3, height: 18)
                    .padding(.leading, 3)
                }
            .padding(.horizontal, 7)
        }
    }
}

private struct SidebarHighlightDisabler: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.disableNativeHighlight() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            disableNativeHighlight()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func disableNativeHighlight() {
            let table = sequence(first: self as NSView, next: \.superview)
                .lazy
                .compactMap { $0 as? NSTableView }
                .first
            table?.selectionHighlightStyle = .none
        }
    }
}

private struct SettingsDetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clipboard: ClipboardHistory
    let page: ShiguangSettingsPage

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                pageContent
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .id(page)
        }
        .navigationTitle(page.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 13) {
                SettingsKindTile(symbol: page.symbol, color: page.color, size: 44, prominent: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(page.title)
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                    Text(page.summary)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                ForEach(headerFacts) { fact in
                    SettingsHeaderFact(fact: fact)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 15)
        .padding(.bottom, 12)
        .background {
            SettingsPageHeaderBackdrop(color: page.color)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Palette.line.opacity(0.65))
                .frame(height: 0.5)
        }
    }

    private var headerFacts: [SettingsHeaderFactModel] {
        switch page {
        case .general:
            return [
                SettingsHeaderFactModel(id: "history", symbol: "photo.stack", text: "\(model.records.count) 张截图", tint: page.color),
                permissionFact
            ]
        case .screenshot:
            return [
                SettingsHeaderFactModel(id: "history", symbol: "clock.arrow.circlepath",
                                        text: model.keepHistory ? "历史已开启" : "不写入历史", tint: page.color),
                permissionFact
            ]
        case .translation:
            return [
                SettingsHeaderFactModel(id: "target", symbol: "globe",
                                        text: LanguageChoice.targets.first(where: { $0.id == model.targetLanguage })?.name ?? "自动",
                                        tint: page.color),
                SettingsHeaderFactModel(id: "engine", symbol: "apple.logo", text: "系统翻译", tint: Color(hex: "66736D"))
            ]
        case .clipboard:
            return [
                SettingsHeaderFactModel(id: "monitor", symbol: clipboard.monitorsSystem ? "record.circle.fill" : "pause.circle.fill",
                                        text: clipboard.monitorsSystem ? "正在监听" : "已暂停",
                                        tint: clipboard.monitorsSystem ? Color(hex: "3B8B67") : Color(hex: "A56A32")),
                SettingsHeaderFactModel(id: "entries", symbol: "tray.full", text: "\(clipboard.entries.count) 项记录", tint: page.color)
            ]
        case .shortcuts:
            return [
                SettingsHeaderFactModel(id: "registered", symbol: model.hotkeyAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                        text: model.hotkeyAvailable ? "4 个快捷键已注册" : "存在快捷键冲突",
                                        tint: model.hotkeyAvailable ? Color(hex: "3B8B67") : Color(hex: "C17A32")),
                SettingsHeaderFactModel(id: "instant", symbol: "bolt.fill", text: "修改后即时生效", tint: page.color)
            ]
        case .history:
            return [
                SettingsHeaderFactModel(id: "count", symbol: "photo.stack", text: "\(model.records.count) 项记录", tint: page.color),
                SettingsHeaderFactModel(id: "local", symbol: "internaldrive.fill", text: "仅保存在本机", tint: Color(hex: "4C7566"))
            ]
        case .privacy:
            return [
                permissionFact,
                SettingsHeaderFactModel(id: "local", symbol: "hand.raised.fill", text: "无云端账号", tint: Color(hex: "4C7566"))
            ]
        case .tools:
            return [
                SettingsHeaderFactModel(id: "count", symbol: "square.grid.2x2", text: "4 个快捷入口", tint: page.color),
                SettingsHeaderFactModel(id: "login", symbol: "person.crop.circle.badge.checkmark", text: "无需登录", tint: Color(hex: "4C7566"))
            ]
        case .about:
            return [
                SettingsHeaderFactModel(id: "version", symbol: "number", text: "版本 \(versionLabel)", tint: page.color),
                SettingsHeaderFactModel(id: "menu", symbol: "menubar.rectangle", text: "菜单栏应用", tint: Color(hex: "4C7566"))
            ]
        }
    }

    private var permissionFact: SettingsHeaderFactModel {
        let granted = model.screenPermission.isGranted
        return SettingsHeaderFactModel(
            id: "permission",
            symbol: granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
            text: granted ? "屏幕访问已授权" : "屏幕访问待授权",
            tint: granted ? Color(hex: "3B8B67") : Color(hex: "C17A32")
        )
    }

    private var versionLabel: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .general:
            generalContent
        case .screenshot:
            screenshotContent
        case .translation:
            translationContent
        case .clipboard:
            clipboardContent
        case .shortcuts:
            shortcutsContent
        case .history:
            historyContent
        case .privacy:
            privacyContent
        case .tools:
            toolsContent
        case .about:
            aboutContent
        }
    }

    private var generalContent: some View {
        Group {
            Section("快速操作") {
                SettingsActionRow(
                    title: "区域截图",
                    detail: "拖选屏幕区域并进入编辑，确认后复制",
                    symbol: "viewfinder",
                    color: ShiguangSettingsPage.screenshot.color,
                    shortcut: model.captureHotkey.symbol
                ) {
                    model.capture()
                }
                SettingsActionRow(
                    title: "截图并翻译",
                    detail: "截取文字区域，直接打开独立翻译窗口",
                    symbol: "character.bubble.fill",
                    color: ShiguangSettingsPage.translation.color,
                    shortcut: model.translateHotkey.symbol
                ) {
                    model.capture(translate: true)
                }
                SettingsActionRow(
                    title: "剪贴板历史",
                    detail: "搜索并重新复制最近保存的内容",
                    symbol: "doc.on.clipboard.fill",
                    color: ShiguangSettingsPage.clipboard.color,
                    shortcut: model.clipboardHotkey.symbol
                ) {
                    model.showClipboard?()
                }
            }

            Section("运行状态") {
                SettingsValueRow(
                    title: "运行方式",
                    detail: "顶部菜单栏常驻，不在 Dock 显示",
                    value: "菜单栏"
                )
                SettingsValueRow(
                    title: "截图历史",
                    detail: "最近保留的截图与识别结果",
                    value: "\(model.records.count) 项"
                )
                SettingsValueRow(
                    title: "剪贴板历史",
                    detail: "文字、图片、GIF、视频和文件引用",
                    value: "\(clipboard.entries.count) 项"
                )
            }

            Section {
                PermissionActionRow(model: model)
            } header: {
                Text("屏幕访问")
            } footer: {
                Text("只在你主动截图、文字识别或录制时读取所选区域。")
            }
        }
    }

    private var screenshotContent: some View {
        Group {
            Section {
                Toggle(isOn: $model.autoOCR) {
                    SettingsRowLabel(
                        title: "导入图片后自动识别文字",
                        detail: "只对导入的图片生效，普通截图仍停留在编辑状态"
                    )
                }
                Toggle(isOn: $model.autoTranslate) {
                    SettingsRowLabel(
                        title: "识别后自动翻译",
                        detail: "使用翻译页设置的默认目标语言"
                    )
                }
                Toggle(isOn: $model.keepHistory) {
                    SettingsRowLabel(
                        title: "保存最近 30 张截图与译文",
                        detail: "历史仅保存在本机，可随时清空"
                    )
                }
            } header: {
                Text("处理方式")
            } footer: {
                Text("普通屏幕截图始终先进入编辑；点击工具栏中的识别、翻译、长截图或录制后再进入对应流程。")
            }

            Section("截图流程") {
                SettingsValueRow(title: "确认", detail: "带标注图片或录制内容直接复制", value: "绿色勾选")
                SettingsValueRow(title: "取消", detail: "不复制、不保存，也不改变现有剪贴板", value: "Esc / 红色叉号")
                SettingsValueRow(title: "历史草稿", detail: "确认前不写入历史记录", value: "安全")
            }

            Section("操作") {
                Button {
                    model.capture()
                } label: {
                    Label("开始一次新截图", systemImage: "viewfinder")
                }
                Button {
                    model.importImage()
                } label: {
                    Label("导入已有图片", systemImage: "photo.badge.plus")
                }
            }
        }
    }

    private var translationContent: some View {
        Group {
            Section {
                LabeledContent {
                    Picker("目标语言", selection: Binding(
                        get: { model.targetLanguage },
                        set: { model.languageEdited(target: $0) }
                    )) {
                        ForEach(LanguageChoice.targets) { language in
                            Text(language.name).tag(language.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                } label: {
                    SettingsRowLabel(
                        title: "默认目标语言",
                        detail: "自动识别原文语种；中文默认译英语，其他语言默认译中文"
                    )
                }
            } header: {
                Text("语言")
            } footer: {
                Text("首次使用某个语言对时，Apple 可能要求下载系统语言包。截图翻译可在独立窗口中随时交换语言。")
            }

            Section("快捷入口") {
                SettingsActionRow(
                    title: "文字翻译",
                    detail: "直接输入或粘贴一段原文",
                    symbol: "text.bubble.fill",
                    color: ShiguangSettingsPage.translation.color
                ) {
                    model.startTextTranslation()
                }
                SettingsActionRow(
                    title: "翻译剪贴板",
                    detail: "翻译当前复制的文字或图片",
                    symbol: "doc.on.clipboard",
                    color: ShiguangSettingsPage.clipboard.color,
                    shortcut: model.clipboardTranslateHotkey.symbol
                ) {
                    model.translateClipboard()
                }
            }
        }
    }

    private var clipboardContent: some View {
        Group {
            Section {
                Toggle(isOn: $clipboard.monitorsSystem) {
                    SettingsRowLabel(
                        title: "记录系统剪贴板",
                        detail: "监听文字、图片、GIF、视频和文件引用"
                    )
                }
                SettingsValueRow(
                    title: "保留数量",
                    detail: "相同内容会去重并移动到最前",
                    value: "最近 100 项"
                )
                SettingsValueRow(
                    title: "快捷打开",
                    detail: "在任意应用中打开剪贴板历史",
                    value: model.clipboardHotkey.symbol
                )
            } header: {
                Text("监听")
            } footer: {
                Text("历史仅保存在本机。来源标记为保密或临时的内容不会收入历史。")
            }

            Section("操作") {
                Button {
                    model.showClipboard?()
                } label: {
                    Label("打开剪贴板历史", systemImage: "arrow.up.right.square")
                }
            }
        }
    }

    private var shortcutsContent: some View {
        Group {
            Section {
                HotkeyRow(title: "区域截图", settings: $model.captureHotkey)
                HotkeyRow(title: "截图并翻译", settings: $model.translateHotkey)
                HotkeyRow(title: "剪贴板历史", settings: $model.clipboardHotkey)
                HotkeyRow(title: "翻译剪贴板", settings: $model.clipboardTranslateHotkey)
            } header: {
                Text("全局快捷键")
            } footer: {
                Text("快捷键修改后立即生效。若组合键被其他应用占用，会在这里提示。")
            }

            if !model.hotkeyAvailable {
                Section {
                    Label("有快捷键未注册成功，可能被其他应用占用。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var historyContent: some View {
        Group {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索历史标题或识别文字", text: $model.search)
                        .textFieldStyle(.plain)
                    if !model.search.isEmpty {
                        Button {
                            model.search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.vertical, 3)

                if model.filteredRecords.isEmpty {
                    Text(model.records.isEmpty ? "暂无截图历史" : "没有匹配的历史记录")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(model.filteredRecords) { record in
                        SettingsHistoryRow(model: model, record: record)
                    }
                }
            } header: {
                Text("最近截图")
            }

            Section("存储") {
                Button {
                    if let directory = model.store?.directory {
                        NSWorkspace.shared.open(directory)
                    }
                } label: {
                    Label("在访达中打开本地存储", systemImage: "folder")
                }
                Button(role: .destructive) {
                    model.clearHistory()
                } label: {
                    Label("清空全部历史", systemImage: "trash")
                }
                .disabled(model.records.isEmpty)
            }
        }
    }

    private var privacyContent: some View {
        Group {
            Section {
                PermissionActionRow(model: model)
            } header: {
                Text("权限")
            } footer: {
                Text("如果系统已显示授权但截图仍被拒绝，可重新启动应用后再试。")
            }

            Section("本机处理") {
                SettingsValueRow(title: "文字识别", detail: "使用 Apple Vision 在本机提取文字", value: "本机")
                SettingsValueRow(title: "翻译", detail: "使用 Apple 系统翻译框架", value: "系统")
                SettingsValueRow(title: "统计与服务器", detail: "没有第三方统计或自建服务器", value: "无")
            }

            Section("本地数据") {
                Button {
                    if let directory = model.store?.directory {
                        NSWorkspace.shared.open(directory)
                    }
                } label: {
                    Label("打开应用数据目录", systemImage: "folder")
                }
                Button(role: .destructive) {
                    model.clearHistory()
                } label: {
                    Label("清空截图历史", systemImage: "trash")
                }
                .disabled(model.records.isEmpty)
            }
        }
    }

    private var toolsContent: some View {
        Section("快捷入口") {
            SettingsActionRow(
                title: "导入图片",
                detail: "识别已有文件中的文字",
                symbol: "photo.badge.plus",
                color: ShiguangSettingsPage.tools.color
            ) {
                model.importImage()
            }
            SettingsActionRow(
                title: "文字翻译",
                detail: "直接粘贴或输入一段原文",
                symbol: "text.bubble.fill",
                color: ShiguangSettingsPage.translation.color
            ) {
                model.startTextTranslation()
            }
            SettingsActionRow(
                title: "翻译剪贴板",
                detail: "翻译当前复制的文字或图片",
                symbol: "doc.on.clipboard",
                color: ShiguangSettingsPage.clipboard.color
            ) {
                model.translateClipboard()
            }
            SettingsActionRow(
                title: "体验示例",
                detail: "使用内置图片检查文字识别，无需屏幕权限",
                symbol: "sparkles",
                color: ShiguangSettingsPage.screenshot.color
            ) {
                model.useDemo()
            }
        }
    }

    private var aboutContent: some View {
        Group {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("拾光截图").font(.title3.weight(.semibold))
                        Text("截取片刻，读懂世界。")
                            .foregroundStyle(.secondary)
                        Text("版本 \(appVersion)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section("运行方式") {
                SettingsValueRow(title: "菜单栏", detail: "顶部状态栏常驻入口", value: "已启用")
                SettingsValueRow(title: "Dock", detail: "关闭窗口后继续在菜单栏运行", value: "不显示")
            }

            Section("隐私") {
                Text("文字识别使用本机 Vision；翻译交给 Apple 系统翻译。应用没有第三方统计 SDK、自建服务器或账号系统。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }
}

private struct SettingsHeaderFactModel: Identifiable {
    let id: String
    let symbol: String
    let text: String
    let tint: Color
}

private struct SettingsHeaderFact: View {
    let fact: SettingsHeaderFactModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: fact.symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(fact.text)
                .lineLimit(1)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(fact.tint)
        .padding(.horizontal, 8)
        .frame(height: 23)
        .background(fact.tint.opacity(0.09), in: Capsule())
        .overlay {
            Capsule()
                .stroke(fact.tint.opacity(0.14))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsSidebarBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Palette.background, Color(hex: "EFEBE1")],
            startPoint: .top,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Palette.accent.opacity(0.035))
                .frame(width: 210, height: 210)
                .offset(x: 85, y: -95)
        }
        .clipped()
    }
}

private struct SettingsPageHeaderBackdrop: View {
    let color: Color

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [color.opacity(0.075), Palette.background.opacity(0.48), Palette.background],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .stroke(color.opacity(0.06), lineWidth: 18)
                .frame(width: 132, height: 132)
                .offset(x: 37, y: -58)
        }
        .clipped()
    }
}

private struct SettingsKindTile: View {
    let symbol: String
    let color: Color
    let size: CGFloat
    var prominent = false

    var body: some View {
        ZStack {
            tileBackground
            .frame(width: size, height: size)

            Image(systemName: symbol)
                .font(.system(size: size * (symbol == "command" ? 0.44 : 0.48), weight: .semibold))
                .foregroundStyle(prominent ? Color.white : color)
        }
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .stroke(prominent ? Color.white.opacity(0.22) : color.opacity(0.13), lineWidth: 0.8)
        }
        .shadow(color: prominent ? color.opacity(0.2) : .clear, radius: 3, y: 1)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var tileBackground: some View {
        if prominent {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.9), color],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        } else {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(color.opacity(0.11))
        }
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsValueRow: View {
    let title: String
    let detail: String
    let value: String

    var body: some View {
        LabeledContent {
            SettingsValueBadge(value: value)
        } label: {
            SettingsRowLabel(title: title, detail: detail)
        }
    }
}

private struct SettingsValueBadge: View {
    let value: String

    var body: some View {
        Text(value)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Palette.ink.opacity(0.82))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Palette.sage.opacity(0.9), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Palette.ink.opacity(0.06))
            }
            .textSelection(.enabled)
    }
}

private struct SettingsActionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let color: Color
    var shortcut: String?
    let action: () -> Void
    @StoredState private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SettingsKindTile(symbol: symbol, color: color, size: 26)
                SettingsRowLabel(title: title, detail: detail)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.ink.opacity(0.72))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Palette.sage, in: RoundedRectangle(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Palette.ink.opacity(0.06))
                        }
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovered ? color.opacity(0.8) : Palette.muted.opacity(0.6))
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered ? color.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .onHover { hovered = $0 }
    }
}

private struct PermissionActionRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if !model.screenPermission.isGranted {
                    Button("授予") { model.requestPermission() }
                }
                Button("检查") { model.checkPermission() }
                Button("系统设置") { model.openPermissionSettings() }
                Image(systemName: model.screenPermission.isGranted
                      ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(model.screenPermission.isGranted ? .green : .orange)
                    .accessibilityLabel(model.screenPermission.isGranted ? "已授权" : "未授权")
            }
        } label: {
            SettingsRowLabel(
                title: "屏幕访问",
                detail: model.screenPermission.isGranted
                    ? "可以使用区域截图、文字识别、长截图和录制"
                    : model.screenPermission.detail
            )
        }
    }
}

private struct SettingsHistoryRow: View {
    @ObservedObject var model: AppModel
    let record: CaptureRecord

    var body: some View {
        HStack(spacing: 10) {
            if let image = model.store?.image(for: record) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 42, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                SettingsKindTile(symbol: "photo", color: ShiguangSettingsPage.history.color, size: 36)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.createdAt.formatted(.dateTime.month().day().hour().minute()))
                    if !record.text.isEmpty {
                        Text("· \(record.text.prefix(28))…")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                model.select(record)
            } label: {
                Image(systemName: "arrow.up.right")
            }
            .buttonStyle(.borderless)
            .help("打开")
            Button(role: .destructive) {
                model.delete(record)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除")
        }
        .padding(.vertical, 2)
    }
}
