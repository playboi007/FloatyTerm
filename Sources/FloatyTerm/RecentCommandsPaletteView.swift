import AppKit

// ---------------------------------------------------------------------------
// MARK: - RecentCommandsPaletteView
// ---------------------------------------------------------------------------

/// An overlay palette for browsing and inserting recent zsh commands.
///
/// Layout:  [search field]
///          [scrollable command list]
///          (thin footer hint)
///
/// Visual style: NSVisualEffectView (.hudWindow, .withinWindow) — same as
/// FindBarView, but taller and centered in the content area.
///
/// Keyboard contract (handled here, not in the window controller):
///  - ↑ / ↓     : move selection
///  - Return     : insert without running (send text, no trailing newline)
///  - ⌘Return    : insert and run (send text + CR 0x0D)
///  - Esc        : dismiss
///  - Any printable character while the table is first-responder → redirect to
///    the search field so the user can just start typing.
final class RecentCommandsPaletteView: NSVisualEffectView {

    // MARK: Callbacks (wired by TerminalWindowController)

    /// Called with the chosen command. `run` == true means append CR.
    var onInsert: ((_ command: String, _ run: Bool) -> Void)?
    /// Called when the palette should be dismissed.
    var onClose: (() -> Void)?

    // MARK: Private subviews

    private let searchField  = NSTextField()
    private let scrollView   = NSScrollView()
    private let tableView    = NSTableView()
    private let closeButton  = NSButton()
    private let hintLabel    = NSTextField(labelWithString:
        "↩ insert  ⌘↩ insert+run  ↑↓ navigate  esc dismiss"
    )

    // MARK: Data

    private var allCommands:         [String] = []
    fileprivate var filteredCommands: [String] = []

    // MARK: Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: Public API

    /// Reloads history from disk and resets the search field. Call each time
    /// the palette is made visible. The file read + parse happens off the main
    /// thread so a large ~/.zsh_history never stalls the open animation; stale
    /// results from a previous reload are discarded via a generation counter.
    private var reloadGeneration = 0
    func reloadHistory() {
        searchField.stringValue = ""
        reloadGeneration += 1
        let generation = reloadGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let commands = ZshHistoryReader.load(limit: 500)
            DispatchQueue.main.async {
                guard let self, self.reloadGeneration == generation else { return }
                self.allCommands = commands
                // Honour whatever the user has typed while the load ran.
                self.applyFilter(self.searchField.stringValue)
                if self.filteredCommands.isEmpty {
                    self.tableView.deselectAll(nil)
                }
            }
        }
    }

    /// Moves keyboard focus to the search field so the user can start typing.
    func focusSearchField() {
        window?.makeFirstResponder(searchField)
    }

    // MARK: Setup

    private func setup() {
        // Backdrop
        material      = .hudWindow
        blendingMode  = .withinWindow
        state         = .active
        wantsLayer    = true
        layer?.cornerRadius  = 10
        layer?.masksToBounds = true

        // ── Search field ──────────────────────────────────────────────────
        searchField.placeholderString = "Search recent commands…"
        searchField.appearance        = NSAppearance(named: .darkAqua)
        searchField.controlSize       = .regular
        searchField.bezelStyle        = .roundedBezel
        searchField.focusRingType     = .none
        searchField.target            = self
        searchField.action            = #selector(searchFieldReturn(_:))
        searchField.delegate          = searchFieldDelegateBox
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // ── Table ─────────────────────────────────────────────────────────
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        column.title = ""
        column.isEditable = false
        column.resizingMask = .autoresizingMask

        tableView.addTableColumn(column)
        tableView.headerView           = nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor      = .clear
        tableView.intercellSpacing     = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.rowHeight            = 22
        tableView.dataSource           = tableDataSource
        tableView.delegate             = tableDelegate
        tableView.doubleAction         = #selector(tableDoubleClicked(_:))
        tableView.target               = self
        // Allow the table to receive key events for arrow-key navigation.
        tableView.refusesFirstResponder = false
        tableView.appearance           = NSAppearance(named: .darkAqua)

        scrollView.documentView        = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground     = false
        scrollView.borderType          = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // ── Close button ──────────────────────────────────────────────────
        closeButton.bezelStyle = .texturedRounded
        closeButton.setButtonType(.momentaryPushIn)
        closeButton.controlSize = .small
        closeButton.image = NSImage(systemSymbolName: "xmark",
                                    accessibilityDescription: "Close palette")
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        closeButton.toolTip = "Close (Esc)"
        closeButton.target  = self
        closeButton.action  = #selector(closeTapped(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        // ── Hint label ────────────────────────────────────────────────────
        hintLabel.font      = .systemFont(ofSize: 10, weight: .light)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        hintLabel.alignment = .center
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        // ── Top row stack (search + close) ────────────────────────────────
        let topStack = NSStackView(views: [searchField, closeButton])
        topStack.orientation   = .horizontal
        topStack.alignment     = .centerY
        topStack.spacing       = 6
        topStack.translatesAutoresizingMaskIntoConstraints = false

        // ── Assemble ──────────────────────────────────────────────────────
        for v in [topStack, scrollView, hintLabel] {
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            // Top row
            topStack.topAnchor.constraint(equalTo: topAnchor,        constant: 10),
            topStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            topStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

            // Scroll view
            scrollView.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor,  constant: 0),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),

            // Hint label
            hintLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            hintLabel.heightAnchor.constraint(equalToConstant: 14),
        ])
        // The table column fills the clip view width.
        column.width = 460
    }

    // MARK: Filtering

    fileprivate func applyFilter(_ text: String) {
        if text.isEmpty {
            filteredCommands = allCommands
        } else {
            let lower = text.lowercased()
            filteredCommands = allCommands.filter {
                $0.lowercased().contains(lower)
            }
        }
        tableView.reloadData()
        // Re-select the first row after every filter change.
        if !filteredCommands.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    // MARK: Selection helpers

    private var selectedCommand: String? {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredCommands.count else { return nil }
        return filteredCommands[row]
    }

    fileprivate func insertSelected(run: Bool) {
        guard let cmd = selectedCommand else { return }
        onInsert?(cmd, run)
    }

    fileprivate func moveSelection(by delta: Int) {
        let count = filteredCommands.count
        guard count > 0 else { return }
        let current = tableView.selectedRow
        let next: Int
        if current < 0 {
            next = delta > 0 ? 0 : count - 1
        } else {
            next = max(0, min(count - 1, current + delta))
        }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: Actions

    @objc private func searchFieldReturn(_ sender: Any?) {
        // Return in the search field inserts without running.
        insertSelected(run: false)
    }

    @objc private func tableDoubleClicked(_ sender: Any?) {
        // Double-click inserts and runs.
        insertSelected(run: true)
    }

    @objc private func closeTapped(_ sender: Any?) {
        onClose?()
    }

    // MARK: Key handling (forwarded from the window)
    //
    // We handle ↑↓/Return/⌘Return/Esc at this level so that none of these
    // events leak down into the terminal view.

    override func keyDown(with event: NSEvent) {
        handleKey(event)
    }

    /// Returns true if the event was consumed.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 125: // ↓
            moveSelection(by: +1); return true
        case 126: // ↑
            moveSelection(by: -1); return true
        case 36:  // Return
            if flags.contains(.command) {
                insertSelected(run: true)
            } else {
                insertSelected(run: false)
            }
            return true
        case 53:  // Esc
            onClose?(); return true
        default:
            // Redirect printable characters typed while the table is focused
            // back into the search field. We move focus there and then re-post
            // the original event so the field's editor receives it naturally.
            if window?.firstResponder === tableView,
               let chars = event.characters, !chars.isEmpty,
               !flags.contains(.command), !flags.contains(.control)
            {
                window?.makeFirstResponder(searchField)
                // Re-post the event so the now-focused field editor handles it.
                if let ev = event.cgEvent.flatMap({ NSEvent(cgEvent: $0) }) {
                    NSApp.postEvent(ev, atStart: true)
                }
                return true
            }
            return false
        }
    }

    // MARK: Lazy delegate/datasource boxes
    //
    // NSTableView's dataSource and delegate must be objects (reference types).
    // We use lightweight private inner boxes so we don't have to make
    // RecentCommandsPaletteView itself conform (avoids AnyObject requirement).

    private lazy var tableDataSource: PaletteTableDataSource = {
        PaletteTableDataSource(palette: self)
    }()

    private lazy var tableDelegate: PaletteTableDelegate = {
        PaletteTableDelegate(palette: self)
    }()

    private lazy var searchFieldDelegateBox: SearchFieldDelegate = {
        SearchFieldDelegate(palette: self)
    }()
}

