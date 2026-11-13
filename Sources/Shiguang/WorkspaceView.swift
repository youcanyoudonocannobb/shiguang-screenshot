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
    static let sage = Color(hex: "E9EEE6")
    static let accentSoft = Color(hex: "F8E6DF")
    static let shadow = Color(hex: "263C35").opacity(0.08)
}

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

// Select the property wrapper explicitly on SDKs that also expose a State macro.
typealias StoredState<Value> = SwiftUI.State<Value>

struct HotkeyRow: View {
    let title: String
    @Binding var settings: HotkeySettings

    var body: some View {
        HStack(spacing: 7) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(width: 82, alignment: .leading)
            Picker("按键", selection: $settings.key) {
                ForEach(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), id: \.self) { character in
                    Text(String(character)).tag(String(character))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 54)
            Toggle("⌃", isOn: $settings.control).toggleStyle(HotkeyModifierStyle()).help("Control")
            Toggle("⌥", isOn: $settings.option).toggleStyle(HotkeyModifierStyle()).help("Option")
            Toggle("⇧", isOn: $settings.shift).toggleStyle(HotkeyModifierStyle()).help("Shift")
            Toggle("⌘", isOn: $settings.command).toggleStyle(HotkeyModifierStyle()).help("Command")
            Spacer(minLength: 2)
            Text(settings.symbol)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.line.opacity(0.8)))
        }
        .padding(.horizontal, 9)
        .frame(height: 42)
        .background(Palette.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line.opacity(0.55)))
    }
}

private struct HotkeyModifierStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(configuration.isOn ? .white : Palette.muted)
                .frame(width: 22, height: 24)
                .background(configuration.isOn ? Palette.ink : Palette.panel,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(configuration.isOn ? Palette.ink : Palette.line.opacity(0.75)))
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "已启用" : "未启用")
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
        VStack(alignment: .leading, spacing: 13) {
            header
            if !isRecognition {
                languageBar
            }
            sourcePanel
            if !isRecognition {
                resultPanel
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
        .frame(minWidth: 420, minHeight: isRecognition ? 330 : 500)
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: isRecognition ? "text.viewfinder" : "character.bubble.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(
                    LinearGradient(colors: [Palette.accent, Color(hex: "BC482B")],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .shadow(color: Palette.accent.opacity(0.2), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(isRecognition ? "文字识别" : "截图翻译")
                    .font(.system(size: 21, weight: .semibold, design: .serif))
                Text(isRecognition ? "提取截图中的文字，可在本机校对后继续翻译。" :
                        "自动检测原文语种，默认在中文与英文之间切换。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            Label(isRecognition ? "本机处理" : "Apple 翻译",
                  systemImage: isRecognition ? "lock.shield" : "apple.logo")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Palette.sage, in: Capsule())
            Button { model.closeEditor() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 30, height: 30)
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
                    .frame(width: 30, height: 30)
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
        .padding(9)
        .background(Palette.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line.opacity(0.8)))
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
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .background(Palette.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line.opacity(0.6)))
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
        .frame(minHeight: 120, maxHeight: .infinity)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line.opacity(0.9)))
        .shadow(color: Palette.shadow, radius: 12, y: 5)
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
        .frame(minHeight: 120, maxHeight: .infinity)
        .background(Palette.sage, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.ink.opacity(0.08)))
        .shadow(color: Palette.shadow, radius: 12, y: 5)
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
        .padding(9)
        .background(Palette.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line.opacity(0.75)))
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

