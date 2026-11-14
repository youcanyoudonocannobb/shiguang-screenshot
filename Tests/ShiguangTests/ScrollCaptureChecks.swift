import AppKit
import CoreText

private struct CheckFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw CheckFailure(message: message) }
}

@main
struct ScrollCaptureChecks {
    static func document(width: Int = 240, height: Int = 2400) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let value = (row / 3 &* 1664525 &+ column / 5 &* 1013904223) ^ (row &* 104729 &+ column &* 31)
                let offset = (row * width + column) * 4
                bytes[offset] = UInt8(truncatingIfNeeded: value >> 6)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 9)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 13)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func frame(_ document: CGImage, offset: Int, height: Int = 400) -> CGImage {
        document.cropping(to: CGRect(x: 0, y: offset, width: document.width, height: height))!
    }

    static func pixels(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }

    static func exactComposition() throws {
        let source = document()
        var stitcher = ScrollStitcher()
        for offset in [0, 73, 181, 330, 459] {
            let result = try stitcher.append(frame(source, offset: offset))
            if offset > 0 { try require(result != .noOverlap, "Valid overlapping frames rejected at \(offset)") }
        }
        let result = try stitcher.result()
        try require(result.height == 859 && result.width == source.width, "Append only new rows")
        try require(pixels(result) == pixels(frame(source, offset: 0, height: 859)),
                    "Stitched output must exactly match source pixels without missing or duplicated rows")
    }

    static func duplicateAndReverse() throws {
        let source = document()
        var stitcher = ScrollStitcher()
        _ = try stitcher.append(frame(source, offset: 0))
        _ = try stitcher.append(frame(source, offset: 150))
        let duplicate = try stitcher.append(frame(source, offset: 150))
        try require(duplicate == .unchanged && stitcher.height == 550, "Bottom of page must not append duplicates")
        let reverse = try stitcher.append(frame(source, offset: 80))
        try require(reverse == .backwards && stitcher.height == 550, "Scrolling upward must not corrupt the image")
        _ = try stitcher.append(frame(source, offset: 230))
        let output = try stitcher.result()
        try require(pixels(output) == pixels(frame(source, offset: 0, height: 630)), "Resume after backtracking")
    }

    static func gapAndRecovery() throws {
        let source = document()
        var stitcher = ScrollStitcher()
        _ = try stitcher.append(frame(source, offset: 0))
        let gap = try stitcher.append(frame(source, offset: 800))
        try require(gap == .noOverlap && stitcher.height == 400, "Reject pages without overlap")
        _ = try stitcher.append(frame(source, offset: 150))
        try require(stitcher.height == 550, "Keep the last matched frame for manual recovery")
    }

    static func allNoOverlapStillReturnsCurrentFrame() throws {
        let source = document()
        var stitcher = ScrollStitcher()
        _ = try stitcher.append(frame(source, offset: 0))
        let result = try stitcher.append(frame(source, offset: 800))
        try require(result == .noOverlap, "Disjoint frames must be reported without corrupting output")
    }

    static func fixedFooter() throws {
        let source = document()
        let decoration = frame(document(width: source.width, height: 24), offset: 0, height: 24)
        func decorated(_ image: CGImage) -> CGImage {
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(decoration, in: CGRect(x: 0, y: 0, width: image.width, height: 24))
            return context.makeImage()!
        }
        var stitcher = ScrollStitcher()
        _ = try stitcher.append(decorated(frame(source, offset: 0)))
        _ = try stitcher.append(decorated(frame(source, offset: 130)))
        _ = try stitcher.append(decorated(frame(source, offset: 260)))
        let output = try stitcher.result()
        try require(pixels(output) == pixels(decorated(frame(source, offset: 0, height: 660))),
                    "A fixed footer must appear once, at the final bottom")
    }

    static func limitsAndResize() throws {
        let source = document()
        var stitcher = ScrollStitcher(maximumPixels: 240 * 500, maximumHeight: 500)
        _ = try stitcher.append(frame(source, offset: 0))
        var limited = false
        do { _ = try stitcher.append(frame(source, offset: 200)) } catch ScrollStitchError.limit { limited = true }
        try require(limited && stitcher.height == 400, "Memory limit must preserve partial output")
        var resized = false
        do { _ = try stitcher.append(frame(source, offset: 0, height: 300)) } catch ScrollStitchError.changedSize { resized = true }
        try require(resized, "Display resize must not stitch incompatible frames")
    }

    static func textDocument(edgeOnly: Bool = false) -> CGImage {
        let width = 800, height = 3600
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for row in 0..<90 {
            let string = edgeOnly ? String(format: "%03d", row) :
                String(format: "%03d | %06d | Capture every unique row exactly once.", row, row * row)
            let text = NSAttributedString(string: string, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .regular),
                .foregroundColor: NSColor.black
            ])
            context.textPosition = CGPoint(x: 6, y: height - 30 - row * 40)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        return context.makeImage()!
    }

    static func sparseText() throws {
        for edgeOnly in [false, true] {
            let source = textDocument(edgeOnly: edgeOnly)
            var stitcher = ScrollStitcher()
            var previous = 0
            for offset in [0, 97, 211, 389, 543] {
                let result = try stitcher.append(frame(source, offset: offset, height: 600))
                try require(result == (offset == 0 ? .first : .appended(offset - previous)),
                            "Sparse text must match the actual displacement, including line numbers at the left edge: \(result)")
                previous = offset
            }
            let output = try stitcher.result()
            try require(pixels(output) == pixels(frame(source, offset: 0, height: 1143)),
                        "Repeated text lines must not lose or duplicate rows")
        }
    }

    // Mirrors a Retina capture of a text window: 2x glyphs, alternating row bands and
    // unique line numbers at the left edge, which used to fool the matcher into a
    // periodic alignment and silently drop a band of rows.
    static func retinaTextDocument() -> CGImage {
        let width = 1040, height = 9000, rowHeight = 81
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for row in 0..<(height / rowHeight) {
            if row % 2 == 1 {
                context.setFillColor(CGColor(gray: 0.965, alpha: 1))
                context.fill(CGRect(x: 0, y: height - (row + 1) * rowHeight, width: width, height: rowHeight))
            }
            let string = String(format: "%03d | %06d | Capture each unique row exactly once.", row, row * row)
            let text = NSAttributedString(string: string, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 36, weight: .regular),
                .foregroundColor: NSColor.black
            ])
            context.textPosition = CGPoint(x: 10, y: height - 60 - row * rowHeight)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        return context.makeImage()!
    }

    static func retinaTextKeepsRowsAndRejectsLostOverlap() throws {
        let source = retinaTextDocument()
        var stitcher = ScrollStitcher()
        for (index, offset) in [0, 300, 600, 900].enumerated() {
            let result = try stitcher.append(frame(source, offset: offset, height: 890))
            if index == 0 { try require(result == .first, "First frame must start the stitch") }
            else { try require(result == .appended(300), "Retina text must match a 300px scroll, got \(result)") }
        }
        let output = try stitcher.result()
        try require(pixels(output) == pixels(frame(source, offset: 0, height: 1790)),
                    "A stitched Retina text page must keep every row in order")
        for offset in [1650, 1700, 1750] {
            var lost = ScrollStitcher()
            _ = try lost.append(frame(source, offset: 0, height: 890))
            let result = try lost.append(frame(source, offset: offset, height: 890))
            try require(result == .noOverlap && lost.height == 890,
                        "A scroll that loses all overlap must be rejected instead of shifting by a page period (offset \(offset), got \(result))")
        }
    }

    static func accumulatedPreviewAndNoProgress() async throws {
        let source = textDocument()
        let assembler = ScrollCaptureAssembler()
        _ = try await assembler.append(frame(source, offset: 0, height: 600))
        var rejected = false
        do { _ = try await assembler.result() }
        catch ScrollStitchError.noProgress { rejected = true }
        try require(rejected, "A single frame must not be reported as a successful long screenshot")
        _ = try await assembler.append(frame(source, offset: 211, height: 600))
        let preview = try await assembler.preview(width: 200)
        let full = try await assembler.result()
        try require(full.height == 811 && preview.height == 202,
                    "Preview must contain the accumulated long image rather than the latest frame")
        let previewPixels = [UInt8](pixels(preview))
        try require(stride(from: 3, to: previewPixels.count, by: 4).allSatisfy { previewPixels[$0] == 255 } &&
                    stride(from: 0, to: previewPixels.count, by: 4).contains { previewPixels[$0] < 180 },
                    "Accumulated preview must have visible, opaque text pixels")
    }

    static func systemOverlaysCannotBeCaptureTargets() throws {
        for bundle in ["com.apple.dock", "com.apple.WindowManager", "com.apple.systemuiserver"] {
            try require(!ScrollWindowPolicy.permits(bundleID: bundle, layer: 0),
                        "Transparent system overlays must not replace the intended scrolling window")
        }
        try require(ScrollWindowPolicy.permits(bundleID: "com.apple.TextEdit", layer: 0) &&
                    ScrollWindowPolicy.permits(bundleID: "local.shiguang.scrollfixture", layer: 3),
                    "Normal and floating document windows must be capturable")
        try require(!ScrollWindowPolicy.permits(bundleID: "local.cursor", layer: 0, alpha: 0) &&
                    !ScrollWindowPolicy.permits(bundleID: "local.menu", layer: 101),
                    "Invisible windows and menus must not become capture targets")
    }

    static func main() async {
        let checks: [(String, () async throws -> Void)] = [
            ("exact_overlap_and_lossless_pixel_composition", exactComposition),
            ("duplicate_end_and_backward_scroll_recovery", duplicateAndReverse),
            ("missing_overlap_is_rejected_and_recoverable", gapAndRecovery),
            ("all_no_overlap_still_returns_current_frame", allNoOverlapStillReturnsCurrentFrame),
            ("fixed_footer_appears_only_once", fixedFooter),
            ("size_and_memory_limits_preserve_partial_capture", limitsAndResize),
            ("sparse_repeated_text_and_edge_line_numbers", sparseText),
            ("retina_text_keeps_rows_and_rejects_lost_overlap", retinaTextKeepsRowsAndRejectsLostOverlap),
            ("accumulated_preview_and_no_progress_error", accumulatedPreviewAndNoProgress),
            ("dock_stage_manager_and_invisible_windows_are_excluded", systemOverlaysCannotBeCaptureTargets)
        ]
        var failures = 0
        for (name, run) in checks {
            do { try await run(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error.localizedDescription)") }
        }
        print("\(checks.count - failures)/\(checks.count) scroll capture checks passed")
        exit(failures == 0 ? 0 : 1)
    }
}
