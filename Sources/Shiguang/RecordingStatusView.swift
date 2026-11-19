import AppKit
import SwiftUI

struct RecordingStatusView: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var recorder: ScreenRecorder
    var onStart: () -> Void
    var onStop: () -> Void
    var onPause: () -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 9) {
                Circle().fill(session.phase == .paused ? Palette.warning : Color(hex: "D46A66")).frame(width: 7, height: 7)
                Text(session.format == .gif ? "GIF" : "MP4").font(.system(size: 11, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let seconds = Int(recorder.elapsedSeconds)
                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                Spacer()
                if [.starting, .pausing, .stopping, .copying].contains(session.phase) { ProgressView().controlSize(.small) }
                if session.phase == .paused { Text("已暂停").font(.system(size: 10)).foregroundStyle(Palette.warning) }
                if session.phase == .ready {
                    Button(action: onStart) { Image(systemName: "record.circle") }
                        .help("开始录制").accessibilityLabel("开始录制")
                }
                if session.phase == .recording || session.phase == .paused {
                    Button(action: onPause) { Image(systemName: session.phase == .paused ? "play.fill" : "pause.fill") }
                        .help(session.phase == .paused ? "继续录制" : "暂停录制")
                        .accessibilityLabel(session.phase == .paused ? "继续录制" : "暂停录制")
                    Button(action: onStop) { Image(systemName: "stop.fill") }
                        .help("停止并复制").accessibilityLabel("停止并复制")
                }
                Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 18)
                Button(action: onCancel) { Image(systemName: "xmark").foregroundStyle(Color(hex: "E28B86")) }
                    .help("取消录制，不保存 (Esc)").accessibilityLabel("取消录制，不保存")
                Button(action: onConfirm) { Image(systemName: "checkmark").foregroundStyle(Color(hex: "82C9A6")) }
                    .disabled(![.recording, .paused, .review].contains(session.phase))
                    .help("复制到剪贴板并完成").accessibilityLabel("复制录制到剪贴板")
                ZStack {
                    WindowDragHandle()
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.55))
                        .allowsHitTesting(false)
                }
                .frame(width: 28, height: 28)
                .help("拖动控制条")
            }
            .buttonStyle(RecordingControlStyle()).font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 12).frame(height: 42)
            .background(Palette.overlay, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            if let error = session.copyError {
                Text(error).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    .padding(8).frame(maxWidth: .infinity)
                    .background(Palette.overlay, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
    }
}
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableView { DraggableView() }
    func updateNSView(_ nsView: DraggableView, context: Context) {}
}

private final class DraggableView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

private struct RecordingControlStyle: ButtonStyle {
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 26, height: 28)
            .background(configuration.isPressed ? .white.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .opacity(enabled ? 1 : 0.35)
    }
}
