import CoreGraphics
import Foundation

enum ScrollWindowPolicy {
    static func permits(bundleID: String?, layer: Int, alpha: Double = 1) -> Bool {
        let systemOverlays: Set<String> = [
            "com.apple.dock", "com.apple.windowmanager", "com.apple.windowserver",
            "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.notificationcenterui"
        ]
        return layer >= 0 && layer < Int(CGWindowLevelForKey(.statusWindow)) && alpha > 0.01 &&
            !systemOverlays.contains(bundleID?.lowercased() ?? "")
    }
}

enum ScrollStitchError: LocalizedError {
    case invalidImage, changedSize, limit, noImage, noProgress, targetUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取长截图画面。"
        case .changedSize: return "截图区域尺寸已变化，请重新开始长截图。"
        case .limit: return "已达到长截图尺寸上限，已保留当前内容。"
        case .noImage: return "还没有可用的截图画面。"
        case .noProgress: return "尚未拼接到新的内容。请框选窗口里的滚动正文，缓慢向下滚动，避开固定工具栏后重试。"
        case .targetUnavailable: return "没有找到选区下的滚动窗口。请先打开需要截取的窗口，再框选正文区域。"
        }
    }
}

enum ScrollAppendResult: Equatable {
    case first, appended(Int), unchanged, backwards, noOverlap
}

struct ScrollFrameSample {
    let width = 256
    let height: Int
    let pixels: [UInt8]
    let contrast: [Int]
    let background: [Int]

    init(_ image: CGImage) throws {
        height = image.height
        guard height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { throw ScrollStitchError.invalidImage }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height))
        pixels = bytes
        var contrastValues = [Int](repeating: 0, count: height)
        var backgrounds = [Int](repeating: 255, count: height)
        for row in 0..<height {
            var minValue = 255, maxValue = 0, total = 0
            for column in stride(from: 2, to: width - 2, by: 2) {
                let value = Int(bytes[row * width + column])
                minValue = min(minValue, value)
                maxValue = max(maxValue, value)
                total += value
            }
            contrastValues[row] = maxValue - minValue
            backgrounds[row] = total / ((width - 4) / 2) > (minValue + maxValue) / 2 ? maxValue : minValue
        }
        contrast = contrastValues
        background = backgrounds
    }

    func distance(to other: Self) -> Double {
        guard height == other.height else { return .infinity }
        var error = 0, count = 0
        for row in stride(from: 0, to: height, by: max(1, height / 400)) {
            for column in stride(from: 2, to: width - 2, by: 2) {
                let lhs = Int(pixels[row * width + column]), rhs = Int(other.pixels[row * width + column])
                if abs(lhs - background[row]) < 10 && abs(rhs - other.background[row]) < 10 { continue }
                error += abs(lhs - rhs)
                count += 1
            }
        }
        return Double(error) / Double(max(1, count))
    }

    func displacement(to next: Self) -> Int? {
        guard height == next.height else { return nil }
        let maximum = height * 85 / 100
        guard maximum >= 4 else { return nil }
        let minimumRun = max(40, height / 8)
        // A pinned footer retraces itself in every frame, so it must not be read as overlap.
        let footer = fixedFooter(comparedTo: next)

        func rowError(oldRow: Int, newRow: Int) -> Double {
            var error = 0, count = 0
            for column in stride(from: 2, to: width - 2, by: 2) {
                let lhs = Int(pixels[oldRow * width + column])
                let rhs = Int(next.pixels[newRow * width + column])
                if abs(lhs - background[oldRow]) < 10 && abs(rhs - next.background[newRow]) < 10 { continue }
                error += min(100, abs(lhs - rhs))
                count += 1
            }
            // Featureless rows carry no signal, so treat them as matching and rely on `textured`.
            // Any real difference, even a couple of glyph pixels, must not be diluted away.
            return count > 0 ? Double(error) / Double(count) : 0
        }

        // For a downward scroll the new frame's top rows retrace the old frame's bottom rows.
        // Walking back from the bottom keeps this linear for mismatching shifts and immune to
        // periodic page backgrounds that made the previous mean-error search jump a whole band.
        func trailingRun(_ shift: Int) -> (rows: Int, textured: Int) {
            let overlap = height - shift - footer
            guard overlap >= minimumRun else { return (0, 0) }
            var rows = 0, textured = 0, gaps = 0
            var row = overlap - 1
            while row >= 0 {
                if rowError(oldRow: shift + row, newRow: row) < 4 {
                    rows += 1
                    gaps = 0
                    if contrast[shift + row] >= 10 || next.contrast[row] >= 10 { textured += 1 }
                } else {
                    gaps += 1
                    if gaps > 2 { break }
                }
                row -= 1
            }
            return (rows, textured)
        }

        var best: (shift: Int, rows: Int, textured: Int)?
        var runnerUp = 0
        for shift in 2...maximum {
            let run = trailingRun(shift)
            guard run.rows >= minimumRun, run.textured >= 8 else { continue }
            if let current = best {
                if run.rows > current.rows {
                    if abs(shift - current.shift) > 8 { runnerUp = max(runnerUp, current.rows) }
                    best = (shift, run.rows, run.textured)
                } else if abs(shift - current.shift) > 8 {
                    runnerUp = max(runnerUp, run.rows)
                }
            } else {
                best = (shift, run.rows, run.textured)
            }
        }
        guard let best else { return nil }
        // A second equally long overlap means the content repeats and any pick could drop rows.
        if runnerUp > 0 && Double(runnerUp) > Double(best.rows) * 0.8 { return nil }
        return best.shift
    }

    func fixedFooter(comparedTo next: Self) -> Int {
        var rows = 0, textured = 0
        for row in stride(from: height - 1, through: height * 4 / 5, by: -1) {
            let error = stride(from: 2, to: width - 2, by: 2).reduce(0) {
                $0 + abs(Int(pixels[row * width + $1]) - Int(next.pixels[row * width + $1]))
            }
            if error > 126 { break }
            rows += 1
            if contrast[row] > 20 { textured += 1 }
        }
        return rows >= 8 && textured >= 4 && rows < height / 5 ? rows : 0
    }
}

