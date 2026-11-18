import AppKit

enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var isCorner: Bool {
        [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self)
    }

    var resizeCursor: NSCursor {
        let position: NSCursor.FrameResizePosition
        switch self {
        case .topLeft: position = .topLeft
        case .top: position = .top
        case .topRight: position = .topRight
        case .right: position = .right
        case .bottomRight: position = .bottomRight
        case .bottom: position = .bottom
        case .bottomLeft: position = .bottomLeft
        case .left: position = .left
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

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

enum ToolbarHorizontalAlignment {
    case center
    case leading
    case trailing
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

    /// The whole edge is interactive, like macOS screenshot and Kitty Tools,
    /// rather than requiring the pointer to land on a tiny corner dot.
    static func handle(at point: CGPoint, in rect: CGRect,
                       tolerance: CGFloat = 8) -> SelectionHandle? {
        guard !rect.isEmpty else { return nil }

        func side(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> Int? {
            guard value >= low - tolerance, value <= high + tolerance else { return nil }
            let nearLow = value <= low + tolerance
            let nearHigh = value >= high - tolerance
            if nearLow && nearHigh {
                return abs(value - low) <= abs(high - value) ? -1 : 1
            }
            return nearLow ? -1 : (nearHigh ? 1 : 0)
        }

        guard let x = side(point.x, rect.minX, rect.maxX),
              let y = side(point.y, rect.minY, rect.maxY),
              x != 0 || y != 0 else { return nil }
        switch (x, y) {
        case (-1, -1): return .bottomLeft
        case (1, -1): return .bottomRight
        case (1, 1): return .topRight
        case (-1, 1): return .topLeft
        case (0, -1): return .bottom
        case (0, 1): return .top
        case (-1, 0): return .left
        case (1, 0): return .right
        default: return nil
        }
    }

    static func resized(_ rect: CGRect, handle: SelectionHandle, delta: CGSize, bounds: CGRect,
                        aspectRatio: CGFloat? = nil) -> CGRect {
        if let aspectRatio, aspectRatio > 0 {
            if [.top, .bottom, .left, .right].contains(handle) {
                return edgeRatioRect(rect, handle: handle, delta: delta,
                                     aspectRatio: aspectRatio, bounds: bounds)
            }
            let anchor = opposite(of: handle, in: rect)
            let target = CGPoint(x: handle.point(in: rect).x + delta.width,
                                 y: handle.point(in: rect).y + delta.height)
            return ratioRect(anchor: anchor, target: target, aspectRatio: aspectRatio, bounds: bounds)
        }
        var left = rect.minX, right = rect.maxX, bottom = rect.minY, top = rect.maxY
        if [.topLeft, .left, .bottomLeft].contains(handle) { left = max(bounds.minX, min(right - 8, left + delta.width)) }
        if [.topRight, .right, .bottomRight].contains(handle) { right = min(bounds.maxX, max(left + 8, right + delta.width)) }
        if [.bottomLeft, .bottom, .bottomRight].contains(handle) { bottom = max(bounds.minY, min(top - 8, bottom + delta.height)) }
        if [.topLeft, .top, .topRight].contains(handle) { top = min(bounds.maxY, max(bottom + 8, top + delta.height)) }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    static func selectionRect(from start: CGPoint, to end: CGPoint, bounds: CGRect,
                              aspectRatio: CGFloat? = nil) -> CGRect {
        if let aspectRatio, aspectRatio > 0 {
            return ratioRect(anchor: start, target: end, aspectRatio: aspectRatio, bounds: bounds)
        }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                      width: abs(end.x - start.x), height: abs(end.y - start.y)).intersection(bounds)
    }

    static func fittedToAspect(_ rect: CGRect, aspectRatio: CGFloat, bounds: CGRect) -> CGRect {
        guard aspectRatio > 0, bounds.width >= 8, bounds.height >= 8 else { return rect }
        var width = max(8, rect.width)
        var height = width / aspectRatio
        if height < 8 {
            height = 8
            width = height * aspectRatio
        }
        if width > bounds.width {
            width = bounds.width
            height = width / aspectRatio
        }
        if height > bounds.height {
            height = bounds.height
            width = height * aspectRatio
        }
        if width < 8 {
            width = 8
            height = width / aspectRatio
        }
        if height < 8 {
            height = 8
            width = height * aspectRatio
        }
        let x = min(max(bounds.minX, rect.midX - width / 2), bounds.maxX - width)
        let y = min(max(bounds.minY, rect.midY - height / 2), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func opposite(of handle: SelectionHandle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.maxX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.minX, y: rect.minY)
        case .right: return CGPoint(x: rect.minX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .left: return CGPoint(x: rect.maxX, y: rect.midY)
        }
    }

    private static func ratioRect(anchor: CGPoint, target: CGPoint, aspectRatio: CGFloat,
                                  bounds: CGRect) -> CGRect {
        let signX: CGFloat = target.x < anchor.x ? -1 : 1
        let signY: CGFloat = target.y < anchor.y ? -1 : 1
        let minimumWidth = max(8, 8 * aspectRatio)
        let minimumHeight = minimumWidth / aspectRatio
        let rawWidth = abs(target.x - anchor.x)
        let rawHeight = abs(target.y - anchor.y)
        var width: CGFloat
        var height: CGFloat
        if rawWidth / max(rawHeight, 0.001) >= aspectRatio {
            width = max(minimumWidth, rawWidth)
            height = width / aspectRatio
        } else {
            height = max(minimumHeight, rawHeight)
            width = height * aspectRatio
        }
        let maximumWidth = signX > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let maximumHeight = signY > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        let scale = min(1, maximumWidth / max(1, width), maximumHeight / max(1, height))
        width = max(1, width * scale)
        height = max(1, height * scale)
        if width / height > aspectRatio {
            width = height * aspectRatio
        } else {
            height = width / aspectRatio
        }
        let end = CGPoint(x: anchor.x + signX * width, y: anchor.y + signY * height)
        return CGRect(x: min(anchor.x, end.x), y: min(anchor.y, end.y),
                      width: width, height: height)
    }

    private static func edgeRatioRect(_ rect: CGRect, handle: SelectionHandle, delta: CGSize,
                                      aspectRatio: CGFloat, bounds: CGRect) -> CGRect {
        switch handle {
        case .top, .bottom:
            let anchorY = handle == .top ? rect.minY : rect.maxY
            var height = max(8, rect.height + (handle == .top ? delta.height : -delta.height))
            let maximumHeight = handle == .top ? bounds.maxY - anchorY : anchorY - bounds.minY
            height = min(height, maximumHeight)
            var width = height * aspectRatio
            if width > bounds.width {
                width = bounds.width
                height = width / aspectRatio
            }
            let centerX = min(max(rect.midX, bounds.minX + width / 2),
                              bounds.maxX - width / 2)
            let y = handle == .top ? anchorY : anchorY - height
            return CGRect(x: centerX - width / 2, y: y, width: width, height: height)
        case .left, .right:
            let anchorX = handle == .left ? rect.maxX : rect.minX
            var width = max(8, rect.width + (handle == .right ? delta.width : -delta.width))
            let maximumWidth = handle == .right ? bounds.maxX - anchorX : anchorX - bounds.minX
            width = min(width, maximumWidth)
            var height = width / aspectRatio
            if height > bounds.height {
                height = bounds.height
                width = height * aspectRatio
            }
            let centerY = min(max(rect.midY, bounds.minY + height / 2),
                              bounds.maxY - height / 2)
            let x = handle == .right ? anchorX : anchorX - width
            return CGRect(x: x, y: centerY - height / 2, width: width, height: height)
        default:
            return rect
        }
    }

    static func toolbarFrame(selection: CGRect, size: CGSize, visible: CGRect, gap: CGFloat = 10,
                             horizontal: ToolbarHorizontalAlignment = .center) -> CGRect {
        let safe = visible.insetBy(dx: 4, dy: 4)
        let centeredX = selection.midX - size.width / 2
        let centeredY = selection.midY - size.height / 2
        let preferredX: CGFloat
        switch horizontal {
        case .center:
            preferredX = centeredX
        case .leading:
            preferredX = selection.minX
        case .trailing:
            preferredX = selection.maxX - size.width + 8
        }
        let x = min(max(safe.minX, preferredX), max(safe.minX, safe.maxX - size.width))
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
        if let lineWidth = mark.lineWidth {
            mapped.lineWidth = lineWidth * min(old.width, old.height) / max(1, min(new.width, new.height))
        }
        if let numberSize = mark.numberSize {
            mapped.numberSize = numberSize * min(old.width, old.height) / max(1, min(new.width, new.height))
        }
        if let maskSize = mark.maskSize {
            mapped.maskSize = maskSize * min(old.width, old.height) / max(1, min(new.width, new.height))
        }
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
        context.setShadow(offset: .zero, blur: 5, color: accent.withAlphaComponent(0.28).cgColor)
        context.setStrokeColor(accent.cgColor)
        context.setLineWidth(2)
        context.stroke(border)

        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.34).cgColor)
        context.setLineWidth(0.5)
        context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))

        if showsHandles && rect.width >= 34 && rect.height >= 34 {
            let corners: Set<SelectionHandle> = [.topLeft, .topRight, .bottomRight, .bottomLeft]
            for handle in SelectionHandle.allCases {
                let point = handle.point(in: rect)
                let isCorner = corners.contains(handle)
                if isCorner {
                    let dot = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                    context.setFillColor(NSColor.white.withAlphaComponent(0.98).cgColor)
                    context.fillEllipse(in: dot)
                    context.setStrokeColor(accent.cgColor)
                    context.setLineWidth(1.5)
                    context.strokeEllipse(in: dot)
                } else {
                    let horizontal = handle == .top || handle == .bottom
                    let grip = CGRect(x: point.x - (horizontal ? 9 : 2),
                                      y: point.y - (horizontal ? 2 : 9),
                                      width: horizontal ? 18 : 4,
                                      height: horizontal ? 4 : 18)
                    let path = CGPath(roundedRect: grip,
                                      cornerWidth: 2, cornerHeight: 2, transform: nil)
                    context.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
                    context.addPath(path)
                    context.fillPath()
                    context.setStrokeColor(accent.withAlphaComponent(0.88).cgColor)
                    context.setLineWidth(1)
                    context.addPath(path)
                    context.strokePath()
                }
            }
        }
        context.restoreGState()
    }
}
