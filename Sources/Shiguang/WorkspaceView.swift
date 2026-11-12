import AppKit
import SwiftUI
import Translation

enum Palette {
    static let background = Color(hex: "F5F3ED")
    static let panel = Color(hex: "FFFEFA")
    static let ink = Color(hex: "263C35")
    static let muted = Color(hex: "7D847B")
    static let accent = Color(hex: "D95E3A")
    static let line = Color(hex: "DDDCD2")
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

// Select the property wrapper explicitly on SDKs that also expose a State macro.
typealias StoredState<Value> = SwiftUI.State<Value>

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clipboard: ClipboardHistory

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                moduleCard
                hotkeyCard
                clipboardCard
                languageCard
                historyCard
                privacyCard
                supportCard
            }.padding(30)
        }.background(Palette.background)
            .foregroundStyle(Palette.ink)
            .tint(Palette.accent)
            .preferredColorScheme(.light)
            .frame(minWidth: 660, minHeight: 590)
            .sheet(isPresented: $model.showsPermissionHelp) {
                permissionHelp
            }
            .alert("需要留意", isPresented: Binding(get: { !model.isTextWorkspace && model.errorMessage != nil }, set: {
                if !$0 { model.errorMessage = nil }
            })) {
                Button("知道了", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Palette.ink).frame(width: 44, height: 44)
                Image(systemName: "viewfinder").font(.system(size: 26, weight: .medium)).foregroundStyle(.white)
                Circle().fill(Palette.accent).frame(width: 8, height: 8).offset(x: 13, y: -13)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("拾光截图").font(.system(size: 23, weight: .medium, design: .serif))
                Text("截取片刻，读懂世界。应用会常驻菜单栏。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Button { model.capture() } label: { Label("试一次截图", systemImage: "viewfinder") }
                .buttonStyle(AccentButton())
        }.padding(.bottom, 4)
    }

    private var moduleCard: some View {
        SettingsCard(title: "功能模块", symbol: "square.grid.3x3.fill") {
            Text("截图先进入编辑，点击工具栏选择识别、翻译、长截图或录制。确认后直接复制到剪贴板。")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            Toggle("导入图片后自动识别文字", isOn: $model.autoOCR)
            Toggle("导入图片识别后自动翻译", isOn: $model.autoTranslate)
            Toggle("保存最近 30 张截图与译文", isOn: $model.keepHistory)
        }.font(.system(size: 13))
    }

    private var hotkeyCard: some View {
        SettingsCard(title: "快捷键", symbol: "keyboard") {
            HotkeyRow(title: "区域截图", settings: $model.captureHotkey)
            Divider()
            HotkeyRow(title: "截图并翻译", settings: $model.translateHotkey)
            Divider()
            HotkeyRow(title: "剪贴板历史", settings: $model.clipboardHotkey)
            if !model.hotkeyAvailable {
                Label("有快捷键未注册成功，可能被其他应用占用。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Palette.accent).font(.system(size: 11))
            }
        }
    }

    private var clipboardCard: some View {
        SettingsCard(title: "系统剪贴板", symbol: "doc.on.clipboard") {
            Toggle("记录系统剪贴板", isOn: $clipboard.monitorsSystem)
            Text("保存运行期间复制的文字、图片、GIF、视频和文件引用，最近 100 项仅保存在本机。")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack {
                Button("打开剪贴板") { model.showClipboard?() }.buttonStyle(QuietButton())
                Text(model.clipboardHotkey.symbol).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted)
            }
        }
    }

    private var languageCard: some View {
        SettingsCard(title: "截图翻译", symbol: "character.bubble") {
            Picker("目标语言", selection: Binding(get: { model.targetLanguage }, set: { model.languageEdited(target: $0) })) {
                ForEach(LanguageChoice.targets) { Text($0.name).tag($0.id) }
            }.pickerStyle(.radioGroup)
            Text("首次使用某个语言对时，Apple 可能要求下载系统语言包。")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private var historyCard: some View {
        SettingsCard(title: "历史截图", symbol: "clock.arrow.circlepath") {
            if model.records.isEmpty {
                Text("暂无截图历史。开启“保存最近 30 张截图”后，截图会自动记录在此。")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField("搜索历史标题或识别文字…", text: $model.search)
                        .textFieldStyle(.plain)
                    if !model.search.isEmpty {
                        Button { model.search = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 8))

                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.filteredRecords) { record in
                            historyRow(record)
                        }
                    }
                }.frame(maxHeight: 220)
            }
        }
    }

    private func historyRow(_ record: CaptureRecord) -> some View {
        HStack(spacing: 12) {
            if let img = model.store?.image(for: record) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.createdAt.formatted(.dateTime.month().day().hour().minute()))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                    if !record.text.isEmpty {
                        Text("• \(record.text.prefix(30))…")
                            .font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                }
            }
            Spacer()
            Button("打开") { model.select(record) }.buttonStyle(QuietButton())
            Button { model.delete(record) } label: {
                Image(systemName: "trash").foregroundStyle(Palette.muted)
            }.buttonStyle(.plain).help("删除此记录")
        }
        .padding(8)
        .background(model.selectedID == record.id ? Palette.accent.opacity(0.1) : Palette.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line.opacity(0.6)))
    }

    private var privacyCard: some View {
        SettingsCard(title: "隐私与存储", symbol: "lock.shield") {
            Text("OCR 使用本机 Vision；翻译交给 Apple 系统翻译。应用没有第三方统计或自建服务器。")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            Divider()
            Label(model.screenPermission.title,
                  systemImage: model.screenPermission.isGranted ? "checkmark.shield" : "exclamationmark.shield")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.screenPermission.isGranted ? Palette.ink : Palette.accent)
            Text(model.screenPermission.detail)
                .font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                if !model.screenPermission.isGranted {
                    Button("授予屏幕权限") { model.requestPermission() }
                }
                Button("检查权限") { model.checkPermission() }
                Button("打开系统设置") { model.openPermissionSettings() }
                Button("重启拾光") { model.restartApp?() }
            }.buttonStyle(QuietButton())
            HStack {
                Button("打开本地存储") {
                    if let directory = model.store?.directory { NSWorkspace.shared.open(directory) }
                }
                Button("清空历史…", role: .destructive) { model.clearHistory() }.disabled(model.records.isEmpty)
            }.buttonStyle(QuietButton())
        }
    }

    private var permissionHelp: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("允许拾光访问屏幕", systemImage: "lock.shield")
                .font(.system(size: 19, weight: .semibold))
            Text(model.screenPermission.title).font(.system(size: 14, weight: .medium))
            Text(model.screenPermission.detail)
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Text("只在你主动截图或录制时访问所选区域。授权后，请重新开始截图或录制。")
                .font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack {
                Button("授予屏幕权限") { model.requestPermission() }.buttonStyle(AccentButton())
                Button("打开系统设置") { model.openPermissionSettings() }.buttonStyle(QuietButton())
                Button("重新检查") { model.checkPermission() }.buttonStyle(QuietButton())
            }
            HStack {
                Button("稍后", role: .cancel) { model.showsPermissionHelp = false }.buttonStyle(QuietButton())
                Spacer()
                Button("重启拾光") { model.restartApp?() }.buttonStyle(QuietButton())
            }
        }
        .padding(26).frame(width: 470)
        .foregroundStyle(Palette.ink).background(Palette.background)
    }

    private var supportCard: some View {
        SettingsCard(title: "其他入口", symbol: "menubar.rectangle") {
            row("导入图片", "识别已有文件中的文字") { model.importImage() }
            Divider()
            row("文字翻译", "直接粘贴一段原文") { model.startTextTranslation() }
            Divider()
            row("体验示例", "无需屏幕权限，检查 OCR") { model.useDemo() }
        }
    }

    private func row(_ title: String, _ subtitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Button("打开", action: action).buttonStyle(QuietButton())
        }
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(title, systemImage: symbol).font(.system(size: 14, weight: .semibold))
            content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Palette.line.opacity(0.8)))
    }
}

