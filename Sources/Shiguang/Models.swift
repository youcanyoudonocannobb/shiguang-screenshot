import AppKit
import CoreImage
import CoreText
import Foundation
import Vision

enum RecordingFormat: String, CaseIterable {
    case video, gif
    var title: String { L(self == .video ? "MP4 视频" : "GIF 动图") }
    var fileExtension: String { self == .video ? "mp4" : "gif" }
}

enum ScrollCaptureMode: String, CaseIterable {
    case automatic, manual
    var title: String { L(self == .automatic ? "自动长截图" : "手动长截图") }
}

enum MenuBarDogStyle: String, Codable, CaseIterable, Identifiable {
    case system
    case lake
    case coral
    case teal
    case amber
    case cat
    case rabbit
    case fox
    case panda
    case custom

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .system: return "系统单色"
        case .lake: return "湖蓝小狗"
        case .coral: return "珊瑚小狗"
        case .teal: return "青绿小狗"
        case .amber: return "琥珀小狗"
        case .cat: return "小猫"
        case .rabbit: return "兔子"
        case .fox: return "狐狸"
        case .panda: return "熊猫"
        case .custom: return "自定义图标"
        }
    }

    var title: String { L(titleKey) }

    var colorHex: String? {
        switch self {
        case .system, .custom: return nil
        case .lake: return "17698B"
        case .coral: return "B84C45"
        case .teal: return "2C7566"
        case .amber: return "9A641B"
        case .cat: return "C97845"
        case .rabbit: return "B98B96"
        case .fox: return "D56A32"
        case .panda: return "4A5963"
        }
    }
}

enum MarkTool: String, Codable, CaseIterable {
    case pointer, rectangle, ellipse, line, arrow, pen, highlighter, number, text, mosaic, spotlight, redact, picker

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
        case .mosaic: return "checkerboard.rectangle"
        case .spotlight: return "sun.max"
        case .redact: return "rectangle.fill"
        case .picker: return "eyedropper"
        }
    }

    var title: String {
        switch self {
        case .pointer: return L("浏览")
        case .rectangle: return L("矩形")
        case .ellipse: return L("椭圆")
        case .line: return L("直线")
        case .arrow: return L("箭头")
        case .pen: return L("画笔")
        case .highlighter: return L("荧光笔")
        case .number: return L("编号")
        case .text: return L("文字")
        case .mosaic: return L("马赛克")
        case .spotlight: return L("聚光灯")
        case .redact: return L("遮盖")
        case .picker: return L("取色")
        }
    }
}

enum AnnotationSizeMetrics {
    static let defaultLineWidthPoints = 3.0
    static let lineWidthRange = 2.0...24.0
    static let defaultNumberSizePoints = 14.0
    static let numberSizeRange = 8.0...48.0
    static let textSizeRange = 12.0...72.0
    static let defaultMaskSizePoints = 24.0
    static let maskSizeRange = 2.0...80.0
    static let stepPoints = 1.0

    /// Parses the compact point-size field and normalizes manual input to a
    /// whole point inside the setting's supported range.
    static func clampedPoints(from text: String,
                              within range: ClosedRange<Double>) -> Double? {
        var numeric = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if numeric.lowercased().hasSuffix("pt") {
            numeric.removeLast(2)
            numeric = numeric.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        numeric = numeric.replacingOccurrences(of: ",", with: ".")
        guard let value = Double(numeric), value.isFinite else { return nil }
        return min(range.upperBound, max(range.lowerBound, value.rounded()))
    }

    /// Marks store sizes as a fraction of the image's shortest side so they
    /// survive cropping and history reloads. The input and output use points.
    static func fraction(points: Double, imageSize: CGSize) -> Double {
        let shortestSide = max(1, min(imageSize.width, imageSize.height))
        return max(0.0001, points / Double(shortestSide))
    }
}

enum TextPresentation: String, CaseIterable, Codable {
    case plain, outlined, highlighted

    var title: String {
        switch self {
        case .plain: return L("无底")
        case .outlined: return L("描边")
        case .highlighted: return L("底色")
        }
    }
}

enum MaskStyle: String, CaseIterable, Codable {
    case blur, pixel

    var title: String {
        L(self == .blur ? "模糊" : "像素")
    }
}

enum MaskStrength: String, CaseIterable, Codable {
    case weak, medium, strong

    var title: String {
        switch self {
        case .weak: return L("弱")
        case .medium: return L("中")
        case .strong: return L("强")
        }
    }

    var fraction: Double {
        switch self {
        case .weak: return 0.012
        case .medium: return 0.024
        case .strong: return 0.045
        }
    }
}

enum SpotlightStrength: String, CaseIterable, Codable {
    case light, deep

