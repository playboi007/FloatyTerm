import AppKit

/// A one-line floating strip a window can collapse into: shows the active
/// session's status dot, name, and live last line of output — a log ticker
/// you can park at a screen edge while working in another app. Drag to move;
/// double-click to expand back into the full window.
final class TickerPanel: NSPanel {

    static let height: CGFloat = 26
    static let defaultWidth: CGFloat = 400

    /// Called when the user double-clicks the strip to expand it back.
    var onExpand: (() -> Void)?

    /// Mirrors the parent window's Space link, like AvatarPanel.
    private(set) var isPinned = false

    private let tickerContent: TickerContentView

    init() {
        let size = NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.height)
        tickerContent = TickerContentView(frame: size)
        super.init(contentRect: size,
                   styleMask: [.nonactivatingPanel],
                   backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        reassertFloatingBehavior()

        tickerContent.onExpand = { [weak self] in self?.onExpand?() }
        contentView = tickerContent
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Refreshes the strip's contents (called from the window's activity timer
    /// and on demand).
    func update(name: String, line: String, status: SessionStatus) {
        tickerContent.update(name: name, line: line, status: status)
    }

    func reassertFloatingBehavior() {
        level = .statusBar
        if isPinned {
            collectionBehavior = [.managed, .fullScreenAuxiliary]
        } else {
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        reassertFloatingBehavior()
    }
}

/// The strip's visual: frosted capsule, status dot, bold session name, and the
/// last output line in monospace.
private final class TickerContentView: NSView {
    var onExpand: (() -> Void)?

    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let lineLabel = NSTextField(labelWithString: "")

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = frameRect.height / 2
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)

        layer?.cornerRadius = frameRect.height / 2
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.masksToBounds = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.9)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        lineLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        lineLabel.textColor = NSColor.white.withAlphaComponent(0.65)
        lineLabel.lineBreakMode = .byTruncatingHead   // keep the END of the line visible
        lineLabel.translatesAutoresizingMaskIntoConstraints = false
        lineLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(dot)
        addSubview(nameLabel)
        addSubview(lineLabel)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            nameLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 140),

            lineLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            lineLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            lineLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        toolTip = "Double-click to expand · drag to move"
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(name: String, line: String, status: SessionStatus) {
        dot.layer?.backgroundColor = status.color.cgColor
        nameLabel.stringValue = name
        lineLabel.stringValue = line
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onExpand?()
            return
        }
        window?.performDrag(with: event)
    }
}