struct HotkeyRow: View {
    let title: String
    @Binding var settings: HotkeySettings

    var body: some View {
        HStack {
            Text(title).frame(width: 88, alignment: .leading)
            Picker("按键", selection: $settings.key) {
                ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), id: \.self) { character in
                    Text(String(character)).tag(String(character))
                }
            }.frame(width: 70)
            Toggle("⌃", isOn: $settings.control).toggleStyle(.button)
            Toggle("⌥", isOn: $settings.option).toggleStyle(.button)
            Toggle("⇧", isOn: $settings.shift).toggleStyle(.button)
            Toggle("⌘", isOn: $settings.command).toggleStyle(.button)
            Spacer()
            Text(settings.symbol).font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

struct CaptureEditorView: View {
    @ObservedObject var model: AppModel
    @StoredState private var configuration: TranslationSession.Configuration?
    var floating = false

    var body: some View {
        Group {
            if model.editorMode == .annotation {
                VStack(spacing: 2) {
                    if let image = model.image {
                        ImageCanvas(image: image, marks: model.marks, tool: model.tool,
                                    colorHex: model.markColor, zoom: $model.zoomFactor,
                                    resetID: model.viewportResetID, movesWindow: floating, enabled: !model.isBusy,
                                    onMark: model.addMark, onEscape: model.closeEditor)
                            .frame(minHeight: 130, maxHeight: .infinity).layoutPriority(1)
                        AnnotationToolbar(model: model, onShowText: { model.translateImage() })
                            .padding(.horizontal, 4)
                    }
                }
            } else {
                TextWorkspaceView(model: model)
            }
        }
        .background { if !floating { VisualBackground() } }
        .foregroundStyle(Palette.ink).tint(Palette.accent).preferredColorScheme(.light)
        .onChange(of: model.translationJob?.id, initial: true) { _, _ in configureTranslation() }
        .onChange(of: model.activeEditor) { _, _ in configureTranslation() }
        .translationTask(configuration) { session in
            guard model.activeEditor == (floating ? "overlay" : "editor"),
                  let job = model.translationJob else { return }
            do {
                let result = try await session.translate(job.text)
                model.finishTranslation(job, text: result.targetText)
            } catch { model.failTranslation(job, error: error) }
        }
    }

