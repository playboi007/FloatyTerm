import AppKit

/// The clickable "agent is driving" badge shown while a window is in Agent Ghost
/// mode. Because the host window is click-through in that mode, a normal subview
/// can't catch the user's clicks — so this is a SEPARATE tiny non-activating
/// panel, pinned to the host's top-right corner, that stays interactive. It is
/// the state indicator (visible only while ghosted) and the in-place escape
/// hatch: clicking it exits Agent Ghost, no menu-bar trip.
///
/// Non-activating + our own PID, so it never fights for focus and is auto-excluded
/// from `list-windows` / window captures. Floats above the host so it's always
/// reachable.
///
/// Not `@MainActor`-annotated: it's only ever driven from `TerminalWindowController`
/// (main thread, but not actor-isolated), matching the rest of the window layer.
final class AgentGhostBadge {
    private let panel: NSPanel
    private let onRelease: () -> Void

    private static let size = NSSize(width: 188, height: 26)
    private static let inset: CGFloat = 8

    init(onRelease: @escaping () -> Void) {
        self.onRelease = onRelease
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the host (which sits at .statusBar) so it's always clickable.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false       // it MUST catch the release click
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = BadgeView(frame: NSRect(origin: .zero, size: Self.size)) { [weak self] in
            self?.onRelease()
        }
    }

    /// Show (and position) the badge over the host window's top-right corner.
    func show(over hostFrame: NSRect) {
        reposition(over: hostFrame)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    /// Keep the badge pinned to the host's top-right as it moves/resizes.
    func reposition(over hostFrame: NSRect) {
        let x = hostFrame.maxX - Self.size.width - Self.inset
        let y = hostFrame.maxY - Self.size.height - Self.inset
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        // A no-op if already frontmost; cheap insurance the host never covers it.
        panel.orderFrontRegardless()
    }
}

/// The pill: an accent rounded rect with a label. Whole view is the hit target.
private final class BadgeView: NSView {
    private let onClick: () -> Void
    private var hovering = false
    private var tracking: NSTrackingArea?

    init(frame frameRect: NSRect, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true; NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent)  { hovering = false; needsDisplay = true; NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent)    { onClick() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let accent = NSColor.systemPink
        let bg = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        (hovering ? accent : accent.withAlphaComponent(0.92)).setFill()
        bg.fill()

        let text = "✦ agent driving · release" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attrs)
    }
}
