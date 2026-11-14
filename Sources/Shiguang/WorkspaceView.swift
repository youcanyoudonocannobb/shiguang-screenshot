import AppKit
import SwiftUI
import Translation

enum Palette {
    // Quiet, paper-warm neutral ground with a single muted clay accent.
    static let background = Color(hex: "FAF9F6")
    static let sidebar = Color(hex: "F2F1ED")
    static let panel = Color(hex: "FFFFFF")
    static let ink = Color(hex: "1F2422")
    static let muted = Color(hex: "767D78")
    static let accent = Color(hex: "B0573A")
    static let accentDeep = Color(hex: "8E4229")
    static let line = Color(hex: "E7E4DE")
    static let sage = Color(hex: "EFF2EE")
    static let accentSoft = Color(hex: "F5E9E1")
    static let shadow = Color(hex: "1F2422").opacity(0.06)
    static let success = Color(hex: "3F7D5D")
    static let warning = Color(hex: "A9772F")
    static let danger = Color(hex: "B4514A")

    // Dark chrome used by the capture overlay, recorder and long-shot panel.
    static let overlay = Color(hex: "1E2123")
    static let overlayRaised = Color(hex: "2A2E30")
    static let overlayInk = Color(hex: "EDEFEC")
    static let overlayMuted = Color(hex: "9AA3A0")
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

// Select the property wrapper explicitly on SDKs that also expose a State macro.
typealias StoredState<Value> = SwiftUI.State<Value>

@MainActor
private final class HotkeyCaptureCoordinator: ObservableObject {
    private var monitor: Any?
    private weak var window: NSWindow?
    private var onCapture: ((HotkeySettings) -> Void)?
    private var onInvalid: ((String) -> Void)?
    private var onCancel: (() -> Void)?

    var isActive: Bool { monitor != nil }

