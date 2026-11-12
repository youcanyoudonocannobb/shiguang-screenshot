import AppKit
import AVFoundation
import Combine
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum RecordingError: LocalizedError {
    case empty, finalizeTimeout, gifExport
    var errorDescription: String? {
        switch self {
        case .empty: return "录制未产生有效画面，请保持录制至少一秒后重试。"
        case .finalizeTimeout: return "录制文件仍未完成写入，请重试。"
        case .gifExport: return "GIF 导出失败，录制视频已保留，可重试保存。"
        }
    }
}

enum RecordingExport {
    static func concatenate(_ movies: [URL], to destination: URL) async throws {
        guard !movies.isEmpty else { throw RecordingError.empty }
        let composition = AVMutableComposition()
        guard let combined = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw RecordingError.empty }
        var cursor = CMTime.zero
        for (index, url) in movies.enumerated() {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RecordingError.empty }
            let range = try await track.load(.timeRange)
            if index == 0 { combined.preferredTransform = try await track.load(.preferredTransform) }
            try combined.insertTimeRange(range, of: track, at: cursor)
            cursor = cursor + range.duration
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw RecordingError.empty }
        try await withTaskCancellationHandler {
            try await export.export(to: destination, as: .mp4)
            try Task.checkCancellation()
        } onCancel: { export.cancelExport() }
    }

    static func videoSize(_ size: CGSize, maximum: CGFloat = 2560) -> CGSize {
        let ratio = min(1, maximum / max(1, max(size.width, size.height)))
        return CGSize(width: max(2, floor(size.width * ratio / 2) * 2),
                      height: max(2, floor(size.height * ratio / 2) * 2))
    }

    static func gif(from movie: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        let conversion = Task.detached(priority: .userInitiated) {
            let asset = AVURLAsset(url: movie)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw RecordingError.empty }
            let seconds = min(duration, 60)
            let count = max(1, Int(ceil(seconds * 10)))
            guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.gif.identifier as CFString, count, nil) else {
                throw RecordingError.gifExport
            }
            CGImageDestinationSetProperties(output, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1280, height: 1280)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
            for index in 0..<count {
                try Task.checkCancellation()
                let time = min(Double(index) / 10, max(0, seconds - 0.01))
                let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                autoreleasepool {
                    let delay = max(0.02, min(0.1, seconds - Double(index) / 10))
                    CGImageDestinationAddImage(output, image,
                                              [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
                }
            }
            guard CGImageDestinationFinalize(output) else { throw RecordingError.gifExport }
        }
        try await withTaskCancellationHandler {
            try await conversion.value
        } onCancel: { conversion.cancel() }
    }
}

struct RecordingDraft: Identifiable {
    let url: URL
    let format: RecordingFormat
    let createdAt: Date
    var id: URL { url }
}

struct RecordingDraftStore {
    let directory: URL

    init(directory: URL) {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    func loadAll() -> [RecordingDraft] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                             includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey])) ?? []
        return files.compactMap { url -> RecordingDraft? in
            guard let format = format(for: url),
                  let values = try? url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return RecordingDraft(url: url, format: format, createdAt: values.creationDate ?? .distantPast)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func load() -> (url: URL, format: RecordingFormat)? {
        loadAll().first.map { ($0.url, $0.format) }
    }

    func preserve(_ movie: URL, format: RecordingFormat) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent("pending-\(UUID().uuidString)-\(format.rawValue).mp4")
        try FileManager.default.copyItem(at: movie, to: destination)
        return destination.resolvingSymlinksInPath()
    }

    func removeExported(_ url: URL) throws {
        guard url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == directory.resolvingSymlinksInPath(),
              format(for: url) != nil else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func format(for url: URL) -> RecordingFormat? {
        guard url.pathExtension == "mp4" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        for format in RecordingFormat.allCases {
            if name == "pending-\(format.rawValue)" { return format }
            let suffix = "-\(format.rawValue)"
            if name.hasPrefix("pending-"), name.hasSuffix(suffix),
               UUID(uuidString: String(name.dropFirst(8).dropLast(suffix.count))) != nil { return format }
        }
        return nil
    }
}

