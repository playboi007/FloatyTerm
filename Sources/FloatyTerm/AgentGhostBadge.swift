import AppKit

/// The "agent is driving" banner shown while a window is in Agent Ghost mode.
///
/// It is deliberately **non-interactive** (`ignoresMouseEvents = true`). An
/// earlier version was clickable-to-release, but a clickable panel floating above
/// everything *intercepts the agent's own synthetic clicks* whenever a click
/// target falls under it (e.g. an app's top-right toolbar) — which silently
/// released ghost mid-sequence and let focus get stolen. A pass-through banner
/// can never eat a click (synthetic or real), so it's purely a status cue.
/// Release happens via the menu bar (Ghosted ▸ restore) or the agent's own
/// `floaty host --ghost off`.
///
/// Separate non-activating panel on our own PID, so it never takes focus and is
/// auto-excluded from `list-windows` / window captures. Floats above the host.
final class AgentGhostBadge {
    private let panel: NSPanel

    private static let size = NSSize(width: 214, height: 26)
    private static let inset: CGFloat = 8

    /// `onRelease` is retained for API stability but no longer wired to a click —
    /// the banner is non-interactive (see type doc).
    init(onRelease: @escaping () -> Void = {}) {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the host (which sits at .statusBar) so it's always visible.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true        // pass-through: never eats agent OR user clicks
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = BadgeView(frame: NSRect(origin: .zero, size: Self.size))
    }

    /// Show (and position) the banner over the host window's top-right corner.
    func show(over hostFrame: NSRect) {
        reposition(over: hostFrame)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    /// Keep the banner pinned to the host's top-right as it moves/resizes.
    func reposition(over hostFrame: NSRect) {
        let x = hostFrame.maxX - Self.size.width - Self.inset
        let y = hostFrame.maxY - Self.size.height - Self.inset
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()           // cheap insurance the host never covers it
    }
}

/// The pill: an accent rounded rect with a label. Purely decorative (the panel
/// ignores mouse events), so no hit-testing / tracking.
private final class BadgeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let accent = NSColor.systemPink
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        accent.setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()

        let text = "✦ agent is driving the screen" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
    }
}