    func start(window: NSWindow?,
               onCapture: @escaping (HotkeySettings) -> Void,
               onInvalid: @escaping (String) -> Void,
               onCancel: @escaping () -> Void) {
        stop()
        self.window = window
        self.onCapture = onCapture
        self.onInvalid = onInvalid
        self.onCancel = onCancel
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if let window = self.window, let eventWindow = event.window, eventWindow !== window {
                return event
            }

            if event.type == .leftMouseDown {
                self.onCancel?()
                self.stop()
                return event
            }

            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 && flags.isEmpty {
                self.onCancel?()
                self.stop()
                return nil
            }

            // Plain typing (including Shift for capitals) remains available for
            // manual notation such as "option+shift+s".
            guard flags.contains(.option) || flags.contains(.control) || flags.contains(.command) else {
                return event
            }
            guard let captured = HotkeySettings.fromKeyEvent(keyCode: event.keyCode, modifiers: flags) else {
                self.onInvalid?("这个按键不能作为快捷键，请换一个按键")
                return nil
            }
            self.onCapture?(captured)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        window = nil
        onCapture = nil
        onInvalid = nil
        onCancel = nil
    }
}

struct HotkeyRow: View {
    let title: String
    @Binding var settings: HotkeySettings
    var onRecordingChanged: (Bool) -> Void = { _ in }
    @StoredState private var draft = ""
    @StoredState private var message: String?
    @StoredState private var isRecording = false
    @StateObject private var captureCoordinator = HotkeyCaptureCoordinator()
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.ink)
                if isRecording {
                    Text("请按下组合键，按 Esc 取消")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.accent)
                        .lineLimit(1)
                } else if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(message.hasPrefix("已") ? Palette.success : Palette.accent)
                        .lineLimit(1)
                } else {
                    Text("支持 \(settings.symbol) 或 option+shift+\(settings.key.lowercased())")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                TextField("⌥⇧S", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .labelsHidden()
                    .frame(width: 124)
                    .focused($focused)
                    .onSubmit { apply() }
                    .help("点击后直接按下组合键，也可以输入 option+shift+s")
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isRecording ? Palette.accent : focused ? Palette.accent.opacity(0.75) : Palette.line,
                                    lineWidth: isRecording ? 1.5 : 1)
                    }
                if draft != settings.symbol {
                    Button("应用") { apply() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 52)
        .onAppear {
            draft = settings.symbol
        }
        .onChange(of: settings) { _, value in
            if !focused { draft = value.symbol }
        }
        .onChange(of: focused) { _, active in
            if active { beginRecording() }
            else { finishRecording() }
        }
        .onChange(of: draft) { _, _ in
            if message?.hasPrefix("已") != true { message = nil }
        }
        .onDisappear {
            captureCoordinator.stop()
            if isRecording {
                isRecording = false
                onRecordingChanged(false)
            }
        }
    }

    private func apply() {
        finishRecording()
        guard let parsed = HotkeySettings.parseInput(draft) else {
            message = "格式无效，请包含至少一个修饰键"
            return
        }
        settings = parsed
        draft = parsed.symbol
        message = "已应用 \(parsed.symbol)"
        focused = false
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        message = nil
        onRecordingChanged(true)
        captureCoordinator.start(window: NSApp.keyWindow, onCapture: { captured in
            settings = captured
            draft = captured.symbol
            message = "已应用 \(captured.symbol)"
            finishRecording()
            focused = false
        }, onInvalid: { text in
            message = text
        }, onCancel: {
            finishRecording()
            focused = false
        })
    }

    private func finishRecording() {
        guard isRecording else { return }
        captureCoordinator.stop()
        isRecording = false
        onRecordingChanged(false)
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
                                    filledShapes: model.fillShapes,
                                    onColorPick: { model.markColor = $0; model.tool = .pointer },
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
              let job = model.translationJob,
              job.provider == .apple else { configuration = nil; return }
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
        VStack(alignment: .leading, spacing: 13) {
            header
            if !isRecognition {
                languageBar
            }
            if isRecognition {
                sourcePanel
                    .frame(minHeight: 210, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    sourcePanel
                    resultPanel
                }
                .frame(maxHeight: .infinity)
            }
            actionBar
            statusBar
            if let error = model.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.accent)
                    .textSelection(.enabled)
                    .padding(.horizontal, 2)
            }
        }
        .padding(18)
        .frame(minWidth: isRecognition ? 420 : 680,
               minHeight: isRecognition ? 330 : 420)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: isRecognition ? "text.viewfinder" : "character.bubble.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 38, height: 38)
                .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(isRecognition ? "文字识别" : "截图翻译")
                    .font(.system(size: 19, weight: .semibold))
                Text(isRecognition ? "提取截图中的文字，可在本机校对后继续翻译。" :
                        (model.translationProvider == .ai
                         ? "使用已配置的 AI 服务翻译，原文与译文并排展示。"
                         : "自动检测原文语种，默认在中文与英文之间切换。"))
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            Label(isRecognition ? "本机处理" : model.translationProvider.title,
                  systemImage: isRecognition ? "lock.shield" : model.translationProvider.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Palette.ink.opacity(0.045), in: Capsule())
            Button { model.closeEditor() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 28, height: 28)
                    .background(Palette.panel, in: Circle())
                    .overlay(Circle().stroke(Palette.line))
            }
            .buttonStyle(.plain)
            .help("关闭 (Esc)")
            .accessibilityLabel("关闭文字窗口")
        }
    }

    private var languageBar: some View {
        HStack(spacing: 8) {
            languageControl(title: "原文", symbol: "text.alignleft",
                            selection: Binding(get: { model.sourceLanguage },
                                               set: { model.languageEdited(source: $0) }),
                            choices: LanguageChoice.sources)
            Button { model.swapTranslationLanguages() } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 28, height: 28)
                    .background(Palette.accentSoft, in: Circle())
            }
            .buttonStyle(.plain)
            .help("交换原文与目标语言")
            .accessibilityLabel("交换原文与目标语言")
            languageControl(title: "译为", symbol: "character.book.closed",
                            selection: Binding(get: { model.targetLanguage },
                                               set: { model.languageEdited(target: $0) }),
                            choices: LanguageChoice.targets)
        }
        .padding(7)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Palette.line))
    }

    private func languageControl(title: String, symbol: String, selection: Binding<String>,
                                 choices: [LanguageChoice]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Palette.muted)
                Picker(title, selection: selection) {
                    ForEach(choices) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(Palette.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.line.opacity(0.8)))
    }

    private var sourcePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: isRecognition ? "text.viewfinder" : "doc.text")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text(isRecognition ? "识别文字" : "原文")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(model.sourceText.count) 字符")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button { model.copyText(model.sourceText) } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(TextPanelButtonStyle())
                .disabled(model.sourceText.isEmpty)
            }
            .padding(.horizontal, 12).frame(height: 40)
            Divider().opacity(0.6)
            ZStack(alignment: .topLeading) {
                if model.sourceText.isEmpty {
                    Text(model.isRecognizing ? "正在设备上识别文字…" :
                            (isRecognition ? "没有识别到文字，可以重试或直接输入。" : "粘贴或输入原文"))
                        .foregroundStyle(Palette.muted)
                        .font(.system(size: 13))
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: { model.sourceText }, set: { model.sourceEdited($0) }))
                    .font(.system(size: 14))
                    .lineSpacing(6)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 9).padding(.vertical, 5)
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.line))
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text("译文")
                    .font(.system(size: 11, weight: .semibold))
                if model.translationJob != nil {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                Button { model.copyText(model.translatedText) } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(TextPanelButtonStyle())
                .disabled(model.translatedText.isEmpty)
            }
            .padding(.horizontal, 12).frame(height: 40)
            Divider().opacity(0.45)
            ScrollView {
                Text(model.translatedText.isEmpty ?
                        (model.translationJob != nil ? "正在翻译…" : "译文会出现在这里。") : model.translatedText)
                    .foregroundStyle(model.translatedText.isEmpty ? Palette.muted : Palette.ink)
                    .font(.system(size: 14))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 15).padding(.vertical, 12)
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        .background(Palette.sage, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.line))
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            if !isRecognition {
                Button("复制原文") { model.copyText(model.sourceText) }
                    .buttonStyle(QuietButton())
                    .disabled(model.sourceText.isEmpty)
                Button("复制译文") { model.copyText(model.translatedText) }
                    .buttonStyle(QuietButton())
                    .disabled(model.translatedText.isEmpty)
                Button("对照") {
                    model.copyText("\(model.sourceText)\n\n\(model.translatedText)")
                }
                .buttonStyle(QuietButton())
                .disabled(model.sourceText.isEmpty || model.translatedText.isEmpty)
            } else {
                Label("可直接修改识别结果", systemImage: "pencil.line")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 8)
            if isRecognition && model.image != nil {
                Button("重新识别") { model.recognize() }
                    .buttonStyle(QuietButton())
                    .disabled(model.isBusy)
            }
            Button(isRecognition ? "翻译文字" : "开始翻译") { model.requestTranslation() }
                .buttonStyle(AccentButton())
                .disabled(!model.canTranslate)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(8)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Palette.line))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isBusy {
                ProgressView().controlSize(.small)
            } else {
                Circle()
                    .fill(model.errorMessage == nil ? Palette.ink.opacity(0.5) : Palette.accent)
                    .frame(width: 5, height: 5)
            }
            Text(model.activity ?? model.notice)
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)
                .lineLimit(2)
            Spacer()
            if model.isRecognizing {
                Button("停止识别") { model.cancelRecognition() }
                    .buttonStyle(TextPanelButtonStyle())
            }
            if model.translationJob != nil {
                Button("停止翻译") { model.cancelTranslation() }
                    .buttonStyle(TextPanelButtonStyle())
            }
            if !isRecognition {
                Text("⌘ ↩")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line))
            }
        }
        .padding(.horizontal, 3)
    }
}

private struct TextPanelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(configuration.isPressed ? Palette.line : Palette.background.opacity(0.8),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line.opacity(0.75)))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct VisualBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(hex: "F1F1EE"), Color(hex: "F7F7F4")],
                       startPoint: .top, endPoint: .bottom)
    }
}

struct AccentButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 9).foregroundStyle(.white)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.82 : 1),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

struct QuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12))
            .padding(.horizontal, 11).padding(.vertical, 8)
            .foregroundStyle(Palette.ink)
            .background(configuration.isPressed ? Palette.line : Palette.panel,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.line))
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

