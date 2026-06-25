import AppKit

/// One row in the session switcher: a tab somewhere in some window.
struct SessionEntry {
    weak var window: TerminalWindowController?
    let tab: any TabContent
    let name: String
    let location: String        // "win 2 · in bubble (Chrome)" — which window,
                                // in what state, over which app
    let status: SessionStatus
    let isTerminal: Bool
    /// True when a known agent CLI (claude, codex, aider…) is this tab's
    /// foreground process — the row gets a "sparkles" icon.
    let isAgent: Bool
    /// The host window's avatar identity (the same symbol + ring color as its
    /// bubble), so rows are matchable to windows at a glance.
    let windowSymbol: String
    let windowColor: NSColor
}

/// The global session switcher (⌥⌘K, or ⌘K inside a window): a floating
/// palette listing every tab in every window, fuzzy-searchable, that summons
/// the chosen session to the current Space.
///
/// Same overlay rules as the terminal windows: non-activating, joins all
/// Spaces, floats over fullscreen apps — it must appear wherever the user is.
final class SessionSwitcherController: NSObject, NSTextFieldDelegate,
                                       NSTableViewDataSource, NSTableViewDelegate,
                                       NSWindowDelegate {

    /// Supplies a fresh snapshot of all sessions each time the palette opens.
    var sessionsProvider: () -> [SessionEntry] = { [] }
    /// Called with the chosen entry (palette is dismissed first).
    var onSummon: ((SessionEntry) -> Void)?
    /// Called with the entry whose ✕ was clicked (or ⌘⌫); the palette stays
    /// open and refreshes its list afterwards.
    var onClose: ((SessionEntry) -> Void)?

    /// True while a close runs: its running-job confirmation alert steals key
    /// from the palette, which must not be mistaken for a click-away dismiss.
    private var suppressDismissOnResign = false

    private var panel: SwitcherPanel?
    private let searchField = NSTextField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private var all: [SessionEntry] = []
    private var filtered: [SessionEntry] = []

    // MARK: - Show / hide

    func toggle() {
        if panel?.isVisible == true { dismiss() } else { show() }
    }

    func show() {
        if panel == nil { build() }
        guard let panel else { return }
        // Reassert on every show: the window server can silently drop the
        // level / all-Spaces / fullscreen-overlay flags after display sleep or
        // fullscreen transitions (same bug FloatingPanel.reassertFloatingBehavior
        // fixes for terminal windows). Without this the palette degrades to a
        // managed window bound to one Space and stops appearing over
        // fullscreen apps.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = Settings.shared.hideFromScreenCapture ? .none : .readOnly
        all = sessionsProvider()
        searchField.stringValue = ""
        applyFilter("")
        positionOnActiveScreen()
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(searchField)
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    /// Clicking anywhere else dismisses the palette.
    func windowDidResignKey(_ notification: Notification) {
        guard !suppressDismissOnResign else { return }
        dismiss()
    }

    // MARK: - Build

    private func build() {
        let size = NSRect(x: 0, y: 0, width: 520, height: 380)
        let p = SwitcherPanel(contentRect: size,
                              styleMask: [.nonactivatingPanel, .borderless],
                              backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.isReleasedWhenClosed = false
        p.delegate = self

        let blur = NSVisualEffectView(frame: size)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        p.contentView = blur

        // ── Search field ─────────────────────────────────────────────────
        searchField.placeholderString = "Search sessions…"
        searchField.appearance = NSAppearance(named: .darkAqua)
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 14)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // ── Table ────────────────────────────────────────────────────────
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("session"))
        column.isEditable = false
        column.width = 480
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.rowHeight = 32
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.appearance = NSAppearance(named: .darkAqua)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "↩ summon here   ⌘⌫ close session   ↑↓ navigate   esc dismiss")
        hint.font = .systemFont(ofSize: 10, weight: .light)
        hint.textColor = NSColor.white.withAlphaComponent(0.45)
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false

        blur.addSubview(searchField)
        blur.addSubview(scrollView)
        blur.addSubview(hint)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: blur.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: blur.trailingAnchor),

            hint.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -8),
            hint.heightAnchor.constraint(equalToConstant: 14)
        ])

        panel = p
    }

    /// Places the palette at the user's configured summon grid point on the
    /// screen the user is actually on (center gets a slight Spotlight-style
    /// upward nudge). The mouse pointer decides which screen that is —
    /// NSScreen.main is "the screen with the key window", which is wrong
    /// whenever FloatyTerm isn't frontmost (e.g. summoned over a fullscreen
    /// app on another display).
    private func positionOnActiveScreen() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let panel, let vis = screen?.visibleFrame else { return }
        let position = Settings.shared.summonPosition
        var frame = position.frame(forSize: panel.frame.size, in: vis, margin: 32)
        if position == .center { frame.origin.y += vis.height * 0.12 }
        panel.setFrame(frame, display: false)
    }

    // MARK: - Filtering / selection

    private func applyFilter(_ text: String, preferredRow: Int = 0) {
        if text.isEmpty {
            filtered = all
        } else {
            let needle = text.lowercased()
            filtered = all.filter {
                $0.name.lowercased().contains(needle)
                    || $0.location.lowercased().contains(needle)
            }
        }
        tableView.reloadData()
        if !filtered.isEmpty {
            let row = max(0, min(filtered.count - 1, preferredRow))
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
    }

    private func moveSelection(by delta: Int) {
        let count = filtered.count
        guard count > 0 else { return }
        let current = tableView.selectedRow
        let next = current < 0
            ? (delta > 0 ? 0 : count - 1)
            : max(0, min(count - 1, current + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    private func summonSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        let entry = filtered[row]
        dismiss()
        onSummon?(entry)
    }

    @objc private func rowDoubleClicked() {
        summonSelected()
    }

    /// Closes one session in place: the palette stays open, refreshes its
    /// list, and keeps the selection near where it was.
    private func close(_ entry: SessionEntry) {
        let keepRow = tableView.selectedRow
        suppressDismissOnResign = true
        onClose?(entry)
        suppressDismissOnResign = false
        all = sessionsProvider()
        applyFilter(searchField.stringValue, preferredRow: max(0, keepRow))
        // The confirmation alert (if any) took key — reclaim it.
        panel?.makeKey()
        panel?.makeFirstResponder(searchField)
    }

    private func closeSelected() {
        let row = tableView.selectedRow
        guard row >= 0, row < filtered.count else { return }
        close(filtered[row])
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):        moveSelection(by: +1); return true
        case #selector(NSResponder.moveUp(_:)):          moveSelection(by: -1); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        case #selector(NSResponder.insertNewline(_:)):   summonSelected(); return true
        // ⌘⌫ in a text field arrives as delete-to-beginning-of-line; here it
        // means "close the selected session" (the hint line documents it).
        case #selector(NSResponder.deleteToBeginningOfLine(_:)):
            closeSelected(); return true
        default: return false
        }
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("sessionCell")
        let cell: SessionCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? SessionCellView {
            cell = reused
        } else {
            cell = SessionCellView()
            cell.identifier = id
        }
        let entry = filtered[row]
        cell.configure(entry)
        cell.onClose = { [weak self] in self?.close(entry) }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SwitcherRowView()
    }
}

