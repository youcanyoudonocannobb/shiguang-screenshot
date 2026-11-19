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
                // Labels let drags through to the bar's drag surface; only the
                // buttons take clicks.
                Group {
                    Circle().fill(session.phase == .paused ? Palette.warning : Color(hex: "D46A66")).frame(width: 7, height: 7)
                    Text(verbatim: session.format == .gif ? "GIF" : "MP4").font(.system(size: 11, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                        let seconds = Int(recorder.elapsedSeconds)
                        Text(verbatim: String(format: "%02d:%02d", seconds / 60, seconds % 60))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                    }
                    Spacer()
                    if [.starting, .pausing, .stopping, .copying].contains(session.phase) { ProgressView().controlSize(.small) }
                    if session.phase == .paused { Text("已暂停").font(.system(size: 10)).foregroundStyle(Palette.warning) }
                }
                .allowsHitTesting(false)
                if session.phase == .ready {
                    Button(action: onStart) { Image(systemName: "record.circle") }
                        .help("开始录制").accessibilityLabel("开始录制")
                }
                if session.phase == .recording || session.phase == .paused {
                    Button(action: onPause) { Image(systemName: session.phase == .paused ? "play.fill" : "pause.fill") }
                        .help(L(session.phase == .paused ? "继续录制" : "暂停录制"))
                        .accessibilityLabel(L(session.phase == .paused ? "继续录制" : "暂停录制"))
                    Button(action: onStop) { Image(systemName: "stop.fill") }
                        .help("停止并复制").accessibilityLabel("停止并复制")
                }
                Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 18).allowsHitTesting(false)
                Button(action: onCancel) { Image(systemName: "xmark").foregroundStyle(Color(hex: "E28B86")) }
                    .help("取消录制").accessibilityLabel("取消录制")
                Button(action: onConfirm) { Image(systemName: "checkmark").foregroundStyle(Color(hex: "82C9A6")) }
                    .disabled(![.recording, .paused, .review].contains(session.phase))
                    .help("复制到剪贴板").accessibilityLabel("复制到剪贴板")
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 28, height: 28)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .buttonStyle(RecordingControlStyle()).font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 12).frame(height: 42)
            .background(WindowDragHandle())
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

/// Moves a borderless window by following the pointer. `performDrag(with:)`
/// did not move the non-activating recording bar: an inactive panel swallows
/// the first click, so the drag never started.
struct ManualWindowDrag {
    private var mouseStart = CGPoint.zero
    private var originStart = CGPoint.zero
    private(set) var isActive = false

    mutating func begin(_ event: NSEvent, window: NSWindow) {
        mouseStart = Self.globalLocation(of: event)
        originStart = window.frame.origin
        isActive = true
    }

    mutating func drag(_ event: NSEvent, window: NSWindow) {
        guard isActive else { return }
        let mouse = Self.globalLocation(of: event)
        let proposed = CGPoint(x: originStart.x + mouse.x - mouseStart.x,
                               y: originStart.y + mouse.y - mouseStart.y)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? window.screen ?? NSScreen.main
        guard let screenFrame = screen?.frame else { window.setFrameOrigin(proposed); return }
        window.setFrameOrigin(Self.constrained(proposed, size: window.frame.size, screen: screenFrame))
    }

    mutating func end() { isActive = false }

    /// Keeps part of the window on screen, and its top edge below the top of
    /// the screen, the way macOS constrains titled windows.
    static func constrained(_ origin: CGPoint, size: CGSize, screen: CGRect) -> CGPoint {
        let keep: CGFloat = 40
        let x = min(max(origin.x, screen.minX - size.width + keep), screen.maxX - keep)
        let y = min(max(origin.y, screen.minY - size.height + keep), screen.maxY - size.height)
        return CGPoint(x: x, y: y)
    }

    /// The event's own position in global Cocoa coordinates. Unlike
    /// `locationInWindow`, it does not shift while the window moves.
    static func globalLocation(of event: NSEvent) -> CGPoint {
        if let location = event.cgEvent?.location, let primary = NSScreen.screens.first {
            return CGPoint(x: location.x, y: primary.frame.maxY - location.y)
        }
        if let window = event.window { return window.convertPoint(toScreen: event.locationInWindow) }
        return NSEvent.mouseLocation
    }
}

private final class DraggableView: NSView {
    private var drag = ManualWindowDrag()

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        drag.begin(event, window: window)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        drag.drag(event, window: window)
    }

    override func mouseUp(with event: NSEvent) {
        drag.end()
        window?.invalidateCursorRects(for: self)
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
