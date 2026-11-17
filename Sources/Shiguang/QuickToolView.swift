import SwiftUI
import Translation

/// Merged launcher: opens local apps and files, and keeps the quick-input
/// commands (variable naming, random data) that used to live in their own panel.
struct QuickToolView: View {
    @ObservedObject var model: AppModel
    let onCopy: (String) -> String?
    let onClose: () -> Void
    let onHeightChange: (CGFloat) -> Void

    @StoredState private var query = ""
    @StoredState private var selectedIndex = 0
    @StoredState private var generatedValues: [RandomDataType: String] = [:]
    @StoredState private var errorMessage: String?
    @StoredState private var translatedChinese = ""
    @StoredState private var translatedEnglish = ""
    @StoredState private var requestedChinese = ""
    @StoredState private var isTranslatingChinese = false
    @StoredState private var translationError: String?
    @StoredState private var translationSerial = 0
    @StoredState private var translationConfiguration: TranslationSession.Configuration?
    @StoredState private var translationTimeoutTask: Task<Void, Never>?
    @StoredState private var fileEntries: [LauncherEntry] = []
    @StoredState private var fileSearchTask: Task<Void, Never>?
    @StateObject private var index = LauncherIndex.shared
    @FocusState private var inputFocused: Bool

    static let panelWidth: CGFloat = 640
    static let collapsedHeight: CGFloat = 66
    private let rowHeight: CGFloat = 46
    private let rowSpacing: CGFloat = 3
    private let maximumCommandResults = 4
    private let maximumEntries = 5

    private enum Row: Identifiable {
        case command(QuickLauncherCommand)
        case entry(LauncherEntry)
        case toolbox

        var id: String {
            switch self {
            case .command(let command): return command.id
            case .entry(let entry): return entry.id
            case .toolbox: return "toolbox"
            }
        }
    }

