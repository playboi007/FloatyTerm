import AppKit
import SwiftTerm

/// A terminal view that adds the standard macOS clipboard shortcuts, file-drop
/// support, a right-click context menu, and ⌘-click link/path routing.
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
        installLinkInterceptor()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerDragTypes()
        installLinkInterceptor()
    }

    // MARK: - ⌘-click link interception

    /// Wired by TerminalController: receives the link/path string when the
    /// user ⌘-clicks a detected link (explicit OSC 8 or SwiftTerm's implicit
    /// URL/filesystem-path detection). When nil, SwiftTerm's default handling
    /// applies (NSWorkspace.open — fine for https, a silent no-op for bare
    /// paths).
    var onOpenLink: ((String, [String: String]) -> Void)?

    /// Strong reference — `terminalDelegate` is weak.
    private var linkInterceptor: LinkInterceptingDelegate?

    /// `requestOpenLink` lives in a TerminalViewDelegate protocol *extension*,
    /// and LocalProcessTerminalView (which is its own terminalDelegate) never
    /// declares it — so a subclass override here would never dispatch: the
    /// conformance witness is statically bound to the extension default.
    /// Instead we splice a forwarding proxy in front of the delegate chain:
    /// every callback passes through to the view's own implementation (pty
    /// writes, resize, title…), only requestOpenLink is redirected.
    private func installLinkInterceptor() {
        let proxy = LinkInterceptingDelegate()
        proxy.inner = terminalDelegate
        proxy.onOpenLink = { [weak self] link, params in
            guard let self else { return }
            if let handler = self.onOpenLink {
                handler(link, params)
            } else if let url = URL(string: link) {
                NSWorkspace.shared.open(url)   // SwiftTerm's default behavior
            }
        }
        terminalDelegate = proxy
        linkInterceptor = proxy
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

    // MARK: - Live-resize freeze
    //
    // SwiftTerm's setFrameSize resizes the terminal grid on EVERY frame of a
    // live window drag: each pass reflows the whole scrollback (splitting and
    // merging wrapped rows) and SIGWINCHes the pty, so a TUI like Claude Code
    // re-renders at every intermediate width. The intermediate renders are
    // committed into the scrollback and the repeated reflows scramble them —
    // permanent visual garbage in both the terminal and the transcript.
    //
    // Freeze the grid while the drag is in flight: swallow intermediate
    // sizes and apply only the final one when the drag ends. One reflow,
    // one SIGWINCH, one TUI re-render per drag.

    /// The most recent size requested during a live resize; applied once the
    /// drag ends.
    private var liveResizeDeferredSize: NSSize?

    override func setFrameSize(_ newSize: NSSize) {
        if window?.inLiveResize == true, newSize != frame.size {
            liveResizeDeferredSize = newSize
            return
        }
        liveResizeDeferredSize = nil
        super.setFrameSize(newSize)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if let size = liveResizeDeferredSize {
            liveResizeDeferredSize = nil
            super.setFrameSize(size)
        }
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

    // MARK: - ⌥-mouse: talk to the terminal, not the app inside it
    //
    // Two gestures share the ⌥ modifier, split by who currently owns the
    // mouse:
    //  • A TUI has enabled mouse reporting (vim, tmux…): ⌥-drag bypasses the
    //    reporting for the duration of the gesture so local text selection
    //    works again — otherwise every drag is swallowed by the app and
    //    selecting text is impossible.
    //  • No mouse reporting (shell prompt): ⌥-click moves the shell's cursor
    //    to the clicked column by synthesizing ←/→ arrow keys — the line
    //    editor does the actual moving, so this can't corrupt anything.
    //
    // SwiftTerm's mouseDown/Dragged/Up are `public` but not `open`, so these
    // can't be overridden here. FloatingPanel.sendEvent calls the three hooks
    // below instead: optionMouseDown BEFORE the event dispatches (so the
    // reporting bypass is in place when SwiftTerm sees the click) and
    // optionMouseUp AFTER (so the TUI never receives a stray button-release
    // and the click has fully resolved before the cursor moves).

    /// True while an ⌥-initiated gesture has `allowMouseReporting` forced off;
    /// restored on mouse-up.
    private var optionGestureBypassedReporting = false

    /// The mouse-down point of a candidate ⌥-click cursor move; cancelled if
    /// the gesture turns into a drag (which means selection, not a jump).
    private var optionClickPending: NSPoint?

    /// Pre-dispatch hook for an ⌥-mouse-down inside this view.
    func optionMouseDown(_ event: NSEvent) {
        if getTerminal().mouseMode != .off, allowMouseReporting {
            allowMouseReporting = false
            optionGestureBypassedReporting = true
        } else if event.clickCount == 1 {
            optionClickPending = convert(event.locationInWindow, from: nil)
        }
    }

    /// Called for any drag while the ⌥-gesture is in flight.
    func optionMouseDragged() {
        optionClickPending = nil
    }

    /// Post-dispatch hook for the mouse-up ending the ⌥-gesture.
    func optionMouseUp() {
        if optionGestureBypassedReporting {
            allowMouseReporting = true
            optionGestureBypassedReporting = false
        }
        if let point = optionClickPending {
            optionClickPending = nil
            moveShellCursor(toward: point)
        }
    }

    /// Sends the arrow presses that walk the shell cursor to the clicked
    /// column. Constraints keep it safe: mouse reporting must be off, the
    /// viewport must be at the live screen (in scrollback the clicked row
    /// can't be compared against the cursor's), and the click must land on
    /// the cursor's own visual row — arrows aimed at other rows are how you
    /// accidentally walk through shell history.
    private func moveShellCursor(toward point: NSPoint) {
        let terminal = getTerminal()
        guard terminal.mouseMode == .off else { return }
        guard !(canScroll && scrollPosition < 1.0) else { return }
        let rows = terminal.rows, cols = terminal.cols
        guard rows > 0, cols > 0 else { return }

        // Cell geometry: height is exact from the optimal frame (cellH × rows);
        // width replicates SwiftTerm's own metric ("W" glyph advance) via
        // CoreText. calculateMouseHit is internal, so this mirrors its math.
        let cellHeight = getOptimalFrameSize().height / CGFloat(rows)
        let ctFont = font as CTFont
        var wChar: [UniChar] = [UniChar(87)]  // "W"
        var wGlyph: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(ctFont, &wChar, &wGlyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, wGlyph, &advance, 1)
        let cellWidth = advance.width
        guard cellWidth > 0, cellHeight > 0 else { return }

        let row = Int((frame.height - point.y) / cellHeight)
        let col = max(0, min(cols - 1, Int(point.x / cellWidth)))
        guard row == terminal.buffer.y else { return }
        let delta = col - terminal.buffer.x
        guard delta != 0 else { return }

        let arrow = terminal.applicationCursor
            ? (delta > 0 ? "\u{1B}OC" : "\u{1B}OD")
            : (delta > 0 ? "\u{1B}[C" : "\u{1B}[D")
        send(txt: String(repeating: arrow, count: abs(delta)))
    }

    // MARK: - Key equivalents (⌘C/V/A/Z, ⌥⌘⌫)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌥⌘⌫ — clear scrollback (also in the right-click menu). Contextual:
        // when a selection is active, the window's selection monitor consumes
        // this combo first to dismiss the highlight, so it only lands here —
        // and clears scrollback — when nothing is selected.
        if event.type == .keyDown, flags == [.command, .option], event.keyCode == 51 {
            clearScrollback(nil)
            return true
        }
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

        // Clear Scrollback — visual only; the transcript keeps its history.
        let clearSBItem = menu.addItem(
            withTitle: "Clear Scrollback",
            action: #selector(clearScrollback(_:)),
            keyEquivalent: "\u{08}"
        )
        clearSBItem.keyEquivalentModifierMask = [.command, .option]
        clearSBItem.target = self
        clearSBItem.isEnabled = canScroll

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

    /// Erases the scrollback buffer (CSI 3 J, fed straight to the view — the
    /// pty never sees it). Purely visual: the transcript mirror and tunnel
    /// history are fed from pty output, so the session record is untouched.
    @objc private func clearScrollback(_ sender: Any?) {
        feed(text: "\u{1B}[3J")
        // CSI 3 J trims the buffer without marking anything dirty; normalize
        // the viewport and force a repaint so the change shows immediately.
        scrollToBottom()
        setNeedsDisplay(bounds)
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

/// Forwards every TerminalViewDelegate callback to the terminal view's own
/// implementation — LocalProcessTerminalView is its own delegate and its
/// implementations feed the pty (send), track resizes, titles, cwd, etc. —
/// except `requestOpenLink`, which is redirected to `onOpenLink`.
///
/// `inner` is weak (it's the view itself; the view strongly retains this
/// proxy), so there is no retain cycle.
private final class LinkInterceptingDelegate: TerminalViewDelegate {
    weak var inner: TerminalViewDelegate?
    var onOpenLink: ((String, [String: String]) -> Void)?

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let onOpenLink {
            onOpenLink(link, params)
        } else {
            inner?.requestOpenLink(source: source, link: link, params: params)
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        inner?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }
    func setTerminalTitle(source: TerminalView, title: String) {
        inner?.setTerminalTitle(source: source, title: title)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        inner?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        inner?.send(source: source, data: data)
    }
    func scrolled(source: TerminalView, position: Double) {
        inner?.scrolled(source: source, position: position)
    }
    func bell(source: TerminalView) {
        inner?.bell(source: source)
    }
    func clipboardCopy(source: TerminalView, content: Data) {
        inner?.clipboardCopy(source: source, content: content)
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        inner?.iTermContent(source: source, content: content)
    }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        inner?.rangeChanged(source: source, startY: startY, endY: endY)
    }
}
