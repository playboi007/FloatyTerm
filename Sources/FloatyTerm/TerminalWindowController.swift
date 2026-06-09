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

    /// Stable identifier so the menu bar can address this specific window
    /// (e.g. to restore it after it has been minimized/hidden).
    let id = UUID()

    /// True while this window is individually hidden via the minimize button
    /// (as opposed to the global ⌥⌘7 hide). Minimized windows are restorable
    /// from the menu-bar "Hidden Windows" list.
    private(set) var isMinimized = false

    /// True while this window is collapsed into its floating avatar bubble.
    private(set) var isCollapsed = false

    // Avatar (bubble) collapse state.
    private var avatar: AvatarPanel?
    private var collapsedSnapshot: NSImage?
    private var savedFrameForExpand: NSRect = .zero
    /// Where the cursor sat WITHIN the window when it collapsed (offset from the
    /// window's bottom-left origin). On expand we place the window so this same
    /// point — the collapse icon — returns to the bubble, preserving spatial
    /// awareness instead of re-centering the window on the bubble.
    private var collapseCursorOffset: NSPoint = .zero

    private let root        = WindowDropView()
    private let topBlur     = NSVisualEffectView()   // header + tab strip backdrop (always)
    private let contentBlur = NSVisualEffectView()   // content backdrop (toggleable)
    private let contentArea = NSView()
    private let header      = HeaderControlsView()
    private let tabStrip    = TabStripView()

    private var _startEmpty: Bool = false

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

    /// Exposed (internal) so TabStripView's drag delegate can read it.
    var tabs: [any TabContent] = []
    private var activeIndex = 0

    /// Held only during init so the first addTerminalTab() call can use it.
    /// Cleared after the first tab is created.
    private var pendingInitialDirectory: String?

    var onNewWindow:       (() -> Void)?
    var onClosed:          ((TerminalWindowController) -> Void)?
    var onOpenPreferences: (() -> Void)?

    /// Called when a tab should be torn off into a new window.
    /// Parameters: the live tab object and the screen point where the drag ended.
    var onDetachTab: ((any TabContent, NSPoint) -> Void)?

    /// - Parameter initialDirectory: The directory in which to open the first
    ///   terminal tab. nil → $HOME (the default / original behaviour).
    /// - Parameter startEmpty: When true, no initial tab is created.  Used by
    ///   the tear-off path so `adoptTab` can install the reparented tab.
    init(initialDirectory: String? = nil, startEmpty: Bool = false) {
        self.pendingInitialDirectory = initialDirectory
        self._startEmpty = startEmpty
        let initial = NSRect(x: 0, y: 0, width: 720, height: 460)
        panel = FloatingPanel(contentRect: initial)
        super.init()

        panel.delegate = self
        panel.setupFloatingBehavior()

        root.frame = initial
        root.autoresizingMask = [.width, .height]
        panel.contentView = root
        root.windowController = self
        root.registerDrop()

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

        header.onAddTab       = { [weak self] in self?.addTerminalTab() }
        header.onNewWindow    = { [weak self] in self?.onNewWindow?() }
        header.onToggleURLBar = { [weak self] in self?.toggleURLBarCollapsed() }
        header.onMinimize     = { [weak self] in self?.minimize() }
        header.onTogglePin    = { [weak self] in self?.togglePin() }
        header.onCollapse     = { [weak self] in self?.collapseToAvatar() }
        tabStrip.onSelect     = { [weak self] i in self?.selectTab(i) }
        tabStrip.onCloseTab   = { [weak self] i in self?.closeTab(i) }

        // Wire drag-support back-references.
        tabStrip.windowController = self
        header.tabStripView       = tabStrip

        panel.keyCommandHandler = { [weak self] event in
            self?.handleKeyCommand(event) ?? false
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChange, object: nil
        )

        // When the active Space changes, re-assert a pinned window so it doesn't
        // intermittently drop out of view during rapid Space swipes (a window-
        // server quirk with fullScreenAuxiliary windows). Guarded by
        // isOnActiveSpace so we only nudge it when it actually belongs to the
        // now-active Space — never pulling it onto a Space it isn't pinned to.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )

        setupFindBar()
        setupRecentPalette()
        setupURLBar()
        if !_startEmpty {
            addTerminalTab() // start with one terminal tab
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Active Space changed: if this window is pinned and now belongs to the
    /// active Space, nudge the compositor to re-display it (fixes the temporary
    /// disappearance after several fullscreen-Space swipes). The second, delayed
    /// pass catches cases where the window server is still re-attaching the
    /// auxiliary window when the notification fires.
    @objc private func activeSpaceChanged() {
        reassertIfPinnedOnActiveSpace()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.reassertIfPinnedOnActiveSpace()
        }
    }

    private func reassertIfPinnedOnActiveSpace() {
        guard panel.isPinned, panel.isVisible, panel.isOnActiveSpace else { return }
        panel.orderFrontRegardless()
    }

    // MARK: - Window placement / visibility

    /// Positions a newly-created window.
    /// - reference: frame of the window currently on the user's Space, if any —
    ///   the new window cascades from it so it lands where the user is looking.
    /// - isLaunchWindow: true only for the first window at app launch, which
    ///   restores the remembered cross-launch frame. Otherwise (a window spawned
    ///   onto a fresh Space with no reference) it centers on the active screen.
    func placeInitialFrame(reference: NSRect?, isLaunchWindow: Bool) {
        if let ref = reference {
            panel.cascade(from: ref)
        } else if isLaunchWindow {
            panel.restoreSavedFrame()
        } else {
            panel.restoreSavedFrame()      // adopt remembered size…
            panel.centerOnActiveScreen()   // …but center on the Space in view
        }
    }

    func show() {
        isMinimized = false
        // Use orderFrontRegardless + makeKey (NOT NSApp.activate) so the panel
        // appears over another app's fullscreen Space without stealing it. This
        // is what makes the overlay reliably show over Chrome/Cursor and lets
        // every window come back together on ⌥⌘7.
        panel.presentOverlay()
        focusActiveTab()
    }

    func hide() {
        persistFrameIfRoaming()
        panel.orderOut(nil)
    }

    /// Only unpinned ("roaming") windows write the shared cross-launch frame.
    /// A pinned window's geometry is Space-specific and must not become the
    /// default that new/roaming windows restore from.
    private func persistFrameIfRoaming() {
        if !panel.isPinned { panel.saveFrame() }
    }

    // MARK: - Collapse to / expand from the floating avatar bubble

    /// Morphs this window into a small floating avatar bubble (hero transition).
    /// The session stays alive; double-clicking the bubble expands it back.
    func collapseToAvatar() {
        guard !isCollapsed else { return }
        let termFrame = panel.frame
        let snapshot = HeroTransition.snapshot(of: root) ?? NSImage(size: termFrame.size)
        collapsedSnapshot = snapshot
        savedFrameForExpand = termFrame

        // Bubble lands at the mouse cursor (where the collapse icon was clicked),
        // clamped on-screen — so the window appears to implode toward the click.
        let d = AvatarPanel.diameter
        let mouse = NSEvent.mouseLocation
        // Remember the cursor's position within the window (the collapse icon)
        // so expand can return that exact point to the bubble.
        collapseCursorOffset = NSPoint(x: mouse.x - termFrame.minX,
                                       y: mouse.y - termFrame.minY)
        let avatarFrame = panel.clampToVisibleScreen(
            NSRect(x: mouse.x - d / 2, y: mouse.y - d / 2, width: d, height: d))

        isCollapsed = true
        persistFrameIfRoaming()
        panel.orderOut(nil)

        HeroTransition.morph(snapshot: snapshot, from: termFrame, to: avatarFrame,
                             startRadius: 8, endRadius: d / 2, fadeToGlyph: true) { [weak self] in
            self?.showAvatar(at: avatarFrame)
        }
    }

    private func showAvatar(at frame: NSRect) {
        let av = avatar ?? AvatarPanel()
        avatar = av
        av.onExpand = { [weak self] in self?.expandFromAvatar() }
        av.setFrame(frame, display: false)
        av.reassertFloatingBehavior()
        av.orderFrontRegardless()
    }

    /// Reverses the collapse: the bubble grows back into the terminal, expanding
    /// from wherever the user has moved the bubble.
    func expandFromAvatar() {
        guard isCollapsed, let av = avatar else { return }
        let avatarFrame = av.frame
        let size = savedFrameForExpand.size
        // Place the window so the collapse-icon point (where the cursor was) lands
        // at the bubble's center — the window unfolds back to where the eye expects.
        let center = NSPoint(x: avatarFrame.midX, y: avatarFrame.midY)
        let raw = NSRect(x: center.x - collapseCursorOffset.x,
                         y: center.y - collapseCursorOffset.y,
                         width: size.width, height: size.height)
        let target = panel.clampToVisibleScreen(raw)
        let image = collapsedSnapshot ?? HeroTransition.snapshot(of: root) ?? NSImage(size: size)
        let d = AvatarPanel.diameter

        av.orderOut(nil)
        HeroTransition.morph(snapshot: image, from: avatarFrame, to: target,
                             startRadius: d / 2, endRadius: 8, fadeToGlyph: false) { [weak self] in
            guard let self else { return }
            self.isCollapsed = false
            self.panel.setFrame(target, display: false)
            self.panel.presentOverlay()
            self.focusActiveTab()
        }
    }

    /// Hides only THIS window (session preserved) and flags it as minimized so
    /// it appears in the menu-bar "Hidden Windows" list for individual restore.
    /// Distinct from the global ⌥⌘7 hide, which hides every window at once.
    func minimize() {
        persistFrameIfRoaming()
        isMinimized = true
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }

    /// True when this window is linked/pinned to a specific Space.
    var isPinned: Bool { panel.isPinned }

    /// True when this window currently lives on the Space the user is viewing.
    var isOnActiveSpace: Bool { panel.isOnActiveSpace }

    /// Toggles whether this window is linked to the current Space. When linked,
    /// it stays on that Space (with its session) instead of floating over all of
    /// them; the pin button reflects the new state.
    private func togglePin() {
        panel.setPinned(!panel.isPinned)
        header.setPinned(panel.isPinned)
    }

    /// A short title for menus, taken from the active tab.
    var displayTitle: String {
        guard tabs.indices.contains(activeIndex) else { return "FloatyTerm" }
        let t = tabs[activeIndex].title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled" : t
    }

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

    // MARK: - Working-directory inheritance

    /// Returns the current working directory of the active terminal tab when the
    /// "Inherit working directory" setting is ON and the active tab is a terminal.
    /// Returns nil otherwise (callers should fall back to $HOME).
    var activeTerminalWorkingDirectory: String? {
        guard Settings.shared.inheritWorkingDirectory else { return nil }
        guard let tc = tabs.indices.contains(activeIndex)
                ? tabs[activeIndex] as? TerminalController : nil else { return nil }
        return tc.currentWorkingDirectory
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
        // For the very first tab (created during init) use the initialDirectory
        // that was passed to init(); for all subsequent tabs, inherit from the
        // currently-active terminal when the setting is ON.
        let startDir: String?
        if tabs.isEmpty, let pending = pendingInitialDirectory {
            startDir = pending
            pendingInitialDirectory = nil   // consume so later tabs use normal logic
        } else {
            // Capture the active terminal's cwd before creating the new controller
            // (once the new tab is inserted it becomes active, so read now).
            startDir = activeTerminalWorkingDirectory
        }
        let tab = TerminalController(startDirectory: startDir)
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

    // MARK: - Tab tear-off / re-dock support

    /// Remove `tab` from this window WITHOUT calling `cleanup()`.
    /// The tab's session stays alive; its view is removed from the contentArea.
    /// If this was the last tab, the window is closed.
    func releaseTab(_ tab: any TabContent) {
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }

        // Hide overlays if the active (about-to-leave) tab owns them.
        if idx == activeIndex {
            if isFindBarVisible  { hideFindBar()       }
            if isPaletteVisible  { hideRecentPalette() }
            if isURLBarVisible   { hideURLBar()        }
        }

        tab.view.removeFromSuperview()
        tabs.remove(at: idx)

        if tabs.isEmpty {
            panel.close()
            return
        }
        activeIndex = min(activeIndex, tabs.count - 1)
        selectTab(activeIndex)
    }

    /// Host `tab` in this window and select it.
    /// Re-wires the tab's callbacks so title/termination events reference THIS controller.
    func adoptTab(_ tab: any TabContent) {
        // Re-wire callbacks before inserting so the refreshes land correctly.
        tab.onTitleChanged = { [weak self] in
            self?.refreshTabStrip()
            // If it's a browser tab, sync the URL bar too.
            if (tab as? BrowserController) != nil {
                self?.syncURLBar()
            }
        }
        if let termTab = tab as? TerminalController {
            termTab.onTerminated = { [weak self, weak termTab] in
                guard let self, let termTab,
                      let idx = self.tabs.firstIndex(where: { $0 === termTab }) else { return }
                self.closeTab(idx)
            }
        }

        insertTab(tab)
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
    func windowDidMove(_ notification: Notification)      { persistFrameIfRoaming() }
    func windowDidResize(_ notification: Notification)    { persistFrameIfRoaming() }

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
    func syncURLBar() {
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
