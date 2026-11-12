import SwiftUI

struct ClipboardView: View {
    @ObservedObject var history: ClipboardHistory
    let onCopy: (ClipboardEntry) -> Void
    let onClose: () -> Void
    @StoredState private var confirmsClear = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard").font(.system(size: 21)).foregroundStyle(Palette.accent)
                Text("剪贴板").font(.system(size: 22, weight: .medium, design: .serif))
                Text("\(history.entries.count) 项").font(.system(size: 11)).foregroundStyle(Palette.muted)
                Spacer()
                Menu {
                    Toggle("记录系统剪贴板", isOn: $history.monitorsSystem)
                    Divider()
                    Button("清空历史…", role: .destructive) { confirmsClear = true }.disabled(history.entries.isEmpty)
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 19)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("剪贴板设置")
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 15)) }
                    .buttonStyle(.plain).help("关闭 (Esc)").accessibilityLabel("关闭剪贴板")
            }
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("搜索文字和文件名", text: $history.search).textFieldStyle(.plain).focused($searchFocused)
                if !history.search.isEmpty {
                    Button { history.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel("清除搜索")
                }
            }.padding(11).background(Palette.panel, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line))
            HStack(spacing: 6) {
                filterButton("全部", kind: nil)
                ForEach([ClipboardEntry.Kind.text, .image, .gif, .video, .files], id: \.self) { kind in
                    filterButton(kind.title, kind: kind)
                }
                Spacer(minLength: 0)
            }
            if history.filteredEntries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 32)).foregroundStyle(Palette.muted)
                    Text(history.search.isEmpty ? "复制后，在这里找回内容" : "没有匹配的内容").font(.system(size: 14))
                    Text("文字、图片、GIF、视频和文件").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(history.filteredEntries) { entry in row(entry).id(entry.id) }
                        }.padding(1)
                    }.onChange(of: history.selectedID) { _, id in
                        if let id { reader.scrollTo(id) }
                    }
                }
            }
            HStack {
                Text("↑ ↓ 选择 · 回车复制 · Esc 关闭").font(.system(size: 10)).foregroundStyle(Palette.muted)
                Spacer()
                if !history.monitorsSystem {
                    Label("系统记录已暂停", systemImage: "pause.circle").font(.system(size: 10)).foregroundStyle(Palette.accent)
                }
            }
            Text(history.message).font(.system(size: 11)).foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
        }
        .padding(20).frame(minWidth: 500, minHeight: 430)
        .background(Palette.background).foregroundStyle(Palette.ink).tint(Palette.accent).preferredColorScheme(.light)
        .onAppear { searchFocused = true }
        .onChange(of: history.search) { _, _ in history.selectedID = history.filteredEntries.first?.id }
        .onChange(of: history.filter) { _, _ in history.selectedID = history.filteredEntries.first?.id }
        .confirmationDialog("清空剪贴板历史？", isPresented: $confirmsClear) {
            Button("清空历史", role: .destructive) { history.clear() }
        } message: { Text("系统剪贴板当前内容仍可粘贴。") }
    }

    private func filterButton(_ title: String, kind: ClipboardEntry.Kind?) -> some View {
        Button { history.filter = kind } label: {
            Text(title).font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(history.filter == kind ? .white : Palette.ink)
                .background(history.filter == kind ? Palette.ink : Palette.panel, in: Capsule())
        }.buttonStyle(.plain)
    }

    private func row(_ entry: ClipboardEntry) -> some View {
        HStack(spacing: 12) {
            Group {
                if let image = history.preview(entry) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Image(systemName: entry.kind.symbol).font(.system(size: 22)).foregroundStyle(Palette.muted)
                }
            }.frame(width: 66, height: 54).background(Palette.background, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(entry.kind.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Palette.accent)
                    Spacer()
                    Text(entry.createdAt.formatted(.dateTime.month().day().hour().minute()))
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Text(entry.summary).font(.system(size: 12)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { onCopy(entry) } label: { Image(systemName: "doc.on.doc").font(.system(size: 15)) }
                .buttonStyle(.plain).padding(7).help("复制此内容").accessibilityLabel("复制\(entry.kind.title)")
        }.padding(10).contentShape(RoundedRectangle(cornerRadius: 10))
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(history.selectedID == entry.id ? Palette.accent : Palette.line,
                                                              lineWidth: history.selectedID == entry.id ? 1.5 : 1))
            .onTapGesture(count: 2) { onCopy(entry) }
            .onTapGesture { history.selectedID = entry.id }
    }
}