/// Borderless panels can't become key by default; the search field needs it.
private final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Rounded selection highlight matching the recent-commands palette.
private final class SwitcherRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 5, yRadius: 5).fill()
    }
}

/// Row layout: [status dot] [type icon] [name ……………] [window avatar] [location] [✕].
private final class SessionCellView: NSTableCellView {
    private let dot = NSView()
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let avatarIcon = NSImageView()
    private let locationLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.75)

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.92)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The host window's avatar, in its ring color — the same identity as
        // its collapsed bubble, so "which window is this in" reads at a glance.
        avatarIcon.translatesAutoresizingMaskIntoConstraints = false

        locationLabel.font = .systemFont(ofSize: 11)
        locationLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        locationLabel.translatesAutoresizingMaskIntoConstraints = false
        locationLabel.setContentHuggingPriority(.required, for: .horizontal)

        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Close session")
        closeButton.isBordered = false
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.35)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.toolTip = "Close this session (⌘⌫)"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(icon)
        addSubview(nameLabel)
        addSubview(avatarIcon)
        addSubview(locationLabel)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            icon.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: avatarIcon.leadingAnchor, constant: -8),

            avatarIcon.trailingAnchor.constraint(equalTo: locationLabel.leadingAnchor, constant: -5),
            avatarIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            avatarIcon.widthAnchor.constraint(equalToConstant: 13),
            avatarIcon.heightAnchor.constraint(equalToConstant: 13),

            locationLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            locationLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: SessionEntry) {
        dot.layer?.backgroundColor = entry.status.color.cgColor
        let symbol = entry.isAgent ? "sparkles" : (entry.isTerminal ? "terminal" : "globe")
        icon.image = NSImage(systemSymbolName: symbol,
                             accessibilityDescription: entry.isAgent ? "Agent"
                                : entry.isTerminal ? "Terminal" : "Browser")
        nameLabel.stringValue = entry.name
        avatarIcon.image = NSImage(systemSymbolName: entry.windowSymbol,
                                   accessibilityDescription: "Window avatar")
        avatarIcon.contentTintColor = entry.windowColor
        locationLabel.stringValue = entry.location
    }

    @objc private func closeTapped() { onClose?() }
}
