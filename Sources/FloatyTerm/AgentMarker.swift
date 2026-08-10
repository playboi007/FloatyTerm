import AppKit

/// A transient on-screen crosshair an agent can flash at a screen point to
/// verify "where am I about to click" WITHOUT the full capture→read cycle.
/// `floaty mark --x 840 --y 412` draws a high-contrast target at that point for
/// ~1.2s, then fades out on its own.
///
/// Coordinates are the SAME global screen points `floaty click` takes (CGEvent
/// space: origin top-left of the primary display, y-down). We flip them into
/// AppKit's bottom-left space to place the window, so the crosshair lands
/// exactly where a click would.
///
/// The overlay is borderless, non-activating, click-through (ignoresMouseEvents)
/// and floats above everything on all Spaces — modeled on RegionSelector's
/// OverlayPanel — so it never steals focus or intercepts a click that follows.
@MainActor
enum AgentMarker {

    private static var panel: NSPanel?
    private static var dismiss: DispatchWorkItem?

    @discardableResult
    static func show(at cgPoint: CGPoint, duration: TimeInterval = 1.2, label: String? = nil) -> Bool {
        // CG top-left → AppKit bottom-left, via the primary (menu-bar) screen.
        guard let primary = NSScreen.screens.first else { return false }
        let cocoa = CGPoint(x: cgPoint.x, y: primary.frame.height - cgPoint.y)

        let size: CGFloat = 160
        let frame = NSRect(x: cocoa.x - size / 2, y: cocoa.y - size / 2, width: size, height: size)

        // Replace any in-flight marker (cancel its pending dismissal first).
        dismiss?.cancel()
        panel?.orderOut(nil)

        let p = NSPanel(contentRect: frame,
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.ignoresMouseEvents = true        // click-through — never eats the agent's next click
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = MarkerView(frame: NSRect(origin: .zero, size: frame.size), label: label)
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p

        // Auto-dismiss with a short fade. The work item is cancellable so a
        // rapid second `mark` doesn't get yanked by the first's timer. It's
        // dispatched onto the main queue, so assumeIsolated is sound — it just
        // tells the compiler what's already true at runtime.
        let fade = min(0.3, duration)
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = fade
                    p.animator().alphaValue = 0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + fade) {
                    MainActor.assumeIsolated {
                        p.orderOut(nil)
                        if panel === p { panel = nil }
                    }
                }
            }
        }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, duration - fade), execute: work)
        return true
    }
}

/// Draws the target: a magenta ring + crosshair + center dot, each stroked with
/// a white halo so it reads on any background, plus an optional label chip.
private final class MarkerView: NSView {
    private let label: String?

    init(frame frameRect: NSRect, label: String?) {
        self.label = label
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let accent = NSColor.systemPink
        let halo = NSColor.white

        func stroke(_ path: NSBezierPath, _ color: NSColor, _ width: CGFloat) {
            color.setStroke(); path.lineWidth = width; path.stroke()
        }

        // Ring (halo under accent).
        let r: CGFloat = 26
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        stroke(ring, halo, 5)
        stroke(ring, accent, 2.5)

        // Crosshair arms, leaving a gap around the ring.
        let arm: CGFloat = 46, gap: CGFloat = r + 6
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: c.x - arm, y: c.y)); cross.line(to: NSPoint(x: c.x - gap, y: c.y))
        cross.move(to: NSPoint(x: c.x + gap, y: c.y)); cross.line(to: NSPoint(x: c.x + arm, y: c.y))
        cross.move(to: NSPoint(x: c.x, y: c.y - arm)); cross.line(to: NSPoint(x: c.x, y: c.y - gap))
        cross.move(to: NSPoint(x: c.x, y: c.y + gap)); cross.line(to: NSPoint(x: c.x, y: c.y + arm))
        stroke(cross, halo, 5)
        stroke(cross, accent, 2.5)

        // Center dot.
        let dot = NSBezierPath(ovalIn: NSRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
        halo.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)).fill()
        accent.setFill(); dot.fill()

        guard let label, !label.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = label as NSString
        let tsize = text.size(withAttributes: attrs)
        let pad: CGFloat = 6
        let chip = NSRect(x: c.x - tsize.width / 2 - pad, y: c.y - r - tsize.height - pad * 2 - 4,
                          width: tsize.width + pad * 2, height: tsize.height + pad)
        let bg = NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5)
        NSColor(white: 0, alpha: 0.7).setFill(); bg.fill()
        text.draw(at: NSPoint(x: chip.minX + pad, y: chip.minY + pad / 2), withAttributes: attrs)
    }
}
