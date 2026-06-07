import AppKit
import SwiftTerm
import WebKit

/// Owns one floating window:
///  - a frosted top region (header controls + a tab strip that appears when
///    there are 2+ tabs) that stays opaque as a visual reference,
///  - a content area below it that shows the active tab's view and whose
///    opacity/blur is configurable.
///
/// Tabs are heterogeneous: any object conforming to `TabContent` may live in
/// `tabs`. Terminal-specific paths (find bar, recent-commands palette, foreground-
/// job check, font updates) are guarded with `as? TerminalController` casts.
final class TerminalWindowController: NSObject, NSWindowDelegate {
    let panel: FloatingPanel

    private let root       = NSView()
    private let topBlur    = NSVisualEffectView()     // header + tab strip backdrop (always)
    private let contentBlur = NSVisualEffectView()    // content backdrop (toggleable)
    private let contentArea = NSView()
    private let header     = HeaderControlsView()
    private let tabStrip   = TabStripView()

    // MARK: - Find bar (terminal-only overlay)
    private let findBar = FindBarView()
    private var findBarTrailingConstraint: NSLayoutConstraint!
    private var findBarTopConstraint: NSLayoutConstraint!
    private var isFindBarVisible = false

    // MARK: - Recent-commands palette (terminal-only overlay)
    private let recentPalette = RecentCommandsPaletteView()
    private var isPaletteVisible = false

    // MARK: - URL bar (browser-only overlay)
    private let urlBar = URLBarView()
    private var isURLBarVisible = false

    private let headerHeight: CGFloat = 28
    private let tabStripHeight: CGFloat = 30
    private var tabStripHeightConstraint: NSLayoutConstraint!

    // MARK: - Heterogeneous tab list

    private var tabs: [any TabContent] = []
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

        topBlur.material     = .hudWindow
        topBlur.blendingMode = .behindWindow
        topBlur.state        = .active

        contentBlur.material     = .hudWindow
        contentBlur.blendingMode = .behindWindow
        contentBlur.state        = .active

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

        header.onAddTab      = { [weak self] in self?.addTerminalTab() }
        header.onNewWindow   = { [weak self] in self?.onNewWindow?() }
        header.onToggleURLBar = { [weak self] in self?.toggleURLBarCollapsed() }
        tabStrip.onSelect    = { [weak self] i in self?.selectTab(i) }
        tabStrip.onCloseTab  = { [weak self] i in self?.closeTab(i) }

        panel.keyCommandHandler = { [weak self] event in
            self?.handleKeyCommand(event) ?? false
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChange, object: nil
        )

        setupFindBar()
        setupRecentPalette()
        setupURLBar()
        addTerminalTab() // start with one terminal tab
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

    /// Public entry for the menu bar's "New Tab" (terminal).
    func openNewTab() { addTerminalTab() }

    /// Public entry for the menu bar's "New Browser Tab".
    func openNewBrowserTab() { addBrowserTab() }

    // MARK: - Keyboard commands

    private func handleKeyCommand(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if flags == .command {
            switch chars {
            case "t": addTerminalTab(); return true
            case "b": addBrowserTab();  return true
            case "w": closeTab(activeIndex); return true
            case "n": onNewWindow?(); return true
            case ",": onOpenPreferences?(); return true
            case "f":
                // ⌘F is terminal-only; no-op when a browser tab is active.
                if activeTabIsTerminal { toggleFindBar() }
                return true
            case "g":
                if activeTabIsTerminal { findNext() }
                return true
            case "r":
                // ⌘R is the recent-commands palette for terminal tabs;
                // no-op for browser tabs (browser reload is in the URL bar).
                if activeTabIsTerminal { toggleRecentPalette() }
                return true
            default:
                if let n = Int(chars), (1...9).contains(n) {
                    selectTab(n - 1)
                    return true
                }
            }
        } else if flags == [.command, .shift] {
            if event.keyCode == 30 { cycleTab(+1); return true }  // ⌘⇧]  next
            if event.keyCode == 33 { cycleTab(-1); return true }  // ⌘⇧[  prev
            if chars == "g" {
                if activeTabIsTerminal { findPrevious() }
                return true
            }
        }
        return false
    }

