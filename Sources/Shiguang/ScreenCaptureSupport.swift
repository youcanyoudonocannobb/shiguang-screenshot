import AppKit
import ScreenCaptureKit

struct ScreenCapturePermission {
    private let preflight: () -> Bool
    private let request: () -> Bool
    private var verifiedByCapture = false
    private var captureWasDenied = false
    private(set) var isGranted = false
    private(set) var requestAccepted = false

    init(preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         request: @escaping () -> Bool = { CGRequestScreenCaptureAccess() }) {
        self.preflight = preflight
        self.request = request
    }

    @discardableResult
    mutating func refresh() -> Bool {
        isGranted = preflight() || verifiedByCapture
        return isGranted
    }

    mutating func captureSucceeded() {
        verifiedByCapture = true
        captureWasDenied = false
        isGranted = true
    }

    mutating func captureDenied() {
        verifiedByCapture = false
        captureWasDenied = true
        requestAccepted = false
        isGranted = false
    }

    @discardableResult
    mutating func authorize() -> Bool {
        guard !refresh() else { return true }
        requestAccepted = request()
        return refresh()
    }

    var title: String {
        if isGranted { return "屏幕访问已就绪" }
        if requestAccepted { return "授权已接受，等待生效" }
        return captureWasDenied ? "系统未允许当前应用访问屏幕" : "屏幕访问尚未确认"
    }

    var detail: String {
        if isGranted { return "可以使用区域截图、截图翻译和区域录制。" }
        if requestAccepted {
            return "系统已接受授权，但当前进程还不能访问屏幕。请重启拾光后再试。"
        }
        if captureWasDenied {
            return "请在系统设置的“隐私与安全性 → 屏幕与系统音频录制”中开启“拾光截图”。如果开关已经打开，请关闭后重新开启，再重启拾光。"
        }
        return "点击“试一次截图”验证访问权限。若系统要求授权，请在“隐私与安全性 → 屏幕与系统音频录制”中开启“拾光截图”。"
    }
}

struct CaptureRegion {
    let sourceRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int

    init?(selection: CGRect, displaySize: CGSize, scale: CGFloat) {
        guard [selection.minX, selection.minY, selection.width, selection.height,
               displaySize.width, displaySize.height, scale].allSatisfy(\.isFinite),
              displaySize.width > 0, displaySize.height > 0, scale > 0 else { return nil }
        let clipped = selection.standardized.intersection(CGRect(origin: .zero, size: displaySize))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
        // AppKit selections start at the bottom left; ScreenCaptureKit uses the top left.
        sourceRect = CGRect(x: clipped.minX, y: displaySize.height - clipped.maxY,
                            width: clipped.width, height: clipped.height)
        pixelWidth = max(1, Int((clipped.width * scale).rounded(.up)))
        pixelHeight = max(1, Int((clipped.height * scale).rounded(.up)))
    }
}

enum CaptureFailure: LocalizedError {
    case displayUnavailable
    case invalidSelection
    case timedOut

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: return "所选显示器已断开，请重新选择截图区域。"
        case .invalidSelection: return "截图区域不在当前显示器内，请重新框选。"
        case .timedOut: return "屏幕截图长时间没有响应，已自动取消。请重新尝试。"
        }
    }
}

@MainActor
enum ScreenCaptureService {
    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
    }

    static func capture(screen: NSScreen, selection: CGRect,
                        excludingWindowIDs: Set<CGWindowID>) async throws -> NSImage {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureFailure.displayUnavailable
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == number.uint32Value }) else {
            throw CaptureFailure.displayUnavailable
        }
        let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        guard let region = CaptureRegion(selection: selection, displaySize: screen.frame.size,
                                         scale: CGFloat(filter.pointPixelScale)) else {
            throw CaptureFailure.invalidSelection
        }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = region.sourceRect
        configuration.width = region.pixelWidth
        configuration.height = region.pixelHeight
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        return NSImage(cgImage: image, size: region.sourceRect.size)
    }
}
