import AppKit

/// Per-window personalization of the avatar bubble: which SF Symbol it shows
/// and the color of its accent ring (also tinting the glyph slightly during
/// the hero morph). Chosen via right-click on the bubble; persisted in the
/// window's WindowRecord so each window keeps its identity across launches.
struct AvatarStyle: Equatable {
    var symbol: String = "terminal"
    var colorName: String = "accent"

    var color: NSColor {
        Self.colors.first { $0.name == colorName }?.color ?? .controlAccentColor
    }

    static let colors: [(name: String, title: String, color: NSColor)] = [
        ("accent", "Accent",  .controlAccentColor),
        ("blue",   "Blue",    .systemBlue),
        ("purple", "Purple",  .systemPurple),
        ("pink",   "Pink",    .systemPink),
        ("red",    "Red",     .systemRed),
        ("orange", "Orange",  .systemOrange),
        ("yellow", "Yellow",  .systemYellow),
        ("green",  "Green",   .systemGreen),
        ("teal",   "Teal",    .systemTeal)
    ]

    static let symbols: [(name: String, title: String)] = [
        ("terminal",        "Terminal"),
        ("apple.terminal",  "Prompt"),
        ("sparkles",        "Sparkles"),
        ("bolt.fill",       "Bolt"),
        ("star.fill",       "Star"),
        ("flame.fill",      "Flame"),
        ("leaf.fill",       "Leaf"),
        ("hammer.fill",     "Hammer"),
        ("gearshape.fill",  "Gear"),
        ("ladybug.fill",    "Ladybug"),
        ("moon.stars.fill", "Moon"),
        ("server.rack",     "Server")
    ]
}

/// The small circular "avatar" bubble a window collapses into. It floats over
/// everything (like the terminal panel), is draggable, and expands back into the
/// terminal on a double-click. Controlled only by direct interaction — there is
/// no hotkey for it.
final class AvatarPanel: NSPanel {

    /// Called when the user double-clicks the bubble to expand it back.
    var onExpand: (() -> Void)?

    /// Called when the user picks a new icon/color from the bubble's
    /// right-click menu, so the owning window can store and persist it.
    var onStyleChange: ((AvatarStyle) -> Void)?

    static let diameter: CGFloat = 60

    /// Mirrors the parent window's link state: when true the bubble is bound to
    /// a single Space (.managed) so it sticks to the Space the window was linked
    /// to, instead of roaming over all Spaces.
    private(set) var isPinned = false

    init() {
        let size = NSRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        super.init(contentRect: size,
                   styleMask: [.nonactivatingPanel],
                   backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        reassertFloatingBehavior()

        let content = AvatarContentView(frame: size)
        content.onExpand = { [weak self] in self?.onExpand?() }
        content.onStyleChange = { [weak self] style in self?.onStyleChange?(style) }
        contentView = content
        avatarContent = content
    }

    private weak var avatarContent: AvatarContentView?

    /// Applies an icon/color personalization to the bubble.
    func apply(style: AvatarStyle) {
        avatarContent?.apply(style: style)
    }

    /// Shows the bubble's attention badge: hidden for .idle, green for a
    /// running job, accent for unseen output (aggregated over the window's tabs).
    func setStatus(_ status: SessionStatus) {
        avatarContent?.setStatus(status)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func reassertFloatingBehavior() {
        level = .statusBar
        if isPinned {
            // Linked: stick to one Space (matches FloatingPanel's pinned mode).
            collectionBehavior = [.managed, .fullScreenAuxiliary]
        } else {
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
    }

    /// Sets whether the bubble is linked to its current Space (inherited from
    /// the parent window when it collapses).
    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        reassertFloatingBehavior()
    }
}

/// The bubble's visual: a translucent dark circle with a configurable glyph,
/// an accent ring, and double-click-to-expand / drag-to-move behaviour.
/// Right-click opens the personalization menu (icon + ring color).
private final class AvatarContentView: NSView {
    var onExpand: (() -> Void)?
    var onStyleChange: ((AvatarStyle) -> Void)?

    private(set) var style = AvatarStyle()
    private let glyph = NSImageView()
    private let badge = NSView()
    private static let glyphConfig = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)

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
        layer?.masksToBounds = true

        // Glyph.
        glyph.frame = bounds
        glyph.contentTintColor = .white
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.autoresizingMask = [.width, .height]
        addSubview(glyph)

        // Attention badge (upper-right, inside the circle so masking keeps it).
        let badgeSize: CGFloat = 11
        badge.frame = NSRect(x: bounds.maxX - badgeSize - 7,
                             y: bounds.maxY - badgeSize - 7,
                             width: badgeSize, height: badgeSize)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = badgeSize / 2
        badge.layer?.borderWidth = 1.5
        badge.layer?.borderColor = NSColor(white: 0.1, alpha: 0.9).cgColor
        badge.autoresizingMask = [.minXMargin, .minYMargin]
        badge.isHidden = true
        addSubview(badge)

        apply(style: style)
        toolTip = "Double-click to expand · drag to move · right-click to personalize"
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Updates the attention badge (hidden when idle).
    func setStatus(_ status: SessionStatus) {
        switch status {
        case .idle:
            badge.isHidden = true
        case .running, .unseenOutput, .needsInput:
            badge.isHidden = false
            badge.layer?.backgroundColor = status.color.cgColor
        }
    }

    /// Applies an icon/color personalization (also called for the initial style).
    func apply(style: AvatarStyle) {
        self.style = style
        layer?.borderColor = style.color.withAlphaComponent(0.9).cgColor
        glyph.image = NSImage(systemSymbolName: style.symbol,
                              accessibilityDescription: "FloatyTerm")?
            .withSymbolConfiguration(Self.glyphConfig)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onExpand?()
            return
        }
        // Single click → start a window drag (no-op if the user doesn't move).
        window?.performDrag(with: event)
    }

    // MARK: - Personalization menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Avatar")

        let iconMenu = NSMenu()
        for (name, title) in AvatarStyle.symbols {
            let item = NSMenuItem(title: title, action: #selector(pickSymbol(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.image = NSImage(systemSymbolName: name, accessibilityDescription: title)
            item.state = (name == style.symbol) ? .on : .off
            iconMenu.addItem(item)
        }
        let iconItem = NSMenuItem(title: "Icon", action: nil, keyEquivalent: "")
        menu.addItem(iconItem)
        menu.setSubmenu(iconMenu, for: iconItem)

        let colorMenu = NSMenu()
        for (name, title, color) in AvatarStyle.colors {
            let item = NSMenuItem(title: title, action: #selector(pickColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.image = Self.swatch(color)
            item.state = (name == style.colorName) ? .on : .off
            colorMenu.addItem(item)
        }
        let colorItem = NSMenuItem(title: "Ring Color", action: nil, keyEquivalent: "")
        menu.addItem(colorItem)
        menu.setSubmenu(colorMenu, for: colorItem)

        menu.addItem(.separator())
        let expand = NSMenuItem(title: "Expand", action: #selector(expandFromMenu), keyEquivalent: "")
        expand.target = self
        menu.addItem(expand)
        return menu
    }

    @objc private func pickSymbol(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var s = style; s.symbol = name
        apply(style: s)
        onStyleChange?(s)
    }

    @objc private func pickColor(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var s = style; s.colorName = name
        apply(style: s)
        onStyleChange?(s)
    }

    @objc private func expandFromMenu() { onExpand?() }

    /// A small filled-circle swatch for the color menu items.
    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }
}