    private func cycleTab(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        selectTab((activeIndex + delta + tabs.count) % tabs.count)
    }

    // MARK: - Convenience type checks

    private var activeTabIsTerminal: Bool {
        tabs.indices.contains(activeIndex) && tabs[activeIndex] is TerminalController
    }

    private var activeTabIsBrowser: Bool {
        tabs.indices.contains(activeIndex) && tabs[activeIndex] is BrowserController
    }

    private var activeBrowser: BrowserController? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] as? BrowserController : nil
    }

    // MARK: - Appearance (transparency + blur)

    private func applyAppearance(focused: Bool) {
        contentBlur.isHidden = !Settings.shared.backgroundBlur
        let alpha = (Settings.shared.dimWhenUnfocused && !focused)
            ? Settings.shared.unfocusedOpacity
            : Settings.shared.focusedOpacity
        contentArea.alphaValue = CGFloat(alpha)
    }

    @objc private func settingsChanged() {
        // Only apply font to terminal tabs.
        tabs.compactMap { $0 as? TerminalController }.forEach { $0.applyFont() }
        applyAppearance(focused: panel.isKeyWindow)
        updateURLBarVisibility()  // reflect URL-bar collapse state changes
    }

    /// Collapses/expands the browser URL bar (persisted; applies to all windows).
    private func toggleURLBarCollapsed() {
        Settings.shared.urlBarCollapsed.toggle()
        // The Settings.didChange notification triggers settingsChanged(), which
        // refreshes URL-bar visibility everywhere.
    }

    // MARK: - Tabs (heterogeneous)

    private func addTerminalTab() {
        let tab = TerminalController()
        tab.onTerminated = { [weak self, weak tab] in
            guard let self, let tab,
                  let idx = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.closeTab(idx)
        }
        tab.onTitleChanged = { [weak self] in self?.refreshTabStrip() }
        insertTab(tab)
    }

    func addBrowserTab() {
        // One-time resource notice.
        showBrowserResourceNoticeIfNeeded()

        let tab = BrowserController()
        tab.onTitleChanged = { [weak self] in
            self?.refreshTabStrip()
            self?.syncURLBar()
        }
        insertTab(tab)
    }

    private func insertTab(_ tab: any TabContent) {
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
        // Hide terminal-only overlays when switching tabs.
        if isFindBarVisible   { hideFindBar()       }
        if isPaletteVisible   { hideRecentPalette() }
        activeIndex = index
        for (i, tab) in tabs.enumerated() {
            tab.view.isHidden = (i != index)
        }
        refreshTabStrip()
        updateURLBarVisibility()
        focusActiveTab()
    }

    private func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        if index == activeIndex && isFindBarVisible  { hideFindBar()       }
        if index == activeIndex && isPaletteVisible  { hideRecentPalette() }
        if index == activeIndex && isURLBarVisible   { hideURLBar()        }
        let tab = tabs.remove(at: index)
        tab.view.removeFromSuperview()
        tab.cleanup()

        if tabs.isEmpty {
            panel.close()
            return
        }
        activeIndex = min(activeIndex, tabs.count - 1)
        selectTab(activeIndex)
    }

    private func focusActiveTab() {
        guard tabs.indices.contains(activeIndex) else { return }
        tabs[activeIndex].focus(in: panel)
    }

    /// Updates the tab strip contents and shows/hides it (only visible with 2+ tabs).
    private func refreshTabStrip() {
        tabStrip.reload(titles: tabs.map { $0.title }, activeIndex: activeIndex)
        let show = tabs.count >= 2
        tabStrip.isHidden = !show
        tabStripHeightConstraint.constant = show ? tabStripHeight : 0
    }

    // MARK: - One-time browser resource notice

    private func showBrowserResourceNoticeIfNeeded() {
        let key = "didShowBrowserResourceNotice"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.alertStyle        = .informational
        alert.messageText       = "Browser tabs use more resources"
        alert.informativeText   = """
            Browser tabs are powered by the system WebKit engine. \
            They will use more CPU and RAM than terminal tabs, especially \
            with rich web applications. This message appears only once.
            """
        alert.addButton(withTitle: "Got It")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Find bar (terminal-only)

    private func setupFindBar() {
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        root.addSubview(findBar)

        findBarTrailingConstraint = findBar.trailingAnchor.constraint(
            equalTo: contentArea.trailingAnchor, constant: -10)
        findBarTopConstraint = findBar.topAnchor.constraint(
            equalTo: contentBlur.topAnchor, constant: 8)

        NSLayoutConstraint.activate([
            findBarTopConstraint,
            findBarTrailingConstraint,
            findBar.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            findBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])

        findBar.onSearchChanged = { [weak self] text in
            guard let self else { return }
            if text.isEmpty {
                self.activeTerminalView?.clearSearch()
            } else {
                self.activeTerminalView?.findNext(text)
            }
        }
        findBar.onFindNext     = { [weak self] in self?.findNext()     }
        findBar.onFindPrevious = { [weak self] in self?.findPrevious() }
        findBar.onClose        = { [weak self] in self?.hideFindBar()  }
    }

    private var activeTerminalView: FloatyTerminalView? {
        (tabs.indices.contains(activeIndex) ? tabs[activeIndex] as? TerminalController : nil)?.terminalView
    }

    func findNext() {
        guard let tv = activeTerminalView else { return }
        let term = findBar.searchText
        guard !term.isEmpty else { showFindBar(); return }
        tv.findNext(term)
    }

    func findPrevious() {
        guard let tv = activeTerminalView else { return }
        let term = findBar.searchText
        guard !term.isEmpty else { showFindBar(); return }
        tv.findPrevious(term)
    }

    private func toggleFindBar() {
        if isFindBarVisible { hideFindBar() } else { showFindBar() }
    }

    private func showFindBar() {
        guard !isFindBarVisible else { findBar.focusSearchField(); return }
        isFindBarVisible = true
        findBar.isHidden = false
        findBar.focusSearchField()
    }

    private func hideFindBar() {
        guard isFindBarVisible else { return }
        isFindBarVisible = false
        findBar.isHidden = true
        activeTerminalView?.clearSearch()
        focusActiveTab()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if AppRuntime.isQuitting || tabs.isEmpty { return true }

        // Only terminal tabs can have a running foreground job.
        let terminalTabs = tabs.compactMap { $0 as? TerminalController }
        let busy = terminalTabs.contains { $0.hasRunningForegroundJob }

        // A single idle terminal (or any mix without a running job) closes freely.
        if !busy && tabs.count == 1 { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = busy ? "A process is still running." : "Close this window?"
        let termCount = terminalTabs.count
        let browCount = tabs.count - termCount
        var parts: [String] = []
        if termCount > 0 { parts.append("\(termCount) terminal session\(termCount == 1 ? "" : "s")") }
        if browCount > 0 { parts.append("\(browCount) browser tab\(browCount == 1 ? "" : "s")") }
        alert.informativeText = "Closing will end \(parts.joined(separator: " and "))."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onClosed?(self)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { applyAppearance(focused: true)  }
    func windowDidResignKey(_ notification: Notification) { applyAppearance(focused: false) }
    func windowDidMove(_ notification: Notification)      { panel.saveFrame() }
    func windowDidResize(_ notification: Notification)    { panel.saveFrame() }

    // MARK: - Recent-commands palette (terminal-only)

    private func setupRecentPalette() {
        recentPalette.translatesAutoresizingMaskIntoConstraints = false
        recentPalette.isHidden = true
        root.addSubview(recentPalette)

        NSLayoutConstraint.activate([
            recentPalette.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
            recentPalette.topAnchor.constraint(equalTo: contentBlur.topAnchor, constant: 20),
            recentPalette.widthAnchor.constraint(equalTo: contentArea.widthAnchor, multiplier: 0.75),
            recentPalette.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            recentPalette.widthAnchor.constraint(lessThanOrEqualToConstant: 700),
            recentPalette.heightAnchor.constraint(equalToConstant: 340)
        ])

        recentPalette.onInsert = { [weak self] command, run in
            guard let self, let tv = self.activeTerminalView else { return }
            tv.send(txt: command)
            if run { tv.send([0x0D]) }
            self.hideRecentPalette()
        }
        recentPalette.onClose = { [weak self] in self?.hideRecentPalette() }
    }

    private func toggleRecentPalette() {
        if isPaletteVisible { hideRecentPalette() } else { showRecentPalette() }
    }

    private func showRecentPalette() {
        guard !isPaletteVisible else { recentPalette.focusSearchField(); return }
        isPaletteVisible = true
        recentPalette.isHidden = false
        recentPalette.reloadHistory()
        recentPalette.focusSearchField()
    }

    private func hideRecentPalette() {
        guard isPaletteVisible else { return }
        isPaletteVisible = false
        recentPalette.isHidden = true
        focusActiveTab()
    }

    // MARK: - URL bar (browser-only)

    private func setupURLBar() {
        urlBar.translatesAutoresizingMaskIntoConstraints = false
        urlBar.isHidden = true
        // Layer above contentArea (inside root, like findBar and recentPalette).
        root.addSubview(urlBar)

        // Centred horizontally; pinned near the top of the content area.
        NSLayoutConstraint.activate([
            urlBar.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
            urlBar.topAnchor.constraint(equalTo: contentBlur.topAnchor, constant: 8),
            urlBar.widthAnchor.constraint(equalTo: contentArea.widthAnchor, multiplier: 0.80),
            urlBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            urlBar.widthAnchor.constraint(lessThanOrEqualToConstant: 700)
        ])

        urlBar.onLoad    = { [weak self] text in self?.browserLoad(text)  }
        urlBar.onBack    = { [weak self] in self?.activeBrowser?.goBack()    }
        urlBar.onForward = { [weak self] in self?.activeBrowser?.goForward() }
        urlBar.onReload  = { [weak self] in self?.activeBrowser?.reload()    }
    }

    private func browserLoad(_ text: String) {
        activeBrowser?.load(text)
        focusActiveTab()
    }

    /// Shows the URL bar with current state (called when a browser tab becomes active).
    private func showURLBar() {
        guard !isURLBarVisible else { return }
        isURLBarVisible = true
        urlBar.isHidden = false
        syncURLBar()
    }

    private func hideURLBar() {
        guard isURLBarVisible else { return }
        isURLBarVisible = false
        urlBar.isHidden = true
    }

    /// Updates URL field text and nav button enabled state from the active browser.
    private func syncURLBar() {
        guard let bc = activeBrowser else { return }
        let urlString = bc.webView.url?.absoluteString ?? ""
        urlBar.updateURL(urlString)
        urlBar.updateNavState(canGoBack: bc.canGoBack, canGoForward: bc.canGoForward)
    }

    /// Called after selectTab / settings change to show/hide the URL bar based
    /// on tab type and the collapse toggle. The globe toggle in the header is
    /// shown only for browser tabs and reflects the expanded/collapsed state.
    private func updateURLBarVisibility() {
        let expanded = !Settings.shared.urlBarCollapsed
        if activeTabIsBrowser && expanded {
            showURLBar()
        } else {
            hideURLBar()
        }
        header.setURLBarToggleVisible(activeTabIsBrowser)
        header.setURLBarToggleActive(expanded)
    }
}