// MARK: - Table Data Source

private final class PaletteTableDataSource: NSObject, NSTableViewDataSource {
    weak var palette: RecentCommandsPaletteView?
    init(palette: RecentCommandsPaletteView) { self.palette = palette }

    func numberOfRows(in tableView: NSTableView) -> Int {
        palette?.filteredCommands.count ?? 0
    }
}

// MARK: - Table Delegate

private final class PaletteTableDelegate: NSObject, NSTableViewDelegate {
    weak var palette: RecentCommandsPaletteView?
    init(palette: RecentCommandsPaletteView) { self.palette = palette }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard let palette else { return nil }

        let id = NSUserInterfaceItemIdentifier("cell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id

            let tf = NSTextField()
            tf.isEditable         = false
            tf.isSelectable       = false
            tf.isBezeled          = false
            tf.drawsBackground    = false
            tf.font               = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            tf.textColor          = NSColor.white.withAlphaComponent(0.9)
            tf.lineBreakMode      = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        cell.textField?.stringValue = palette.filteredCommands[row]
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = PaletteRowView()
        return rv
    }

    // Allow single-click to confirm (Return key still works via keyDown).
    func tableViewSelectionDidChange(_ notification: Notification) {
        // Nothing extra needed; Return action reads selectedRow at call time.
    }
}

// MARK: - Custom row view (selected row highlight)

private final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 4, yRadius: 4).fill()
    }
}

// MARK: - Search field delegate box

private final class SearchFieldDelegate: NSObject, NSTextFieldDelegate {
    weak var palette: RecentCommandsPaletteView?
    init(palette: RecentCommandsPaletteView) { self.palette = palette }

    func controlTextDidChange(_ obj: Notification) {
        guard let palette,
              let tf = obj.object as? NSTextField else { return }
        palette.applyFilter(tf.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard let palette else { return false }
        // ↑ / ↓ while in the search field → move table selection
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            palette.moveSelection(by: +1); return true
        }
        if commandSelector == #selector(NSResponder.moveUp(_:)) {
            palette.moveSelection(by: -1); return true
        }
        // Esc
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            palette.onClose?(); return true
        }
        // Return / ⌘Return
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let runNow = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            palette.insertSelected(run: runNow)
            return true
        }
        return false
    }
}