    private func configureTranslation() {
        guard model.activeEditor == (floating ? "overlay" : "editor"),
              let job = model.translationJob else { configuration = nil; return }
        let source = job.source == "auto" ? nil : Locale.Language(identifier: job.source)
        let target = Locale.Language(identifier: job.target)
        if #available(macOS 26.4, *) {
            configuration = TranslationSession.Configuration(source: source, target: target, preferredStrategy: .lowLatency)
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }
}

private struct TextWorkspaceView: View {
    @ObservedObject var model: AppModel
    private var isRecognition: Bool { model.editorMode == .recognition }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: isRecognition ? "text.viewfinder" : "character.bubble")
                    .font(.system(size: 20)).foregroundStyle(Palette.accent)
                Text(isRecognition ? "文字识别" : "翻译")
                    .font(.system(size: 19, weight: .semibold, design: .serif))
                Spacer()
                Button { model.closeEditor() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("关闭 (Esc)").accessibilityLabel("关闭文字窗口")
            }
            if !isRecognition {
                HStack(spacing: 10) {
                    Picker("原文语言", selection: Binding(get: { model.sourceLanguage }, set: { model.languageEdited(source: $0) })) {
                        ForEach(LanguageChoice.sources) { Text($0.name).tag($0.id) }
                    }
                    Image(systemName: "arrow.right").foregroundStyle(Palette.muted)
                    Picker("目标语言", selection: Binding(get: { model.targetLanguage }, set: { model.languageEdited(target: $0) })) {
                        ForEach(LanguageChoice.targets) { Text($0.name).tag($0.id) }
                    }
                }.controlSize(.small)
            }
            HStack {
                Text(isRecognition ? "识别文字" : "原文").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(model.sourceText.count) 字符").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            ZStack(alignment: .topLeading) {
                if model.sourceText.isEmpty {
                    Text(model.isRecognizing ? "正在设备上识别文字…" : (isRecognition ? "没有识别到文字，可以重试或直接输入。" : "粘贴或输入原文"))
                        .foregroundStyle(Palette.muted).padding(12).allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: { model.sourceText }, set: { model.sourceEdited($0) }))
                    .font(.system(size: 14)).lineSpacing(6).scrollContentBackground(.hidden).padding(6)
            }
            .frame(minHeight: 120, maxHeight: .infinity)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
            if !isRecognition {
                Text("译文").font(.system(size: 12, weight: .medium))
                ScrollView {
                    Text(model.translatedText.isEmpty ? (model.translationJob != nil ? "正在翻译…" : "译文会出现在这里。") : model.translatedText)
                        .foregroundStyle(model.translatedText.isEmpty ? Palette.muted : Palette.ink)
                        .font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(minHeight: 120, maxHeight: .infinity)
                .background(Color(hex: "EDF1E9"), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 8) {
                Button("复制原文") { model.copyText(model.sourceText) }
                    .buttonStyle(QuietButton()).disabled(model.sourceText.isEmpty)
                if !isRecognition {
                    Button("复制译文") { model.copyText(model.translatedText) }
                        .buttonStyle(QuietButton()).disabled(model.translatedText.isEmpty)
                }
                Spacer()
                if isRecognition && model.image != nil {
                    Button("重新识别") { model.recognize() }.buttonStyle(QuietButton()).disabled(model.isBusy)
                }
                Button(isRecognition ? "翻译文字" : "翻译") { model.requestTranslation() }
                    .buttonStyle(AccentButton()).disabled(!model.canTranslate)
                    .keyboardShortcut(.return, modifiers: .command)
            }
            HStack(spacing: 8) {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(model.activity ?? model.notice).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
                Spacer()
                if model.isRecognizing { Button("停止识别") { model.cancelRecognition() }.controlSize(.small) }
                if model.translationJob != nil { Button("停止翻译") { model.cancelTranslation() }.controlSize(.small) }
            }
            if let error = model.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(Palette.accent).textSelection(.enabled)
            }
        }.padding(22).frame(minWidth: 420, minHeight: isRecognition ? 300 : 460)
    }
}

struct VisualBackground: View {
    var body: some View {
        ZStack {
            Palette.background
            LinearGradient(colors: [Color(hex: "EFEEE7"), Color(hex: "F8F5EF")], startPoint: .topLeading, endPoint: .bottomTrailing)
            DotGrid().stroke(Palette.line.opacity(0.75), lineWidth: 1)
        }
    }
}

struct AccentButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 15).padding(.vertical, 10).foregroundStyle(.white)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.82 : 1), in: RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct QuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12))
            .padding(.horizontal, 11).padding(.vertical, 9)
            .foregroundStyle(Palette.ink)
            .background(configuration.isPressed ? Palette.line : .white.opacity(0.86), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line.opacity(0.8)))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct DotGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in stride(from: CGFloat(12), to: rect.width, by: 20) {
            for y in stride(from: CGFloat(12), to: rect.height, by: 20) {
                path.addEllipse(in: CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return path
    }
}