    private var invocation: QuickLauncherInvocation? {
        QuickLauncherParser.invocation(from: query)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingCommands: [QuickLauncherCommand] {
        let value = trimmedQuery.lowercased()
        guard !value.isEmpty else { return [] }
        let token = value.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? value
        return QuickLauncherCommand.all.filter { command in
            command.title.lowercased().contains(value) ||
                command.trigger.lowercased().contains(token) ||
                command.aliases.contains { $0.lowercased().contains(token) }
        }
    }

    private var commands: [QuickLauncherCommand] {
        if let invocation {
            return [invocation.command]
        }
        if !matchingCommands.isEmpty {
            return Array(matchingCommands.prefix(maximumCommandResults))
        }
        return []
    }

    private var rows: [Row] {
        if invocation != nil {
            return commands.map(Row.command)
        }
        var result: [Row] = []
        if trimmedQuery.isEmpty {
            return []
        }
        if trimmedQuery.hasPrefix("/") {
            let path = (trimmedQuery as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            let detail: String
            if exists {
                detail = isDirectory.boolValue ? "文件夹 · 回车打开" : "文件 · 回车在访达中显示"
            } else {
                detail = "路径不存在 · 回车打开上级文件夹"
            }
            return [.entry(LauncherEntry(kind: .path, title: path,
                                         subtitle: detail, url: url))]
        }
        let lower = trimmedQuery.lowercased()
        if lower == "json" || lower == "工具箱" {
            return [.toolbox]
        }
        result += index.matchingApplications(trimmedQuery, limit: maximumEntries).map(Row.entry)
        result += fileEntries.map(Row.entry)
        result += commands.map(Row.command)
        return result
    }

    private var selectedRow: Row? {
        guard !rows.isEmpty else { return nil }
        return rows[min(max(selectedIndex, 0), rows.count - 1)]
    }

    private func argument(for command: QuickLauncherCommand) -> String {
        if let invocation, invocation.command == command {
            return invocation.argument
        }
        return ""
    }

    private func output(for command: QuickLauncherCommand) -> String {
        switch command {
        case .random(let type):
            return generatedValues[type] ?? ""
        case .variable(let style):
            let value = argument(for: command)
            guard !value.isEmpty else { return "" }
            if ChineseEnglishGlossary.containsChinese(value) {
                guard translatedChinese == value, !translatedEnglish.isEmpty else { return "" }
                return VariableNameTransformer.convertEnglish(translatedEnglish, style: style)
            }
            return VariableNameTransformer.convertEnglish(value, style: style)
        }
    }

    private var resultsPanelHeight: CGFloat {
        guard !rows.isEmpty else { return 0 }
        let rowsHeight = CGFloat(rows.count) * rowHeight
        let spacing = CGFloat(max(rows.count - 1, 0)) * rowSpacing
        return 12 + rowsHeight + spacing + 25
    }

    private var preferredHeight: CGFloat {
        rows.isEmpty ? Self.collapsedHeight : Self.collapsedHeight + 6 + resultsPanelHeight
    }

    var body: some View {
        VStack(spacing: 6) {
            searchBar
            if !rows.isEmpty {
                resultsPanel
            }
        }
        .padding(6)
        .frame(width: Self.panelWidth, height: preferredHeight, alignment: .top)
        .background(Color.clear)
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .preferredColorScheme(.light)
        .onExitCommand(perform: onClose)
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
            index.loadIfNeeded()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                inputFocused = true
            }
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            errorMessage = nil
            let effective = QuickLauncherParser.invocation(from: query)
            updateTranslation(for: effective)
            seedRandomValueIfNeeded(for: effective?.command)
            scheduleFileSearch()
        }
        .onChange(of: preferredHeight, initial: true) { _, height in
            onHeightChange(height)
        }
        .onDisappear {
            translationTimeoutTask?.cancel()
            fileSearchTask?.cancel()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Palette.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            TextField("搜索应用、文件，或输入 xt / name / 地址", text: $query)
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
        }
        .padding(.horizontal, 10)
        .frame(height: 54)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.line))
        .shadow(color: Palette.shadow, radius: 12, y: 4)
    }

    private var resultsPanel: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: rowSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, index: index)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: CGFloat(rows.count) * rowHeight +
                   CGFloat(max(rows.count - 1, 0)) * rowSpacing)

            resultsFooter
        }
        .padding(6)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Palette.line))
        .shadow(color: Palette.shadow, radius: 12, y: 4)
    }

    private var resultsFooter: some View {
        HStack(spacing: 8) {
            keyHint("↑ ↓", label: "选择")
            keyHint("↩", label: "打开 / 复制")
            if let errorMessage {
                Text(errorMessage).foregroundStyle(Palette.danger).lineLimit(1)
            } else if let translationError {
                Text(translationError).foregroundStyle(Palette.danger).lineLimit(1)
            } else if isTranslatingChinese {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("翻译中")
                }
                .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 4)
            Text("Esc 关闭").foregroundStyle(Palette.muted)
        }
        .font(.system(size: 9))
        .padding(.horizontal, 4)
        .frame(height: 25)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.line).frame(height: 1)
        }
    }

    @ViewBuilder private func rowView(_ row: Row, index rowIndex: Int) -> some View {
        switch row {
        case .command(let command):
            commandRow(command, index: rowIndex)
        case .entry(let entry):
            entryRow(entry, index: rowIndex)
        case .toolbox:
            toolboxRow(index: rowIndex)
        }
    }

    private func toolboxRow(index rowIndex: Int) -> some View {
        let selected = rowIndex == selectedDisplayIndex
        return Button {
            selectedIndex = rowIndex
            activateSelection()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? .white : Palette.accent)
                    .frame(width: 28, height: 28)
                    .background(selected ? Palette.accent : Palette.accentSoft,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("工具箱")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text("JSON 转换 / 编码转换")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 8)
                Text("打开")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(selected ? Palette.ink : Palette.muted)
                Image(systemName: "return")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Palette.muted.opacity(selected ? 1 : 0.45))
                    .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .background(selected ? Palette.accentSoft.opacity(0.8) : Palette.panel.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Palette.accent.opacity(0.35) : Palette.line.opacity(0.85))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selectedIndex = rowIndex }
        }
        .accessibilityLabel("工具箱，JSON 转换与编码转换")
    }

    private func entryRow(_ entry: LauncherEntry, index rowIndex: Int) -> some View {
        let selected = rowIndex == selectedDisplayIndex
        return Button {
            selectedIndex = rowIndex
            activateSelection()
        } label: {
            HStack(spacing: 11) {
                Image(nsImage: LauncherAction.icon(for: entry))
                    .resizable().scaledToFit()
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    Text(entry.subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(entry.kind.title)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 5)
                    .frame(height: 17)
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 4))
                Image(systemName: "return")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Palette.muted.opacity(selected ? 1 : 0.45))
                    .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .background(selected ? Palette.accentSoft.opacity(0.8) : Palette.panel.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Palette.accent.opacity(0.35) : Palette.line.opacity(0.85))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selectedIndex = rowIndex }
        }
        .accessibilityLabel("\(entry.title)，\(entry.kind.title)")
    }

    private var selectedDisplayIndex: Int {
        min(max(selectedIndex, 0), max(rows.count - 1, 0))
    }

    private func commandRow(_ command: QuickLauncherCommand, index rowIndex: Int) -> some View {
        let selected = rowIndex == selectedDisplayIndex
        let preview = preview(for: command)
        return Button {
            selectedIndex = rowIndex
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

                if let preview {
                    Text(preview)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(selected ? Palette.ink : Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 250, alignment: .trailing)
                } else if isTranslatingChinese, selected {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("翻译中").font(.system(size: 9.5))
                    }
                    .foregroundStyle(Palette.muted)
                } else if case .variable = command, argument(for: command).isEmpty {
                    Text(command.example)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                } else {
                    Text("…")
                        .font(.system(size: 11, design: .monospaced))
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
            .frame(height: rowHeight)
            .background(selected ? Palette.accentSoft.opacity(0.8) : Palette.panel.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? Palette.accent.opacity(0.35) : Palette.line.opacity(0.85))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { selectedIndex = rowIndex }
        }
        .accessibilityLabel("\(command.title)，快捷语 \(command.trigger)")
    }

    private func preview(for command: QuickLauncherCommand) -> String? {
        switch command {
        case .random(let type):
            return generatedValues[type]
        case .variable(let style):
            let value = argument(for: command)
            guard !value.isEmpty else { return nil }
            if ChineseEnglishGlossary.containsChinese(value) {
                guard translatedChinese == value, !translatedEnglish.isEmpty else { return nil }
                return VariableNameTransformer.convertEnglish(translatedEnglish, style: style)
            }
            return VariableNameTransformer.convertEnglish(value, style: style)
        }
    }

    private func activateSelection() {
        guard let selectedRow else { return }
        switch selectedRow {
        case .entry(let entry):
            if let error = LauncherAction.open(entry) {
                errorMessage = error
            } else {
                onClose()
            }
        case .command(let command):
            if case .variable = command, argument(for: command).isEmpty {
                query = "\(command.trigger) "
                inputFocused = true
                return
            }
            copyCommand(command)
        case .toolbox:
            model.showToolbox?()
            onClose()
        }
    }

    private func copyCommand(_ command: QuickLauncherCommand) {
        let value = output(for: command)
        guard !value.isEmpty else { return }
        if let error = onCopy(value) {
            errorMessage = error
            return
        }
        errorMessage = nil
        onClose()
    }

    private func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + delta, 0), rows.count - 1)
        if case .command(let command)? = selectedRow {
            seedRandomValueIfNeeded(for: command)
        }
    }

    private func scheduleFileSearch() {
        fileSearchTask?.cancel()
        fileEntries = []
        let value = trimmedQuery
        let lower = value.lowercased()
        guard value.count >= 2, invocation == nil,
              !value.hasPrefix("/"), lower != "json", lower != "工具箱" else {
            fileEntries = []
            return
        }
        fileSearchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let found = await LauncherIndex.searchFiles(value, limit: 4)
            guard !Task.isCancelled, trimmedQuery == value else { return }
            fileEntries = found.filter { entry in
                !index.applications.contains(where: { $0.url.path == entry.url.path })
            }
        }
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
            var configuration = TranslationSession.Configuration(source: source, target: target)
            // Invalidate so SwiftUI starts a fresh task for each new phrase.
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
