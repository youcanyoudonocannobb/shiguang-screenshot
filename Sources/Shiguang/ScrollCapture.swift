import AppKit
import Combine
import ScreenCaptureKit
import SwiftUI

struct ScrollCaptureTarget {
    let windowID: CGWindowID
    let processID: pid_t
    let bounds: CGRect

    static func at(_ point: CGPoint, covering region: CGRect) -> Self? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let process = window[kCGWindowOwnerPID as String] as? Int32,
                  process != ProcessInfo.processInfo.processIdentifier,
                  ScrollWindowPolicy.permits(bundleID: NSRunningApplication(processIdentifier: process)?.bundleIdentifier,
                                             layer: layer, alpha: window[kCGWindowAlpha as String] as? Double ?? 1),
                  let number = window[kCGWindowNumber as String] as? UInt32,
                  let value = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: value),
                  bounds.contains(point),
                  bounds.intersection(region).width * bounds.intersection(region).height >= region.width * region.height * 0.6
            else { continue }
            return Self(windowID: number, processID: process, bounds: bounds)
        }
        return nil
    }
}

@MainActor
final class ScrollCaptureController: ObservableObject {
    let mode: ScrollCaptureMode
    @Published private(set) var status = "正在准备画面…"
    @Published private(set) var dimensions = ""
    @Published private(set) var frames = 0
    @Published private(set) var paused = false
    @Published private(set) var finishing = false
    @Published private(set) var preview: NSImage?
    @Published private(set) var sourceApplication = ""
    var onComplete: ((NSImage) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?
    private var task: Task<Void, Never>?
    private var assembler = ScrollCaptureAssembler()
    private var cancelled = false
    private var finishRequested = false
    private var filter: SCContentFilter?
    private var configuration: SCStreamConfiguration?
    private var windowCrop = CGRect.zero
    private var lastCandidate: ScrollFrameSample?

    init(mode: ScrollCaptureMode) { self.mode = mode }

    func start(screen: NSScreen, local: CGRect, global: CGRect) {
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let cursor = CGPoint(x: global.midX, y: primaryTop - global.midY)
        let captureBounds = CGRect(x: global.minX, y: primaryTop - global.maxY, width: global.width, height: global.height)
        let target = ScrollCaptureTarget.at(cursor, covering: captureBounds)
        task = Task {
            do {
                guard local.width >= 80, local.height >= 120 else { throw CaptureFailure.invalidSelection }
                guard let target else { throw ScrollStitchError.targetUnavailable }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                try Task.checkCancellation()
                guard let window = content.windows.first(where: { $0.windowID == target.windowID }) else {
                    throw ScrollStitchError.targetUnavailable
                }
                sourceApplication = window.owningApplication?.applicationName ?? "选中的窗口"
                // Capture the target window independently so floating controls and app switching cannot interrupt stitching.
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let scale = CGFloat(filter.pointPixelScale)
                let size = window.frame.size
                let crop = captureBounds.offsetBy(dx: -target.bounds.minX, dy: -target.bounds.minY)
                guard crop.minX >= 0, crop.minY >= 0, crop.maxX <= size.width + 1,
                      crop.maxY <= size.height + 1 else { throw CaptureFailure.invalidSelection }
                let config = SCStreamConfiguration()
                config.width = Int(size.width * scale)
                config.height = Int(size.height * scale)
                config.ignoreShadowsSingleWindow = true
                config.showsCursor = false
                config.capturesAudio = false
                windowCrop = CGRect(x: crop.minX * scale, y: crop.minY * scale,
                                    width: crop.width * scale, height: crop.height * scale).integral
                self.filter = filter
                self.configuration = config
                NSRunningApplication(processIdentifier: target.processID)?.activate(options: [])
                try await Task.sleep(for: .milliseconds(250))
                let first = try await capture()
                preview = NSImage(cgImage: first, size: global.size)
                _ = try await accept(first)
                lastCandidate = try ScrollFrameSample(first)
                let started = Date()
                var unchangedSteps = 0
                while !finishRequested {
                    try Task.checkCancellation()
                    if Date().timeIntervalSince(started) > 300 {
                        status = "已达到 5 分钟，正在生成长图"
                        break
                    }
                    if mode == .automatic {
                        if paused {
                            try await Task.sleep(for: .milliseconds(150))
                            continue
                        }
                        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else {
                            status = "请切回选中的窗口，自动滚动将继续"
                            try await Task.sleep(for: .milliseconds(250))
                            continue
                        }
                        guard CGPreflightPostEventAccess() else {
                            paused = true
                            status = "自动滚动权限不可用，可结束保存或改用手动长截图"
                            continue
                        }
                        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                                  wheel1: -Int32(min(240, local.height * 0.25)), wheel2: 0, wheel3: 0) else {
                            throw ScrollStitchError.invalidImage
                        }
                        event.location = cursor
                        event.postToPid(target.processID)
                        try await Task.sleep(for: .milliseconds(350))
                    } else {
                        try await Task.sleep(for: .milliseconds(160))
                    }
                    if finishRequested { break }
                    let frame = try await capture()
                    let sample = try ScrollFrameSample(frame)
                    if mode == .manual {
                        _ = try await accept(frame)
                        self.lastCandidate = sample
                        continue
                    }
                    if let lastCandidate, sample.distance(to: lastCandidate) > 1.3 {
                        self.lastCandidate = sample
                        var stable = false
                        for _ in 0..<12 {
                            try await Task.sleep(for: .milliseconds(130))
                            let next = try await capture()
                            let nextSample = try ScrollFrameSample(next)
                            if let candidate = self.lastCandidate, candidate.distance(to: nextSample) < 1.3 {
                                let result = try await accept(next)
                                unchangedSteps = result == .unchanged ? unchangedSteps + 1 : 0
                                stable = true
                                break
                            }
                            self.lastCandidate = nextSample
                        }
                        if !stable {
                            paused = true
                            status = "画面仍在变化，暂停后点击继续"
                        }
                    } else {
                        self.lastCandidate = sample
                        let result = try await accept(frame)
                        unchangedSteps = result == .unchanged ? unchangedSteps + 1 : 0
                    }
                    if mode == .automatic && unchangedSteps >= 3 {
                        status = "已到达页面底部"
                        break
                    }
                }
                try Task.checkCancellation()
                if finishRequested {
                    var previous = try await capture()
                    for _ in 0..<8 {
                        try await Task.sleep(for: .milliseconds(130))
                        let final = try await capture()
                        if try ScrollFrameSample(previous).distance(to: ScrollFrameSample(final)) < 1.3 {
                            _ = try await accept(final)
                            break
                        }
                        previous = final
                    }
                }
                finishing = true
                let image = try await assembler.result()
                try Task.checkCancellation()
                self.task = nil
                preview = NSImage(cgImage: image, size: CGSize(width: global.width,
                           height: CGFloat(image.height) * global.width / CGFloat(image.width)))
                onComplete?(NSImage(cgImage: image, size: CGSize(width: global.width,
                           height: CGFloat(image.height) * global.width / CGFloat(image.width))))
            } catch is CancellationError {
                return
            } catch ScrollStitchError.limit {
                do {
                    let image = try await assembler.result()
                    guard !cancelled else { return }
                    self.task = nil
                    onComplete?(NSImage(cgImage: image, size: .zero))
                } catch {
                    guard !cancelled else { return }
                    self.task = nil
                    onError?(error)
                }
            } catch {
                guard !cancelled else { return }
                self.task = nil
                onError?(error)
            }
        }
    }

