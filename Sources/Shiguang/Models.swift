import AppKit
import CoreText
import Foundation
import Vision

enum RecordingFormat: String, CaseIterable {
    case video, gif
    var title: String { self == .video ? "MP4 视频" : "GIF 动图" }
    var fileExtension: String { self == .video ? "mp4" : "gif" }
}

enum ScrollCaptureMode: String, CaseIterable {
    case automatic, manual
    var title: String { self == .automatic ? "自动长截图" : "手动长截图" }
}

enum MarkTool: String, Codable, CaseIterable {
    case pointer, rectangle, ellipse, line, arrow, pen, highlighter, number, text, mosaic, redact, picker

    var symbol: String {
        switch self {
        case .pointer: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "minus"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .number: return "number.circle"
        case .text: return "textformat"
        case .mosaic: return "square.grid.3x3.fill"
        case .redact: return "rectangle.fill"
        case .picker: return "eyedropper"
        }
    }

    var title: String {
        switch self {
        case .pointer: return "浏览"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .line: return "直线"
        case .arrow: return "箭头"
        case .pen: return "画笔"
        case .highlighter: return "荧光笔"
        case .number: return "编号"
        case .text: return "文字"
        case .mosaic: return "马赛克"
        case .redact: return "遮盖"
        case .picker: return "取色"
        }
    }
}

struct UnitPoint: Codable, Equatable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = min(1, max(0, x))
        self.y = min(1, max(0, y))
    }

    func scaled(_ size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
}

struct Mark: Codable, Identifiable, Equatable {
    var id = UUID()
    var tool: MarkTool
    var points: [UnitPoint]
    var colorHex: String
    var filled: Bool?
    var text: String?
    var fontSize: Double?
}

struct CaptureRecord: Codable, Identifiable {
    var id: UUID
    var createdAt: Date
    var title: String
    var fileName: String
    var text: String = ""
    var translation: String = ""
    var sourceLanguage: String = "auto"
    var targetLanguage: String = "zh-Hans"
    var marks: [Mark] = []
}

struct LanguageChoice: Identifiable {
    let id: String
    let name: String
    static let targets = [
        LanguageChoice(id: "zh-Hans", name: "简体中文"),
        LanguageChoice(id: "zh-Hant", name: "繁體中文"),
        LanguageChoice(id: "en", name: "English"),
        LanguageChoice(id: "ja", name: "日本語"),
        LanguageChoice(id: "ko", name: "한국어"),
        LanguageChoice(id: "fr", name: "Français"),
        LanguageChoice(id: "de", name: "Deutsch"),
        LanguageChoice(id: "es", name: "Español")
    ]
    static let sources = [LanguageChoice(id: "auto", name: "自动检测")] + targets
}

enum LocalError: LocalizedError {
    case image, capture(String), storage(String)
    var errorDescription: String? {
        switch self {
        case .image: return "无法读取这张图片，请使用 PNG、JPEG、HEIC 或 TIFF 文件。"
        case .capture(let text), .storage(let text): return text
        }
    }
}

extension NSImage {
    var cgImageValue: CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        if let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return cg
        }
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    var pngData: Data? {
        guard let cg = cgImageValue else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

extension NSColor {
    convenience init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(srgbRed: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255,
                  blue: Double(value & 255) / 255, alpha: 1)
    }
}

