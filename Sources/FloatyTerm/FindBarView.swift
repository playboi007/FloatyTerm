import AppKit
import SwiftTerm

/// A minimal find bar that overlays the active terminal's content area.
///
/// Visual style mirrors the rest of FloatyTerm: dark/translucent background
/// (NSVisualEffectView with .hudWindow material), white-ish text, and rounded
/// corners — consistent with TabChip and HeaderControlsView.
///
/// SwiftTerm public API used:
///   - `TerminalView.findNext(_:options:)`
///   - `TerminalView.findPrevious(_:options:)`
///   - `TerminalView.clearSearch()`
///   - `SearchOptions(caseSensitive:regex:wholeWord:)`
final class FindBarView: NSVisualEffectView, NSSearchFieldDelegate {

    // MARK: - Callbacks wired by the owner

    /// Called as the user types — triggers a findNext for live preview.
    var onSearchChanged: ((String) -> Void)?
    /// Called when Next is requested (Return, button).
    var onFindNext: (() -> Void)?
    /// Called when Prev is requested (Shift+Return, button).
    var onFindPrevious: (() -> Void)?
    /// Called when the bar should be dismissed (Escape, × button).
    var onClose: (() -> Void)?

    // MARK: - Subviews

    private let searchField = NSSearchField()
    private let prevButton  = NSButton()
    private let nextButton  = NSButton()
    private let closeButton = NSButton()

    // MARK: - Public state

    var searchText: String {
        get { searchField.stringValue }
        set { searchField.stringValue = newValue }
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Focus

    /// Moves keyboard focus to the search field.
    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    // MARK: - Setup

    private func setup() {
        // Visual effect backdrop — matches the app's hudWindow blur theme.
        material       = .hudWindow
        blendingMode   = .withinWindow
        state          = .active
        wantsLayer     = true
        layer?.cornerRadius  = 8
        layer?.masksToBounds = true

        // Search field
        searchField.placeholderString = "Find"
        searchField.delegate          = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        searchField.setContentCompressionResistancePriority(.defaultLow,  for: .horizontal)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Tint the text white-ish to match the dark translucent background.
        searchField.appearance = NSAppearance(named: .darkAqua)

        // Navigation & close buttons
        configureIconButton(prevButton,  symbol: "chevron.up",   tooltip: "Previous Match")
        prevButton.target = self
        prevButton.action = #selector(prevTapped)

        configureIconButton(nextButton,  symbol: "chevron.down",  tooltip: "Next Match")
        nextButton.target = self
        nextButton.action = #selector(nextTapped)

        configureIconButton(closeButton, symbol: "xmark",         tooltip: "Close Find Bar")
        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        // Layout stack
        let stack = NSStackView(views: [searchField, prevButton, nextButton, closeButton])
        stack.orientation  = .horizontal
        stack.alignment    = .centerY
        stack.spacing      = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor,   constant:  8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor,  constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor,            constant:  6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor,      constant: -6),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
    }

    private func configureIconButton(_ button: NSButton, symbol: String, tooltip: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle   = .texturedRounded
        button.setButtonType(.momentaryPushIn)
        button.controlSize  = .small
        button.image        = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        button.toolTip      = tooltip
    }

    // MARK: - Button actions

    @objc private func prevTapped()  { onFindPrevious?() }
    @objc private func nextTapped()  { onFindNext?() }
    @objc private func closeTapped() { onClose?() }

    @objc private func searchFieldAction() {
        // Shift+Return → previous; plain Return → next.
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            onFindPrevious?()
        } else {
            onFindNext?()
        }
    }

    // MARK: - NSSearchFieldDelegate / NSControlTextEditingDelegate

    func controlTextDidChange(_ obj: Notification) {
        onSearchChanged?(searchField.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onClose?()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            searchFieldAction()
            return true
        }
        return false
    }
}