@MainActor
final class RecordingSession: ObservableObject {
    enum Phase { case ready, starting, recording, pausing, paused, stopping, review, copying, confirmed, cancelled }
    let format: RecordingFormat
    @Published private(set) var phase = Phase.ready
    @Published private(set) var movieURL: URL?
    @Published private(set) var copyError: String?
    private(set) var confirmRequested = false
    var cancelled: Bool { phase == .cancelled }

    init(format: RecordingFormat) { self.format = format }

    func begin() -> Bool {
        guard phase == .ready else { return false }
        phase = .starting
        return true
    }

    func didStart() {
        guard phase == .starting else { return }
        phase = .recording
    }

    func stop() -> Bool {
        guard phase == .recording || phase == .paused else { return false }
        phase = .stopping
        return true
    }

    func pause() -> Bool {
        guard phase == .recording else { return false }
        phase = .pausing
        return true
    }

    func didPause() { if phase == .pausing { phase = .paused } }

    func resume() -> Bool {
        guard phase == .paused else { return false }
        phase = .starting
        return true
    }

    func didFinish(_ url: URL) {
        guard phase == .recording || phase == .stopping else { return }
        movieURL = url
        phase = .review
    }

    func requestConfirmation() -> Bool {
        guard phase == .recording || phase == .paused || phase == .review else { return false }
        confirmRequested = true
        return true
    }

    func didCommit() {
        guard phase == .copying, confirmRequested else { return }
        phase = .confirmed
    }

    func beginCopy() -> Bool {
        guard phase == .review, confirmRequested else { return false }
        copyError = nil
        phase = .copying
        return true
    }

    func failCopy(_ error: Error) {
        guard phase == .copying else { return }
        phase = .review
        confirmRequested = false
        copyError = "复制失败：\(error.localizedDescription)"
    }

    func cancel() {
        guard phase != .confirmed else { return }
        confirmRequested = false
        movieURL = nil
        phase = .cancelled
    }
}

@MainActor
final class ScreenRecorder: NSObject, ObservableObject, SCRecordingOutputDelegate, SCStreamDelegate {
    @Published private(set) var startedAt: Date?
    @Published private(set) var stopping = false
    @Published private(set) var paused = false
    @Published private(set) var format = RecordingFormat.video
    var onStarted: (() -> Void)?
    var onPaused: (() -> Void)?
    var onFinished: ((Result<URL, Error>) -> Void)?
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var folder: URL?
    private var segmentURL: URL?
    private var segments: [URL] = []
    private var accumulatedSeconds: TimeInterval = 0
    private var source: (screen: NSScreen, selection: CGRect)?
    private var timeout: Task<Void, Never>?
    private var limit: Task<Void, Never>?
    private var joining: Task<Void, Never>?
    private var completed = false
    private var pauseRequested = false
    var isActive: Bool { stream != nil || paused }
    var elapsedSeconds: TimeInterval { accumulatedSeconds + (startedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0) }

    func start(screen: NSScreen, selection: CGRect, format: RecordingFormat) async throws {
        self.format = format
        completed = false
        stopping = false
        paused = false
        startedAt = nil
        accumulatedSeconds = 0
        segments = []
        source = (screen, selection)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShiguangRecording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        folder = directory
        do { try await startSegment() }
        catch { await cancel(); throw error }
    }

