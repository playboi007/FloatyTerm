import AppKit

/// One row in the session switcher: a tab somewhere in some window.
struct SessionEntry {
    weak var window: TerminalWindowController?
    let tab: any TabContent
    let name: String
    let location: String        // "here" / "another Space" / "hidden" / "in bubble"
    let status: SessionStatus
    let isTerminal: Bool
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

        let hint = NSTextField(labelWithString: "↩ summon here   ↑↓ navigate   esc dismiss")
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
    /// active screen (center gets a slight Spotlight-style upward nudge).
    private func positionOnActiveScreen() {
        guard let panel,
              let vis = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let position = Settings.shared.summonPosition
        var frame = position.frame(forSize: panel.frame.size, in: vis, margin: 32)
        if position == .center { frame.origin.y += vis.height * 0.12 }
        panel.setFrame(frame, display: false)
    }

    // MARK: - Filtering / selection

    private func applyFilter(_ text: String) {
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
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
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
        cell.configure(filtered[row])
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

/// Row layout: [status dot] [type icon] [name ……………] [location].
private final class SessionCellView: NSTableCellView {
    private let dot = NSView()
    private let icon = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let locationLabel = NSTextField(labelWithString: "")

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

        locationLabel.font = .systemFont(ofSize: 11)
        locationLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        locationLabel.translatesAutoresizingMaskIntoConstraints = false
        locationLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(dot)
        addSubview(icon)
        addSubview(nameLabel)
        addSubview(locationLabel)

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
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: locationLabel.leadingAnchor, constant: -8),

            locationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            locationLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: SessionEntry) {
        dot.layer?.backgroundColor = entry.status.color.cgColor
        icon.image = NSImage(systemSymbolName: entry.isTerminal ? "terminal" : "globe",
                             accessibilityDescription: entry.isTerminal ? "Terminal" : "Browser")
        nameLabel.stringValue = entry.name
        locationLabel.stringValue = entry.location
    }
}
