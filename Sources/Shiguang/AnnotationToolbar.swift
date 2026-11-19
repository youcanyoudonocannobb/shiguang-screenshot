import SwiftUI

struct AnnotationToolbar: View {
    /// Transparent room kept above the bar for the hover label.
    static let hoverSpace: CGFloat = 30
    static let minimumWidth: CGFloat = 800

    @ObservedObject var model: AppModel
    var showsSelectionTools = true
    var showsCompletion = true
    @StoredState private var showsRecordingOptions = false
    @StoredState private var showsScrollOptions = false
    @StoredState private var showsMoreTools = false
    @StoredState private var styleTool: MarkTool?
    @StoredState private var hoveredTitle: String?
    @StoredState private var hoverFrames: [String: CGRect] = [:]
    private static let primaryMarkTools = MarkTool.toolbarOrder
    private static let markColors = [
        "F45C93", "F05A52", "F29A38", "F1CF45",
        "58B75B", "3F7EE0", "111111", "FFFFFF"
    ]

    var body: some View {
        HStack(spacing: 8) {
            annotationCluster
            actionCluster
        }
        .overlay(alignment: .topLeading) { hoverChip }
        .coordinateSpace(name: "annotationToolbar")
        .fixedSize(horizontal: true, vertical: true)
        .tint(.white)
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.12), value: hoveredTitle)
        .onChange(of: model.tool) { _, tool in
            if Self.primaryMarkTools.contains(tool), tool != .picker, !model.isBusy {
                styleTool = tool
            } else if tool == .pointer || tool == .picker || model.isBusy {
                styleTool = nil
            }
        }
    }

    private var annotationCluster: some View {
        toolbarCluster {
            if showsSelectionTools {
                action("移动选区", symbol: "cursorarrow", selected: model.tool == .pointer) {
                    model.tool = .pointer
                    styleTool = nil
                    model.resetViewport()
                }
            }
            ForEach(Self.primaryMarkTools, id: \.self) { tool in
                markToolButton(tool)
            }
            moreToolsButton
        }
    }

    private var actionCluster: some View {
        toolbarCluster {
            action("撤销", symbol: "arrow.uturn.backward") { model.undo() }.disabled(!model.canUndo)
            action("重做", symbol: "arrow.uturn.forward") { model.redo() }.disabled(!model.canRedo)
            clusterDivider
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
                    CaptureOptionsPanel(title: "长截图") {
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
                    CaptureOptionsPanel(title: "录制") {
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
            clusterDivider
            action("打开剪贴板", symbol: "doc.on.clipboard") { model.showClipboard?() }
            action("钉住到桌面", symbol: "pin") {
                model.requestPin()
            }
            .disabled(model.isBusy)
            if showsCompletion, model.draftImage != nil {
                clusterDivider
                completionAction("取消截图", symbol: "xmark", prominent: false) {
                    model.discardDraft()
                }
                completionAction("复制到剪贴板并完成", symbol: "checkmark", prominent: true) {
                    model.confirmDraft()
                }
            } else if showsCompletion {
                clusterDivider
                action("关闭截图 (Esc)", symbol: "xmark") { model.closeEditor() }
            }
        }
    }

    private func markToolButton(_ tool: MarkTool) -> some View {
        Group {
            if tool == .text {
                action(tool.title, text: "T", selected: model.tool == tool) {
                    chooseMarkTool(tool)
                }
            } else {
                action(tool.title, symbol: tool.symbol, selected: model.tool == tool) {
                    chooseMarkTool(tool)
                }
            }
        }
        .disabled(model.isBusy)
        .popover(isPresented: stylePopoverBinding(for: tool), arrowEdge: .bottom) {
            toolStylePanel(tool)
        }
    }

    private func chooseMarkTool(_ tool: MarkTool) {
        if tool == .picker {
            model.tool = .picker
            styleTool = nil
            return
        }
        if model.tool == tool {
            styleTool = styleTool == tool ? nil : tool
        } else {
            model.tool = tool
            styleTool = tool
        }
    }

    private func stylePopoverBinding(for tool: MarkTool) -> Binding<Bool> {
        Binding(
            get: { styleTool == tool && model.tool == tool && !model.isBusy },
            set: { show in
                if show {
                    styleTool = tool
                } else if styleTool == tool {
                    styleTool = nil
                }
            }
        )
    }

    private func toolStylePanel(_ tool: MarkTool) -> some View {
        HStack(spacing: 7) {
            if supportsColor(tool) {
                ForEach(Self.markColors, id: \.self) { hex in
                    colorSwatch(hex)
                }
                if !Self.markColors.contains(model.markColor.uppercased()) {
                    colorSwatch(model.markColor)
                }
                colorDivider
                Button {
                    styleTool = nil
                    model.tool = .picker
                } label: {
                    Image(systemName: "eyedropper")
                        .font(.system(size: 14.5, weight: .medium))
                        .frame(width: 26, height: 28)
                        .foregroundStyle(.white)
                }
                .buttonStyle(ToolbarActionStyle())
                .help("从截图取色")
                .accessibilityLabel("从截图取色")
            }
            if supportsShapeFill(tool) {
                if supportsColor(tool) { colorDivider }
                fillStyleToggle
            }
            if supportsStroke(tool) {
                if supportsColor(tool) || supportsShapeFill(tool) { colorDivider }
                lineWeightToggle
            }
            if tool == .number {
                colorDivider
                numberSizeToggle
            }
            if tool == .arrow {
                colorDivider
                arrowHeadToggle
            }
            if tool == .text {
                colorDivider
                textControls
            }
            if tool == .mosaic {
                maskControls
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Palette.overlay, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(.white.opacity(0.12), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        .preferredColorScheme(.dark)
    }

    private func colorSwatch(_ hex: String) -> some View {
        let normalized = hex.uppercased()
        let selected = model.markColor.uppercased() == normalized
        return Button {
            model.markColor = normalized
        } label: {
            Circle()
                .fill(Color(hex: normalized))
                .frame(width: 20, height: 20)
                .overlay(Circle().stroke(
                    normalized == "FFFFFF" ? .black.opacity(0.18) : .white.opacity(0.14),
                    lineWidth: 0.7
                ))
                .padding(3)
                .overlay(Circle().stroke(selected ? Palette.overlayAccent : .clear,
                                          lineWidth: 2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(selected ? "当前标注颜色" : "使用此标注颜色")
        .accessibilityLabel(L(selected ? "当前标注颜色" : "标注颜色") + " \(normalized)")
    }

    private func supportsColor(_ tool: MarkTool) -> Bool { tool.usesColor }

    private func supportsShapeFill(_ tool: MarkTool) -> Bool {
        tool == .rectangle || tool == .ellipse
    }

    private func supportsStroke(_ tool: MarkTool) -> Bool { tool.usesStroke }

    private var fillStyleToggle: some View {
        HStack(spacing: 2) {
            fillStyleButton("空心", filled: false)
            fillStyleButton("实心", filled: true)
        }
        .padding(2)
        .background(.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func fillStyleButton(_ title: String, filled: Bool) -> some View {
        let selected = model.fillShapes == filled
        return Button {
            model.fillShapes = filled
        } label: {
            Text(L(title))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(selected ? .white : .white.opacity(0.62))
                .frame(height: 24)
                .padding(.horizontal, 8)
                .background(selected ? .white.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var lineWeightToggle: some View {
        pointSizeControl(
            points: $model.markLineWidthPoints,
            range: AnnotationSizeMetrics.lineWidthRange,
            label: "线条粗细",
            decreaseHelp: "减小线条粗细",
            increaseHelp: "增大线条粗细"
        )
    }

    private var numberSizeToggle: some View {
        pointSizeControl(
            points: $model.numberSizePoints,
            range: AnnotationSizeMetrics.numberSizeRange,
            label: "序号大小",
            decreaseHelp: "减小序号大小",
            increaseHelp: "增大序号大小"
        )
    }

    private func pointSizeControl(points: Binding<Double>, range: ClosedRange<Double>,
                                  label: String, decreaseHelp: String,
                                  increaseHelp: String) -> some View {
        PointSizeControl(
            points: points,
            range: range,
            label: label,
            decreaseHelp: decreaseHelp,
            increaseHelp: increaseHelp
        )
    }

    private var arrowHeadToggle: some View {
        HStack(spacing: 2) {
            compactChoice("单头", selected: !model.arrowDoubleHeaded) {
                model.arrowDoubleHeaded = false
            }
            compactChoice("双头", selected: model.arrowDoubleHeaded) {
                model.arrowDoubleHeaded = true
            }
        }
        .padding(2)
        .background(.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var textControls: some View {
        HStack(spacing: 5) {
            pointSizeControl(
                points: $model.textFontSize,
                range: AnnotationSizeMetrics.textSizeRange,
                label: "字号",
                decreaseHelp: "减小字号",
                increaseHelp: "增大字号"
            )

            HStack(spacing: 2) {
                ForEach(TextPresentation.allCases, id: \.self) { style in
                    compactChoice(style.title, selected: model.textPresentation == style) {
                        model.textPresentation = style
                    }
                }
            }
            .padding(2)
            .background(.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var maskControls: some View {
        HStack(spacing: 5) {
            pointSizeControl(
                points: $model.maskSizePoints,
                range: AnnotationSizeMetrics.maskSizeRange,
                label: "马赛克颗粒",
                decreaseHelp: "减小马赛克颗粒",
                increaseHelp: "增大马赛克颗粒"
            )

            HStack(spacing: 2) {
                ForEach(MaskStyle.allCases, id: \.self) { style in
                    compactChoice(style.title, selected: model.maskStyle == style) {
                        model.maskStyle = style
                    }
                }
            }
            .padding(2)
            .background(.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func compactChoice(_ title: String, selected: Bool,
                               perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Text(L(title))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(selected ? .white : .white.opacity(0.62))
                .frame(height: 24)
                .padding(.horizontal, 7)
                .background(selected ? .white.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var colorDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(width: 1, height: 20)
            .padding(.horizontal, 2)
    }

    private var moreToolsButton: some View {
        action("更多功能", symbol: "ellipsis", selected: showsMoreTools || moreToolsActive) {
            showsMoreTools.toggle()
        }
        .popover(isPresented: $showsMoreTools, arrowEdge: .top) {
            moreToolsPanel
        }
    }

    /// Hover label drawn above the bar. The AppKit tooltip path (`help`) was
    /// unreliable inside the full-screen selection overlay, so the title is
    /// rendered by SwiftUI instead.
    @ViewBuilder private var hoverChip: some View {
        if let hoveredTitle, let frame = hoverFrames[hoveredTitle] {
            GeometryReader { proxy in
                Text(L(hoveredTitle))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Palette.overlay.opacity(0.97), in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: .black.opacity(0.24), radius: 6, y: 2)
                    .position(x: min(max(28, frame.midX), proxy.size.width - 28),
                              y: frame.minY - 22)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)))
            }
        }
    }

    private func toolbarCluster<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 1) { content() }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(
                LinearGradient(colors: [Palette.overlayRaised.opacity(0.98),
                                        Palette.overlay.opacity(0.98)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(alignment: .top) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(LinearGradient(colors: [.white.opacity(0.16), .clear],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
            }
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.8))
            .shadow(color: .black.opacity(0.24), radius: 8, y: 4)
    }

    private var clusterDivider: some View {
        Rectangle().fill(.white.opacity(0.14))
            .frame(width: 1, height: 17)
            .padding(.horizontal, 3)
    }

    private var moreToolsActive: Bool {
        model.tool == .highlighter || model.tool == .redact
    }

    private var moreToolsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("更多功能")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            moreToolRow(.highlighter)
            moreToolRow(.redact)

            HStack(spacing: 10) {
                Label("填充矩形和椭圆", systemImage: "circle.lefthalf.filled")
                Spacer(minLength: 0)
                Toggle("", isOn: $model.fillShapes)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Palette.accent)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))

            Divider().overlay(.white.opacity(0.16))

            HStack(spacing: 7) {
                Label("缩放", systemImage: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Button { model.resetViewport() } label: {
                    Text("\(Int((model.zoomFactor * 100).rounded()))%")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .frame(minWidth: 42)
                }
                .buttonStyle(.plain)
                .help("恢复适应窗口")
                zoomControl("minus", help: "缩小图片") {
                    model.zoomFactor = max(0.25, model.zoomFactor / 1.25)
                }
                .disabled(model.zoomFactor <= 0.25)
                zoomControl("plus", help: "放大图片") {
                    model.zoomFactor = min(8, model.zoomFactor * 1.25)
                }
                .disabled(model.zoomFactor >= 8)
            }
            .foregroundStyle(.white)
        }
        .padding(13)
        .frame(width: 286)
        .background(Palette.overlay)
        .preferredColorScheme(.dark)
    }

    private func moreToolRow(_ tool: MarkTool) -> some View {
        Button {
            model.tool = tool
            showsMoreTools = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tool.symbol)
                    .frame(width: 20)
                Text(tool.title)
                Spacer(minLength: 0)
                if model.tool == tool {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(model.tool == tool ? Color.white.opacity(0.16) : Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
    }

    private func zoomControl(_ symbol: String, help: String,
                             perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 27, height: 27)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L(help))
        .accessibilityLabel(L(help))
    }

    private func icon(_ symbol: String, selected: Bool = false) -> some View {
        ZStack {
            if selected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.accent)
                    .frame(width: 25, height: 25)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 0.7))
            }
            Image(systemName: symbol)
                .font(.system(size: 15.5, weight: .medium))
                .frame(width: 28, height: 30)
        }
        .foregroundStyle(.white)
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func action(_ title: String, text: String, selected: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.accent)
                        .frame(width: 25, height: 25)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.white.opacity(0.18), lineWidth: 0.7))
                }
                Text(text)
                    .font(.system(size: 15.5, weight: .semibold, design: .rounded))
                    .frame(width: 28, height: 30)
            }
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(ToolbarActionStyle())
        .help(L(title))
        .accessibilityLabel(L(title))
        .onHover { hoveredTitle = $0 ? title : nil }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("annotationToolbar")) } action: { hoverFrames[title] = $0 }
    }

    private func action(_ title: String, symbol: String, selected: Bool = false,
                        perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            icon(symbol, selected: selected)
        }
        .buttonStyle(ToolbarActionStyle())
        .help(L(title))
        .accessibilityLabel(L(title))
        .onHover { hoveredTitle = $0 ? title : nil }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("annotationToolbar")) } action: { hoverFrames[title] = $0 }
    }

    private func completionAction(_ title: String, symbol: String, prominent: Bool,
                                  perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: prominent ? 13 : 15, weight: .bold))
                .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.82))
                .frame(width: 28, height: 30)
                .background(
                    Circle().fill(prominent ? Palette.accent : Color.clear)
                )
                .overlay(
                    Circle().stroke(prominent ? Color.white.opacity(0.22) : Color.clear,
                                    lineWidth: 0.8)
                )
                .contentShape(Circle())
        }
        .buttonStyle(ToolbarActionStyle())
        .help(L(title))
        .accessibilityLabel(L(title))
    }
}

