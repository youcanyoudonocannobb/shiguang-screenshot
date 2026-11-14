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

        BrandArtwork.drawAppIcon()

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