enum ImageRenderer {
    // Marks use top-left normalized coordinates in both the preview and exported image.
    static func render(_ image: NSImage, marks: [Mark]) -> NSImage {
        guard let source = image.cgImageValue else { return image }
        let size = CGSize(width: source.width, height: source.height)
        guard size.width > 0, size.height > 0 else { return image }
        guard let context = CGContext(data: nil, width: source.width, height: source.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.draw(source, in: CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let width = max(2, min(size.width, size.height) * 0.005)
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for mark in marks {
            guard let first = mark.points.first?.scaled(size),
                  let last = mark.points.last?.scaled(size) else { continue }
            let color = NSColor(hex: mark.colorHex).cgColor
            context.setStrokeColor(color)
            let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                              width: abs(last.x - first.x), height: abs(last.y - first.y))
            switch mark.tool {
            case .pointer, .picker:
                break
            case .rectangle:
                if mark.filled == true {
                    context.setFillColor(color)
                    context.fill(rect)
                } else {
                    context.stroke(rect)
                }
            case .ellipse:
                if mark.filled == true {
                    context.setFillColor(color)
                    context.fillEllipse(in: rect)
                } else {
                    context.strokeEllipse(in: rect)
                }
            case .line:
                context.beginPath()
                context.move(to: first)
                context.addLine(to: last)
                context.strokePath()
            case .redact:
                context.setFillColor(NSColor.black.cgColor)
                context.fill(rect)
            case .mosaic:
                // Pixelate the composited image so earlier annotations are covered too.
                guard rect.width > 0, rect.height > 0, let composite = context.makeImage(),
                      let small = pixelated(composite) else { continue }
                context.saveGState()
                context.clip(to: rect)
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .none
                context.draw(small, in: CGRect(origin: .zero, size: size))
                context.restoreGState()
            case .number:
                drawNumber(mark.text ?? "1", at: first, color: color, imageSize: size, context: context)
            case .text:
                guard let text = mark.text, !text.isEmpty else { continue }
                context.saveGState()
                context.clip(to: CGRect(origin: .zero, size: size))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                let font = NSFont.systemFont(ofSize: max(8, (mark.fontSize ?? 0.035) * size.height), weight: .semibold)
                (text as NSString).draw(at: first, withAttributes: [.font: font, .foregroundColor: NSColor(hex: mark.colorHex)])
                NSGraphicsContext.restoreGraphicsState()
                context.restoreGState()
            case .pen:
                context.beginPath()
                context.move(to: first)
                for point in mark.points.dropFirst() { context.addLine(to: point.scaled(size)) }
                context.strokePath()
            case .highlighter:
                context.saveGState()
                context.setAlpha(0.34)
                context.setLineWidth(width * 3.8)
                context.beginPath()
                context.move(to: first)
                for point in mark.points.dropFirst() { context.addLine(to: point.scaled(size)) }
                context.strokePath()
                context.restoreGState()
            case .arrow:
                context.beginPath()
                context.move(to: first)
                context.addLine(to: last)
                let angle = atan2(last.y - first.y, last.x - first.x)
                let length = min(width * 5, hypot(last.x - first.x, last.y - first.y) * 0.4)
                for offset in [-Double.pi / 6, Double.pi / 6] {
                    context.move(to: last)
                    context.addLine(to: CGPoint(x: last.x - length * cos(angle + offset),
                                               y: last.y - length * sin(angle + offset)))
                }
                context.strokePath()
            }
        }
        guard let output = context.makeImage() else { return image }
        return NSImage(cgImage: output, size: size)
    }

    private static func drawNumber(_ text: String, at point: CGPoint, color: CGColor,
                                   imageSize: CGSize, context: CGContext) {
        let radius = max(11, min(34, min(imageSize.width, imageSize.height) * 0.022))
        let badge = CGRect(x: point.x - radius, y: point.y - radius,
                           width: radius * 2, height: radius * 2)
        context.saveGState()
        context.setFillColor(color)
        context.fillEllipse(in: badge)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.94))
        context.setLineWidth(max(2, radius * 0.12))
        context.strokeEllipse(in: badge.insetBy(dx: 1, dy: 1))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(13, radius * 1.05), weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let value = text as NSString
        let valueSize = value.size(withAttributes: attributes)
        value.draw(at: CGPoint(x: point.x - valueSize.width / 2,
                               y: point.y - valueSize.height / 2),
                   withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private static func pixelated(_ source: CGImage) -> CGImage? {
        let block = max(10, Int(Double(min(source.width, source.height)) * 0.025))
        let width = max(1, source.width / block)
        let height = max(1, source.height / block)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

final class HistoryStore {
    let directory: URL
    private let manager = FileManager.default
    private var indexURL: URL { directory.appendingPathComponent("history.json") }

    init(directory: URL? = nil) throws {
        self.directory = directory ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shiguang", isDirectory: true)
        try manager.createDirectory(at: self.directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
    }

    func load() throws -> [CaptureRecord] {
        guard manager.fileExists(atPath: indexURL.path) else { return [] }
        let data = try Data(contentsOf: indexURL)
        let records = try JSONDecoder().decode([CaptureRecord].self, from: data)
        return records.filter { manager.fileExists(atPath: url(for: $0).path) }
    }

    func save(_ records: [CaptureRecord]) throws {
        let data = try JSONEncoder().encode(records)
        try data.write(to: indexURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    func add(_ image: NSImage, title: String) throws -> CaptureRecord {
        guard let data = image.pngData else { throw LocalError.image }
        let id = UUID()
        let record = CaptureRecord(id: id, createdAt: Date(), title: title, fileName: "\(id).png")
        try data.write(to: url(for: record), options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(for: record).path)
        return record
    }

    func url(for record: CaptureRecord) -> URL {
        directory.appendingPathComponent(URL(fileURLWithPath: record.fileName).lastPathComponent)
    }

    func image(for record: CaptureRecord) -> NSImage? {
        NSImage(contentsOf: url(for: record))
    }

    func removeImage(_ record: CaptureRecord) throws {
        let path = url(for: record)
        if manager.fileExists(atPath: path.path) { try manager.removeItem(at: path) }
    }
}

enum OCRService {
    /// Warms the Vision text pipeline with a throwaway image so the first real
    /// capture does not pay the model paging cost (measured ~15s on a cold start).
    static func warmUp() async {
        let size = 128
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica" as CFString, 40, nil),
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "A1", attributes: attributes))
        context.textPosition = CGPoint(x: 14, y: 46)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return }
        _ = try? await recognize(image)
    }

    static func recognize(_ image: CGImage) async throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR", "fr-FR", "de-DE", "es-ES"]
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let supported = try request.supportedRecognitionLanguages()
                request.recognitionLanguages = request.recognitionLanguages.filter { supported.contains($0) }
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }.value
        } onCancel: {
            request.cancel()
        }
    }
}