    private func startSegment() async throws {
        guard let source, let folder else { throw RecordingError.empty }
        let screen = source.screen
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else { throw CaptureFailure.displayUnavailable }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        guard let region = CaptureRegion(selection: source.selection, displaySize: screen.frame.size,
                                         scale: CGFloat(filter.pointPixelScale)) else { throw CaptureFailure.invalidSelection }
        let size = RecordingExport.videoSize(CGSize(width: region.pixelWidth, height: region.pixelHeight), maximum: format == .gif ? 1280 : 2560)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.sourceRect
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: format == .gif ? 10 : 30)
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        let url = folder.appendingPathComponent("segment-\(segments.count).mp4")
        segmentURL = url
        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = url
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.output = output
        self.stream = stream
        do {
            try stream.addRecordingOutput(output)
            try await stream.startCapture()
            try Task.checkCancellation()
            if startedAt == nil { armTimeout() }
        } catch {
            self.output = nil
            self.stream = nil
            try? await stream.stopCapture()
            throw error
        }
    }

    func pause() async {
        guard stream != nil, !stopping, !completed else { return }
        pauseRequested = true
        await stopCurrentSegment()
    }

    func resume() async throws {
        guard paused, !completed else { return }
        paused = false
        stopping = false
        pauseRequested = false
        try await startSegment()
    }

    func cancel() async {
        completed = true
        timeout?.cancel()
        limit?.cancel()
        joining?.cancel()
        onStarted = nil
        onPaused = nil
        onFinished = nil
        let current = stream
        stream = nil
        output = nil
        try? await current?.stopCapture()
        await joining?.value
        joining = nil
        paused = false
        startedAt = nil
        discardTemporaryMovie()
    }

    func discardTemporaryMovie() {
        guard let folder, folder.lastPathComponent.hasPrefix("ShiguangRecording-"),
              folder.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() ==
                FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath() else { return }
        try? FileManager.default.removeItem(at: folder)
        self.folder = nil
    }

    func stop() async {
        guard !completed, !stopping else { return }
        pauseRequested = false
        if paused {
            paused = false
            stopping = true
            finishSegments()
        } else { await stopCurrentSegment() }
    }

    private func stopCurrentSegment() async {
        guard let stream else { return }
        stopping = true
        limit?.cancel()
        armTimeout()
        do { try await stream.stopCapture() }
        catch { finish(.failure(error)) }
    }

    private func armTimeout() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, !self.completed else { return }
            let current = self.stream
            self.finish(.failure(RecordingError.finalizeTimeout))
            try? await current?.stopCapture()
        }
    }

    private func finishSegments() {
        guard !completed else { return }
        guard let first = segments.first, let folder else { finish(.failure(RecordingError.empty)); return }
        if segments.count == 1 { finish(.success(first)); return }
        let movies = segments
        let destination = folder.appendingPathComponent("recording.mp4")
        joining = Task { [weak self] in
            do {
                try await RecordingExport.concatenate(movies, to: destination)
                try Task.checkCancellation()
                self?.finish(.success(destination))
            } catch is CancellationError { return }
            catch { self?.finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !completed else { return }
        completed = true
        timeout?.cancel()
        limit?.cancel()
        stream = nil
        output = nil
        startedAt = nil
        paused = false
        stopping = false
        if case .failure = result { discardTemporaryMovie() }
        let completion = onFinished
        onFinished = nil
        onStarted = nil
        onPaused = nil
        completion?(result)
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [self] in
            guard self.output === recordingOutput, !self.completed else { return }
            self.timeout?.cancel()
            self.startedAt = Date()
            self.onStarted?()
            if self.format == .gif {
                self.limit = Task { [weak self] in
                    guard let self else { return }
                    do { try await Task.sleep(for: .seconds(max(0.1, 60 - self.accumulatedSeconds))) } catch { return }
                    await self.stop()
                }
            }
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard self.output === recordingOutput, let url = self.segmentURL, !self.completed else { return }
            self.timeout?.cancel()
            self.limit?.cancel()
            self.stream = nil
            self.output = nil
            self.startedAt = nil
            let duration = recordingOutput.recordedDuration.seconds
            if duration > 0 { self.segments.append(url); self.accumulatedSeconds += duration }
            else { try? FileManager.default.removeItem(at: url) }
            if self.pauseRequested {
                self.pauseRequested = false
                self.paused = true
                self.stopping = false
                self.onPaused?()
            } else { self.finishSegments() }
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.output === recordingOutput else { return }
            let stream = self.stream
            self.finish(.failure(error))
            try? await stream?.stopCapture()
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.finish(.failure(error))
        }
    }
}
