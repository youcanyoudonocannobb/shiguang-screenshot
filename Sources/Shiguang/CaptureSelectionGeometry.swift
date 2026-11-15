import AppKit

enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

enum CaptureSelectionGeometry {
    static func windowRect(_ cgBounds: CGRect, primaryTop: CGFloat, screenFrame: CGRect) -> CGRect? {
        let appKit = CGRect(x: cgBounds.minX, y: primaryTop - cgBounds.maxY, width: cgBounds.width, height: cgBounds.height)
        let clipped = appKit.intersection(screenFrame)
        guard !clipped.isNull, clipped.width >= 8, clipped.height >= 8 else { return nil }
        return clipped.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        let size = CGSize(width: min(bounds.width, max(8, rect.width)), height: min(bounds.height, max(8, rect.height)))
        return CGRect(x: min(bounds.maxX - size.width, max(bounds.minX, rect.minX)),
                      y: min(bounds.maxY - size.height, max(bounds.minY, rect.minY)), width: size.width, height: size.height)
    }

    static func resized(_ rect: CGRect, handle: SelectionHandle, delta: CGSize, bounds: CGRect) -> CGRect {
        var left = rect.minX, right = rect.maxX, bottom = rect.minY, top = rect.maxY
        if [.topLeft, .left, .bottomLeft].contains(handle) { left = max(bounds.minX, min(right - 8, left + delta.width)) }
        if [.topRight, .right, .bottomRight].contains(handle) { right = min(bounds.maxX, max(left + 8, right + delta.width)) }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) { bottom = max(bounds.minY, min(top - 8, bottom + delta.height)) }
        if [.topLeft, .top, .topRight].contains(handle) { top = min(bounds.maxY, max(bottom + 8, top + delta.height)) }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    static func toolbarFrame(selection: CGRect, size: CGSize, visible: CGRect, gap: CGFloat = 10) -> CGRect {
        let safe = visible.insetBy(dx: 4, dy: 4)
        let centeredX = selection.midX - size.width / 2
        let centeredY = selection.midY - size.height / 2
        let x = min(max(safe.minX, centeredX), max(safe.minX, safe.maxX - size.width))
        let y = min(max(safe.minY, centeredY), max(safe.minY, safe.maxY - size.height))

        // Prefer the bottom edge. If the selection is near the bottom, move above;
        // for a near full-height selection, attach to its right or left edge.
        let candidates = [
            CGRect(x: x, y: selection.minY - gap - size.height, width: size.width, height: size.height),
            CGRect(x: x, y: selection.maxY + gap, width: size.width, height: size.height),
            CGRect(x: selection.maxX + gap, y: y, width: size.width, height: size.height),
            CGRect(x: selection.minX - gap - size.width, y: y, width: size.width, height: size.height)
        ]
        if let fitting = candidates.first(where: { safe.contains($0) }) { return fitting }

        let fallback = candidates.max {
            $0.intersection(safe).width * $0.intersection(safe).height <
                $1.intersection(safe).width * $1.intersection(safe).height
        } ?? candidates[0]
        return CGRect(
            x: min(max(safe.minX, fallback.minX), max(safe.minX, safe.maxX - size.width)),
            y: min(max(safe.minY, fallback.minY), max(safe.minY, safe.maxY - size.height)),
            width: size.width,
            height: size.height
        )
    }

    static func crop(_ image: NSImage, rect: CGRect, displaySize: CGSize) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), displaySize.width > 0, displaySize.height > 0 else { return nil }
        let scaleX = CGFloat(cg.width) / displaySize.width, scaleY = CGFloat(cg.height) / displaySize.height
        let pixelRect = CGRect(x: rect.minX * scaleX, y: (displaySize.height - rect.maxY) * scaleY,
                               width: rect.width * scaleX, height: rect.height * scaleY).integral
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !pixelRect.isEmpty, let cropped = cg.cropping(to: pixelRect) else { return nil }
        return NSImage(cgImage: cropped, size: rect.size)
    }

    static func remap(_ mark: Mark, from old: CGRect, to new: CGRect) -> Mark {
        var mapped = mark
        mapped.points = mark.points.map { point in
            var next = point
            next.x = (old.minX + point.x * old.width - new.minX) / new.width
            next.y = (new.maxY - (old.maxY - point.y * old.height)) / new.height
            return next
        }
        if let font = mark.fontSize { mapped.fontSize = font * old.height / new.height }
        return mapped
    }
}

enum PinnedWindowGeometry {
    static func resizedContentSize(current: CGSize, imageAspectRatio: CGFloat, scale: CGFloat,
                                   chromeHeight: CGFloat, visibleFrameSize: CGSize) -> CGSize {
        guard current.width > 0, current.height > 0, visibleFrameSize.width > 0, visibleFrameSize.height > 0 else {
            return current
        }
        let ratio = max(0.01, imageAspectRatio)
        let usableHeight = max(80, visibleFrameSize.height * 0.92 - max(0, chromeHeight))
        let maximumWidth = min(visibleFrameSize.width * 0.92, usableHeight / ratio)
        let minimumWidth = min(140, maximumWidth)
        let factor = min(2, max(0.5, scale))
        let width = min(maximumWidth, max(minimumWidth, current.width * factor))
        return CGSize(width: width, height: width * ratio)
    }

    static func anchoredFrame(currentFrame: CGRect, currentContentSize: CGSize,
                              targetContentSize: CGSize, anchorInContent: CGPoint,
                              chromeHeight: CGFloat, visibleFrame: CGRect) -> CGRect {
        guard currentContentSize.width > 0, currentContentSize.height > 0 else {
            return currentFrame
        }
        let anchorX = min(1, max(0, anchorInContent.x / currentContentSize.width))
        let anchorY = min(1, max(0, anchorInContent.y / currentContentSize.height))
        let screenAnchor = CGPoint(x: currentFrame.minX + anchorX * currentContentSize.width,
                                   y: currentFrame.minY + anchorY * currentContentSize.height)
        let frameSize = CGSize(width: targetContentSize.width,
                               height: targetContentSize.height + max(0, chromeHeight))
        let proposed = CGRect(x: screenAnchor.x - anchorX * frameSize.width,
                              y: screenAnchor.y - anchorY * targetContentSize.height,
                              width: frameSize.width, height: frameSize.height)
        return CaptureSelectionGeometry.clamped(proposed, to: visibleFrame.insetBy(dx: 4, dy: 4))
    }
}

enum SelectionChrome {
    static let accent = NSColor(srgbRed: 0.25, green: 0.77, blue: 0.94, alpha: 1)
    static let mask = NSColor(srgbRed: 0.025, green: 0.075, blue: 0.11, alpha: 0.52)

    static func draw(in rect: CGRect, context: CGContext, showsHandles: Bool = true) {
        guard rect.width > 0, rect.height > 0 else { return }
        context.saveGState()

        let border = rect.insetBy(dx: 1, dy: 1)
        context.setShadow(offset: .zero, blur: 12, color: accent.withAlphaComponent(0.55).cgColor)
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(2.5)
        context.stroke(border)

        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.72).cgColor)
        context.setLineWidth(0.75)
        context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))

        if showsHandles && rect.width >= 34 && rect.height >= 34 {
            for handle in SelectionHandle.allCases {
                let point = handle.point(in: rect)
                let dot = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                context.setFillColor(NSColor.white.withAlphaComponent(0.98).cgColor)
                context.fillEllipse(in: dot)
                context.setStrokeColor(accent.cgColor)
                context.setLineWidth(2)
                context.strokeEllipse(in: dot)
            }
        }
        context.restoreGState()
    }
}
