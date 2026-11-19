import AppKit

enum FinderAppError: LocalizedError, Equatable {
    case unavailable

    var errorDescription: String? { L("找不到该应用，请在「超级右键」设置中重新添加。") }
}

/// An app the user added in Settings to open Finder items with.
struct FinderApp: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Where the app was when it was added.
    let url: URL
    let bundleIdentifier: String?

    init?(bundleAt location: URL) {
        let url = location.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        self.url = url
        bundleIdentifier = Bundle(url: url)?.bundleIdentifier
    }

    /// Where the app is now. An app that was moved, or replaced by an update
    /// elsewhere, is found again by its bundle identifier.
    func resolvedURL(locate: (String) -> URL? = {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
    }) -> URL? {
        if FileManager.default.fileExists(atPath: url.path) { return url }
        return bundleIdentifier.flatMap(locate)
    }

    /// The name Finder shows, such as 微信 for WeChat.app.
    var title: String {
        let location = resolvedURL() ?? url
        let name = (try? location.resourceValues(forKeys: [.localizedNameKey]))?.localizedName
            ?? location.deletingPathExtension().lastPathComponent
        return name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    var icon: NSImage { NSWorkspace.shared.icon(forFile: (resolvedURL() ?? url).path) }

    var menuEntry: FinderMenuApp { FinderMenuApp(id: id, title: title, icon: Self.menuIcon(from: icon)) }

    /// Adding the same app twice, even from another copy, keeps one entry.
    func isSameApp(as other: FinderApp) -> Bool {
        if let bundleIdentifier, bundleIdentifier == other.bundleIdentifier { return true }
        return url.path == other.url.path
    }

    /// The icon as Finder draws it in a menu: 16 pt, rendered at 2x.
    static func menuIcon(from image: NSImage) -> Data? {
        let side: CGFloat = 16
        guard let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side * 2), pixelsHigh: Int(side * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        // Set the point size first: the context takes its scale from it.
        pixels.size = NSSize(width: side, height: side)
        guard let context = NSGraphicsContext(bitmapImageRep: pixels) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return pixels.representation(using: .png, properties: [:])
    }
}
