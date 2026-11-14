import SwiftUI

struct AnnotationToolbar: View {
    /// Transparent room kept above the bar for the hover label.
    static let hoverSpace: CGFloat = 30

    @ObservedObject var model: AppModel
    var onShowText: (() -> Void)? = nil
    var showsSelectionTools = true
    var showsCompletion = true
    @StoredState private var showsRecordingOptions = false
    @StoredState private var showsScrollOptions = false
    @StoredState private var showsColors = false
    @StoredState private var showsMarkTools = false
    @StoredState private var hoveredTitle: String?
    @StoredState private var hoverFrames: [String: CGRect] = [:]

    var body: some View {
        HStack(spacing: 5) {
            groupBox {
            if showsSelectionTools {
                action("移动选区", symbol: "cursorarrow", selected: model.tool == .pointer) {
                    model.tool = .pointer
                    model.resetViewport()
                }
            }
            ForEach([MarkTool.rectangle, .arrow, .pen, .text, .mosaic], id: \.self) { tool in
                if tool == .text {
                    action(tool.title, text: "T", selected: model.tool == tool) {
                        model.tool = model.tool == tool ? .pointer : tool
                    }.disabled(model.isBusy)
                } else {
                    action(tool.title, symbol: tool.symbol, selected: model.tool == tool) {
                        model.tool = model.tool == tool ? .pointer : tool
                    }.disabled(model.isBusy)
                }
            }
            action("更多标注", symbol: "square.grid.2x2") { showsMarkTools.toggle() }
                .disabled(model.isBusy)
                .popover(isPresented: $showsMarkTools, arrowEdge: .top) {
                    markToolsPanel
                }
            Button { showsColors.toggle() } label: {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 16, weight: .medium))
                    Circle()
                        .fill(Color(hex: model.markColor))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color(hex: "17191C"), lineWidth: 2))
                        .offset(x: 2, y: 2)
                }
                .frame(width: 30, height: 32)
                .foregroundStyle(.white)
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .background(showsColors ? Color.white.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(ToolbarActionStyle())
            .onHover { hoveredTitle = $0 ? "标注颜色" : nil }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("annotationToolbar")) } action: { hoverFrames["标注颜色"] = $0 }
            .help("标注颜色")
            .accessibilityLabel("标注颜色")
            .popover(isPresented: $showsColors, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("标注颜色")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                    HStack(spacing: 9) {
                        ForEach(["E45F3C", "347A64", "3975B7", "D8A72C", "FFFFFF", "1C2723"], id: \.self) { hex in
                            Button {
                                model.markColor = hex
                                showsColors = false
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 24, height: 24)
                                    .overlay(Circle().stroke(hex == "FFFFFF" ? Palette.line : .clear, lineWidth: 1))
                                    .padding(3)
                                    .overlay(Circle().stroke(model.markColor == hex ? Color.white : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("标注颜色 \(hex)")
                        }
                    }
                }
                .padding(13)
                .background(Color(hex: "17191C"))
                .preferredColorScheme(.dark)
            }
            }
            groupBox {
            action("撤销", symbol: "arrow.uturn.backward") { model.undo() }.disabled(!model.canUndo)
            action("重做", symbol: "arrow.uturn.forward") { model.redo() }.disabled(!model.canRedo)
            }
            groupBox {
            action(model.isRecognizing ? "取消文字识别" : "文字识别", symbol: model.isRecognizing ? "stop.circle" : "text.viewfinder") {
                if model.isRecognizing { model.cancelRecognition() }
                else { model.recognizeInWindow() }
            }.disabled(model.isBusy && !model.isRecognizing)
            action(model.translationJob != nil ? "取消翻译" : "翻译", symbol: model.translationJob != nil ? "stop.circle" : "character.bubble") {
                if model.translationJob != nil { model.cancelTranslation() }
                else { model.translateImage() }
            }.disabled(model.isBusy && model.translationJob == nil)
            action("长截图", symbol: "rectangle.expand.vertical") { showsScrollOptions.toggle() }
                .disabled(model.isBusy && !model.isRecognizing)
                .popover(isPresented: $showsScrollOptions, arrowEdge: .top) {
                    CaptureOptionsPanel(title: "长截图", hint: "使用当前选区，完成拼接后可继续编辑。") {
                        CaptureOptionButton("自动滚动并拼接", detail: "自动向下滚动并连接画面", symbol: "arrow.down") {
                            showsScrollOptions = false
                            model.captureScrolling(.automatic)
                        }
                        CaptureOptionButton("跟随鼠标手动滚动", detail: "按自己的节奏滚动页面", symbol: "hand.point.up") {
                            showsScrollOptions = false
                            model.captureScrolling(.manual)
                        }
                    }
                }
            action("录制", symbol: "record.circle") { showsRecordingOptions.toggle() }
                .disabled(model.isBusy && !model.isRecognizing)
                .popover(isPresented: $showsRecordingOptions, arrowEdge: .top) {
                    CaptureOptionsPanel(title: "录制", hint: "使用当前选区 · 无声录制 · GIF 最长 60 秒") {
                        CaptureOptionButton("MP4 视频", detail: "30 帧/秒", symbol: "film") {
                            showsRecordingOptions = false
                            model.record(.video)
                        }
                        CaptureOptionButton("GIF 动图", detail: "10 帧/秒", symbol: "photo.on.rectangle.angled") {
                            showsRecordingOptions = false
                            model.record(.gif)
                        }
                    }
                }
            }
            groupBox {
            action("打开剪贴板", symbol: "doc.on.clipboard") { model.showClipboard?() }
            Menu {
                Button("适应窗口") { model.resetViewport() }
                Button("放大图片") { model.zoomFactor = min(8, model.zoomFactor * 1.25) }
                Button("缩小图片") { model.zoomFactor = max(0.25, model.zoomFactor / 1.25) }
                Divider()
                Button("显示原文与译文") { onShowText?() }
                Button("复制之前的录制") { model.saveRecording?() }.disabled(!model.recordingReady)
                if model.draftImage == nil { Button("导出 PNG 文件…") { model.exportImage() } }
                if model.activeEditor == "overlay" {
                    Button("打开完整编辑器") { model.showEditor?() }
                } else {
                    Button("悬浮编辑") { model.showFloatingEditor?() }
                }
                Button("置顶图片") { model.requestPin() }
                Button("黑色遮盖") { model.tool = model.tool == .redact ? .pointer : .redact }
                Button("清除全部标注") { model.clearMarks() }.disabled(model.marks.isEmpty)
            } label: { icon("ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("更多操作").accessibilityLabel("更多操作")
                .onHover { hoveredTitle = $0 ? "更多操作" : nil }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("annotationToolbar")) } action: { hoverFrames["更多操作"] = $0 }
            }
            if showsCompletion, model.draftImage != nil {
                completionDivider
                completionAction("取消截图", symbol: "xmark", tint: Color(hex: "FF7979")) {
                    model.discardDraft()
                }
                completionAction("复制到剪贴板并完成", symbol: "checkmark", tint: Color(hex: "75E6A5")) {
                    model.confirmDraft()
                }
            } else if showsCompletion {
                completionDivider
                action("关闭截图 (Esc)", symbol: "xmark") { model.closeEditor() }
            }
        }
        .padding(7)
        .background(
            LinearGradient(colors: [Color(hex: "24292F"), Color(hex: "14171A")],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(LinearGradient(colors: [.white.opacity(0.16), .clear],
                                       startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(.white.opacity(0.13)))
        .overlay(alignment: .topLeading) { hoverChip }
        .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
        .coordinateSpace(name: "annotationToolbar")
        .fixedSize(horizontal: true, vertical: true)
        .tint(.white)
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.12), value: hoveredTitle)
    }

    /// Hover label drawn above the bar. The AppKit tooltip path (`help`) was
    /// unreliable inside the full-screen selection overlay, so the title is
    /// rendered by SwiftUI instead.
    @ViewBuilder private var hoverChip: some View {
        if let hoveredTitle, let frame = hoverFrames[hoveredTitle] {
            GeometryReader { proxy in
                Text(hoveredTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(hex: "0D0F12").opacity(0.97), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                    .position(x: min(max(28, frame.midX), proxy.size.width - 28),
                              y: frame.minY - 22)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
            }
        }
    }

    private func groupBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 1) { content() }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                LinearGradient(colors: [.white.opacity(0.075), .white.opacity(0.035)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 20).padding(.horizontal, 3)
    }

    private var completionDivider: some View {
        Rectangle().fill(.white.opacity(0.22)).frame(width: 1, height: 24).padding(.horizontal, 6)
    }

    private var markToolsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("更多标注").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            LazyVGrid(columns: [GridItem(.fixed(126)), GridItem(.fixed(126))], spacing: 8) {
                ForEach([MarkTool.ellipse, .line, .highlighter, .number, .redact, .picker], id: \.self) { tool in
                    Button {
                        model.tool = tool
                        showsMarkTools = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tool.symbol).frame(width: 18)
                            Text(tool.title)
                            Spacer(minLength: 0)
                            if model.tool == tool {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            }
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).frame(height: 32)
                        .background(model.tool == tool ? Color.white.opacity(0.18) : Color.white.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
            }
            Divider().overlay(.white.opacity(0.16))
            Toggle(isOn: $model.fillShapes) {
                Label("填充新绘制的矩形/椭圆", systemImage: "circle.lefthalf.filled")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Palette.accent)
            Text(model.tool == .picker ? "点击图片取色，取色后自动回到浏览工具。" : "标注颜色会用于形状、画笔、文字和编号。")
                .font(.system(size: 10)).foregroundStyle(Color(hex: "BEC5CF"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13).frame(width: 286)
        .background(Color(hex: "17191C"))
        .tint(.white).environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    private func icon(_ symbol: String, selected: Bool = false) -> some View {
        ZStack(alignment: .bottom) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 30, height: 32)
            if selected {
                Capsule()
                    .fill(Color(hex: "75E6A5"))
                    .frame(width: 11, height: 2)
                    .padding(.bottom, 2)
            }
        }
        .foregroundStyle(.white)
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .background(selected ? Color.white.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    private func action(_ title: String, text: String, selected: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            ZStack(alignment: .bottom) {
                Text(text)
                    .font(.system(size: 16.5, weight: .semibold, design: .rounded))
                    .frame(width: 30, height: 32)
                if selected {
                    Capsule()
                        .fill(Color(hex: "75E6A5"))
                        .frame(width: 11, height: 2)
                        .padding(.bottom, 2)
                }
            }
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(selected ? Color.white.opacity(0.14) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(ToolbarActionStyle())
        .help(title)
        .accessibilityLabel(title)
        .onHover { hoveredTitle = $0 ? title : nil }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("annotationToolbar")) } action: { hoverFrames[title] = $0 }
    }

    private func action(_ title: String, symbol: String, selected: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            icon(symbol, selected: selected)
        }
        .buttonStyle(ToolbarActionStyle())
        .help(title)
        .accessibilityLabel(title)
        .onHover { hoveredTitle = $0 ? title : nil }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("annotationToolbar")) } action: { hoverFrames[title] = $0 }
    }

    private func completionAction(_ title: String, symbol: String, tint: Color,
                                  perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 32)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.5), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(ToolbarActionStyle())
        .help(title)
        .accessibilityLabel(title)
    }
}

