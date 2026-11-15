import AppKit

enum BrandArtwork {
    private enum MenuBarArtworkStyle: String {
        case system, lake, coral, teal, amber, cat, rabbit, fox, panda, custom

        var title: String {
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

    static func menuBarImage(styleID: String,
                             customImageData: Data? = nil) -> NSImage {
        var style = MenuBarArtworkStyle(rawValue: styleID) ?? .system
        if style == .custom {
            if let customImageData,
               let customImage = customMenuBarImage(data: customImageData) {
                return customImage
            }
            style = .system
        }

        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let transform = AffineTransform(scaleByX: rect.width / 100, byY: rect.height / 100)
            (transform as NSAffineTransform).concat()
            switch style {
            case .system:
                drawTemplateMenuDog()
            case .lake, .coral, .teal, .amber:
                drawFilledMenuDog(base: color(hex: style.colorHex ?? "17698B"))
            case .cat:
                drawMenuCat()
            case .rabbit:
                drawMenuRabbit()
            case .fox:
                drawMenuFox()
            case .panda:
                drawMenuPanda()
            case .custom:
                drawTemplateMenuDog()
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = style == .system
        image.accessibilityDescription = "PawShot \(style.title)"
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

    private static func customMenuBarImage(data: Data) -> NSImage? {
        guard let source = NSImage(data: data), source.isValid,
              source.size.width > 0, source.size.height > 0 else { return nil }
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
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
        image.accessibilityDescription = "PawShot 自定义图标"
        return image
    }

    private static func color(hex: String) -> NSColor {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: 1)
    }

    static func drawAppIcon() {
        let tile = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904),
                                xRadius: 208, yRadius: 208)
        NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.48, blue: 0.65, alpha: 1),
                   ending: NSColor(srgbRed: 0.055, green: 0.31, blue: 0.45, alpha: 1))!
            .draw(in: tile, angle: -90)
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(translationByX: 152, byY: 166)
        (transform as NSAffineTransform).concat()
        (AffineTransform(scaleByX: 7.2, byY: 7.2) as NSAffineTransform).concat()
        drawDog(template: false)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func dogFacePath() -> NSBezierPath {
        let face = NSBezierPath()
        face.move(to: NSPoint(x: 25, y: 68))
        face.curve(to: NSPoint(x: 50, y: 87), controlPoint1: NSPoint(x: 25, y: 82),
                   controlPoint2: NSPoint(x: 36, y: 87))
        face.curve(to: NSPoint(x: 75, y: 68), controlPoint1: NSPoint(x: 64, y: 87),
                   controlPoint2: NSPoint(x: 75, y: 82))
        face.line(to: NSPoint(x: 79, y: 40))
        face.curve(to: NSPoint(x: 50, y: 13), controlPoint1: NSPoint(x: 80, y: 20),
                   controlPoint2: NSPoint(x: 66, y: 13))
        face.curve(to: NSPoint(x: 21, y: 40), controlPoint1: NSPoint(x: 34, y: 13),
                   controlPoint2: NSPoint(x: 20, y: 20))
        face.close()
        return face
    }

