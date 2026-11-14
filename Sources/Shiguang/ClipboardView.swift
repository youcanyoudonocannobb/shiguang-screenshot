import SwiftUI

struct ClipboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var history: ClipboardHistory
    let onCopy: (ClipboardEntry) -> Void
    let onCopyText: (String) -> Void
    let onClose: () -> Void
    @StoredState private var confirmsClear = false
    @StoredState private var variableInput = ""
    @StoredState private var generatedValues: [RandomDataType: String] = [:]
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            header
            sectionBar
            if history.section == .history {
                searchField
                filterBar
                content
            } else {
                toolsContent
            }
            footer
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 460)
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .preferredColorScheme(.light)
        .onAppear {
            searchFocused = history.section == .history
            seedGeneratedValues()
        }
        .onChange(of: history.section) { _, section in
            searchFocused = section == .history
            if section == .tools { seedGeneratedValues() }
        }
        .onChange(of: history.search) { _, _ in history.selectedID = history.filteredEntries.first?.id }
        .onChange(of: history.filter) { _, _ in history.selectedID = history.filteredEntries.first?.id }
        .confirmationDialog("清空剪贴板历史？", isPresented: $confirmsClear) {
            Button("清空历史", role: .destructive) { history.clear() }
        } message: {
            Text("系统剪贴板当前内容仍可粘贴。")
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.accent)
                .frame(width: 36, height: 36)
                .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text("剪贴板")
                        .font(.system(size: 19, weight: .semibold))
                    if history.section == .history {
                        Text("\(history.entries.count) 项")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Palette.ink.opacity(0.045), in: Capsule())
                    }
                }
                Text(history.section == .tools
                     ? "变量命名与测试数据 · 一键复制"
                     : (history.monitorsSystem ? "正在记录本机剪贴板 · 最近 100 项" : "系统记录已暂停"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(history.section == .history && !history.monitorsSystem
                                     ? Palette.warning : Palette.muted)
            }
            Spacer()
            Menu {
                Toggle("记录系统剪贴板", isOn: $history.monitorsSystem)
                Divider()
                Button("清空历史…", role: .destructive) { confirmsClear = true }
                    .disabled(history.entries.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(Palette.panel, in: Circle())
                    .overlay(Circle().stroke(Palette.line))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("剪贴板设置")
            .accessibilityLabel("剪贴板设置")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 28, height: 28)
                    .background(Palette.panel, in: Circle())
                    .overlay(Circle().stroke(Palette.line))
            }
            .buttonStyle(.plain)
            .help("关闭 (Esc)")
            .accessibilityLabel("关闭剪贴板")
        }
    }

    private var sectionBar: some View {
        HStack(spacing: 4) {
            ForEach(ClipboardSection.allCases) { section in
                let selected = history.section == section
                Button { history.section = section } label: {
                    HStack(spacing: 5) {
                        Image(systemName: section == .history ? "clock.arrow.circlepath" : "wrench.and.screwdriver")
                            .font(.system(size: 10, weight: .semibold))
                        Text(section.title)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(selected ? .white : Palette.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(selected ? Palette.ink : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Palette.line))
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(searchFocused ? Palette.accent : Palette.muted)
            TextField("搜索文字、内容类型或文件名", text: $history.search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !history.search.isEmpty {
                Button { history.search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
            Text("⌘F")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(searchFocused ? Palette.accent.opacity(0.6) : Palette.line,
                    lineWidth: searchFocused ? 1.2 : 1))
    }

    private var filterBar: some View {
        HStack(spacing: 5) {
            filterButton("全部", kind: nil, symbol: "square.grid.2x2")
            ForEach([ClipboardEntry.Kind.text, .image, .gif, .video, .files], id: \.self) { kind in
                filterButton(kind.title, kind: kind, symbol: kind.symbol)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        if history.filteredEntries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: history.search.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Palette.muted)
                Text(history.search.isEmpty ? "复制后，在这里找回内容" : "没有匹配的内容")
                    .font(.system(size: 13, weight: .medium))
                Text(history.search.isEmpty ? "文字、图片、GIF、视频和文件都会保存在本机" :
                        "试试其他关键词或切换内容类型")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.line))
        } else {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(history.filteredEntries) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(1)
                }
                .onChange(of: history.selectedID) { _, id in
                    if let id { reader.scrollTo(id) }
                }
            }
        }
    }

    private var toolsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                toolsSectionTitle("变量命名", detail: "输入中文、英文或混合词组，实时转换")
                variableNameCard

                HStack {
                    toolsSectionTitle("随机测试数据", detail: "点击卡片生成并复制，可在本地反复刷新")
                    Spacer()
                }
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(RandomDataType.allCases) { type in
                        randomDataCard(type)
                    }
                }
            }
            .padding(1)
        }
    }

    private var variableNameCard: some View {
        let conversion = VariableNameTransformer.convert(
            variableInput,
            defaultStyle: model.variableNamingStyle
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "textformat.abc.dottedunderline")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 28, height: 28)
                    .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                TextField("例如：xt user profile / 用户 名称", text: $variableInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                Menu {
                    ForEach(VariableNamingStyle.allCases) { style in
                        Button {
                            model.variableNamingStyle = style
                        } label: {
                            if style == model.variableNamingStyle {
                                Label("\(style.title) · \(style.shortcut)", systemImage: "checkmark")
                            } else {
                                Text("\(style.title) · \(style.shortcut)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(conversion.style.title)
                        Text(conversion.style.shortcut)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Palette.muted)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Palette.muted)
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(Palette.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.line))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            HStack(spacing: 8) {
                Text(conversion.value.isEmpty ? "转换结果会显示在这里" : conversion.value)
                    .font(.system(size: 13, weight: conversion.value.isEmpty ? .regular : .medium,
                                  design: .monospaced))
                    .foregroundStyle(conversion.value.isEmpty ? Palette.muted : Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if conversion.usedCommand {
                    Text("命令 \(conversion.style.shortcut)")
                        .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Palette.accentSoft, in: Capsule())
                }
                Button {
                    guard !conversion.value.isEmpty else { return }
                    onCopyText(conversion.value)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 9)
                        .frame(height: 27)
                }
                .buttonStyle(.plain)
                .foregroundStyle(conversion.value.isEmpty ? Palette.muted : .white)
                .background(conversion.value.isEmpty ? Palette.ink.opacity(0.06) : Palette.accent,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .disabled(conversion.value.isEmpty)
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Palette.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.line))

            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Palette.accent)
                Text("命令前缀")
                    .font(.system(size: 9.5, weight: .semibold))
                ForEach(VariableNamingStyle.allCases) { style in
                    Text("\(style.shortcut) \(style.title)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Palette.ink.opacity(0.045), in: Capsule())
                }
                Spacer(minLength: 0)
                Text(model.variableNamingHotkey.symbol)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(12)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.line))
    }

    private func randomDataCard(_ type: RandomDataType) -> some View {
        Button {
            let value = RandomDataGenerator.generate(type)
            generatedValues[type] = value
            onCopyText(value)
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: type.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .frame(width: 24, height: 24)
                        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    Text(type.title)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                }
                Text(generatedValues[type] ?? "点击生成并复制")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(generatedValues[type] == nil ? Palette.muted : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Palette.line))
        }
        .buttonStyle(.plain)
        .help("生成新的\(type.title)并复制")
        .accessibilityLabel("生成并复制\(type.title)")
    }

    private func toolsSectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(Palette.muted)
        }
    }

    private func seedGeneratedValues() {
        guard generatedValues.isEmpty else { return }
        for type in RandomDataType.allCases {
            generatedValues[type] = RandomDataGenerator.generate(type)
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            if history.section == .history {
                HStack(spacing: 7) {
                    keyHint("↑ ↓", label: "选择")
                    keyHint("↩", label: "复制")
                    keyHint("Esc", label: "关闭")
                    Spacer()
                    if !history.monitorsSystem {
                        Label("记录已暂停", systemImage: "pause.circle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.warning)
                    }
                }
            } else {
                HStack(spacing: 7) {
                    keyHint(model.variableNamingHotkey.symbol, label: "打开快捷输入")
                    Spacer()
                    Text("测试数据仅用于开发与演示")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.muted)
                }
            }
            if !history.message.isEmpty {
                Text(history.message)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 2)
    }

    private func filterButton(_ title: String, kind: ClipboardEntry.Kind?, symbol: String) -> some View {
        let selected = history.filter == kind
        return Button {
            history.filter = kind
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                Text("\(entryCount(for: kind))")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(selected ? .white.opacity(0.6) : Palette.muted)
            }
            .foregroundStyle(selected ? .white : Palette.ink)
            .padding(.horizontal, 9)
            .frame(height: 27)
            .background(selected ? Palette.ink : Palette.panel, in: Capsule())
            .overlay(Capsule().stroke(selected ? Palette.ink : Palette.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("筛选\(title)，\(entryCount(for: kind)) 项")
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        let selected = history.selectedID == entry.id
        return HStack(spacing: 10) {
            Group {
                if let image = history.preview(entry) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(3)
                } else {
                    Image(systemName: entry.kind.symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Palette.muted)
                }
            }
            .frame(width: 64, height: 48)
            .background(Palette.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Palette.line.opacity(0.9)))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(entry.kind.title)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                    Spacer()
                    Text(entry.createdAt.formatted(.dateTime.month().day().hour().minute()))
                        .font(.system(size: 9.5))
                        .foregroundStyle(Palette.muted)
                }
                Text(entry.summary)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { onCopy(entry) } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? Palette.accent : Palette.muted)
                    .frame(width: 28, height: 28)
                    .background(Palette.panel, in: Circle())
                    .overlay(Circle().stroke(selected ? Palette.accent.opacity(0.4) : Palette.line))
            }
            .buttonStyle(.plain)
            .help("复制此内容")
            .accessibilityLabel("复制\(entry.kind.title)")
        }
        .padding(8)
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .background(selected ? Palette.accentSoft : Palette.panel,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(selected ? Palette.accent.opacity(0.45) : Palette.line,
                    lineWidth: selected ? 1.2 : 1))
        .onTapGesture(count: 2) { onCopy(entry) }
        .onTapGesture { history.selectedID = entry.id }
    }

    private func keyHint(_ key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Palette.muted)
        }
    }

    private func entryCount(for kind: ClipboardEntry.Kind?) -> Int {
        guard let kind else { return history.entries.count }
        return history.entries.filter { $0.kind == kind }.count
    }
}
