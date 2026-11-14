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
        NSColor(srgbRed: 0.965, green: 0.965, blue: 0.952, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 924, height: 924), xRadius: 224, yRadius: 224).fill()
        NSColor(srgbRed: 0.145, green: 0.16, blue: 0.155, alpha: 1).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 58
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let a: CGFloat = 260
        let b: CGFloat = 764
        let length: CGFloat = 140
        for (x, y, dx, dy) in [(a, a, length, length), (b, a, -length, length),
                              (a, b, length, -length), (b, b, -length, -length)] {
            path.move(to: NSPoint(x: x, y: y + dy))
            path.line(to: NSPoint(x: x, y: y))
            path.line(to: NSPoint(x: x + dx, y: y))
        }
        path.stroke()
        NSColor(srgbRed: 0.69, green: 0.34, blue: 0.23, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 432, y: 432, width: 160, height: 160)).fill()
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
