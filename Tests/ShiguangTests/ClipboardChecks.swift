import AppKit
import ImageIO
import UniformTypeIdentifiers

private struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message: message) }
}

@MainActor
private final class Fixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShiguangClipboardCheck-\(UUID())")
    let board = NSPasteboard(name: NSPasteboard.Name("Shiguang.Check.\(UUID())"))
    let suite = "Shiguang.ClipboardCheck.\(UUID())"
    lazy var defaults = UserDefaults(suiteName: suite)!
    lazy var history = ClipboardHistory(directory: folder, pasteboard: board, preferences: defaults)
    func clean() {
        history.stop()
        board.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
}

@main
@MainActor
struct ClipboardChecks {
    static func image() -> NSImage {
        let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 32, y: 0, width: 32, height: 32))
        return NSImage(cgImage: context.makeImage()!, size: CGSize(width: 64, height: 32))
    }

    static func richTextAndPersistence() throws {
        let f = Fixture(); defer { f.clean() }
        let history = f.history
        let values = [NSPasteboard.PasteboardType.string.rawValue: Data("Clipboard fixture 中文".utf8),
                      NSPasteboard.PasteboardType.html.rawValue: Data("<b>Clipboard fixture 中文</b>".utf8)]
        let snapshot = ClipboardSnapshot(items: [values, ["local.shiguang.custom": Data([1, 2, 3, 4])]])
        try snapshot.write(to: f.board)
        history.poll()
        try require(history.entries.count == 1 && history.entries[0].kind == .text, "Observe a system-style copy")
        let reopened = ClipboardHistory(directory: f.folder, pasteboard: f.board, preferences: f.defaults)
        f.board.clearContents(); f.board.setString("Replace current contents", forType: .string)
        try reopened.copy(reopened.entries[0])
        let restored = ClipboardSnapshot.read(f.board)!
        try require(restored.items == snapshot.items, "Restore every pasteboard item and representation after relaunch")
        reopened.captureCurrent()
        try require(reopened.entries.count == 1, "Re-copy must not duplicate history")
    }

    static func imageCopyAndPreview() throws {
        let f = Fixture(); defer { f.clean() }
        try f.history.copyImage(image())
        let data = f.board.data(forType: .png)!
        let pixels = NSBitmapImageRep(data: data)!
        try require(pixels.pixelsWide == 64 && pixels.pixelsHigh == 32, "Copy image pixels at their original dimensions")
        let red = pixels.colorAt(x: 5, y: 5)!.usingColorSpace(.deviceRGB)!
        let blue = pixels.colorAt(x: 55, y: 5)!.usingColorSpace(.deviceRGB)!
        try require(red.redComponent > 0.9 && blue.blueComponent > 0.9, "Do not change image content while copying")
        try require(f.history.entries[0].kind == .image && f.history.preview(f.history.entries[0]) != nil,
                    "Image history must have a visible thumbnail")
        try f.history.copyImage(image())
        try require(f.history.entries.count == 1, "Identical copied images must deduplicate")
    }

    static func nativeMediaRepresentations() throws {
        let f = Fixture(); defer { f.clean() }
        let gif = try f.history.makeMediaURL(fileExtension: "gif")
        let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 2, nil)!
        let cg = image().cgImage(forProposedRect: nil, context: nil, hints: nil)!
        for _ in 0..<2 { CGImageDestinationAddImage(destination, cg, nil) }
        try require(CGImageDestinationFinalize(destination), "Create animated GIF fixture")
        try f.history.copyMedia(gif)
        let gifEntry = f.history.entries[0]
        let gifData = try Data(contentsOf: gif)
        try require(gifEntry.kind == .gif && f.board.data(forType: NSPasteboard.PasteboardType(UTType.gif.identifier)) == gifData,
                    "Publish actual GIF bytes, including animation")
        let urls = f.board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        try require(urls?.first == gif, "The system must recognize GIF as a native copied file")
        let movie = try f.history.makeMediaURL(fileExtension: "mp4")
        try Data("movie file reference fixture".utf8).write(to: movie)
        try f.history.copyMedia(movie)
        let movieURLs = f.board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        try require(movieURLs?.first == movie && f.history.entries[0].kind == .video,
                    "Publish MP4 using the native file clipboard")
        try f.history.copy(gifEntry)
        try require(ClipboardSnapshot.read(f.board)?.fileURLs == [gif], "History must re-copy the original GIF file")
    }

    static func retentionAndInFlightMedia() throws {
        let f = Fixture(); defer { f.clean() }
        let history = ClipboardHistory(directory: f.folder, pasteboard: f.board, preferences: f.defaults, limit: 1)
        let media = try history.makeMediaURL(fileExtension: "mp4")
        try Data("confirmed media fixture".utf8).write(to: media)
        try history.copyMedia(media)
        history.clear()
        try require(FileManager.default.fileExists(atPath: media.path), "Clearing history must keep the current clipboard file usable")
        let building = try history.makeMediaURL(fileExtension: "gif")
        try Data("unfinished media fixture".utf8).write(to: building)
        try history.copyText("next clipboard fixture")
        try require(!FileManager.default.fileExists(atPath: media.path), "Prune expired media after the clipboard releases it")
        try require(FileManager.default.fileExists(atPath: building.path), "Recording conversion output must survive history pruning")
        history.discardUnpublishedMedia(building)
        try require(!FileManager.default.fileExists(atPath: building.path), "Cancel must remove unpublished media")
        let external = f.folder.appendingPathComponent("user-file.txt")
        try Data("external file fixture".utf8).write(to: external)
        try ClipboardSnapshot.file(external).write(to: f.board)
        history.captureCurrent()
        history.clear()
        try require(FileManager.default.fileExists(atPath: external.path), "Never delete an original copied file")
    }

    static func concealedAndCorruptData() throws {
        let f = Fixture(); defer { f.clean() }
        try f.history.copyText("public fixture")
        let concealed = ClipboardSnapshot(items: [[NSPasteboard.PasteboardType.string.rawValue: Data("synthetic private fixture".utf8),
            "org.nspasteboard.ConcealedType": Data([1])]])
        try concealed.write(to: f.board)
        f.history.poll()
        try require(f.history.entries.count == 1 && f.history.entries[0].summary == "public fixture",
                    "Do not retain content marked concealed by its source")
        let corrupt = Data("not a clipboard history index".utf8)
        try corrupt.write(to: f.folder.appendingPathComponent("history.json"))
        let reopened = ClipboardHistory(directory: f.folder, pasteboard: f.board, preferences: f.defaults)
        try reopened.copyText("copying still works")
        let unchanged = try Data(contentsOf: f.folder.appendingPathComponent("history.json"))
        try require(unchanged == corrupt && f.board.string(forType: .string) == "copying still works",
                    "Preserve a corrupt index while keeping clipboard copy available")
    }

    static func missingFilesAndNavigation() throws {
        let f = Fixture(); defer { f.clean() }
        try f.history.copyText("First fixture")
        try f.history.copyText("Second fixture")
        f.history.prepareForDisplay()
        f.history.moveSelection(1)
        try require(f.history.entries[1].id == f.history.selectedID, "Keyboard navigation selects older content")
        f.history.search = "First"
        try require(f.history.filteredEntries.count == 1, "Search clipboard text")
        let file = f.folder.appendingPathComponent("missing.txt")
        try Data("file fixture".utf8).write(to: file)
        try ClipboardSnapshot.file(file).write(to: f.board)
        f.history.captureCurrent()
        let entry = f.history.entries[0]
        try FileManager.default.removeItem(at: file)
        try f.history.copyText("preserve current clipboard")
        var rejected = false
        do { try f.history.copy(entry) } catch ClipboardFailure.missing { rejected = true }
        try require(rejected && f.board.string(forType: .string) == "preserve current clipboard",
                    "A missing file must not replace the current clipboard")
    }

    static func main() {
        let unchanged = NSPasteboard.general.changeCount
        let checks: [(String, () throws -> Void)] = [
            ("rich_text_multiple_items_and_relaunch", richTextAndPersistence),
            ("image_pixels_thumbnail_and_deduplication", imageCopyAndPreview),
            ("native_gif_and_video_file_clipboard", nativeMediaRepresentations),
            ("current_and_in_flight_media_lifetime", retentionAndInFlightMedia),
            ("concealed_content_and_corrupt_index", concealedAndCorruptData),
            ("missing_file_preserves_clipboard_and_keyboard_navigation", missingFilesAndNavigation)
        ]
        var failures = 0
        for (name, run) in checks {
            do { try run(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error.localizedDescription)") }
        }
        if NSPasteboard.general.changeCount != unchanged { failures += 1; print("FAIL tests_changed_system_clipboard") }
        print("\(checks.count - failures)/\(checks.count) clipboard checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