    var title: String { L(self == .light ? "浅" : "深") }
    var alpha: Double { self == .light ? 0.36 : 0.58 }
}

enum CaptureAspectRatio: String, CaseIterable, Identifiable {
    case free, square, fourThree, threeTwo, sixteenNine, nineSixteen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return L("自由")
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        case .nineSixteen: return "9:16"
        }
    }

    var value: CGFloat? {
        switch self {
        case .free: return nil
        case .square: return 1
        case .fourThree: return 4 / 3
        case .threeTwo: return 3 / 2
        case .sixteenNine: return 16 / 9
        case .nineSixteen: return 9 / 16
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
    var lineWidth: Double?
    var numberSize: Double?
    var arrowDoubleHeaded: Bool?
    var textPresentation: TextPresentation?
    var maskStyle: MaskStyle?
    var maskStrength: MaskStrength?
    var maskSize: Double?
    var spotlightStrength: SpotlightStrength?
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
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for mark in marks {
            guard let first = mark.points.first?.scaled(size),
                  let last = mark.points.last?.scaled(size) else { continue }
            let width = max(2, min(size.width, size.height) * (mark.lineWidth ?? 0.005))
            context.setLineWidth(width)
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
                // Mask the composited image so earlier annotations are covered too.
                guard rect.width > 0, rect.height > 0, let composite = context.makeImage() else { continue }
                // `maskSize` stores the newer pt-based size. `maskStrength`
                // remains the fallback for annotations saved by older builds.
                let strength = mark.maskSize ?? (mark.maskStrength ?? .medium).fraction
                let detail = max(1, min(size.width, size.height) * strength)
                let processed: CGImage?
                switch mark.maskStyle ?? .pixel {
                case .blur:
                    processed = blurred(composite, radius: max(1, detail))
                case .pixel:
                    processed = pixelated(composite, blockPixels: detail)
                }
                guard let processed else { continue }
                context.saveGState()
                context.clip(to: rect)
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = mark.maskStyle == .blur ? .high : .none
                context.draw(processed, in: CGRect(origin: .zero, size: size))
                context.restoreGState()
            case .spotlight:
                context.saveGState()
                context.setFillColor(NSColor.black.withAlphaComponent(
                    mark.spotlightStrength?.alpha ?? SpotlightStrength.light.alpha).cgColor)
                let path = CGMutablePath()
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRoundedRect(in: rect,
                                    cornerWidth: min(rect.width, rect.height) * 0.025,
                                    cornerHeight: min(rect.width, rect.height) * 0.025)
                context.addPath(path)
                context.fillPath(using: .evenOdd)
                context.setStrokeColor(CGColor(gray: 1, alpha: 0.28))
                context.setLineWidth(max(1, width * 0.45))
                context.stroke(rect)
                context.restoreGState()
            case .number:
                drawNumber(mark.text ?? "1", at: first, color: color, imageSize: size,
                           sizeFraction: mark.numberSize, context: context)
            case .text:
                drawText(mark, at: first, imageSize: size, context: context)
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
                drawArrowHead(in: context, tip: last, angle: angle, length: length)
                if mark.arrowDoubleHeaded == true {
                    drawArrowHead(in: context, tip: first, angle: angle + .pi, length: length)
                }
                context.strokePath()
            }
        }
        guard let output = context.makeImage() else { return image }
        return NSImage(cgImage: output, size: size)
    }

    private static func drawNumber(_ text: String, at point: CGPoint, color: CGColor,
                                   imageSize: CGSize, sizeFraction: Double?,
                                   context: CGContext) {
        let shortestSide = min(imageSize.width, imageSize.height)
        let radius: CGFloat
        if let sizeFraction {
            radius = max(2, min(shortestSide * 0.45,
                                shortestSide * max(0.002, sizeFraction)))
        } else {
            // Number marks created before point sizing have no stored size.
            radius = max(9, min(46, shortestSide * 0.022))
        }
        let badge = CGRect(x: point.x - radius, y: point.y - radius,
                           width: radius * 2, height: radius * 2)
        context.saveGState()
        context.setFillColor(color)
        context.fillEllipse(in: badge)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.94))
        context.setLineWidth(max(1, radius * 0.12))
        context.strokeEllipse(in: badge.insetBy(dx: 1, dy: 1))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(5, radius * 1.05), weight: .bold)
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

    private static func drawArrowHead(in context: CGContext, tip: CGPoint,
                                      angle: CGFloat, length: CGFloat) {
        for offset in [-Double.pi / 6, Double.pi / 6] {
            context.move(to: tip)
            context.addLine(to: CGPoint(x: tip.x - length * cos(angle + offset),
                                        y: tip.y - length * sin(angle + offset)))
        }
    }

    private static func drawText(_ mark: Mark, at point: CGPoint,
                                 imageSize: CGSize, context: CGContext) {
        guard let text = mark.text, !text.isEmpty else { return }
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: imageSize))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let foreground = NSColor(hex: mark.colorHex)
        let font = NSFont.systemFont(ofSize: max(8, (mark.fontSize ?? 0.035) * imageSize.height),
                                    weight: .semibold)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: foreground
        ]
        let presentation = mark.textPresentation ?? .plain
        if presentation == .outlined {
            let rgb = foreground.usingColorSpace(.sRGB) ?? foreground
            let luminance = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
            attributes[.strokeColor] = luminance > 0.72 ? NSColor.black : NSColor.white
            attributes[.strokeWidth] = -3.2
        }
        let value = text as NSString
        if presentation == .highlighted {
            let textSize = value.size(withAttributes: attributes)
            let padding = max(3, font.pointSize * 0.2)
            let box = CGRect(x: point.x - padding, y: point.y - padding * 0.55,
                             width: textSize.width + padding * 2,
                             height: textSize.height + padding * 1.1)
            foreground.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: box, xRadius: padding * 0.7, yRadius: padding * 0.7).fill()
            foreground.withAlphaComponent(0.34).setStroke()
            let border = NSBezierPath(roundedRect: box, xRadius: padding * 0.7, yRadius: padding * 0.7)
            border.lineWidth = max(0.7, font.pointSize * 0.035)
            border.stroke()
        }
        value.draw(at: point, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private static func pixelated(_ source: CGImage, blockPixels: CGFloat) -> CGImage? {
        let block = max(1, Int(blockPixels.rounded()))
        let width = max(1, source.width / block)
        let height = max(1, source.height / block)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .low
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    private static func blurred(_ source: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: source)
        let extent = input.extent
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage?.cropped(to: extent) else { return nil }
        return ciContext.createCGImage(output, from: extent)
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
