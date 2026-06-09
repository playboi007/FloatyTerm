import AppKit

/// The small circular "avatar" bubble a window collapses into. It floats over
/// everything (like the terminal panel), is draggable, and expands back into the
/// terminal on a double-click. Controlled only by direct interaction — there is
/// no hotkey for it.
final class AvatarPanel: NSPanel {

    /// Called when the user double-clicks the bubble to expand it back.
    var onExpand: (() -> Void)?

    static let diameter: CGFloat = 60

    init() {
        let size = NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        super.init(contentRect: size,
                   styleMask: [.nonactivatingPanel],
                   backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false

        let content = AvatarContentView(frame: size)
        content.onExpand = { [weak self] in self?.onExpand?() }
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func reassertFloatingBehavior() {
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
}

/// The bubble's visual: a translucent dark circle with a terminal glyph, an
/// accent ring, and double-click-to-expand / drag-to-move behaviour.
private final class AvatarContentView: NSView {
    var onExpand: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // Frosted backdrop clipped to a circle.
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = frameRect.width / 2
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)

        // Accent ring.
        layer?.cornerRadius = frameRect.width / 2
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        layer?.masksToBounds = true

        // Terminal glyph.
        let glyph = NSImageView(frame: bounds)
        let cfg = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        glyph.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "FloatyTerm")?
            .withSymbolConfiguration(cfg)
        glyph.contentTintColor = .white
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.autoresizingMask = [.width, .height]
        addSubview(glyph)

        toolTip = "Double-click to expand · drag to move"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onExpand?()
            return
        }
        // Single click → start a window drag (no-op if the user doesn't move).
        window?.performDrag(with: event)
    }
}
