import AppKit

/// A single tab "chip": a title button plus a small close (×) button.
private final class TabChip: NSView {
    private let titleButton = NSButton()
    private let closeButton = NSButton()
    var onSelect: () -> Void = {}
    var onClose: () -> Void = {}

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

/// The strip that lives BELOW the header and shows one chip per tab. It is
/// shown only when there are at least two tabs.
final class TabStripView: NSView {
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
final class HeaderControlsView: NSView {
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