struct ScrollStitcher {
    var maximumPixels = 32_000_000
    var maximumHeight = 30_000
    private(set) var width = 0
    private(set) var height = 0
    private(set) var frameCount = 0
    private var strips: [CGImage] = []
    private var lastFrame: CGImage?
    private var lastSample: ScrollFrameSample?
    private var footerHeight = 0
    private var footer: CGImage?

    mutating func append(_ image: CGImage) throws -> ScrollAppendResult {
        guard image.width > 0, image.height > 0 else { throw ScrollStitchError.invalidImage }
        let sample = try ScrollFrameSample(image)
        guard let previous = lastSample, let lastFrame else {
            guard image.height <= maximumHeight, image.width * image.height <= maximumPixels else {
                throw ScrollStitchError.limit
            }
            width = image.width
            height = image.height
            frameCount = 1
            strips = [image]
            self.lastFrame = image
            lastSample = sample
            return .first
        }
        guard image.width == width, image.height == lastFrame.height else { throw ScrollStitchError.changedSize }
        if previous.distance(to: sample) < 0.8 { return .unchanged }
        guard let shift = previous.displacement(to: sample) else {
            if sample.displacement(to: previous) != nil { return .backwards }
            return .noOverlap
        }
        guard shift > 0 else { return .backwards }
        guard height + shift <= maximumHeight, width * (height + shift) <= maximumPixels else {
            throw ScrollStitchError.limit
        }
        if frameCount == 1 {
            footerHeight = previous.fixedFooter(comparedTo: sample)
            if footerHeight > 0 {
                strips = [try copyRows(lastFrame, start: 0, count: lastFrame.height - footerHeight)]
            }
        }
        let start = image.height - footerHeight - shift
        guard start >= 0 else { return .noOverlap }
        strips.append(try copyRows(image, start: start, count: shift))
        if footerHeight > 0 {
            footer = try copyRows(image, start: image.height - footerHeight, count: footerHeight)
        }
        height += shift
        frameCount += 1
        self.lastFrame = image
        lastSample = sample
        return .appended(shift)
    }

    func result() throws -> CGImage {
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScrollStitchError.noImage
        }
        var top = 0
        for strip in strips + (footer.map { [$0] } ?? []) {
            context.draw(strip, in: CGRect(x: 0, y: height - top - strip.height, width: width, height: strip.height))
            top += strip.height
        }
        guard top == height, let image = context.makeImage() else { throw ScrollStitchError.invalidImage }
        return image
    }

    private func copyRows(_ image: CGImage, start: Int, count: Int) throws -> CGImage {
        guard let cropped = image.cropping(to: CGRect(x: 0, y: start, width: image.width, height: count)),
              let context = CGContext(data: nil, width: image.width, height: count, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScrollStitchError.invalidImage
        }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: image.width, height: count))
        guard let result = context.makeImage() else { throw ScrollStitchError.invalidImage }
        return result
    }
}

actor ScrollCaptureAssembler {
    private var stitcher = ScrollStitcher()
    func append(_ image: CGImage) throws -> (ScrollAppendResult, Int, Int, Int) {
        let result = try stitcher.append(image)
        return (result, stitcher.width, stitcher.height, stitcher.frameCount)
    }

    func preview(width: Int = 232) throws -> CGImage {
        let full = try stitcher.result()
        let height = max(1, Int(Double(full.height) * Double(width) / Double(full.width)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScrollStitchError.invalidImage
        }
        context.interpolationQuality = .medium
        context.draw(full, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw ScrollStitchError.invalidImage }
        return image
    }

    func result() throws -> CGImage {
        guard stitcher.frameCount > 1 else { throw ScrollStitchError.noProgress }
        return try stitcher.result()
    }
}
