import AppKit

enum BrandArtwork {
    static func menuBarImage(colorHex: String? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            let transform = AffineTransform(scaleByX: rect.width / 100, byY: rect.height / 100)
            (transform as NSAffineTransform).concat()
            if let colorHex {
                drawFilledMenuDog(base: color(hex: colorHex))
            } else {
                drawTemplateMenuDog()
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = colorHex == nil
        image.accessibilityDescription = "PawShot 小狗"
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
