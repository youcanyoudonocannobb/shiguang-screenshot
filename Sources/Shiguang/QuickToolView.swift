import SwiftUI
import Translation

struct QuickToolView: View {
    @ObservedObject var model: AppModel
    let onCopy: (String) -> String?
    let onClose: () -> Void

    @StoredState private var query = ""
    @StoredState private var selectedIndex = 0
    @StoredState private var generatedValues: [RandomDataType: String] = [:]
    @StoredState private var copiedValue = ""
    @StoredState private var errorMessage: String?
    @StoredState private var translatedChinese = ""
    @StoredState private var translatedEnglish = ""
    @StoredState private var requestedChinese = ""
    @StoredState private var isTranslatingChinese = false
    @StoredState private var translationError: String?
    @StoredState private var translationSerial = 0
    @StoredState private var translationConfiguration: TranslationSession.Configuration?
    @StoredState private var translationTimeoutTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool

    private var invocation: QuickLauncherInvocation? {
        QuickLauncherParser.invocation(from: query)
    }

    private var matchingCommands: [QuickLauncherCommand] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return QuickLauncherCommand.all }
        let token = value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? value
        return QuickLauncherCommand.all.filter { command in
            command.title.lowercased().contains(value) ||
                command.trigger.lowercased().contains(token) ||
                command.aliases.contains { $0.lowercased().contains(token) }
        }
    }

    private var effectiveInvocation: QuickLauncherInvocation? {
        if let invocation { return invocation }
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, matchingCommands.isEmpty else { return nil }
        return QuickLauncherInvocation(
            command: .variable(model.variableNamingStyle),
            argument: value
        )
    }

    private var commands: [QuickLauncherCommand] {
        if let effectiveInvocation { return [effectiveInvocation.command] }
        return matchingCommands
    }

    private var selectedCommand: QuickLauncherCommand? {
        guard !commands.isEmpty else { return nil }
        return commands[min(max(selectedIndex, 0), commands.count - 1)]
    }

    private var argument: String {
        effectiveInvocation?.argument ?? ""
    }

    private var selectedOutput: String {
        guard let selectedCommand else { return "" }
        switch selectedCommand {
        case .random(let type):
            return generatedValues[type] ?? ""
        case .variable(let style):
            guard !argument.isEmpty else { return "" }
            if ChineseEnglishGlossary.containsChinese(argument) {
                guard translatedChinese == argument, !translatedEnglish.isEmpty else { return "" }
                return VariableNameTransformer.convertEnglish(translatedEnglish, style: style)
            }
            return VariableNameTransformer.convertEnglish(argument, style: style)
        }
    }

    private var resultDetail: String {
        guard let selectedCommand else { return "输入快捷语后按 Return 复制" }
        if case .variable = selectedCommand, argument.isEmpty {
            return selectedCommand.example
        }
        if ChineseEnglishGlossary.containsChinese(argument), !translatedEnglish.isEmpty {
            return "\(argument) → \(translatedEnglish)"
        }
        return selectedCommand.detail
    }

    var body: some View {
        VStack(spacing: 10) {
            searchBar
            resultHeader
            commandList
            resultBar
            footer
        }
        .padding(12)
        .frame(width: 640, height: 454)
        .background {
            LinearGradient(
                colors: [Palette.background, Color(hex: "EDF4F8")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .preferredColorScheme(.light)
        .background {
            QuickTranslationBridge(
                request: requestedChinese,
                configuration: translationConfiguration,
                onResult: finishTranslation
            )
            .id(translationSerial)
        }
        .onAppear {
            seedGeneratedValues()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                inputFocused = true
            }
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            copiedValue = ""
            errorMessage = nil
            let parsed = QuickLauncherParser.invocation(from: query)
            let matches = matchingCommands
            let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let effective = parsed ?? ((!value.isEmpty && matches.isEmpty)
                ? QuickLauncherInvocation(command: .variable(model.variableNamingStyle), argument: value)
                : nil)
            updateTranslation(for: effective)
            seedRandomValueIfNeeded(for: effective?.command)
        }
        .onDisappear {
            translationTimeoutTask?.cancel()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "pawprint.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text("PawShot 快捷输入")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                TextField("输入快捷语，例如 xt 用户登录、uuid、ip", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .focused($inputFocused)
                    .onSubmit { activateSelection() }
                    .onKeyPress(.upArrow) {
                        moveSelection(-1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        moveSelection(1)
                        return .handled
                    }
            }

            if !query.isEmpty {
                Button {
                    query = ""
                    inputFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除输入")
            }

            Text(model.variableNamingHotkey.symbol)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 7)
                .frame(height: 23)
                .background(Palette.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 27, height: 27)
                    .background(Palette.panel, in: Circle())
                    .overlay(Circle().stroke(Palette.line))
            }
            .buttonStyle(.plain)
            .help("关闭 (Esc)")
            .accessibilityLabel("关闭快捷输入")
        }
        .padding(.horizontal, 11)
        .frame(height: 50)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.line))
        .shadow(color: Palette.shadow, radius: 12, y: 4)
    }

    private var resultHeader: some View {
        HStack {
            Text(invocation == nil && !query.isEmpty && effectiveInvocation != nil ? "默认变量格式" : "快捷语")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Palette.muted)
            Spacer()
            Text("↑ ↓ 选择 · ↩ 执行")
                .font(.system(size: 9))
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 3)
    }

    private var commandList: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                if commands.isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 20, weight: .light))
                        Text("没有匹配的快捷语")
                            .font(.system(size: 12, weight: .medium))
                        Text("试试 xt、lt、dt、snake、uuid、address 或 ip")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 38)
                } else {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        commandRow(command, index: index)
                    }
                }
            }
            .padding(1)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
    }

    private func commandRow(_ command: QuickLauncherCommand, index: Int) -> some View {
        let selected = index == min(max(selectedIndex, 0), max(commands.count - 1, 0))
        let preview = preview(for: command)
        return Button {
            selectedIndex = index
            activateSelection()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: command.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? .white : Palette.accent)
                    .frame(width: 28, height: 28)
                    .background(selected ? Palette.accent : Palette.accentSoft,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(command.title)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(command.trigger)
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(selected ? Palette.accent : Palette.muted)
                            .padding(.horizontal, 5)
                            .frame(height: 17)
                            .background(selected ? Palette.panel : Palette.background,
                                        in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text(command.detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if case .variable = command, effectiveInvocation?.argument.isEmpty == true {
                    Text(command.example)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                } else if let preview {
                    Text(preview)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(selected ? Palette.ink : Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 250, alignment: .trailing)
                } else if isTranslatingChinese {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("翻译中")
                            .font(.system(size: 9.5))
                    }
                    .foregroundStyle(Palette.muted)
                }

                Image(systemName: "return")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Palette.muted.opacity(selected ? 1 : 0.45))
                    .frame(width: 22, height: 22)
                    .background(selected ? Palette.panel : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(selected ? Palette.accentSoft.opacity(0.8) : Palette.panel.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Palette.accent.opacity(0.35) : Palette.line.opacity(0.85))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(command.title)，快捷语 \(command.trigger)")
    }

    private var resultBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("生成结果")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                    if isTranslatingChinese {
                        ProgressView().controlSize(.mini)
                    }
                }
                Text(selectedOutput.isEmpty ? resultDetail : selectedOutput)
                    .font(.system(size: 14, weight: selectedOutput.isEmpty ? .regular : .medium,
                                  design: selectedOutput.isEmpty ? .default : .monospaced))
                    .foregroundStyle(selectedOutput.isEmpty ? Palette.muted : Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.danger)
                    .lineLimit(1)
            } else if let translationError {
                Text(translationError)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.danger)
                    .lineLimit(1)
            }

            Button(action: copySelection) {
                HStack(spacing: 6) {
                    Image(systemName: copiedValue == selectedOutput && !selectedOutput.isEmpty
                          ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .bold))
                    Text(copiedValue == selectedOutput && !selectedOutput.isEmpty ? "已复制" : "复制")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(selectedOutput.isEmpty ? Palette.muted : .white)
                .frame(width: 90, height: 32)
                .background(selectedOutput.isEmpty ? Palette.ink.opacity(0.07) : Palette.accent,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(selectedOutput.isEmpty)
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityLabel("复制生成结果")
        }
        .padding(.horizontal, 12)
        .frame(height: 58)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.line))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            keyHint("↩", label: "执行 / 复制")
            keyHint("Esc", label: "关闭")
            Spacer()
            Text("中文会先翻译为英文再生成变量名")
                .font(.system(size: 9))
                .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 2)
    }

    private func preview(for command: QuickLauncherCommand) -> String? {
        switch command {
        case .random(let type):
            return generatedValues[type]
        case .variable(let style):
            guard effectiveInvocation?.command == command, !argument.isEmpty else { return nil }
            if ChineseEnglishGlossary.containsChinese(argument) {
                guard translatedChinese == argument, !translatedEnglish.isEmpty else { return nil }
                return VariableNameTransformer.convertEnglish(translatedEnglish, style: style)
            }
            return VariableNameTransformer.convertEnglish(argument, style: style)
        }
    }

    private func activateSelection() {
        guard let selectedCommand else { return }
        if case .variable = selectedCommand, argument.isEmpty {
            query = "\(selectedCommand.trigger) "
            inputFocused = true
            return
        }
        copySelection()
    }

    private func copySelection() {
        guard !selectedOutput.isEmpty else { return }
        if let error = onCopy(selectedOutput) {
            errorMessage = error
            copiedValue = ""
            return
        }
        errorMessage = nil
        withAnimation(.easeOut(duration: 0.14)) {
            copiedValue = selectedOutput
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !commands.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), commands.count - 1)
        seedRandomValueIfNeeded(for: selectedCommand)
    }

    private func updateTranslation(for invocation: QuickLauncherInvocation?) {
        translationSerial += 1
        let serial = translationSerial
        translationTimeoutTask?.cancel()
        guard let invocation, case .variable = invocation.command else {
            clearTranslation()
            return
        }
        let value = invocation.argument.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ChineseEnglishGlossary.containsChinese(value) else {
            clearTranslation()
            return
        }
        if let translated = ChineseEnglishGlossary.translate(value) {
            requestedChinese = value
            translatedChinese = value
            translatedEnglish = translated
            isTranslatingChinese = false
            translationError = nil
            translationConfiguration = nil
            return
        }

        requestedChinese = value
        translatedChinese = ""
        translatedEnglish = ""
        translationError = nil
        isTranslatingChinese = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard serial == translationSerial, requestedChinese == value else { return }
            let source = Locale.Language(identifier: "zh-Hans")
            let target = Locale.Language(identifier: "en")
            var configuration: TranslationSession.Configuration
            if #available(macOS 26.4, *) {
                configuration = TranslationSession.Configuration(
                    source: source,
                    target: target,
                    preferredStrategy: .lowLatency
                )
            } else {
                configuration = TranslationSession.Configuration(source: source, target: target)
            }
            // Source and target stay zh-Hans -> en for every lookup. Invalidate the
            // configuration so SwiftUI starts a fresh task for each new phrase.
            configuration.invalidate()
            translationConfiguration = configuration
            translationTimeoutTask = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard serial == translationSerial, isTranslatingChinese else { return }
                isTranslatingChinese = false
                translationError = "中文翻译超时，请重新输入或稍后重试。"
            }
        }
    }

    private func clearTranslation() {
        translationTimeoutTask?.cancel()
        translationTimeoutTask = nil
        requestedChinese = ""
        translatedChinese = ""
        translatedEnglish = ""
        isTranslatingChinese = false
        translationError = nil
        translationConfiguration = nil
    }

    private func finishTranslation(request: String, english: String?, error: String?) {
        guard request == requestedChinese else { return }
        translationTimeoutTask?.cancel()
        translationTimeoutTask = nil
        isTranslatingChinese = false
        if let english {
            translatedChinese = request
            translatedEnglish = english
            translationError = nil
        } else {
            translationError = "中文翻译失败：\(error ?? "未知错误")"
        }
    }

    private func seedGeneratedValues() {
        for type in RandomDataType.allCases where generatedValues[type] == nil {
            generatedValues[type] = RandomDataGenerator.generate(type)
        }
    }

    private func seedRandomValueIfNeeded(for command: QuickLauncherCommand?) {
        guard case .random(let type) = command else { return }
        if generatedValues[type] == nil {
            generatedValues[type] = RandomDataGenerator.generate(type)
        }
    }

    private func keyHint(_ key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 5)
                .frame(height: 19)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.line))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Palette.muted)
        }
    }
}

private struct QuickTranslationBridge: View {
    let request: String
    let configuration: TranslationSession.Configuration?
    let onResult: (String, String?, String?) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .translationTask(configuration) { session in
                guard !request.isEmpty else { return }
                do {
                    let response = try await session.translate(request)
                    await MainActor.run {
                        onResult(request, response.targetText, nil)
                    }
                } catch {
                    await MainActor.run {
                        onResult(request, nil, error.localizedDescription)
                    }
                }
            }
    }
}
