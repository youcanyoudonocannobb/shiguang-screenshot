import AppKit
import SwiftUI

struct OCRWorkspaceView: View {
    @ObservedObject var model: AppModel
    @StoredState private var copiedHint: String?

    private var mode: OCRMode { model.ocrMode }

    private var resultText: String {
        switch mode {
        case .text: return model.sourceText
        case .table: return model.ocrTable?.markdown ?? ""
        case .formula: return model.ocrFormula
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(spacing: 0) {
                imagePanel
                Rectangle().fill(Palette.line).frame(width: 1)
                resultPanel
            }
            .frame(maxHeight: .infinity)
            Rectangle().fill(Palette.line).frame(height: 1)
            footer
        }
        .background(Palette.background)
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().scaledToFit().frame(width: 26, height: 26)
                .accessibilityHidden(true)
            Text("OCR 文字识别")
                .font(.system(size: 15, weight: .semibold))
            Spacer(minLength: 12)
            modePicker
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
        .background(Palette.panel)
    }

    private var modePicker: some View {
        HStack(spacing: 6) {
            ForEach(OCRMode.allCases) { item in
                Button {
                    model.switchOCRMode(item)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol).font(.system(size: 11, weight: .semibold))
                        Text(item.title).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(mode == item ? Color.white : Palette.ink)
                    .padding(.horizontal, 13)
                    .frame(height: 30)
                    .background(mode == item ? Palette.accent : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy && mode != item)
                .accessibilityLabel(item.title)
            }
        }
        .padding(3)
        .background(Palette.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line))
    }

    private var imagePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("截图").font(.system(size: 12, weight: .semibold))
                if let image = model.image {
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("选择图片") { model.importImage() }
                    .buttonStyle(OCRChipButtonStyle())
            }
            .padding(.horizontal, 16).frame(height: 40)

            if let image = model.image {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(14)
                }
                .background(Palette.sage.opacity(0.5))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo").font(.system(size: 26, weight: .light))
                        .foregroundStyle(Palette.accent.opacity(0.6))
                    Text("截图后可在这里查看原图").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.sage.opacity(0.5))
            }
        }
        .frame(minWidth: 260, idealWidth: 380, maxWidth: .infinity)
    }

    private var resultPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(mode.title).font(.system(size: 12, weight: .semibold))
                if model.isBusy {
                    ProgressView().controlSize(.mini)
                    Text(model.activity ?? "处理中…").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
                Spacer()
                if !resultText.isEmpty {
                    Text("\(resultText.count) 字符").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 16).frame(height: 40)

            switch mode {
            case .text:
                textResult
            case .table:
                tableResult
            case .formula:
                formulaResult
            }
        }
        .frame(minWidth: 300, maxWidth: .infinity)
    }

    private var textResult: some View {
        ZStack(alignment: .topLeading) {
            if model.sourceText.isEmpty {
                Text(model.isRecognizing ? "正在识别文字…" : "识别结果会显示在这里")
                    .foregroundStyle(Palette.muted).font(.system(size: 13))
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
            TextEditor(text: Binding(get: { model.sourceText }, set: { model.sourceEdited($0) }))
                .font(.system(size: 13)).lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .accessibilityLabel("识别文字")
        }
    }

    @ViewBuilder private var tableResult: some View {
        if let table = model.ocrTable, !table.isEmpty {
            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 0) {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, row in
                        HStack(spacing: 0) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .font(.system(size: 12, weight: rowIndex == 0 ? .semibold : .regular))
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(3)
                                    .frame(minWidth: 92, maxWidth: 260, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .frame(maxHeight: .infinity, alignment: .topLeading)
                                    .background(rowIndex == 0 ? Palette.accentSoft.opacity(0.7) : Palette.panel)
                                    .overlay(Rectangle().stroke(Palette.line, lineWidth: 0.6))
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }
        } else {
            emptyResult(symbol: "tablecells", text: model.isBusy ? "正在识别表格结构…" : "识别结果会以表格形式显示")
        }
    }

    @ViewBuilder private var formulaResult: some View {
        if model.ocrFormula.isEmpty {
            emptyResult(symbol: "function", text: model.isBusy ? "正在识别公式…" : "识别结果会以 LaTeX 形式显示")
        } else {
            ScrollView {
                Text(model.ocrFormula)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    private func emptyResult(symbol: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26, weight: .light))
                .foregroundStyle(Palette.accent.opacity(0.6))
            Text(text).font(.system(size: 12)).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { model.importImage() } label: { Label("选择图片", systemImage: "photo") }
            Button { model.clearDocument() } label: { Label("清空", systemImage: "xmark") }
                .disabled(model.image == nil)
            Spacer(minLength: 8)
            if let copiedHint {
                Text(copiedHint).font(.system(size: 10)).foregroundStyle(Palette.success)
            }
            switch mode {
            case .text:
                Button { copy(model.sourceText, hint: "已复制文字") } label: {
                    Label("复制文字", systemImage: "doc.on.doc")
                }
                .disabled(model.sourceText.isEmpty)
            case .table:
                Button { copy(model.ocrTable?.markdown ?? "", hint: "已复制 Markdown") } label: {
                    Label("复制 Markdown", systemImage: "doc.on.doc")
                }
                .disabled(model.ocrTable?.isEmpty != false)
                Button { copy(model.ocrTable?.tsv ?? "", hint: "已复制表格") } label: {
                    Label("复制表格", systemImage: "tablecells")
                }
                .disabled(model.ocrTable?.isEmpty != false)
                Button { exportCSV() } label: {
                    Label("导出 CSV", systemImage: "square.and.arrow.down")
                }
                .disabled(model.ocrTable?.isEmpty != false)
            case .formula:
                Button { copy(model.ocrFormula, hint: "已复制 LaTeX") } label: {
                    Label("复制 LaTeX", systemImage: "doc.on.doc")
                }
                .disabled(model.ocrFormula.isEmpty)
            }
            Button { model.recognizeCurrentMode() } label: {
                Label("重新识别", systemImage: "arrow.clockwise")
            }
            .disabled(model.image == nil || model.isBusy)
        }
        .buttonStyle(OCRChipButtonStyle())
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Palette.panel)
        .onChange(of: mode) { _, _ in copiedHint = nil }
    }

    private func copy(_ text: String, hint: String) {
        guard !text.isEmpty else { return }
        model.copyText(text)
        copiedHint = hint
    }

    private func exportCSV() {
        guard let table = model.ocrTable, !table.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "PawShot-表格.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try table.csv.write(to: url, atomically: true, encoding: .utf8)
            copiedHint = "已导出 CSV"
        } catch {
            model.errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }
}

private struct OCRWorkspaceChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

private struct OCRChipButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @StoredState private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(configuration.isPressed ? Palette.line : hovered ? Palette.accentSoft : Palette.panel,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovered = $0 }
    }
}
