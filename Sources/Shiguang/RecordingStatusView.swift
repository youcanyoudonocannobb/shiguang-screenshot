import AVKit
import SwiftUI

struct RecordingStatusView: View {
    @ObservedObject var session: RecordingSession
    @ObservedObject var recorder: ScreenRecorder
    var onStart: () -> Void
    var onStop: () -> Void
    var onPause: () -> Void
    var onConfirm: () -> Void
    var onCancel: () -> Void
    @StoredState private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 2) {
            if session.phase == .review || session.phase == .copying, let player {
                NativeRecordingPlayer(player: player).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 9) {
                Circle().fill(session.phase == .paused ? Color.orange : Color(hex: "FF666B")).frame(width: 7, height: 7)
                Text(session.format == .gif ? "GIF" : "MP4").font(.system(size: 11, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    let seconds = Int(recorder.elapsedSeconds)
                    Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                }
                Spacer()
                if [.starting, .pausing, .stopping, .copying].contains(session.phase) { ProgressView().controlSize(.small) }
                if session.phase == .paused { Text("已暂停").font(.system(size: 10)).foregroundStyle(Color(hex: "FFD180")) }
                if session.phase == .ready {
                    Button(action: onStart) { Image(systemName: "record.circle") }
                        .help("开始录制").accessibilityLabel("开始录制")
                }
                if session.phase == .recording || session.phase == .paused {
                    Button(action: onPause) { Image(systemName: session.phase == .paused ? "play.fill" : "pause.fill") }
                        .help(session.phase == .paused ? "继续录制" : "暂停录制")
                        .accessibilityLabel(session.phase == .paused ? "继续录制" : "暂停录制")
                    Button(action: onStop) { Image(systemName: "stop.fill") }
                        .help("停止并预览").accessibilityLabel("停止并预览")
                }
                Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 18)
                Button(action: onCancel) { Image(systemName: "xmark").foregroundStyle(Color(hex: "FF7979")) }
                    .help("取消录制，不保存 (Esc)").accessibilityLabel("取消录制，不保存")
                Button(action: onConfirm) { Image(systemName: "checkmark").foregroundStyle(Color(hex: "75E6A5")) }
                    .disabled(![.recording, .paused, .review].contains(session.phase))
                    .help("复制到剪贴板并完成").accessibilityLabel("复制录制到剪贴板")
                Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    .help("拖动控制条").allowsHitTesting(false)
            }
            .buttonStyle(RecordingControlStyle()).font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 12).frame(height: 42)
            .background(Color(hex: "17191C"), in: RoundedRectangle(cornerRadius: 10))
            if session.phase == .review || session.phase == .copying {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    .padding(8).frame(maxWidth: .infinity).background(Color(hex: "17191C"), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .onChange(of: session.movieURL, initial: true) { _, url in
            player?.pause()
            player = url.map { AVPlayer(url: $0) }
        }
        .onDisappear { player?.pause(); player = nil }
    }

    private var subtitle: String {
        if let error = session.copyError { return error }
        switch session.phase {
        case .ready: return "点击开始录制 · 草稿"
        case .starting: return "正在启动…"
        case .pausing: return "正在暂停…"
        case .paused: return "已暂停"
        case .stopping: return "正在生成预览…"
        case .review: return "预览草稿 · 点击 ✓ 复制到剪贴板"
        case .copying: return "正在复制到剪贴板…"
        default: return "无声录制"
        }
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

private struct NativeRecordingPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
