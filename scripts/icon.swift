import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(size) / 1024)
        (transform as NSAffineTransform).concat()

        let outerRect = NSRect(x: 56, y: 56, width: 912, height: 912)
        let outerPath = NSBezierPath(roundedRect: outerRect, xRadius: 204, yRadius: 204)

        // Soft elevation shadow so the squircle reads clearly on light surfaces.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -18)
        shadow.shadowBlurRadius = 36
        shadow.shadowColor = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.09, alpha: 0.24)
        shadow.set()
        NSColor(srgbRed: 0.11, green: 0.13, blue: 0.12, alpha: 1).setFill()
        outerPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Deep warm-obsidian body gradient.
        let bodyGradient = NSGradient(starting: NSColor(srgbRed: 0.165, green: 0.188, blue: 0.180, alpha: 1),
                                      ending: NSColor(srgbRed: 0.090, green: 0.104, blue: 0.100, alpha: 1))!
        bodyGradient.draw(in: outerPath, angle: -90)

        // Subtle warm ambient glow in the center.
        NSGraphicsContext.saveGraphicsState()
        outerPath.addClip()
        let glowRect = NSRect(x: 212, y: 212, width: 600, height: 600)
        let glowPath = NSBezierPath(ovalIn: glowRect)
        let glowGradient = NSGradient(starting: NSColor(srgbRed: 0.72, green: 0.36, blue: 0.24, alpha: 0.16),
                                      ending: NSColor(srgbRed: 0.72, green: 0.36, blue: 0.24, alpha: 0.0))!
        glowGradient.draw(in: glowPath, relativeCenterPosition: .zero)
        NSGraphicsContext.restoreGraphicsState()

        // Fine outer rim highlight.
        let rimPath = NSBezierPath(roundedRect: outerRect.insetBy(dx: 2.5, dy: 2.5), xRadius: 201.5, yRadius: 201.5)
        rimPath.lineWidth = 3.5
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12).setStroke()
        rimPath.stroke()

        // Recessed inner viewfinder mat.
        let wellRect = NSRect(x: 156, y: 156, width: 712, height: 712)
        let wellPath = NSBezierPath(roundedRect: wellRect, xRadius: 148, yRadius: 148)
        NSColor(srgbRed: 0.070, green: 0.082, blue: 0.079, alpha: 0.62).setFill()
        wellPath.fill()
        wellPath.lineWidth = 2.5
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.065).setStroke()
        wellPath.stroke()

        // Subtle optical rule-of-thirds hairlines.
        let grid = NSBezierPath()
        grid.lineWidth = 2
        for offset in [396.0, 628.0] {
            grid.move(to: NSPoint(x: offset, y: 196))
            grid.line(to: NSPoint(x: offset, y: 828))
            grid.move(to: NSPoint(x: 196, y: offset))
            grid.line(to: NSPoint(x: 828, y: offset))
        }
        NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 0.05).setStroke()
        grid.stroke()

        // Warm-ivory precision viewfinder brackets with smooth corner arcs.
        NSColor(srgbRed: 0.965, green: 0.957, blue: 0.937, alpha: 1).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 38
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let a: CGFloat = 262
        let b: CGFloat = 762
        let arm: CGFloat = 132
        let cornerR: CGFloat = 34
        for (x, y, sx, sy) in [(a, a, 1.0, 1.0), (b, a, -1.0, 1.0),
                               (a, b, 1.0, -1.0), (b, b, -1.0, -1.0)] {
            let p1 = NSPoint(x: x, y: y + sy * arm)
            let pCorner = NSPoint(x: x, y: y)
            let p2 = NSPoint(x: x + sx * arm, y: y)
            path.move(to: p1)
            path.appendArc(from: pCorner, to: p2, radius: cornerR)
            path.line(to: p2)
        }
        path.stroke()

        // Focal ring + terracotta optical shutter core.
        let ringPath = NSBezierPath(ovalIn: NSRect(x: 416, y: 416, width: 192, height: 192))
        ringPath.lineWidth = 3.5
        NSColor(srgbRed: 0.965, green: 0.957, blue: 0.937, alpha: 0.16).setStroke()
        ringPath.stroke()

        let coreRect = NSRect(x: 454, y: 454, width: 116, height: 116)
        let corePath = NSBezierPath(ovalIn: coreRect)
        let coreGradient = NSGradient(starting: NSColor(srgbRed: 0.80, green: 0.42, blue: 0.29, alpha: 1),
                                      ending: NSColor(srgbRed: 0.64, green: 0.30, blue: 0.20, alpha: 1))!
        coreGradient.draw(in: corePath, angle: -90)

        let coreRim = NSBezierPath(ovalIn: coreRect.insetBy(dx: 1.5, dy: 1.5))
        coreRim.lineWidth = 2.5
        NSColor(srgbRed: 1, green: 0.95, blue: 0.92, alpha: 0.22).setStroke()
        coreRim.stroke()

        NSGraphicsContext.restoreGraphicsState()
        let data = bitmap.representation(using: .png, properties: [:])!
        let suffix = scale == 2 ? "@2x" : ""
        try data.write(to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

// ICNS accepts PNG-backed chunks; avoid platform-specific iconutil dependencies.
let entries = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png")
]
func header(_ type: String, length: Int) -> Data {
    var data = Data(type.utf8)
    var size = UInt32(length).bigEndian
    withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
    return data
}
var chunks = Data()
for (type, file) in entries {
    let png = try Data(contentsOf: directory.appendingPathComponent(file))
    chunks.append(header(type, length: png.count + 8))
    chunks.append(png)
}
var icon = header("icns", length: chunks.count + 8)
icon.append(chunks)
let destination = CommandLine.arguments.count > 2
    ? URL(fileURLWithPath: CommandLine.arguments[2])
    : directory.deletingPathExtension().appendingPathExtension("icns")
try icon.write(to: destination)