private struct PointSizeControl: View {
    @Binding var points: Double
    let range: ClosedRange<Double>
    let label: String
    let decreaseHelp: String
    let increaseHelp: String

    @StoredState private var draft = ""
    @StoredState private var hovering = false
    /// The value is plain text until clicked. A text field shown up front
    /// became the popover's first responder as soon as the popover opened,
    /// so Delete, the arrow keys and tool shortcuts edited the field instead
    /// of the selected mark.
    @StoredState private var isEditingValue = false
    @FocusState private var editing: Bool

    private var canDecrease: Bool { isEditingValue || points > range.lowerBound }
    private var canIncrease: Bool { isEditingValue || points < range.upperBound }

    var body: some View {
        HStack(spacing: 1) {
            stepperButton(
                symbol: "minus",
                help: decreaseHelp,
                enabled: canDecrease,
                delta: -AnnotationSizeMetrics.stepPoints
            )

            HStack(spacing: 2) {
                if isEditingValue {
                    TextField("", text: $draft)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .tint(.white)
                        .frame(width: 23, height: 24)
                        .focused($editing)
                        .onAppear { DispatchQueue.main.async { editing = true } }
                        .onSubmit { endEditing(commitDraft: true) }
                        .onExitCommand { endEditing(commitDraft: false) }
                        .onChange(of: editing) { _, focused in
                            if !focused { endEditing(commitDraft: true) }
                        }
                        // Closing the popover (for example by clicking the
                        // canvas) keeps what was typed.
                        .onDisappear { commit() }
                        .accessibilityLabel(L(label))
                } else {
                    Text(formatted(points))
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                        .frame(width: 23, height: 24, alignment: .trailing)
                        .accessibilityLabel(L(label))
                        .accessibilityValue("\(formatted(points)) pt")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { beginEditing() }
                }

                Text("pt")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .accessibilityHidden(true)

                Image(systemName: "pencil")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(isEditingValue ? 0.95 : 0.54))
                    .frame(width: 8)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 4)
            .frame(width: 58, height: 24)
            .background(.white.opacity(isEditingValue ? 0.14 : (hovering ? 0.11 : 0.08)),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isEditingValue ? Palette.overlayAccent.opacity(0.9) :
                                .white.opacity(hovering ? 0.22 : 0.08),
                            lineWidth: 0.8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            // The whole box starts editing; while editing, clicks belong to
            // the text field so the caret can be placed.
            .gesture(TapGesture().onEnded { beginEditing() },
                     including: isEditingValue ? .subviews : .all)
            .onHover { hovering = $0 }
            .help(L(label) + " · \(formatted(range.lowerBound))–\(formatted(range.upperBound)) pt")

            stepperButton(
                symbol: "plus",
                help: increaseHelp,
                enabled: canIncrease,
                delta: AnnotationSizeMetrics.stepPoints
            )
        }
        .padding(2)
        .background(.white.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func stepperButton(symbol: String, help: String,
                               enabled: Bool, delta: Double) -> some View {
        Button {
            if isEditingValue { endEditing(commitDraft: true) }
            points = min(range.upperBound, max(range.lowerBound, points + delta))
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.3))
                .frame(width: 24, height: 24)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(L(help))
        .accessibilityLabel(L(help))
    }

    private func beginEditing() {
        guard !isEditingValue else { return }
        draft = formatted(points)
        isEditingValue = true
    }

    private func endEditing(commitDraft: Bool) {
        guard isEditingValue else { return }
        if commitDraft { commit() } else { draft = formatted(points) }
        isEditingValue = false
        editing = false
    }

    private func commit() {
        guard let value = AnnotationSizeMetrics.clampedPoints(from: draft, within: range) else {
            draft = formatted(points)
            return
        }
        if points != value { points = value }
        draft = formatted(points)
    }

    private func formatted(_ value: Double) -> String {
        "\(Int(value.rounded()))"
    }
}

private struct CaptureOptionsPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L(title)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            content
        }
        .padding(14).frame(width: 284)
        .background(Palette.overlay)
        .presentationBackground(Palette.overlay)
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
                    Text(L(title)).font(.system(size: 13, weight: .medium))
                    Text(L(detail)).font(.system(size: 11)).foregroundStyle(Palette.overlayMuted)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white).padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(CaptureOptionStyle())
        .accessibilityLabel(L(title)).accessibilityValue(L(detail))
    }
}

private struct CaptureOptionStyle: ButtonStyle {
    @StoredState private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Palette.overlayAccent.opacity(0.24) :
                            (hovered ? Palette.overlayAccent.opacity(0.14) : Palette.overlayRaised.opacity(0.52)),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(hovered ? 0.26 : 0.1)))
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
            .opacity(enabled ? 1 : 0.32)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .onHover { hovered = $0 }
    }
}
