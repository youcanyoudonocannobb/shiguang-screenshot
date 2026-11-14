import AppKit
import SwiftUI
import Translation

enum Palette {
    static let background = Color(hex: "F4F7FA")
    static let sidebar = Color(hex: "EAF0F5")
    static let panel = Color(hex: "FFFFFF")
    static let ink = Color(hex: "203444")
    static let muted = Color(hex: "627585")
    static let accent = Color(hex: "216D91")
    static let accentDeep = Color(hex: "174F6B")
    static let line = Color(hex: "DCE5EC")
    static let sage = Color(hex: "EDF5FA")
    static let accentSoft = Color(hex: "E2EFF7")
    static let shadow = Color(hex: "203444").opacity(0.06)
    static let success = Color(hex: "347A69")
    static let warning = Color(hex: "996222")
    static let danger = Color(hex: "B64D53")

    // Dark chrome used by the capture overlay, recorder and long-shot panel.
    static let overlay = Color(hex: "172A38")
    static let overlayRaised = Color(hex: "263D4D")
    static let overlayInk = Color(hex: "F1F7FB")
    static let overlayMuted = Color(hex: "A8BECD")
    static let overlayAccent = Color(hex: "91CDEB")
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

struct VisualBackground: View {
    var body: some View {
        LinearGradient(colors: [Palette.background, Palette.panel],
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

