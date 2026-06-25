import AppKit

/// A floating URL / navigation bar shown only when the active tab is a browser.
///
/// Visual style mirrors FindBarView: NSVisualEffectView (.hudWindow, .withinWindow),
/// rounded corners, dark-aqua appearance, white-tinted controls.
///
/// Layout:  [←] [→] [⟳]  [  url field  ]
///
/// The bar is pinned to the top of contentArea (8 pt below its top edge) and
/// centred horizontally, with a generous but bounded width.
final class URLBarView: NSVisualEffectView, NSTextFieldDelegate {

    // MARK: - Callbacks (wired by TerminalWindowController)

    /// Called when the user commits a URL / search query (Return key).
    var onLoad: ((String) -> Void)?
    /// Called when the back button is tapped.
    var onBack: (() -> Void)?
    /// Called when the forward button is tapped.
    var onForward: (() -> Void)?
    /// Called when the reload button is tapped.
    var onReload: (() -> Void)?
    /// Called when the popup/redirect shield is tapped (toggles protection for
    /// the current site).
    var onToggleShield: (() -> Void)?

    // MARK: - Subviews

    private let backButton    = NSButton()
    private let forwardButton = NSButton()
    private let reloadButton  = NSButton()
    private let urlField      = NSTextField()
    private let shieldButton  = NSButton()

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Public API

    /// Updates the URL field text (called when the active page changes).
    func updateURL(_ urlString: String) {
        // Only update when the field isn't being edited to avoid clobbering.
        guard window?.firstResponder !== urlField.currentEditor() else { return }
        urlField.stringValue = urlString
    }

    /// Enables / disables the back and forward buttons.
    func updateNavState(canGoBack: Bool, canGoForward: Bool) {
        backButton.isEnabled    = canGoBack
        forwardButton.isEnabled = canGoForward
    }

    /// Updates the popup/redirect shield: its glyph, tint, count badge, and
    /// tooltip. `blocking` is whether protection is active for the current
    /// site; `count` is how many intrusions this page has dropped.
    func updateShield(blocking: Bool, count: Int) {
        let symbol = blocking
            ? (count > 0 ? "shield.lefthalf.filled" : "shield")
            : "shield.slash"
        shieldButton.image = NSImage(systemSymbolName: symbol,
                                     accessibilityDescription: "Popup blocker")
        // Count rides as the button title so a busy page reads "🛡 3".
        shieldButton.title = (blocking && count > 0) ? " \(count)" : ""
        shieldButton.imagePosition = shieldButton.title.isEmpty ? .imageOnly : .imageLeading
        shieldButton.contentTintColor = blocking
            ? NSColor.white.withAlphaComponent(count > 0 ? 1.0 : 0.55)
            : NSColor.systemOrange.withAlphaComponent(0.9)
        shieldButton.toolTip = blocking
            ? (count > 0
                ? "\(count) popup\(count == 1 ? "" : "s")/redirect\(count == 1 ? "" : "s") blocked on this page — click to allow on this site"
                : "Popup blocking on — click to allow popups on this site")
            : "Popups allowed on this site — click to re-enable blocking"
    }

    /// Focuses the URL field (selects all text for quick replacement).
    func focusURLField() {
        window?.makeFirstResponder(urlField)
        urlField.currentEditor()?.selectAll(nil)
    }

    // MARK: - Setup

    private func setup() {
        // Backdrop — same hudWindow blur as FindBarView and the palette.
        material     = .hudWindow
        blendingMode = .withinWindow
        state        = .active
        wantsLayer   = true
        layer?.cornerRadius  = 8
        layer?.masksToBounds = true

        // ── Navigation buttons ───────────────────────────────────────────────
        configureNavButton(backButton,    symbol: "chevron.left",  tooltip: "Go Back",    action: #selector(backTapped))
        configureNavButton(forwardButton, symbol: "chevron.right", tooltip: "Go Forward", action: #selector(forwardTapped))
        configureNavButton(reloadButton,  symbol: "arrow.clockwise", tooltip: "Reload",   action: #selector(reloadTapped))

        // Buttons start disabled; updateNavState / updateURL will re-enable.
        backButton.isEnabled    = false
        forwardButton.isEnabled = false

        // ── URL text field ───────────────────────────────────────────────────
        urlField.placeholderString = "Search or enter URL"
        urlField.appearance        = NSAppearance(named: .darkAqua)
        urlField.controlSize       = .regular
        urlField.bezelStyle        = .roundedBezel
        urlField.focusRingType     = .none
        urlField.target            = self
        urlField.action            = #selector(urlFieldCommitted)
        urlField.delegate          = self
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // ── Shield (popup / redirect blocker) ────────────────────────────────
        configureNavButton(shieldButton, symbol: "shield", tooltip: "Popup blocker",
                           action: #selector(shieldTapped))
        shieldButton.imageHugsTitle = true
        shieldButton.font = .systemFont(ofSize: 10, weight: .semibold)

        // ── Layout stack ─────────────────────────────────────────────────────
        let stack = NSStackView(views: [backButton, forwardButton, reloadButton, urlField, shieldButton])
        stack.orientation = .horizontal
        stack.alignment   = .centerY
        stack.spacing     = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor,   constant:  8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor,  constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor,            constant:  6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor,      constant: -6),
            urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
    }

    private func configureNavButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle   = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.controlSize  = .small
        button.image        = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        button.toolTip      = tooltip
        button.target       = self
        button.action       = action
    }

    // MARK: - Button actions

    @objc private func backTapped()    { onBack?()    }
    @objc private func forwardTapped() { onForward?() }
    @objc private func reloadTapped()  { onReload?()  }
    @objc private func shieldTapped()  { onToggleShield?() }

    @objc private func urlFieldCommitted() {
        onLoad?(urlField.stringValue)
    }

    // MARK: - NSTextFieldDelegate

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape: restore the current page URL and return focus to the web view.
            window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            urlFieldCommitted()
            return true
        }
        return false
    }
}
