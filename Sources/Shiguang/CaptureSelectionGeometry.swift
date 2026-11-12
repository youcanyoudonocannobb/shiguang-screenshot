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

    static func toolbarFrame(selection: CGRect, size: CGSize, visible: CGRect, gap: CGFloat = 2) -> CGRect {
        let x = min(max(visible.minX + 4, selection.maxX - size.width), visible.maxX - size.width - 4)
        let below = selection.minY - gap - size.height
        let y = below >= visible.minY + 4 ? below :
            (selection.maxY + gap + size.height <= visible.maxY - 4 ? selection.maxY + gap :
                max(visible.minY + 4, min(below, visible.maxY - size.height - 4)))
        return CGRect(origin: CGPoint(x: max(visible.minX, x), y: y), size: size)
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
