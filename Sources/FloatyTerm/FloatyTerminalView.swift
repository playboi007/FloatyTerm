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

    /// Wired by TerminalController: current armed state and toggle for the
    /// "Notify When Done" item — so the action is reachable even on a
    /// single-tab window, where no tab chip exists to right-click.
    var notifyWhenDoneState: (() -> Bool)?
    var onToggleNotifyWhenDone: (() -> Void)?

    /// Wired by TerminalController: the shell's current working directory, used
    /// to resolve relative image paths in the selection. nil when unavailable.
    var currentDirectoryProvider: (() -> String?)?

    /// Wired by TerminalController: invoked with an absolute image-file path
    /// when the user picks "Open in Image Viewer" from the context menu.
    var onOpenImageInViewer: ((String) -> Void)?

    /// Wired by TerminalController: invoked with an absolute Markdown-file path
    /// when the user picks "Open in Markdown Viewer" from the context menu.
    var onOpenMarkdownInViewer: ((String) -> Void)?

    /// Resolves the current selection to an absolute filesystem path — absolute
    /// as-is, or relative to the shell's cwd — trimming surrounding quotes the
    /// user may have selected. Returns nil when there's no usable selection.
    private func selectedFilePath() -> String? {
        guard let raw = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let unquoted = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        let expanded = (unquoted as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return expanded
        } else if let cwd = currentDirectoryProvider?(), !cwd.isEmpty {
            return (cwd as NSString).appendingPathComponent(expanded)
        }
        return expanded
    }

    /// The selected path if it names an existing image file, else nil.
    private func selectedImagePath() -> String? {
        guard let p = selectedFilePath(), ImageViewerController.isImageFile(p) else { return nil }
        return p
    }

    /// The selected path if it names an existing Markdown file, else nil.
    private func selectedMarkdownPath() -> String? {
        guard let p = selectedFilePath(), MarkdownViewerController.isMarkdownFile(p) else { return nil }
        return p
    }

    @objc private func openSelectedImage(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onOpenImageInViewer?(path)
    }

    @objc private func openSelectedMarkdown(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        onOpenMarkdownInViewer?(path)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "Terminal")
        // SwiftTerm's validateUserInterfaceItem returns false for selectors
        // it doesn't know (Tail DevTools Log, Notify When Done…), which the
        // auto-enabling menu turns into permanently grayed-out items. Manual
        // isEnabled below is authoritative instead.
        menu.autoenablesItems = false

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

        // Open in Viewer — only when the selection resolves to an image or
        // Markdown file on disk. Opens it in a child tab next to this terminal.
        if let imagePath = selectedImagePath() {
            menu.addItem(.separator())
            let openImg = menu.addItem(
                withTitle: "Open in Image Viewer",
                action: #selector(openSelectedImage(_:)),
                keyEquivalent: ""
            )
            openImg.target = self
            openImg.representedObject = imagePath
            openImg.image = NSImage(systemSymbolName: "photo",
                                    accessibilityDescription: nil)
        } else if let mdPath = selectedMarkdownPath() {
            menu.addItem(.separator())
            let openMd = menu.addItem(
                withTitle: "Open in Markdown Viewer",
                action: #selector(openSelectedMarkdown(_:)),
                keyEquivalent: ""
            )
            openMd.target = self
            openMd.representedObject = mdPath
            openMd.image = NSImage(systemSymbolName: "doc.richtext",
                                   accessibilityDescription: nil)
        }

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

        menu.addItem(.separator())

        // Stage "tail -f <newest devtools log>" at the prompt — the one-step
        // way to point an agent at the live browser console/network feed.
        let tailItem = menu.addItem(
            withTitle: "Tail DevTools Log",
            action: #selector(tailDevtoolsLog(_:)),
            keyEquivalent: ""
        )
        tailItem.target = self
        tailItem.image = NSImage(systemSymbolName: "waveform.path.ecg",
                                 accessibilityDescription: nil)
        let logs = DevtoolsRelay.allLogs()
        tailItem.isEnabled = !logs.isEmpty
        // Progressive disclosure: one log = plain click (latest); several =
        // a submenu, latest on top, then everything by provenance.
        if logs.count > 1 {
            let sub = NSMenu(title: "Logs")
            sub.autoenablesItems = false
            let latest = sub.addItem(withTitle: "Latest — \(logs[0].name)",
                                     action: #selector(tailSpecificLog(_:)), keyEquivalent: "")
            latest.target = self
            latest.representedObject = logs[0].path
            sub.addItem(.separator())
            for log in logs {
                let item = sub.addItem(withTitle: "\(log.category)/\(log.name)",
                                       action: #selector(tailSpecificLog(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = log.path
            }
            tailItem.submenu = sub
        }

        if let armed = notifyWhenDoneState?() {
            let notify = menu.addItem(
                withTitle: "Notify When Done",
                action: #selector(toggleNotifyWhenDone(_:)),
                keyEquivalent: ""
            )
            notify.target = self
            notify.state = armed ? .on : .off
            notify.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)
        }

        return menu
    }

    @objc private func toggleNotifyWhenDone(_ sender: Any?) {
        onToggleNotifyWhenDone?()
    }

    @objc private func tailDevtoolsLog(_ sender: Any?) {
        guard let path = DevtoolsRelay.newestLogPath() else { return }
        // Staged, not executed: at a shell it's ready to run with ↩; at an
        // agent prompt the user can prepend/append instructions first.
        send(txt: "tail -f \"\(path)\" ")
    }

    @objc private func tailSpecificLog(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        send(txt: "tail -f \"\(path)\" ")
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
