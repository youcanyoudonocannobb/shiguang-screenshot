import AppKit

enum BrandArtwork {
    static func menuBarImage(tintHex: String? = nil,
                             customImageData: Data? = nil,
                             size: NSSize = NSSize(width: 20, height: 18)) -> NSImage {
        if let customImageData,
           let customImage = customMenuBarImage(data: customImageData, size: size) {
            return customImage
        }

        let tint = tintHex.map { color(hex: $0) }
        let background = tint?.blended(withFraction: 0.2, of: .black) ?? tint ?? .black
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            NSGraphicsContext.saveGraphicsState()
            // Isolate the badge so the template's cutout never erases the surface behind it.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            defer {
                context.endTransparencyLayer()
                NSGraphicsContext.restoreGraphicsState()
            }

            let side = min(rect.width, rect.height) * 8 / 9
            let badge = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            background.setFill()
            NSBezierPath(roundedRect: badge, xRadius: side / 4, yRadius: side / 4).fill()

            let markSide = side * 0.76
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX - markSide / 2, yBy: rect.midY - markSide / 2)
            transform.scale(by: markSide / 100)
            transform.concat()
            if tint == nil { context.setBlendMode(.clear) }
            drawMark(leading: .white, trailing: .white)
            return true
        }
        image.isTemplate = tintHex == nil
        image.accessibilityDescription = "NookPup"
        return image
    }

    static func normalizedMenuBarIconData(from data: Data) -> Data? {
        guard let image = NSImage(data: data), image.isValid, image.size.width > 0, image.size.height > 0 else {
            return nil
        }

        let side: CGFloat = 64
        let normalized = NSImage(size: NSSize(width: side, height: side))
        normalized.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        let scale = min(side / image.size.width, side / image.size.height)
        let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = NSRect(x: (side - drawSize.width) / 2,
                              y: (side - drawSize.height) / 2,
                              width: drawSize.width, height: drawSize.height)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
        normalized.unlockFocus()

        guard let tiff = normalized.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [:])
    }

    private static func customMenuBarImage(data: Data, size: NSSize) -> NSImage? {
        guard let source = NSImage(data: data), source.isValid,
              source.size.width > 0, source.size.height > 0 else { return nil }
        let image = NSImage(size: size, flipped: false) { rect in
            let available = rect.insetBy(dx: 1, dy: 1)
            let scale = min(available.width / source.size.width,
                            available.height / source.size.height)
            let size = NSSize(width: source.size.width * scale,
                              height: source.size.height * scale)
            let drawRect = NSRect(x: available.midX - size.width / 2,
                                  y: available.midY - size.height / 2,
                                  width: size.width, height: size.height)
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "NookPup"
        return image
    }

    private static func color(hex: String) -> NSColor {
        let value = UInt64(hex, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    static func drawAppIcon() {
        let tileRect = NSRect(x: 64, y: 64, width: 896, height: 896)
        let tile = NSBezierPath(roundedRect: tileRect, xRadius: 214, yRadius: 214)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(hex: "10252B").withAlphaComponent(0.26)
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.shadowBlurRadius = 26
        shadow.set()
        color(hex: "10252B").setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: color(hex: "35585D"), ending: color(hex: "10252B"))?
            .draw(in: tile, angle: -57)
        let rim = NSBezierPath(roundedRect: tileRect.insetBy(dx: 3, dy: 3),
                               xRadius: 211, yRadius: 211)
        rim.lineWidth = 3
        NSColor.white.withAlphaComponent(0.21).setStroke()
        rim.stroke()

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: 192, yBy: 192)
        transform.scale(by: 6.4)
        transform.concat()
        drawMark(leading: color(hex: "FFF5DD"), trailing: color(hex: "D7EE82"))
        NSGraphicsContext.restoreGraphicsState()
    }

    // The diagonal gap between the two halves stays open at menu bar size.
    private static func drawMark(leading: NSColor, trailing: NSColor) {
        let corner: [NSPoint] = [
            .init(x: 7, y: 11), .init(x: 7, y: 89), .init(x: 26, y: 89),
            .init(x: 53, y: 62), .init(x: 39, y: 48), .init(x: 26, y: 61), .init(x: 26, y: 11)
        ]
        for (rotated, ink) in [(false, leading), (true, trailing)] {
            let points = rotated ? corner.map { NSPoint(x: 100 - $0.x, y: 100 - $0.y) } : corner
            let piece = NSBezierPath()
            piece.move(to: points[0])
            for point in points.dropFirst() { piece.line(to: point) }
            piece.close()
            piece.lineJoinStyle = .round
            piece.lineWidth = 2.4
            ink.setFill()
            ink.setStroke()
            piece.fill()
            piece.stroke()
        }
    }
}
