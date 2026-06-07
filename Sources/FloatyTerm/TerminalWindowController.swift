import AppKit
import SwiftTerm

/// Owns one floating window:
///  - a frosted top region (header controls + a tab strip that appears when
///    there are 2+ tabs) that stays opaque as a visual reference,
///  - a content area below it that shows the active tab's terminal and whose
///    opacity/blur is configurable.
final class TerminalWindowController: NSObject, NSWindowDelegate {
    let panel: FloatingPanel

    private let root = NSView()
    private let topBlur = NSVisualEffectView()      // header + tab strip backdrop (always)
    private let contentBlur = NSVisualEffectView()  // terminal backdrop (toggleable)
    private let contentArea = NSView()
    private let header = HeaderControlsView()
    private let tabStrip = TabStripView()

    // MARK: - Find bar
    private let findBar = FindBarView()
    private var findBarTrailingConstraint: NSLayoutConstraint!
    private var findBarTopConstraint: NSLayoutConstraint!
    private var isFindBarVisible = false

    // MARK: - Recent-commands palette
    private let recentPalette = RecentCommandsPaletteView()
    private var isPaletteVisible = false

    private let headerHeight: CGFloat = 28
    private let tabStripHeight: CGFloat = 30
    private var tabStripHeightConstraint: NSLayoutConstraint!

    private var tabs: [TerminalController] = []
    private var activeIndex = 0

    var onNewWindow: (() -> Void)?
    var onClosed: ((TerminalWindowController) -> Void)?
    var onOpenPreferences: (() -> Void)?

