import AppKit
import SwiftTerm

/// A terminal view that adds the standard macOS clipboard shortcuts, file-drop
/// support, and a right-click context menu.
///
/// Because FloatyTerm is a menu-less accessory app, the system doesn't route
/// ⌘C/⌘V/⌘A to the terminal automatically (there's no Edit menu to carry the
/// key equivalents). We handle them here instead.
///
/// Note: ⌘C is the *copy* shortcut and is independent of Ctrl-C, which still
/// sends SIGINT to the running program as usual.
final class FloatyTerminalView: LocalProcessTerminalView {

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerDragTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerDragTypes()
    }

    // MARK: - Output hook

    /// Fired with the raw bytes whenever the shell produces output (pty →
    /// view). TerminalController uses it for "unseen output" tracking and the
    /// ticker's live last-line.
    var onOutput: ((ArraySlice<UInt8>) -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        onOutput?(slice)
    }

    // MARK: - Window-drag guard

    /// The terminal area must never move the window; text selection and input
    /// must work normally here. `isMovableByWindowBackground` is already set to
    /// false on the panel, but this belt-and-suspenders override guarantees the
    /// terminal view never participates in window dragging even if the panel
    /// setting were ever reverted.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - Selection / scroll helpers (public API surface for context menus)

    /// True when the user has an active text selection in the terminal.
    /// Backed by SwiftTerm's public `selectionActive` property.
    var hasSelection: Bool { selectionActive }

    /// Returns the currently selected text, or nil if nothing is selected.
    /// Backed by SwiftTerm's public `getSelection()` method.
    var selectedText: String? { getSelection() }

    /// Scrolls the terminal viewport to the very bottom (most-recent output).
    /// Uses SwiftTerm's public `scroll(toPosition:)` with position 1.0.
    func scrollToBottom() {
        scroll(toPosition: 1.0)
    }

    /// Scrolls the terminal viewport to the very top of the scrollback buffer.
    /// Uses SwiftTerm's public `scroll(toPosition:)` with position 0.0.
    func scrollToTop() {
        scroll(toPosition: 0.0)
    }

    // MARK: - Key equivalents (⌘C/V/A/Z)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard event.type == .keyDown, flags == .command else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers {
        case "c":
            // Only intercept ⌘C when text is actually selected, so we never
            // clobber the clipboard with an empty string when nothing is picked.
            // Must use SwiftTerm's selection state — selectedRange() is the
            // NSTextInputClient (IME marked-text) range, not the mouse selection.
            if hasSelection {
                copy(self)
                return true
            }
            return super.performKeyEquivalent(with: event)
        case "v":
            paste(self)
            return true
        case "a":
            selectAll(nil)
            return true
        case "z":
            // There's no document-style undo in a terminal. This triggers zsh's
            // line-editor `undo` widget (default-bound to Ctrl-_, byte 0x1F),
            // which reverts edits to the command you're currently typing.
            send([0x1F])
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: - Right-click context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Terminal")

        // Copy — enabled only when there is an active selection.
        let copyItem = menu.addItem(
            withTitle: "Copy",
            action: #selector(copy(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        copyItem.isEnabled = hasSelection

        // Paste
        let pasteItem = menu.addItem(
            withTitle: "Paste",
            action: #selector(paste(_:)),
            keyEquivalent: ""
        )
        pasteItem.target = self

        // Select All
        let selectAllItem = menu.addItem(
            withTitle: "Select All",
            action: #selector(selectAll(_:)),
            keyEquivalent: ""
        )
        selectAllItem.target = self

        menu.addItem(.separator())

        // Clear — sends the standard shell clear sequence (Ctrl-L).
        let clearItem = menu.addItem(
            withTitle: "Clear",
            action: #selector(clearTerminal(_:)),
            keyEquivalent: ""
        )
        clearItem.target = self

        // Scroll to Bottom — only useful when the user has scrolled up.
        let scrollBottomItem = menu.addItem(
            withTitle: "Scroll to Bottom",
            action: #selector(scrollToBottomAction(_:)),
            keyEquivalent: ""
        )
        scrollBottomItem.target = self
        scrollBottomItem.isEnabled = canScroll && scrollPosition < 1.0

        return menu
    }

    /// Sends Ctrl-L to the shell, which triggers the `clear` built-in in most shells.
    @objc private func clearTerminal(_ sender: Any?) {
        send([0x0C]) // Ctrl-L
    }

    /// Action wrapper so the menu item can target `self` with a selector.
    @objc private func scrollToBottomAction(_ sender: Any?) {
        scrollToBottom()
    }

    // MARK: - File / URL drag-and-drop

    /// The pasteboard types we accept. We handle file URLs, generic URLs, and
    /// plain text (so text dragged from other apps also works).
    private static let acceptedDragTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        .URL,
        .string
    ]

    private func registerDragTypes() {
        registerForDraggedTypes(Self.acceptedDragTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return dragOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        // Nothing special needed; the drag highlight is handled by AppKit.
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return dragOperation(for: sender) != []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = collectPaths(from: sender.draggingPasteboard)
        guard !paths.isEmpty else { return false }

        // Shell-quote each path (single-quote wrapping; embedded single-quotes
        // become '\'') and join with spaces.
        let quoted = paths.map { shellQuote($0) }.joined(separator: " ")
        // Append a trailing space so the user can continue typing immediately.
        send(txt: quoted + " ")
        return true
    }

    // MARK: - Drag helpers

    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        let hasAcceptable = pb.canReadItem(withDataConformingToTypes: [
            NSPasteboard.PasteboardType.fileURL.rawValue,
            NSPasteboard.PasteboardType.URL.rawValue,
            NSPasteboard.PasteboardType.string.rawValue
        ])
        return hasAcceptable ? .copy : []
    }

    /// Reads the pasteboard and returns an ordered list of path/URL strings.
    /// File URLs are converted to their filesystem path; other URLs and strings
    /// are used as-is.
    private func collectPaths(from pb: NSPasteboard) -> [String] {
        var results: [String] = []

        // 1. File URLs (highest priority — gives us clean filesystem paths).
        if let fileURLItems = pb.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]
        {
            results.append(contentsOf: fileURLItems.map { $0.path })
        }

        // 2. Non-file URLs (http/https etc.) — use the absolute string.
        if results.isEmpty,
           let urlItems = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        {
            let nonFile = urlItems.filter { !$0.isFileURL }
            results.append(contentsOf: nonFile.map { $0.absoluteString })
        }

        // 3. Plain string fallback.
        if results.isEmpty, let str = pb.string(forType: .string), !str.isEmpty {
            results.append(str)
        }

        return results
    }

    /// Single-quote wraps a string for POSIX shell safety.
    /// Any embedded single-quote is replaced with the sequence: '\''
    /// e.g.  /my path/it's here  →  '/my path/it'"'"'s here'
    private func shellQuote(_ s: String) -> String {
        // Replace each ' with '\'' then wrap the whole thing in outer quotes.
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
