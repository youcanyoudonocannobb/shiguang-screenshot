import AppKit
import Foundation

struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw CheckFailure(message: message) }
}

func unwrap<T>(_ value: T?) throws -> T {
    guard let value else { throw CheckFailure(message: "Unexpected nil: \(T.self)") }
    return value
}

@main
struct ShiguangChecks {
    private static func whiteImage(width: Int = 100, height: Int = 100) -> NSImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
    }

    static func redaction() throws {
        let mark = Mark(tool: .redact,
                        points: [UnitPoint(x: 0.1, y: 0.1), UnitPoint(x: 0.4, y: 0.3)],
                        colorHex: "E45F3C")
        let output = ImageRenderer.render(whiteImage(), marks: [mark])
        let bitmap = try unwrap(NSBitmapImageRep(data: unwrap(output.pngData)))
        let inside = try unwrap(bitmap.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
        let outside = try unwrap(bitmap.colorAt(x: 20, y: 80)?.usingColorSpace(.deviceRGB))
        try check(inside.redComponent < 0.01 && inside.greenComponent < 0.01 && inside.blueComponent < 0.01,
                  "Redaction must be opaque black in the TOP left of the exported PNG")
        try check(outside.redComponent > 0.99, "Redaction must not affect the bottom left")
        try check(bitmap.pixelsWide == 100 && bitmap.pixelsHigh == 100, "Export must retain original pixel size")
    }

    static func history() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(directory: folder)
        var record = try store.add(whiteImage(), title: "Test")
        record.text = "Original"
        record.translation = "译文"
        record.marks = [Mark(tool: .arrow, points: [UnitPoint(x: 0, y: 0), UnitPoint(x: 1, y: 1)], colorHex: "347A64")]
        try store.save([record])
        let loaded = try unwrap(store.load().first)
        try check(loaded.id == record.id && loaded.translation == "译文" && loaded.marks == record.marks,
                  "History round-trip must retain text and marks")
        try check(store.image(for: loaded) != nil, "Saved image must be readable")
        try store.removeImage(loaded)
        try check(store.load().isEmpty, "Missing images must be excluded from history")
    }

    static func corruptHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(directory: folder)
        let index = folder.appendingPathComponent("history.json")
        let corrupted = Data("broken json".utf8)
        try corrupted.write(to: index)
        var failed = false
        do { _ = try store.load() } catch { failed = true }
        try check(failed, "Invalid JSON must be reported")
        try check(Data(contentsOf: index) == corrupted, "Corrupt history must not be silently overwritten")
    }

    static func pathSafety() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try HistoryStore(directory: folder)
        let record = CaptureRecord(id: UUID(), createdAt: Date(), title: "Unsafe", fileName: "../outside.png")
        try check(store.url(for: record).deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL,
                  "Stored filename must not escape the history directory")
    }

    static func coordinates() throws {
        try check(UnitPoint(x: -0.2, y: 1.4) == UnitPoint(x: 0, y: 1), "Coordinates must clamp to image")
        try check(UnitPoint(x: 0.25, y: 0.5).scaled(CGSize(width: 200, height: 100)) == CGPoint(x: 50, y: 50),
                  "Normalized coordinates must scale consistently")
    }

    @MainActor
    static func main() async {
        var lines: [String] = []
        func log(_ line: String) { lines.append(line); print(line) }
        let tests: [(String, () throws -> Void)] = [
            ("redaction_pixels_and_dimensions", redaction),
            ("history_roundtrip_and_missing_file", history),
            ("corrupt_history_preserved", corruptHistory),
            ("history_path_safety", pathSafety),
            ("normalized_coordinates", coordinates)
        ]
        var failures = 0
        for (name, run) in tests {
            do { try run(); log("PASS \(name)") }
            catch { failures += 1; log("FAIL \(name): \(error.localizedDescription)") }
        }
        do {
            let image = try unwrap(DemoImage.make().cgImageValue)
            let text = try await OCRService.recognize(image)
            try check(text.localizedCaseInsensitiveContains("Make room"), "OCR missing heading: \(text)")
            try check(text.localizedCaseInsensitiveContains("good ideas"), "OCR missing second line: \(text)")
            try check(text.localizedCaseInsensitiveContains("Capture a thought"), "OCR missing body: \(text)")
            log("PASS vision_real_image_recognition")
        } catch { failures += 1; log("FAIL vision_real_image_recognition: \(error.localizedDescription)") }
        log("\(6 - failures)/6 checks passed")
        if Bundle.main.bundleURL.pathExtension == "app" {
            let report = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("checks-result.txt")
            try? lines.joined(separator: "\n").write(to: report, atomically: true, encoding: .utf8)
        }
        exit(failures == 0 ? 0 : 1)
    }
}