private struct CaptureOptionsPanel<Content: View>: View {
    let title: String
    let hint: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            content
            Text(hint).font(.system(size: 11)).foregroundStyle(Color(hex: "BEC5CF"))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14).frame(width: 284)
        .background(Color(hex: "17191C"))
        .presentationBackground(Color(hex: "17191C"))
        .tint(.white).environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }
}

private struct CaptureOptionButton: View {
    let title: String
    let detail: String
    let symbol: String
    let perform: () -> Void

    init(_ title: String, detail: String, symbol: String, perform: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.perform = perform
    }

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium))
                    Text(detail).font(.system(size: 11)).foregroundStyle(Color(hex: "BEC5CF"))
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white).padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(CaptureOptionStyle())
        .accessibilityLabel(title).accessibilityValue(detail)
    }
}

private struct CaptureOptionStyle: ButtonStyle {
    @StoredState private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color(hex: configuration.isPressed ? "454A53" : hovered ? "383D45" : "292D33"),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(hovered ? 0.32 : 0.12)))
            .onHover { hovered = $0 }
    }
}

private struct ToolbarActionStyle: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    @StoredState private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.18) :
                            (hovered ? Color.white.opacity(0.10) : .clear),
                        in: RoundedRectangle(cornerRadius: 6))
            .scaleEffect(hovered && enabled ? 1.05 : 1)
            .opacity(enabled ? 1 : 0.32)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .onHover { hovered = $0 }
    }
}
