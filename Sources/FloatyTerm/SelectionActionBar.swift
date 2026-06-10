import AppKit

/// A compact floating action bar that appears next to a fresh text selection
/// in a terminal: Copy · Open (URL/file, when detected) · Search Web · Insert
/// at prompt. Positioned near the mouse by the window controller; dismissed on
/// the next click or tab switch.
final class SelectionActionBar: NSVisualEffectView {

    var onCopy:   (() -> Void)?
    var onOpen:   (() -> Void)?
    var onSearch: (() -> Void)?
    var onInsert: (() -> Void)?

    static let barHeight: CGFloat = 30

    private let copyButton   = NSButton()
    private let openButton   = NSButton()
    private let searchButton = NSButton()
    private let insertButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    /// Shows/hides the Open button (only when the selection looks openable).
    func setOpenAvailable(_ available: Bool) {
        openButton.isHidden = !available
    }

    /// The bar's natural width for its current button set.
    var naturalWidth: CGFloat {
        let buttons = openButton.isHidden ? 3 : 4
        return CGFloat(buttons) * 30 + 16
    }

    private func setup() {
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        configure(copyButton,   symbol: "doc.on.doc",            tooltip: "Copy",            action: #selector(copyTapped))
        configure(openButton,   symbol: "arrow.up.right.square", tooltip: "Open (URL / file)", action: #selector(openTapped))
        configure(searchButton, symbol: "magnifyingglass",       tooltip: "Search the web",  action: #selector(searchTapped))
        configure(insertButton, symbol: "text.cursor",           tooltip: "Insert at prompt", action: #selector(insertTapped))

        let stack = NSStackView(views: [copyButton, openButton, searchButton, insertButton])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.isBordered = false
        button.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    }

    @objc private func copyTapped()   { onCopy?()   }
    @objc private func openTapped()   { onOpen?()   }
    @objc private func searchTapped() { onSearch?() }
    @objc private func insertTapped() { onInsert?() }
}
