import AppKit

/// A live, clean view of one terminal session's output — for watching an
/// agent (Claude / Fable) work without fighting the TUI: smooth scrolling,
/// native ⌘F search with highlight-all, selectable text, and reactive updates
/// as output streams.
///
/// Renders the session's always-on transcript store (TerminalController
/// captures ANSI-stripped lines from the moment the shell starts), so output
/// that predates opening the reader is already here, and capture keeps
/// working when the terminal is in alternate-screen mode (TUIs), where the
/// terminal buffer itself holds no scrollback. Docked as a child window
/// beside its terminal, so it travels with it.
final class TranscriptReaderController: NSObject, NSWindowDelegate {

    var onClosed: (() -> Void)?

    private(set) weak var session: TerminalController?
    private weak var parentPanel: NSPanel?

    private let panel: ReaderPanel
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let followButton = NSButton()

    // MARK: - Transcript state

    /// Absolute index (including lines the store has dropped) of the next
    /// transcript line to pull from the session.
    private var nextLineIndex = 0
    private var stableLines: [String] = []   // committed lines rendered so far
    private var stableCharCount = 0    // textStorage length of the committed region
    private var following = true
    private var refreshWork: DispatchWorkItem?

    /// Absolute line index where "new since last look" begins — captured on
    /// show() from the session's last-read position. A divider line is
    /// spliced into the rendered text at this point (render-only; never
    /// written into the session's transcript), then cleared.
    private var pendingMarker: Int?

    private static let newSinceLastLookDivider = "── new since last look ──"

