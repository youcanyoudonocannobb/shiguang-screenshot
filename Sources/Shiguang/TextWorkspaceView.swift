import AppKit
import SwiftUI

struct TextWorkspaceView: View {
    @ObservedObject var model: AppModel
    private var isRecognition: Bool { model.editorMode == .recognition }
    private var needsAISetup: Bool {
        !isRecognition && model.translationProvider == .ai && !model.aiReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            VStack(spacing: 0) {
                if !isRecognition {
                    languageBar
                    Rectangle().fill(Palette.line).frame(height: 1)
                }
                HStack(spacing: 0) {
                    sourcePanel
                    if !isRecognition {
                        Rectangle().fill(Palette.line).frame(width: 1)
                        resultPanel
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .background(Palette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line))
            if model.errorMessage != nil || needsAISetup { feedback }
            actionBar
        }
        .padding(20)
        .frame(minWidth: isRecognition ? 480 : 680, minHeight: isRecognition ? 330 : 400)
        .background(Palette.background)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().scaledToFit().frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(isRecognition ? "文字识别" : "翻译")
                    .font(.system(size: 20, weight: .semibold))
                Text(isRecognition ? "识别后可直接校对" : "读懂选中的每一句")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 16)
            if isRecognition {
                Label("本机识别", systemImage: "lock.shield")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            } else {
                Menu {
                    ForEach(TranslationProvider.allCases) { provider in
                        Button(provider.title) { model.translationProvider = provider }
                    }
                    Divider()
                    Button("翻译设置…") { openTranslationSettings() }
                } label: {
                    Label(model.translationProvider.title, systemImage: model.translationProvider.symbol)
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(model.isBusy)
                .accessibilityLabel("选择翻译引擎")
            }
        }
    }

    private var languageBar: some View {
        HStack(spacing: 16) {
            languageControl(title: "从", selection: Binding(get: { model.sourceLanguage },
                set: { model.languageEdited(source: $0) }), choices: LanguageChoice.sources)
            Button { model.swapTranslationLanguages() } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.accent)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(TextPanelButtonStyle())
            .help("交换原文与目标语言").accessibilityLabel("交换原文与目标语言")
            languageControl(title: "译为", selection: Binding(get: { model.targetLanguage },
                set: { model.languageEdited(target: $0) }), choices: LanguageChoice.targets)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .disabled(model.isBusy)
    }

    private func languageControl(title: String, selection: Binding<String>,
                                 choices: [LanguageChoice]) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
            Picker(title, selection: selection) {
                ForEach(choices) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small).frame(maxWidth: 160)
            .accessibilityLabel(title == "从" ? "原文语言" : "目标语言")
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourcePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(isRecognition ? "识别文字" : "原文").font(.system(size: 12, weight: .semibold))
                Text("\(model.sourceText.count) 字符").font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                copyButton("复制原文", text: model.sourceText)
            }
            .padding(.horizontal, 16).padding(.top, 6).frame(height: 42)
            ZStack(alignment: .topLeading) {
                if model.sourceText.isEmpty {
                    Text(model.isRecognizing ? "正在设备上识别文字…" :
                            isRecognition ? "没有识别到文字，可以重试或输入。" : "粘贴或输入原文…")
                        .foregroundStyle(Palette.muted).font(.system(size: 15))
                        .padding(.horizontal, 18).padding(.vertical, 12).allowsHitTesting(false)
                }
                TextEditor(text: Binding(get: { model.sourceText }, set: { model.sourceEdited($0) }))
                    .font(.system(size: 15)).lineSpacing(6)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .accessibilityLabel(isRecognition ? "识别文字" : "原文")
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("译文").font(.system(size: 12, weight: .semibold))
                Spacer()
                copyButton("复制译文", text: model.translatedText)
            }
            .padding(.horizontal, 16).padding(.top, 6).frame(height: 42)
            if model.translatedText.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 25, weight: .light)).foregroundStyle(Palette.accent.opacity(0.65))
                    Text(model.translationJob != nil ? "正在翻译…" : "译文将在这里呈现")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(model.translatedText)
                        .foregroundStyle(Palette.ink).font(.system(size: 15)).lineSpacing(6)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.vertical, 12)
                }
            }
        }
        .frame(minWidth: 260, maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
        .background(Palette.sage.opacity(0.65))
    }

    private func copyButton(_ title: String, text: String) -> some View {
        Button { model.copyText(text) } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(TextPanelButtonStyle()).disabled(text.isEmpty)
            .help(title).accessibilityLabel(title)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            statusBar.layoutPriority(-1)
            Spacer(minLength: 8)
            if !isRecognition {
                Button("复制对照") { model.copyText("\(model.sourceText)\n\n\(model.translatedText)") }
                    .buttonStyle(QuietButton())
                    .disabled(model.sourceText.isEmpty || model.translatedText.isEmpty)
            }
            if isRecognition && model.image != nil {
                Button("重新识别") { model.recognize() }
                    .buttonStyle(QuietButton()).disabled(model.isBusy)
            }
            Button { model.requestTranslation() } label: {
                HStack(spacing: 10) {
                    Text(isRecognition ? "翻译文字" : model.translatedText.isEmpty ? "翻译" : "重新翻译")
                    Text("⌘↩").font(.system(size: 10)).opacity(0.7)
                }
            }
            .buttonStyle(AccentButton()).disabled(!model.canTranslate)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isBusy { ProgressView().controlSize(.small) }
            Text(model.isBusy ? (model.activity ?? "处理中…") : isRecognition ? "可直接校对文字" : "自动识别语言 · Esc 关闭")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2)
            if model.isRecognizing {
                Button("停止识别") { model.cancelRecognition() }.buttonStyle(TextPanelButtonStyle())
            }
            if model.translationJob != nil {
                Button("停止翻译") { model.cancelTranslation() }.buttonStyle(TextPanelButtonStyle())
            }
        }
    }

    private var feedback: some View {
        HStack(spacing: 10) {
            Image(systemName: needsAISetup ? "key" : "exclamationmark.circle")
                .foregroundStyle(needsAISetup ? Palette.accent : Palette.danger)
            Text(needsAISetup ? "配置 AI 服务后即可翻译，也可以切换到 Apple 翻译。" : model.errorMessage ?? "")
                .font(.system(size: 11)).foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            if model.translationProvider == .ai {
                Button("配置 AI") { openTranslationSettings() }.buttonStyle(TextPanelButtonStyle())
            }
        }
        .padding(12).background(Palette.accentSoft.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }

    private func openTranslationSettings() {
        UserDefaults.standard.set("translation", forKey: "settings.selectedPage")
        model.showWorkspace?()
    }
}

private struct TextPanelButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @StoredState private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.ink)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(configuration.isPressed ? Palette.line : hovered ? Palette.accentSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.4).onHover { hovered = $0 }
    }
}
