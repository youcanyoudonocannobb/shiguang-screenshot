import AppKit

final class Rows: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        for row in 0..<120 {
            let top = CGFloat(row * 40)
            let rect = CGRect(x: 0, y: top, width: bounds.width, height: 40)
            guard rect.intersects(dirtyRect) else { continue }
            if row % 2 == 0 {
                NSColor(calibratedRed: 0.92, green: 0.96, blue: 0.95, alpha: 1).setFill()
                rect.fill()
            }
            let label = String(format: "%03d | %06d | Capture each unique row exactly once.", row + 1, (row + 1) * (row + 1))
            (label as NSString).draw(at: CGPoint(x: 14, y: top + 10), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.black
            ])
        }
    }
}

@main
struct Fixture {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: CGRect(x: 180, y: 220, width: 800, height: 700),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Shiguang synthetic scroll fixture"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary]
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = Rows(frame: CGRect(x: 0, y: 0, width: 780, height: 4800))
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
        withExtendedLifetime(window) {}
    }
}
