import AppKit

// MARK: - Drag-handle helper

/// Mix-in behaviour: any NSView that adopts this override will forward its
/// mouseDown events to `window?.performDrag(with:)`, making the view act as a
/// window-drag handle while still letting subview NSControls receive their own
/// clicks normally (AppKit delivers mouseDown to the front-most hit-tested view
/// first, so buttons/chips are never preempted).
class DragHandleView: NSView {
    /// Returning false here is belt-and-suspenders: we're already disabling
    /// isMovableByWindowBackground globally, but this makes the intent explicit.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Initiate a window drag. If the user just clicks without moving, this
        // is a harmless no-op from AppKit's perspective.
        window?.performDrag(with: event)
    }
}

// MARK: - TabChip

/// A single tab "chip": a title button plus a small close (×) button.
private final class TabChip: NSView {
    private let titleButton = NSButton()
    private let closeButton = NSButton()
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}

    // The chip background itself must not move the window; clicks on the chip
    // background (not on a button) should not propagate up as drag handles.
    override var mouseDownCanMoveWindow: Bool { false }

    init(title: String, active: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = active
            ? NSColor.white.withAlphaComponent(0.20).cgColor
            : NSColor.white.withAlphaComponent(0.06).cgColor

        titleButton.title = title
        titleButton.isBordered = false
        titleButton.font = .systemFont(ofSize: 11)
        titleButton.contentTintColor = active ? .white : NSColor.white.withAlphaComponent(0.7)
        titleButton.lineBreakMode = .byTruncatingTail
        titleButton.target = self
        titleButton.action = #selector(selectTapped)
        titleButton.translatesAutoresizingMaskIntoConstraints = false

        closeButton.title = "×"
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 13)
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleButton)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),

            titleButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleButton.widthAnchor.constraint(lessThanOrEqualToConstant: 140),

            closeButton.leadingAnchor.constraint(equalTo: titleButton.trailingAnchor, constant: 2),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func selectTapped() { onSelect() }
    @objc private func closeTapped() { onClose() }
}

// MARK: - DragHandleClipView

/// An NSClipView subclass that acts as a drag handle. Needed because the
/// NSScrollView inside TabStripView intercepts mouseDown on its clip view;
/// replacing it with this subclass ensures clicks on empty strip space still
/// initiate a window drag.
private final class DragHandleClipView: NSClipView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - TabStripView

/// The strip that lives BELOW the header and shows one chip per tab. It is
/// shown only when there are at least two tabs.
final class TabStripView: DragHandleView {
    var onSelect: (Int) -> Void = { _ in }
    var onCloseTab: (Int) -> Void = { _ in }

    private let scroll = NSScrollView()
    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Replace the default NSClipView with our drag-handle subclass so that
        // mouseDown on empty space in the scroll area initiates a window drag.
        scroll.contentView = DragHandleClipView()
        scroll.documentView = stack
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.heightAnchor)
        ])
    }

    func reload(titles: [String], activeIndex: Int) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, title) in titles.enumerated() {
            let chip = TabChip(title: title.isEmpty ? "Tab \(index + 1)" : title,
                               active: index == activeIndex)
            chip.onSelect = { [weak self] in self?.onSelect(index) }
            chip.onClose = { [weak self] in self?.onCloseTab(index) }
            stack.addArrangedSubview(chip)
        }
    }
}

/// The controls in the top header strip: "＋" (new tab) and "⧉" (new window).
final class HeaderControlsView: DragHandleView {
    var onAddTab: () -> Void = {}
    var onNewWindow: () -> Void = {}

    private let addButton = NSButton()
    private let newWindowButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        configure(addButton, glyph: "+", action: #selector(addTapped))
        configure(newWindowButton, glyph: "⧉", action: #selector(newWindowTapped))
        addSubview(addButton)
        addSubview(newWindowButton)

        NSLayoutConstraint.activate([
            addButton.trailingAnchor.constraint(equalTo: newWindowButton.leadingAnchor, constant: -4),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),

            newWindowButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            newWindowButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newWindowButton.widthAnchor.constraint(equalToConstant: 24)
        ])
    }

    private func configure(_ button: NSButton, glyph: String, action: Selector) {
        button.title = glyph
        button.isBordered = false
        button.font = .systemFont(ofSize: 15)
        button.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func addTapped() { onAddTab() }
    @objc private func newWindowTapped() { onNewWindow() }
}