    private static func drawEars(color: NSColor) {
        for mirrored in [false, true] {
            NSGraphicsContext.saveGraphicsState()
            if mirrored {
                var reflection = AffineTransform()
                reflection.translate(x: 100, y: 0)
                reflection.scale(x: -1, y: 1)
                (reflection as NSAffineTransform).concat()
            }
            let ear = NSBezierPath()
            ear.move(to: NSPoint(x: 29, y: 80))
            ear.curve(to: NSPoint(x: 7, y: 49), controlPoint1: NSPoint(x: 12, y: 82),
                      controlPoint2: NSPoint(x: 3, y: 66))
            ear.curve(to: NSPoint(x: 18, y: 36), controlPoint1: NSPoint(x: 9, y: 38),
                      controlPoint2: NSPoint(x: 12, y: 33))
            ear.curve(to: NSPoint(x: 29, y: 80), controlPoint1: NSPoint(x: 29, y: 39),
                      controlPoint2: NSPoint(x: 35, y: 69))
            ear.close()
            color.setFill()
            ear.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func drawFilledMenuDog(base: NSColor) {
        let ear = base.blended(withFraction: 0.28, of: .black) ?? base
        let muzzle = base.blended(withFraction: 0.86, of: .white) ?? .white
        let eye = NSColor(srgbRed: 0.99, green: 0.98, blue: 0.93, alpha: 1)
        let features = NSColor(srgbRed: 0.055, green: 0.16, blue: 0.22, alpha: 1)

        base.setFill()
        dogFacePath().fill()
        drawEars(color: ear)

        muzzle.setFill()
        NSBezierPath(ovalIn: NSRect(x: 31, y: 20, width: 38, height: 27)).fill()
        eye.setFill()
        for horizontal in [34.0, 58.0] {
            NSBezierPath(ovalIn: NSRect(x: horizontal, y: 53, width: 7, height: 9)).fill()
        }
        features.setFill()
        dogNosePath().fill()
        let smile = dogSmilePath()
        smile.lineWidth = 2.4
        smile.lineCapStyle = .round
        features.setStroke()
        smile.stroke()
    }

    private static func drawTemplateMenuDog() {
        NSColor.black.setFill()
        dogFacePath().fill()
        drawEars(color: .black)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
        for horizontal in [34.0, 58.0] {
            NSBezierPath(ovalIn: NSRect(x: horizontal, y: 53, width: 7, height: 9)).fill()
        }
        dogNosePath().fill()
        let smile = dogSmilePath()
        smile.lineWidth = 2.4
        smile.lineCapStyle = .round
        smile.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawMenuCat() {
        let base = color(hex: "C97845")
        let innerEar = color(hex: "F0B5A7")
        let muzzle = color(hex: "F7DFCE")
        let features = color(hex: "172A38")

        for mirrored in [false, true] {
            NSGraphicsContext.saveGraphicsState()
            if mirrored {
                var reflection = AffineTransform()
                reflection.translate(x: 100, y: 0)
                reflection.scale(x: -1, y: 1)
                (reflection as NSAffineTransform).concat()
            }
            let ear = NSBezierPath()
            ear.move(to: NSPoint(x: 22, y: 66))
            ear.line(to: NSPoint(x: 27, y: 92))
            ear.line(to: NSPoint(x: 46, y: 72))
            ear.close()
            base.setFill()
            ear.fill()
            let inner = NSBezierPath()
            inner.move(to: NSPoint(x: 28, y: 70))
            inner.line(to: NSPoint(x: 30, y: 84))
            inner.line(to: NSPoint(x: 40, y: 72))
            inner.close()
            innerEar.setFill()
            inner.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        base.setFill()
        NSBezierPath(ovalIn: NSRect(x: 23, y: 14, width: 54, height: 64)).fill()
        muzzle.setFill()
        NSBezierPath(ovalIn: NSRect(x: 31, y: 19, width: 38, height: 27)).fill()

        features.setFill()
        for horizontal in [34.0, 59.0] {
            NSBezierPath(ovalIn: NSRect(x: horizontal, y: 52, width: 7, height: 10)).fill()
        }
        let nose = NSBezierPath()
        nose.move(to: NSPoint(x: 45, y: 37))
        nose.line(to: NSPoint(x: 55, y: 37))
        nose.line(to: NSPoint(x: 50, y: 31))
        nose.close()
        nose.fill()

        let mouth = NSBezierPath()
        mouth.move(to: NSPoint(x: 50, y: 31))
        mouth.line(to: NSPoint(x: 50, y: 26))
        mouth.move(to: NSPoint(x: 50, y: 26))
        mouth.curve(to: NSPoint(x: 43, y: 24), controlPoint1: NSPoint(x: 48, y: 23),
                    controlPoint2: NSPoint(x: 45, y: 23))
        mouth.move(to: NSPoint(x: 50, y: 26))
        mouth.curve(to: NSPoint(x: 57, y: 24), controlPoint1: NSPoint(x: 52, y: 23),
                    controlPoint2: NSPoint(x: 55, y: 23))
        mouth.lineWidth = 1.6
        mouth.lineCapStyle = .round
        features.setStroke()
        mouth.stroke()
    }

    private static func drawMenuRabbit() {
        let base = color(hex: "D8CFD3")
        let innerEar = color(hex: "C88D9C")
        let muzzle = color(hex: "FAF3F4")
        let features = color(hex: "29363F")

        for x in [28.0, 58.0] {
            base.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: 53, width: 14, height: 43)).fill()
            innerEar.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 3, y: 58, width: 8, height: 31)).fill()
        }

        base.setFill()
        NSBezierPath(ovalIn: NSRect(x: 21, y: 8, width: 58, height: 66)).fill()
        muzzle.setFill()
        NSBezierPath(ovalIn: NSRect(x: 29, y: 17, width: 42, height: 31)).fill()

        features.setFill()
        for horizontal in [33.0, 59.0] {
            NSBezierPath(ovalIn: NSRect(x: horizontal, y: 48, width: 8, height: 10)).fill()
        }
        NSBezierPath(ovalIn: NSRect(x: 45, y: 33, width: 10, height: 7)).fill()
        let mouth = NSBezierPath()
        mouth.move(to: NSPoint(x: 50, y: 33))
        mouth.line(to: NSPoint(x: 50, y: 28))
        mouth.move(to: NSPoint(x: 50, y: 28))
        mouth.line(to: NSPoint(x: 44, y: 25))
        mouth.move(to: NSPoint(x: 50, y: 28))
        mouth.line(to: NSPoint(x: 56, y: 25))
        mouth.lineWidth = 1.6
        mouth.lineCapStyle = .round
        features.setStroke()
        mouth.stroke()
    }

