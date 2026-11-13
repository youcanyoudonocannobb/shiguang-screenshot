import SwiftUI

struct ClipboardView: View {
    @ObservedObject var history: ClipboardHistory
    let onCopy: (ClipboardEntry) -> Void
    let onClose: () -> Void
    @StoredState private var confirmsClear = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 13) {
            header
            searchField
            filterBar
            content
            footer
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 460)
        .background(ClipboardBackdrop())
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .preferredColorScheme(.light)
        .onAppear { searchFocused = true }
        .onChange(of: history.search) { _, _ in history.selectedID = history.filteredEntries.first?.id }
        .onChange(of: history.filter) { _, _ in history.selectedID = history.filteredEntries.first?.id }
        .confirmationDialog("清空剪贴板历史？", isPresented: $confirmsClear) {
            Button("清空历史", role: .destructive) { history.clear() }
        } message: {
            Text("系统剪贴板当前内容仍可粘贴。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(
                        LinearGradient(colors: [Palette.ink, Color(hex: "3A5148")],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                Circle()
                    .fill(Palette.accent)
                    .frame(width: 8, height: 8)
                    .offset(x: 2, y: -2)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("剪贴板")
                        .font(.system(size: 23, weight: .semibold, design: .serif))
                    Text("\(history.entries.count)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Palette.sage, in: Capsule())
                }
                Text(history.monitorsSystem ? "正在记录本机剪贴板 · 最近 100 项" : "系统记录已暂停")
                    .font(.system(size: 10))
                    .foregroundStyle(history.monitorsSystem ? Palette.muted : Palette.accent)
            }
            Spacer()
            Menu {
                Toggle("记录系统剪贴板", isOn: $history.monitorsSystem)
                Divider()
                Button("清空历史…", role: .destructive) { confirmsClear = true }
                    .disabled(history.entries.isEmpty)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 30, height: 30)
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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 30, height: 30)
                    .background(Palette.panel, in: Circle())
                    .overlay(Circle().stroke(Palette.line))
            }
            .buttonStyle(.plain)
            .help("关闭 (Esc)")
            .accessibilityLabel("关闭剪贴板")
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(searchFocused ? Palette.accent : Palette.muted)
            TextField("搜索文字、内容类型或文件名", text: $history.search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !history.search.isEmpty {
                Button { history.search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
            Text("⌘F")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Palette.line.opacity(0.8)))
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(searchFocused ? Palette.accent.opacity(0.55) : Palette.line,
                    lineWidth: searchFocused ? 1.25 : 1))
        .shadow(color: Palette.shadow, radius: 8, y: 3)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
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
            VStack(spacing: 11) {
                Image(systemName: history.search.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Palette.muted)
                    .frame(width: 56, height: 56)
                    .background(Palette.panel, in: Circle())
                    .overlay(Circle().stroke(Palette.line))
                Text(history.search.isEmpty ? "复制后，在这里找回内容" : "没有匹配的内容")
                    .font(.system(size: 14, weight: .medium))
                Text(history.search.isEmpty ? "文字、图片、GIF、视频和文件都会保存在本机" :
                        "试试其他关键词或切换内容类型")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.panel.opacity(0.42), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.line.opacity(0.55)))
        } else {
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(spacing: 7) {
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

    private var footer: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                keyHint("↑ ↓", label: "选择")
                keyHint("↩", label: "复制")
                keyHint("Esc", label: "关闭")
                Spacer()
                if !history.monitorsSystem {
                    Label("记录已暂停", systemImage: "pause.circle")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Palette.accent)
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
        .padding(.horizontal, 3)
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
                    .foregroundStyle(selected ? .white.opacity(0.65) : Palette.muted)
            }
            .foregroundStyle(selected ? .white : Palette.ink)
            .padding(.horizontal, 9)
            .frame(height: 29)
            .background(selected ? Palette.ink : Palette.panel.opacity(0.86), in: Capsule())
            .overlay(Capsule().stroke(selected ? Palette.ink : Palette.line.opacity(0.8)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("筛选\(title)，\(entryCount(for: kind)) 项")
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        let selected = history.selectedID == entry.id
        return HStack(spacing: 11) {
            Group {
                if let image = history.preview(entry) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(3)
                } else {
                    Image(systemName: entry.kind.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(entry.kind == .files ? Palette.ink : Palette.accent)
                }
            }
            .frame(width: 70, height: 54)
            .background(Palette.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line.opacity(0.7)))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(entry.kind.title)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Palette.accentSoft, in: Capsule())
                    Spacer()
                    Text(entry.createdAt.formatted(.dateTime.month().day().hour().minute()))
                        .font(.system(size: 9))
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Palette.accent : Palette.muted)
                    .frame(width: 30, height: 30)
                    .background(Palette.panel, in: Circle())
                    .overlay(Circle().stroke(selected ? Palette.accent.opacity(0.35) : Palette.line))
            }
            .buttonStyle(.plain)
            .help("复制此内容")
            .accessibilityLabel("复制\(entry.kind.title)")
        }
        .padding(9)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .background(selected ? Palette.accentSoft : Palette.panel.opacity(0.9),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .stroke(selected ? Palette.accent.opacity(0.42) : Palette.line.opacity(0.75),
                    lineWidth: selected ? 1.25 : 1))
        .overlay(alignment: .leading) {
            if selected {
                Capsule()
                    .fill(Palette.accent)
                    .frame(width: 3, height: 28)
                    .padding(.leading, 2)
            }
        }
        .shadow(color: selected ? Palette.accent.opacity(0.08) : Palette.shadow,
                radius: selected ? 9 : 5, y: 2)
        .onTapGesture(count: 2) { onCopy(entry) }
        .onTapGesture { history.selectedID = entry.id }
    }

    private func keyHint(_ key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.line))
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

private struct ClipboardBackdrop: View {
    var body: some View {
        ZStack {
            Palette.background
            LinearGradient(colors: [Color(hex: "F7F3EA"), Color(hex: "F0F2EA")],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            DotGrid()
                .stroke(Palette.ink.opacity(0.035), lineWidth: 1)
            Circle()
                .fill(Palette.accent.opacity(0.055))
                .frame(width: 260, height: 260)
                .offset(x: 250, y: -220)
        }
        .ignoresSafeArea()
    }
}