    func finish() {
        guard !finishing else { return }
        finishing = true
        finishRequested = true
        status = "正在生成长图…"
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        task?.cancel()
        task = nil
        onCancel?()
    }

    func togglePause() {
        guard mode == .automatic, !finishing else { return }
        paused.toggle()
        status = paused ? "已暂停，可以调整页面后继续" : "正在自动滚动…"
    }

    private func capture() async throws -> CGImage {
        guard let filter, let configuration else { throw ScrollStitchError.noImage }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard let cropped = image.cropping(to: windowCrop) else { throw ScrollStitchError.invalidImage }
        return cropped
    }

    private func accept(_ frame: CGImage) async throws -> ScrollAppendResult {
        let (result, width, height, count) = try await assembler.append(frame)
        try Task.checkCancellation()
        dimensions = "\(width) × \(height)"
        if result == .first || count > frames {
            let thumbnail = try await assembler.preview()
            try Task.checkCancellation()
            preview = NSImage(cgImage: thumbnail, size: CGSize(width: thumbnail.width, height: thumbnail.height))
        }
        frames = count
        switch result {
        case .first, .appended:
            status = mode == .automatic ? "正在自动滚动拼接" : "向下缓慢滚动，完成后点击完成"
        case .unchanged: break
        case .backwards: status = "正在回看已截内容，向下滚动可继续"
        case .noOverlap:
            status = "滚动过快或画面变化，请向上滚回一点再继续"
            if mode == .automatic { paused = true }
        }
        return result
    }
}

final class ScrollCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

struct ScrollCaptureStatusView: View {
    @ObservedObject var capture: ScrollCaptureController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.expand.vertical").font(.system(size: 18))
                Text(capture.mode.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { capture.cancel() } label: { Image(systemName: "xmark").foregroundStyle(.red) }
                    .buttonStyle(.plain).help("取消长截图 (Esc)").accessibilityLabel("取消长截图")
            }
            Text("\(capture.dimensions) · \(capture.frames) 帧")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
            Text(capture.sourceApplication).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            previewView.frame(maxHeight: .infinity)
            Text(capture.status).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                .lineLimit(3).frame(height: 42, alignment: .topLeading)
            HStack {
                if capture.mode == .automatic {
                    Button(capture.paused ? "继续" : "暂停") { capture.togglePause() }.disabled(capture.finishing)
                }
                Spacer()
                Button("完成拼接") { capture.finish() }.disabled(capture.frames < 2 || capture.finishing)
                    .accessibilityLabel("完成长图拼接")
            }
        }
        .buttonStyle(.bordered).padding(12)
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .background(Color(hex: "17191C"), in: RoundedRectangle(cornerRadius: 12))
    }

    private var previewView: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    if let image = capture.preview {
                        Image(nsImage: image).resizable()
                            .frame(width: 232, height: max(1, 232 * image.size.height / max(1, image.size.width)))
                            .accessibilityLabel("已拼接的完整长图预览")
                    } else {
                        Text("等待画面").font(.system(size: 11)).padding(30)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
            }.onChange(of: capture.frames) { _, _ in reader.scrollTo("bottom", anchor: .bottom) }
                .background(.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.14)))
            }
    }
}
