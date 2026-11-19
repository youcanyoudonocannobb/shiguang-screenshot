import AppKit
import NaturalLanguage
import SwiftUI
import Translation

@MainActor
final class SelectionTranslationController: ObservableObject {
    @Published var translatedText = ""
    @Published var errorMessage: String?
    @Published var isLoading = true
    @Published var appleConfiguration: TranslationSession.Configuration?
    @Published var sourceLanguage: String
    @Published var targetLanguage: String

    let text: String
    let provider: TranslationProvider
    private let model: AppModel
    private var started = false
    private var requestGeneration = UUID()
    private var aiTask: Task<Void, Never>?

    init(model: AppModel, text: String) {
        self.model = model
        self.text = text
        provider = model.translationProvider
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let detected = recognizer.dominantLanguage?.rawValue ?? "auto"
        let source = Self.supportedLanguage(containing: detected)
        sourceLanguage = source
        targetLanguage = source.hasPrefix("zh") ? "en" : "zh-Hans"
    }

    func start() {
        guard !started else { return }
        started = true
        beginTranslation()
    }

    func changeLanguages(source: String? = nil, target: String? = nil) {
        var nextSource = source.map(Self.supportedLanguage(containing:)) ?? sourceLanguage
        var nextTarget = target ?? targetLanguage

        if source != nil, nextSource != "auto", Self.sameLanguageFamily(nextSource, nextTarget) {
            nextTarget = nextSource.hasPrefix("zh") ? "en" : "zh-Hans"
        } else if target != nil, nextSource != "auto", Self.sameLanguageFamily(nextSource, nextTarget) {
            nextSource = "auto"
        }

        guard nextSource != sourceLanguage || nextTarget != targetLanguage else { return }
        sourceLanguage = nextSource
        targetLanguage = nextTarget
        beginTranslation()
    }

    func canSelect(target: String) -> Bool {
        sourceLanguage == "auto" ||
            target == targetLanguage ||
            !Self.sameLanguageFamily(sourceLanguage, target)
    }

    private func beginTranslation() {
        requestGeneration = UUID()
        aiTask?.cancel()
        aiTask = nil
        translatedText = ""
        errorMessage = nil
        isLoading = true

        if provider == .apple {
            var previousConfiguration = appleConfiguration
            appleConfiguration = nil
            previousConfiguration?.invalidate()
            let source = sourceLanguage == "auto" ? nil : Locale.Language(identifier: sourceLanguage)
            appleConfiguration = TranslationSession.Configuration(
                source: source,
                target: Locale.Language(identifier: targetLanguage)
            )
        } else {
            translateWithAI()
        }
    }

    func translate(session: TranslationSession) async {
        let generation = requestGeneration
        do {
            let response = try await session.translate(text)
            guard generation == requestGeneration else { return }
            translatedText = response.targetText
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func cancel() {
        aiTask?.cancel()
        aiTask = nil
        appleConfiguration = nil
    }

    private func translateWithAI() {
        let configuration = model.aiConfiguration
        guard configuration.isConfigured else {
            errorMessage = L("请先配置 AI 翻译服务。")
            isLoading = false
            return
        }
        let apiKey = model.aiAPIKey
        guard configuration.allowsEmptyAPIKey ||
                !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = L("请先填写 AI 服务的 API Key。")
            isLoading = false
            return
        }
        let generation = requestGeneration
        let source = sourceLanguage
        let target = targetLanguage
        aiTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await AITranslationService().translateWithProtocolFallback(
                    text: text,
                    source: source,
                    target: target,
                    configuration: configuration,
                    apiKey: apiKey
                )
                guard !Task.isCancelled, generation == requestGeneration else { return }
                model.applyDetectedAIAPI(result.api)
                translatedText = result.text
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == requestGeneration else { return }
                errorMessage = error.localizedDescription
            }
            guard generation == requestGeneration else { return }
            isLoading = false
        }
    }

    private static func sameLanguageFamily(_ lhs: String, _ rhs: String) -> Bool {
        lhs.split(separator: "-").first == rhs.split(separator: "-").first
    }

    private static func supportedLanguage(containing identifier: String) -> String {
        if identifier.hasPrefix("zh-Hant") { return "zh-Hant" }
        if identifier.hasPrefix("zh") { return "zh-Hans" }
        return LanguageChoice.targets.first(where: {
            identifier == $0.id || identifier.hasPrefix("\($0.id)-")
        })?.id ?? "auto"
    }
}

struct SelectionTranslationView: View {
    @ObservedObject var model: AppModel
    let text: String
    let onClose: () -> Void
    @StateObject private var controller: SelectionTranslationController

    init(model: AppModel, text: String, onClose: @escaping () -> Void) {
        self.model = model
        self.text = text
        self.onClose = onClose
        _controller = StateObject(wrappedValue: SelectionTranslationController(model: model, text: text))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "character.bubble.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 28, height: 28)
                    .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("划词翻译")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .frame(width: 24, height: 24)
                        .background(Palette.ink.opacity(0.045), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭划词翻译")
            }

            HStack(spacing: 6) {
                languageMenu(
                    accessibilityTitle: "原文语言",
                    selection: controller.sourceLanguage,
                    choices: LanguageChoice.sources
                ) { controller.changeLanguages(source: $0) }

                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.muted.opacity(0.75))

                languageMenu(
                    accessibilityTitle: "目标语言",
                    selection: controller.targetLanguage,
                    choices: LanguageChoice.targets,
                    isEnabled: controller.canSelect(target:)
                ) { controller.changeLanguages(target: $0) }

                Spacer(minLength: 0)
            }

            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .lineLimit(2)

            Rectangle().fill(Palette.line).frame(height: 1)

            Group {
                if controller.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在翻译…")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if let errorMessage = controller.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.danger)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ScrollView {
                        Text(controller.translatedText)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !controller.translatedText.isEmpty {
                HStack {
                    Spacer()
                    Button {
                        model.copyText(controller.translatedText)
                        close()
                    } label: {
                        Label("复制译文", systemImage: "doc.on.doc")
                            .font(.system(size: 10.5, weight: .semibold))
                            .padding(.horizontal, 9)
                            .frame(height: 27)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
        }
        .padding(13)
        .frame(width: SelectionTranslationLayout.width, height: SelectionTranslationLayout.height)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.line))
        .preferredColorScheme(.light)
        .onAppear(perform: controller.start)
        .onDisappear(perform: controller.cancel)
        .onExitCommand(perform: close)
        .translationTask(controller.appleConfiguration) { session in
            await controller.translate(session: session)
        }
    }

    private func languageMenu(
        accessibilityTitle: String,
        selection: String,
        choices: [LanguageChoice],
        isEnabled: @escaping (String) -> Bool = { _ in true },
        onSelect: @escaping (String) -> Void
    ) -> some View {
        let selectedName = choices.first(where: { $0.id == selection })?.name ?? selection
        return Menu {
            ForEach(choices) { language in
                Button {
                    onSelect(language.id)
                } label: {
                    if language.id == selection {
                        Label(language.name, systemImage: "checkmark")
                    } else {
                        Text(language.name)
                    }
                }
                .disabled(!isEnabled(language.id))
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedName)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(Palette.muted)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Palette.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(accessibilityTitle)
    }

    private func close() {
        controller.cancel()
        onClose()
    }
}

enum SelectionTranslationLayout {
    static let width: CGFloat = 390
    static let height: CGFloat = 252
}

final class SelectionTranslationPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