    private static func drawMenuFox() {
        let base = color(hex: "D56A32")
        let innerEar = color(hex: "7D3C2D")
        let muzzle = color(hex: "FFF0DF")
        let features = color(hex: "1E2B33")

        for mirrored in [false, true] {
            NSGraphicsContext.saveGraphicsState()
            if mirrored {
                var reflection = AffineTransform()
                reflection.translate(x: 100, y: 0)
                reflection.scale(x: -1, y: 1)
                (reflection as NSAffineTransform).concat()
            }
            let ear = NSBezierPath()
            ear.move(to: NSPoint(x: 18, y: 61))
            ear.line(to: NSPoint(x: 28, y: 94))
            ear.line(to: NSPoint(x: 47, y: 72))
            ear.close()
            base.setFill()
            ear.fill()
            innerEar.setFill()
            let inner = NSBezierPath()
            inner.move(to: NSPoint(x: 25, y: 67))
            inner.line(to: NSPoint(x: 29, y: 84))
            inner.line(to: NSPoint(x: 39, y: 72))
            inner.close()
            inner.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        let face = NSBezierPath()
        face.move(to: NSPoint(x: 50, y: 88))
        face.curve(to: NSPoint(x: 23, y: 63), controlPoint1: NSPoint(x: 37, y: 86),
                   controlPoint2: NSPoint(x: 27, y: 75))
        face.curve(to: NSPoint(x: 29, y: 31), controlPoint1: NSPoint(x: 19, y: 49),
                   controlPoint2: NSPoint(x: 23, y: 38))
        face.line(to: NSPoint(x: 50, y: 13))
        face.line(to: NSPoint(x: 71, y: 31))
        face.curve(to: NSPoint(x: 77, y: 63), controlPoint1: NSPoint(x: 77, y: 38),
                   controlPoint2: NSPoint(x: 81, y: 49))
        face.curve(to: NSPoint(x: 50, y: 88), controlPoint1: NSPoint(x: 73, y: 75),
                   controlPoint2: NSPoint(x: 63, y: 86))
        face.close()
        base.setFill()
        face.fill()

        muzzle.setFill()
        let leftCheek = NSBezierPath()
        leftCheek.move(to: NSPoint(x: 50, y: 14))
        leftCheek.curve(to: NSPoint(x: 28, y: 35), controlPoint1: NSPoint(x: 38, y: 17),
                        controlPoint2: NSPoint(x: 30, y: 26))
        leftCheek.curve(to: NSPoint(x: 50, y: 42), controlPoint1: NSPoint(x: 35, y: 42),
                        controlPoint2: NSPoint(x: 43, y: 45))
        leftCheek.close()
        leftCheek.fill()
        let rightCheek = NSBezierPath()
        rightCheek.move(to: NSPoint(x: 50, y: 14))
        rightCheek.curve(to: NSPoint(x: 72, y: 35), controlPoint1: NSPoint(x: 62, y: 17),
                         controlPoint2: NSPoint(x: 70, y: 26))
        rightCheek.curve(to: NSPoint(x: 50, y: 42), controlPoint1: NSPoint(x: 65, y: 42),
                         controlPoint2: NSPoint(x: 57, y: 45))
        rightCheek.close()
        rightCheek.fill()

        features.setFill()
        for horizontal in [31.0, 61.0] {
            NSBezierPath(ovalIn: NSRect(x: horizontal, y: 51, width: 8, height: 10)).fill()
        }
        NSBezierPath(ovalIn: NSRect(x: 44, y: 29, width: 12, height: 8)).fill()
    }

    private static func drawMenuPanda() {
        let base = color(hex: "F4F2E9")
        let dark = color(hex: "26333B")
        let eye = NSColor.white

        dark.setFill()
        NSBezierPath(ovalIn: NSRect(x: 14, y: 66, width: 28, height: 27)).fill()
        NSBezierPath(ovalIn: NSRect(x: 58, y: 66, width: 28, height: 27)).fill()
        base.setFill()
        NSBezierPath(ovalIn: NSRect(x: 19, y: 8, width: 62, height: 69)).fill()

        dark.setFill()
        NSBezierPath(ovalIn: NSRect(x: 27, y: 42, width: 19, height: 25)).fill()
        NSBezierPath(ovalIn: NSRect(x: 54, y: 42, width: 19, height: 25)).fill()
        eye.setFill()
        for horizontal in [34.0, 60.0] {
            NSBezierPath(ovalIn: NSRect(x: horizontal, y: 51, width: 6, height: 8)).fill()
        }
        dark.setFill()
        NSBezierPath(ovalIn: NSRect(x: 44, y: 30, width: 12, height: 8)).fill()
        let smile = NSBezierPath()
        smile.move(to: NSPoint(x: 40, y: 24))
        smile.curve(to: NSPoint(x: 50, y: 22), controlPoint1: NSPoint(x: 44, y: 19),
                    controlPoint2: NSPoint(x: 47, y: 19))
        smile.curve(to: NSPoint(x: 60, y: 24), controlPoint1: NSPoint(x: 53, y: 19),
                    controlPoint2: NSPoint(x: 56, y: 19))
        smile.lineWidth = 1.8
        smile.lineCapStyle = .round
        dark.setStroke()
        smile.stroke()
    }

    private static func dogNosePath() -> NSBezierPath {
        let nose = NSBezierPath()
        nose.move(to: NSPoint(x: 43, y: 40))
        nose.curve(to: NSPoint(x: 57, y: 40), controlPoint1: NSPoint(x: 43, y: 45),
                   controlPoint2: NSPoint(x: 57, y: 45))
        nose.curve(to: NSPoint(x: 50, y: 33), controlPoint1: NSPoint(x: 57, y: 36),
                   controlPoint2: NSPoint(x: 53, y: 33))
        nose.curve(to: NSPoint(x: 43, y: 40), controlPoint1: NSPoint(x: 47, y: 33),
                   controlPoint2: NSPoint(x: 43, y: 36))
        nose.close()
        return nose
    }

    private static func dogSmilePath() -> NSBezierPath {
        let smile = NSBezierPath()
        smile.move(to: NSPoint(x: 43, y: 28))
        smile.curve(to: NSPoint(x: 57, y: 28), controlPoint1: NSPoint(x: 47, y: 23),
                    controlPoint2: NSPoint(x: 53, y: 23))
        return smile
    }

    private static func drawDog(template: Bool) {
        let dark = template ? NSColor.black : NSColor(srgbRed: 0.055, green: 0.19, blue: 0.27, alpha: 1)
        let face = dogFacePath()
        if template {
            dark.setStroke()
            face.lineWidth = 5.5
            face.stroke()
        } else {
            NSColor(srgbRed: 0.99, green: 0.98, blue: 0.93, alpha: 1).setFill()
            face.fill()
        }

        drawEars(color: dark)

        if !template {
            NSColor(srgbRed: 0.90, green: 0.94, blue: 0.94, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 32, y: 21, width: 36, height: 26)).fill()
        }
        dark.setFill()
        for horizontal in [35.0, 59.0] {
            NSBezierPath(ovalIn: NSRect(x: horizontal, y: 53, width: 6, height: 8)).fill()
        }
        dogNosePath().fill()
        if !template {
            let smile = dogSmilePath()
            smile.lineWidth = 2.5
            smile.lineCapStyle = .round
            dark.setStroke()
            smile.stroke()
        }
    }
}