@MainActor
enum DemoImage {
    static func make() -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1440, pixelsHigh: 900,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(hex: "F6F1E8").setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1440, height: 900)).fill()
        NSColor(hex: "E46442").setFill()
        NSBezierPath(roundedRect: NSRect(x: 88, y: 690, width: 100, height: 8), xRadius: 4, yRadius: 4).fill()
        func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, color: String, bold: Bool = false) {
            let font = NSFont(name: bold ? "Georgia-Bold" : "Georgia", size: size) ?? .systemFont(ofSize: size)
            (string as NSString).draw(at: NSPoint(x: x, y: y),
                                     withAttributes: [.font: font, .foregroundColor: NSColor(hex: color)])
        }
        text("A LITTLE INSPIRATION", x: 88, y: 740, size: 22, color: "8B8378")
        text("Make room", x: 88, y: 545, size: 92, color: "263C35", bold: true)
        text("for good ideas.", x: 88, y: 430, size: 92, color: "263C35", bold: true)
        text("Capture a thought. Understand a new language.", x: 92, y: 285, size: 32, color: "5F6F66")
        text("Keep the things that make you curious.", x: 92, y: 228, size: 32, color: "5F6F66")
        text("SHIGUANG   /   YOUR EVERYDAY COMPANION", x: 92, y: 85, size: 18, color: "8B8378")
        NSGraphicsContext.restoreGraphicsState()
        return NSImage(cgImage: bitmap.cgImage!, size: NSSize(width: 1440, height: 900))
    }
}