    override init() {
        let initial = NSRect(x: 0, y: 0, width: 720, height: 460)
        panel = FloatingPanel(contentRect: initial)
        super.init()

        panel.delegate = self
        panel.setupFloatingBehavior()

        root.frame = initial
        root.autoresizingMask = [.width, .height]
        panel.contentView = root

        topBlur.material = .hudWindow
        topBlur.blendingMode = .behindWindow
        topBlur.state = .active

        contentBlur.material = .hudWindow
        contentBlur.blendingMode = .behindWindow
        contentBlur.state = .active

        for v in [topBlur, contentBlur, contentArea, header, tabStrip] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(contentBlur)
        root.addSubview(contentArea)
        root.addSubview(topBlur)
        topBlur.addSubview(header)
        topBlur.addSubview(tabStrip)

        tabStripHeightConstraint = tabStrip.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            topBlur.topAnchor.constraint(equalTo: root.topAnchor),
            topBlur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBlur.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            header.topAnchor.constraint(equalTo: topBlur.topAnchor),
            header.leadingAnchor.constraint(equalTo: topBlur.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: topBlur.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: headerHeight),

            tabStrip.topAnchor.constraint(equalTo: header.bottomAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: topBlur.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: topBlur.trailingAnchor),
            tabStrip.bottomAnchor.constraint(equalTo: topBlur.bottomAnchor),
            tabStripHeightConstraint,

            contentBlur.topAnchor.constraint(equalTo: topBlur.bottomAnchor),
            contentBlur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentBlur.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentBlur.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            contentArea.topAnchor.constraint(equalTo: contentBlur.topAnchor),
            contentArea.leadingAnchor.constraint(equalTo: contentBlur.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: contentBlur.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: contentBlur.bottomAnchor)
        ])

        header.onAddTab = { [weak self] in self?.addTab() }
        header.onNewWindow = { [weak self] in self?.onNewWindow?() }
        tabStrip.onSelect = { [weak self] i in self?.selectTab(i) }
        tabStrip.onCloseTab = { [weak self] i in self?.closeTab(i) }

        panel.keyCommandHandler = { [weak self] event in
            self?.handleKeyCommand(event) ?? false
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChange, object: nil
        )

        setupFindBar()
        setupRecentPalette()
        addTab() // start with one tab
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Window placement / visibility

    func setupInitialFrame(cascadeIndex: Int) {
        panel.restoreSavedFrame()
        if cascadeIndex > 0 {
            let offset = CGFloat(cascadeIndex) * 26
            var f = panel.frame
            f.origin.x += offset
            f.origin.y -= offset
            panel.setFrame(f, display: false)
        }
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        focusActiveTab()
    }

    func hide() {
        panel.saveFrame()
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }

    /// Public entry for the menu bar's "New Tab".
    func openNewTab() { addTab() }

    // MARK: - Keyboard commands

    private func handleKeyCommand(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if flags == .command {
            switch chars {
            case "t": addTab(); return true
            case "w": closeTab(activeIndex); return true
            case "n": onNewWindow?(); return true
            case ",": onOpenPreferences?(); return true
            case "f": toggleFindBar(); return true
            case "g": findNext(); return true
            case "r": toggleRecentPalette(); return true
            default:
                if let n = Int(chars), (1...9).contains(n) {
                    selectTab(n - 1)
                    return true
                }
            }
        } else if flags == [.command, .shift] {
            if event.keyCode == 30 { cycleTab(+1); return true } // ⌘⇧]  next
            if event.keyCode == 33 { cycleTab(-1); return true } // ⌘⇧[  prev
            if chars == "g"        { findPrevious(); return true } // ⌘⇧G prev match
        }
        return false
    }

    private func cycleTab(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        selectTab((activeIndex + delta + tabs.count) % tabs.count)
    }

    // MARK: - Appearance (transparency + blur)

    /// Controls the terminal region's opacity and the blur toggle. We fade the
    /// whole content area (the reliable mechanism for this terminal engine);
    /// with blur OFF and a low value, the live content behind shows through.
    /// The top region (header + tab strip) keeps full opacity as a reference.
    private func applyAppearance(focused: Bool) {
        contentBlur.isHidden = !Settings.shared.backgroundBlur
        let alpha = (Settings.shared.dimWhenUnfocused && !focused)
            ? Settings.shared.unfocusedOpacity
            : Settings.shared.focusedOpacity
        contentArea.alphaValue = CGFloat(alpha)
    }

    @objc private func settingsChanged() {
        tabs.forEach { $0.applyFont() }
        applyAppearance(focused: panel.isKeyWindow)
    }

    // MARK: - Tabs

    private func addTab() {
        let tab = TerminalController()
        tab.onTerminated = { [weak self, weak tab] in
            guard let self, let tab,
                  let idx = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.closeTab(idx)
        }
        tab.onTitleChanged = { [weak self] in self?.refreshTabStrip() }

        let v = tab.view
        v.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: contentArea.topAnchor),
            v.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor)
        ])

        tabs.append(tab)
        selectTab(tabs.count - 1)
        applyAppearance(focused: panel.isKeyWindow)
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        // Hide find bar when switching tabs (clear search in the old active tab).
        if isFindBarVisible { hideFindBar() }
        // Hide recent-commands palette when switching tabs.
        if isPaletteVisible { hideRecentPalette() }
        activeIndex = index
        for (i, tab) in tabs.enumerated() {
            tab.view.isHidden = (i != index)
        }
        refreshTabStrip()
        focusActiveTab()
    }

    private func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        // If closing the active tab, clear the find bar and palette first.
        if index == activeIndex && isFindBarVisible { hideFindBar() }
        if index == activeIndex && isPaletteVisible { hideRecentPalette() }
        let tab = tabs.remove(at: index)
        tab.view.removeFromSuperview()

        if tabs.isEmpty {
            panel.close() // no tabs left → close the window
            return
        }
        activeIndex = min(activeIndex, tabs.count - 1)
        selectTab(activeIndex)
    }

    private func focusActiveTab() {
        guard tabs.indices.contains(activeIndex) else { return }
        panel.makeFirstResponder(tabs[activeIndex].view)
    }

    /// Updates the tab strip contents and shows/hides it (only visible with 2+ tabs).
    private func refreshTabStrip() {
        tabStrip.reload(titles: tabs.map { $0.title }, activeIndex: activeIndex)
        let show = tabs.count >= 2
        tabStrip.isHidden = !show
        tabStripHeightConstraint.constant = show ? tabStripHeight : 0
    }

    // MARK: - Find bar

    private func setupFindBar() {
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        // Add as a floating overlay above contentArea (inside root so it appears
        // above the blur views in z-order without disturbing the layout system).
        root.addSubview(findBar)

        // Pin to top-right of the content area, with a small inset.
        findBarTrailingConstraint = findBar.trailingAnchor.constraint(
            equalTo: contentArea.trailingAnchor, constant: -10
        )
        findBarTopConstraint = findBar.topAnchor.constraint(
            equalTo: contentBlur.topAnchor, constant: 8
        )

        NSLayoutConstraint.activate([
            findBarTopConstraint,
            findBarTrailingConstraint,
            findBar.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            findBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])

        // Wire callbacks.
        findBar.onSearchChanged = { [weak self] text in
            // Live preview: jump to first match as user types.
            guard let self else { return }
            if text.isEmpty {
                self.activeTerminalView?.clearSearch()
            } else {
                self.activeTerminalView?.findNext(text)
            }
        }
        findBar.onFindNext = { [weak self] in self?.findNext() }
        findBar.onFindPrevious = { [weak self] in self?.findPrevious() }
        findBar.onClose = { [weak self] in self?.hideFindBar() }
    }

    private var activeTerminalView: FloatyTerminalView? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex].view : nil
    }

    // MARK: - Public find API (explicitly requested by the feature spec)

    /// Shows the find bar (if not already visible) and advances to the next match
    /// for the current search term.
    func findNext() {
        guard let tv = activeTerminalView else { return }
        let term = findBar.searchText
        guard !term.isEmpty else {
            showFindBar()
            return
        }
        tv.findNext(term)
    }

    /// Shows the find bar (if not already visible) and moves to the previous match
    /// for the current search term.
    func findPrevious() {
        guard let tv = activeTerminalView else { return }
        let term = findBar.searchText
        guard !term.isEmpty else {
            showFindBar()
            return
        }
        tv.findPrevious(term)
    }

    /// Toggles find bar visibility.
    private func toggleFindBar() {
        if isFindBarVisible { hideFindBar() } else { showFindBar() }
    }

    private func showFindBar() {
        guard !isFindBarVisible else {
            // Already visible — just re-focus the field.
            findBar.focusSearchField()
            return
        }
        isFindBarVisible = true
        findBar.isHidden = false
        findBar.focusSearchField()
    }

    private func hideFindBar() {
        guard isFindBarVisible else { return }
        isFindBarVisible = false
        findBar.isHidden = true
        // Clear search highlights in the active terminal.
        activeTerminalView?.clearSearch()
        // Return focus to the terminal.
        focusActiveTab()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if AppRuntime.isQuitting || tabs.isEmpty { return true }

        let busy = tabs.contains { $0.hasRunningForegroundJob }
        if !busy && tabs.count == 1 { return true } // a single idle shell closes freely

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = busy ? "A process is still running." : "Close this window?"
        alert.informativeText = "Closing will end \(tabs.count) terminal "
            + "session\(tabs.count == 1 ? "" : "s")."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        // Defer so we don't drop our own last strong reference mid-callback.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onClosed?(self)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { applyAppearance(focused: true) }
    func windowDidResignKey(_ notification: Notification) { applyAppearance(focused: false) }
    func windowDidMove(_ notification: Notification) { panel.saveFrame() }
    func windowDidResize(_ notification: Notification) { panel.saveFrame() }

    // MARK: - Recent-commands palette

    private func setupRecentPalette() {
        recentPalette.translatesAutoresizingMaskIntoConstraints = false
        recentPalette.isHidden = true
        // Layer it above the content area (and above the find bar) inside root.
        root.addSubview(recentPalette)

        // Center the palette horizontally in the content area; pin its top just
        // below the header region; give it a fixed width and comfortable height.
        NSLayoutConstraint.activate([
            recentPalette.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
            recentPalette.topAnchor.constraint(
                equalTo: contentBlur.topAnchor, constant: 20),
            recentPalette.widthAnchor.constraint(
                equalTo: contentArea.widthAnchor, multiplier: 0.75),
            recentPalette.widthAnchor.constraint(
                greaterThanOrEqualToConstant: 340),
            recentPalette.widthAnchor.constraint(
                lessThanOrEqualToConstant: 700),
            recentPalette.heightAnchor.constraint(
                equalToConstant: 340)
        ])

        // Wire insert callback: send text (and optionally CR) to active terminal.
        recentPalette.onInsert = { [weak self] command, run in
            guard let self, let tv = self.activeTerminalView else { return }
            tv.send(txt: command)
            if run { tv.send([0x0D]) }
            self.hideRecentPalette()
        }

        recentPalette.onClose = { [weak self] in
            self?.hideRecentPalette()
        }
    }

    private func toggleRecentPalette() {
        if isPaletteVisible { hideRecentPalette() } else { showRecentPalette() }
    }

    private func showRecentPalette() {
        guard !isPaletteVisible else {
            // Already visible — re-focus the search field.
            recentPalette.focusSearchField()
            return
        }
        isPaletteVisible = true
        recentPalette.isHidden = false
        // Reload history fresh every time the palette opens.
        recentPalette.reloadHistory()
        recentPalette.focusSearchField()
    }

    private func hideRecentPalette() {
        guard isPaletteVisible else { return }
        isPaletteVisible = false
        recentPalette.isHidden = true
        // Return focus to the terminal.
        focusActiveTab()
    }
}