    private static let textAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor.white.withAlphaComponent(0.88)
    ]

    init(session: TerminalController, parent: NSPanel, displayName: String) {
        self.session = session
        self.parentPanel = parent
        panel = ReaderPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: parent.frame.height),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        super.init()
        buildUI(displayName: displayName)

        panel.onFind  = { [weak self] in self?.showFind() }
        panel.onClose = { [weak self] in self?.close() }

        // Reactive updates: throttled trailing-edge refresh on every output chunk.
        session.onOutputActivity = { [weak self] in self?.scheduleRefresh() }
    }

    // MARK: - Show / close

    func show() {
        guard let parent = parentPanel else { return }
        panel.level = parent.level
        panel.collectionBehavior = parent.collectionBehavior
        panel.sharingType = parent.sharingType   // inherit screen-capture privacy
        panel.setFrame(dockedFrame(beside: parent), display: false)
        parent.addChildWindow(panel, ordered: .above)   // travels with the terminal
        panel.orderFrontRegardless()
        // Where did the user last leave off? If output has accumulated since,
        // remember the boundary so refresh() can splice a divider there.
        if let session {
            let marker = session.transcriptLastReadIndex
            let end = session.transcriptDropped + session.transcriptLines.count
            if marker > 0 && marker < end { pendingMarker = marker }
        }
        refresh()
        if following { textView.scrollToEndOfDocument(nil) }
    }

    func close() {
        // The user has now seen everything committed so far.
        if let session {
            session.transcriptLastReadIndex =
                session.transcriptDropped + session.transcriptLines.count
        }
        session?.onOutputActivity = nil
        refreshWork?.cancel()
        parentPanel?.removeChildWindow(panel)
        panel.orderOut(nil)
        onClosed?()
    }

    /// Beside the terminal: to the right when there's room, else to the left.
    private func dockedFrame(beside parent: NSPanel) -> NSRect {
        let width: CGFloat = 480
        let p = parent.frame
        var f = NSRect(x: p.maxX + 8, y: p.minY, width: width, height: p.height)
        if let vis = parent.screen?.visibleFrame, f.maxX > vis.maxX {
            f.origin.x = p.minX - width - 8
            if f.minX < vis.minX { f.origin.x = vis.minX }
        }
        return f
    }

    // MARK: - UI

    private func buildUI(displayName: String) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        blur.frame = panel.contentView?.bounds ?? .zero
        blur.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(blur)

        titleLabel.stringValue = "Transcript — \(displayName)"
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        configure(followButton, symbol: "arrow.down.to.line",
                  tooltip: "Follow output (auto-scroll)", action: #selector(toggleFollow))
        followButton.contentTintColor = .controlAccentColor   // following = on

        let findButton = NSButton()
        configure(findButton, symbol: "magnifyingglass", tooltip: "Find (⌘F)",
                  action: #selector(findTapped))
        let closeButton = NSButton()
        configure(closeButton, symbol: "xmark", tooltip: "Close (⌘W)",
                  action: #selector(closeTapped))

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.usesFindBar = true              // native ⌘F bar with highlight-all
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Follow-state tracking: scrolling away from the bottom pauses follow,
        // returning to the bottom resumes it.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        for v in [titleLabel, followButton, findButton, closeButton, scrollView] {
            blur.addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: blur.topAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: followButton.leadingAnchor, constant: -8),

            closeButton.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            findButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            findButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            followButton.trailingAnchor.constraint(equalTo: findButton.leadingAnchor, constant: -4),
            followButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: blur.bottomAnchor)
        ])
    }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.isBordered = false
        button.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
    }

    // MARK: - Actions

    @objc private func toggleFollow() {
        following.toggle()
        followButton.contentTintColor = following
            ? .controlAccentColor : NSColor.white.withAlphaComponent(0.7)
        if following { textView.scrollToEndOfDocument(nil) }
    }

    @objc private func findTapped() { showFind() }
    @objc private func closeTapped() { close() }

    private func showFind() {
        panel.makeKey()
        panel.makeFirstResponder(textView)
        let proxy = NSMenuItem()
        proxy.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(proxy)
    }

    @objc private func scrolled() {
        let visible = scrollView.contentView.bounds
        let docHeight = textView.frame.height
        let atBottom = visible.maxY >= docHeight - 30
        if following != atBottom {
            following = atBottom
            followButton.contentTintColor = following
                ? .controlAccentColor : NSColor.white.withAlphaComponent(0.7)
        }
    }

    // MARK: - Transcript mirroring

    private func scheduleRefresh() {
        guard refreshWork == nil else { return }   // trailing-edge throttle
        let work = DispatchWorkItem { [weak self] in
            self?.refreshWork = nil
            self?.refresh()
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Pulls lines committed to the session's transcript since the last
    /// refresh and appends them; the live screen renders as a volatile tail
    /// that's rewritten in place (so TUI frames and progress bars update live
    /// without disturbing scroll position or selection above).
    private func refresh() {
        guard panel.isVisible, let session else { return }

        // Expire old lines first, so `dropped` and `lines` are read from one
        // consistent state.
        session.purgeExpiredTranscript()
        let dropped = session.transcriptDropped
        let lines = session.transcriptLines
        // If we fell more than a whole buffer behind (shouldn't happen with a
        // 10k-line store and a 0.15s refresh), the gap is silently skipped.
        let start = max(nextLineIndex - dropped, 0)
        var newStable = start < lines.count ? Array(lines[start...]) : []
        let batchStart = dropped + start   // absolute index of newStable[0]
        nextLineIndex = dropped + lines.count

        // Splice the "new since last look" divider once the batch reaches the
        // marker. Absolute → array offset: marker − batchStart (clamped to 0
        // in case the marked line itself already aged out of the store). The
        // divider exists only in the rendered text — the session's transcript
        // is untouched; the reader's own line/char bookkeeping just treats it
        // as one more line.
        if let marker = pendingMarker, marker < nextLineIndex, !newStable.isEmpty {
            newStable.insert(Self.newSinceLastLookDivider,
                             at: max(marker - batchStart, 0))
            pendingMarker = nil
        }
        stableLines.append(contentsOf: newStable)

        // While following the tail live, the user is caught up.
        if following { session.transcriptLastReadIndex = nextLineIndex }

        // The mirror's live screen (or a TUI's current frame): rewritten in
        // place on every refresh rather than committed.
        let volatileLines = session.transcriptVolatile

        render(newStable: newStable, volatile: volatileLines)
        capIfNeeded(volatile: volatileLines)
    }

    /// Appends newly-committed lines and rewrites only the volatile tail, so
    /// scroll position and selection in the committed region stay put.
    private func render(newStable: [String], volatile: [String]) {
        guard let storage = textView.textStorage else { return }
        var tail = ""
        var addedStable = 0
        if !newStable.isEmpty {
            let chunk = newStable.map { $0 + "\n" }.joined()
            addedStable = (chunk as NSString).length
            tail += chunk
        }
        tail += volatile.joined(separator: "\n")

        let replaceRange = NSRange(location: stableCharCount,
                                   length: storage.length - stableCharCount)
        storage.replaceCharacters(
            in: replaceRange,
            with: NSAttributedString(string: tail, attributes: Self.textAttributes))
        stableCharCount += addedStable

        if following { textView.scrollToEndOfDocument(nil) }
    }

    /// Bounds memory: beyond 8000 committed lines, drop the oldest 2000 and
    /// rebuild the storage once.
    private func capIfNeeded(volatile: [String]) {
        guard stableLines.count > 8000, let storage = textView.textStorage else { return }
        stableLines.removeFirst(2000)
        let stableText = stableLines.map { $0 + "\n" }.joined()
        stableCharCount = (stableText as NSString).length
        let full = stableText + volatile.joined(separator: "\n")
        storage.setAttributedString(
            NSAttributedString(string: full, attributes: Self.textAttributes))
        if following { textView.scrollToEndOfDocument(nil) }
    }
}

/// Resizable companion panel; key-able so the find bar can take typing.
private final class ReaderPanel: NSPanel {
    var onFind: (() -> Void)?
    var onClose: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "f": onFind?(); return true
            case "w": onClose?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
