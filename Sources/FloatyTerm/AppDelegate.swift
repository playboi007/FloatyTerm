import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [TerminalWindowController] = []
    private var hotKey: HotKey!
    private let statusItem = StatusItemController()
    private let settingsWC = SettingsWindowController()
    private let switcher = SessionSwitcherController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Restore every window from the per-window records (frame + avatar
        // style). No records (first run / legacy install) → one fresh window,
        // which falls back to the old shared-frame slot for migration.
        let records = WindowStateStore.load()
        if records.isEmpty {
            makeWindow()
        } else {
            for record in records { makeWindow(restoring: record) }
        }

        hotKey = HotKey()
        registerHotKeys()

        statusItem.onToggle        = { [weak self] in self?.toggle() }
        statusItem.onNewWindow     = { [weak self] in self?.makeWindow() }
        statusItem.onNewTab        = { [weak self] in self?.newTerminalTabInCurrentWindow() }
        statusItem.onNewBrowserTab = { [weak self] in self?.newBrowserTabInCurrentWindow() }
        statusItem.onPreferences   = { [weak self] in self?.settingsWC.show() }

        switcher.sessionsProvider = { [weak self] in self?.sessionEntries() ?? [] }
        switcher.onSummon = { [weak self] entry in self?.summon(entry) }

        // Feed the menu the list of individually-minimized windows so each can
        // be restored on its own, and provide the restore action.
        statusItem.hiddenWindowsProvider = { [weak self] in
            (self?.windows ?? [])
                .filter { $0.isMinimized }
                .map { (id: $0.id, title: $0.displayTitle) }
        }
        statusItem.onRestoreWindow = { [weak self] id in
            self?.windows.first { $0.id == id }?.show()
        }

        // Ghosted (click-through) windows can't be clicked; this menu section
        // is how they come back.
        statusItem.ghostedWindowsProvider = { [weak self] in
            (self?.windows ?? [])
                .filter { $0.isGhosted }
                .map { (id: $0.id, title: $0.displayTitle) }
        }
        statusItem.onUnghostWindow = { [weak self] id in
            self?.windows.first { $0.id == id }?.setGhosted(false)
        }

        // Re-register the global hotkey if it changes in Preferences.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChange, object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Ask whether to save the session — only when there's something worth
        // saving (any unpinned window; pinned windows are dropped regardless,
        // since their Space can't be re-targeted after relaunch).
        let savable = windows.filter { !$0.isPinned }
        if !savable.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Save windows for next launch?"
            alert.informativeText = """
                Saved windows reopen with their tabs: terminals restart in \
                their last directory (running processes end), browser tabs \
                reload their page. Windows pinned to a Space are dropped — \
                Spaces can't be re-targeted after a relaunch.
                """
            alert.addButton(withTitle: "Save & Quit")
            alert.addButton(withTitle: "Quit Without Saving")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                AppRuntime.isQuitting = true
                WindowStateStore.save(savable.map { $0.stateRecord })
                return .terminateNow
            case .alertSecondButtonReturn:
                AppRuntime.isQuitting = true
                // Keep only the front window's geometry (no tabs), so the next
                // launch opens one fresh window in a familiar spot.
                if let first = savable.first {
                    var record = first.stateRecord
                    record.tabs = nil
                    record.activeIndex = nil
                    WindowStateStore.save([record])
                } else {
                    WindowStateStore.save([])
                }
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
        AppRuntime.isQuitting = true
        return .terminateNow
    }

    /// Writes the current per-window records (frame + avatar + tabs) to disk.
    /// Called whenever a window reports a state change, and on close — this
    /// continuous snapshot doubles as crash recovery; the quit prompt decides
    /// what the FINAL saved session looks like. Pinned windows are excluded
    /// (their Space identity can't survive a relaunch).
    private func persistWindowState() {
        WindowStateStore.save(windows.filter { !$0.isPinned }.map { $0.stateRecord })
    }

    /// The toggle combo currently registered with Carbon, so unrelated settings
    /// changes (font slider ticks, opacity drags…) don't unregister/re-register
    /// the hotkeys dozens of times per second.
    private var registeredToggleCombo: (code: UInt32, mods: UInt32)?

    @objc private func settingsChanged() {
        let code = Settings.shared.hotKeyCode
        let mods = Settings.shared.hotKeyModifiers
        guard registeredToggleCombo?.code != code
           || registeredToggleCombo?.mods != mods else { return }
        registerHotKeys()
    }

    /// Registers the global hotkeys:
    ///  - id 1: the toggle (⌥⌘7 by default, customizable) — localized hide/show.
    ///  - id 2: spawn-on-this-Space, fixed at ⌥⌘5.
    ///  - id 3: session switcher, fixed at ⌥⌘K.
    /// Re-called whenever Settings change so a rebind of the toggle updates it.
    private func registerHotKeys() {
        let code = Settings.shared.hotKeyCode
        let mods = Settings.shared.hotKeyModifiers
        hotKey.register(id: 1, keyCode: code, modifiers: mods, action: { [weak self] in
            self?.handleTogglePressed()
        }, onRelease: { [weak self] in
            self?.handleToggleReleased()
        })
        registeredToggleCombo = (code, mods)
        hotKey.register(id: 2, keyCode: UInt32(kVK_ANSI_5),
                        modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.spawnOnCurrentSpace()
        }
        hotKey.register(id: 3, keyCode: UInt32(kVK_ANSI_K),
                        modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.toggleSwitcher()
        }
    }

    // MARK: - Windows

    /// Creates a new floating window.
    /// - Parameter initialDirectory: Starting directory for the new window's
    ///   first terminal tab. Pass nil to use $HOME (the default).
    /// - Parameter record: When restoring at launch, the persisted record whose
    ///   frame and avatar style this window adopts (skips normal placement).
    @discardableResult
    private func makeWindow(initialDirectory: String? = nil,
                            restoring record: WindowRecord? = nil) -> TerminalWindowController {
        let isLaunchWindow = windows.isEmpty
        // Cascade from the window the user is currently looking at (if any) so a
        // new window lands where they are — not from a stale shared frame that
        // might belong to a pinned window on another Space.
        let reference = (isLaunchWindow || record != nil) ? nil : frontWindowFrameOnCurrentSpace()
        // A record with saved tabs starts empty — restoreTabs() rebuilds them.
        let restoredTabs = record?.tabs ?? []
        let wc = TerminalWindowController(initialDirectory: initialDirectory,
                                          startEmpty: !restoredTabs.isEmpty)
        wireCallbacks(wc)
        windows.append(wc)
        if let record {
            wc.applyRestored(record)
            if !restoredTabs.isEmpty {
                wc.restoreTabs(restoredTabs, activeIndex: record.activeIndex ?? 0)
            }
        } else {
            wc.placeInitialFrame(reference: reference, isLaunchWindow: isLaunchWindow)
        }
        wc.show()
        persistWindowState()
        return wc
    }

    /// Frame of the window currently visible on the user's Space, preferring the
    /// key window. Returns nil when no FloatyTerm window is on the active Space
    /// (e.g. a fresh Space where all existing windows are pinned elsewhere).
    private func frontWindowFrameOnCurrentSpace() -> NSRect? {
        if let key = windows.first(where: { $0.isKey }) { return key.panel.frame }
        if let here = windows.first(where: isPresentOnCurrentSpace) { return here.panel.frame }
        return nil
    }

    /// Creates a new floating window that starts empty and immediately adopts
    /// `tab`.  The panel is positioned so `screenPoint` (the drop location) sits
    /// near the top-left of the new window.
    @discardableResult
    private func makeWindowAdopting(_ tab: any TabContent, at screenPoint: NSPoint) -> TerminalWindowController {
        let wc = TerminalWindowController(startEmpty: true)
        wireCallbacks(wc)
        windows.append(wc)
        // Position the new window near the drop point, kept fully on-screen
        // (a drop near a screen edge must not strand the window off-screen).
        let windowSize = wc.panel.frame.size
        let raw = NSRect(x: screenPoint.x - 20,
                         y: screenPoint.y - windowSize.height + 20,
                         width: windowSize.width, height: windowSize.height)
        wc.panel.setFrame(wc.panel.clampToVisibleScreen(raw), display: false)
        wc.adoptTab(tab)
        wc.show()
        persistWindowState()
        return wc
    }

    /// Wires the three standard callbacks that all windows share.
    /// `wc` must be captured weakly: these closures are stored ON wc itself,
    /// so a strong capture is a retain cycle that leaks every closed window.
    private func wireCallbacks(_ wc: TerminalWindowController) {
        wc.onNewWindow = { [weak self, weak wc] in
            self?.makeWindow(initialDirectory: wc?.activeTerminalWorkingDirectory)
        }
        wc.onClosed = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
            self?.persistWindowState()
        }
        wc.onOpenPreferences = { [weak self] in self?.settingsWC.show() }
        wc.onDetachTab = { [weak self] tab, screenPoint in
            self?.makeWindowAdopting(tab, at: screenPoint)
        }
        wc.onStateChanged = { [weak self] in self?.persistWindowState() }
        wc.onOpenSwitcher = { [weak self] in self?.toggleSwitcher() }
    }

    private func currentWindow() -> TerminalWindowController? {
        windows.first(where: { $0.isKey }) ?? windows.last
    }

    private func newTerminalTabInCurrentWindow() {
        if let wc = currentWindow() {
            wc.openNewTab()
            wc.show()
        } else {
            makeWindow()
        }
    }

    private func newBrowserTabInCurrentWindow() {
        if let wc = currentWindow() {
            wc.openNewBrowserTab()
            wc.show()
        } else {
            // No window yet — make one (starts with a terminal tab), then add browser.
            let wc = makeWindow()
            wc.openNewBrowserTab()
        }
    }

    /// A FloatyTerm window the user can actually see on the CURRENT Space:
    /// any visible roaming (unpinned, all-Spaces) window, or a pinned window
    /// that happens to live on the active Space.
    private func isPresentOnCurrentSpace(_ wc: TerminalWindowController) -> Bool {
        wc.isVisible && (!wc.isPinned || wc.isOnActiveSpace)
    }

    /// ⌥⌘7 — a localized toggle for the CURRENT Space. It only hides or shows
    /// terminals relevant to where the user is; it never spawns (that's ⌥⌘5)
    /// and never yanks pinned windows bound to other Spaces.
    /// Returns the windows it revealed (empty when it hid or spawned), so the
    /// hold-to-peek path knows what to put away again on key release.
    @discardableResult
    private func toggle() -> [TerminalWindowController] {
        // Bootstrap: no windows exist at all → create the first one.
        if windows.isEmpty {
            makeWindow()
            return []
        }

        // If something is already visible on this Space, dismiss only those.
        // Pinned windows bound to OTHER Spaces are left untouched.
        if windows.contains(where: isPresentOnCurrentSpace) {
            windows.filter(isPresentOnCurrentSpace).forEach { $0.hide() }
            return []
        }

        // Nothing here: reveal everything that was hidden — roaming windows
        // (which join all Spaces, so they reappear here) AND pinned windows
        // hidden by a previous ⌥⌘7 (each reappears on its own Space). We skip
        // windows tucked away via their own controls (minimize / collapse
        // bubble / ticker strip), which are restored differently. This keeps
        // ⌥⌘7 a symmetric toggle: whatever it hides, it brings back.
        let toShow = windows.filter {
            !$0.isVisible && !$0.isMinimized && !$0.isCollapsed && !$0.isTicker
        }
        toShow.forEach { $0.show() }
        return toShow
    }

    // MARK: - Hold-to-peek (toggle hotkey held = show while held)

    private var toggleKeyIsDown = false
    private var togglePressTime: Date?
    private var peekCandidates: [TerminalWindowController] = []

    private func handleTogglePressed() {
        guard !toggleKeyIsDown else { return }   // ignore key auto-repeat
        toggleKeyIsDown = true
        togglePressTime = Date()
        peekCandidates = toggle()
    }

    /// Released after holding ≥0.45s on a press that REVEALED windows → that
    /// was a peek: tuck them away again. A quick tap keeps them (normal toggle).
    private func handleToggleReleased() {
        toggleKeyIsDown = false
        guard let pressed = togglePressTime else { return }
        togglePressTime = nil
        if Date().timeIntervalSince(pressed) >= 0.45, !peekCandidates.isEmpty {
            peekCandidates.filter { $0.isVisible }.forEach { $0.hide() }
        }
        peekCandidates = []
    }

    /// ⌥⌘5 — explicitly spawn a fresh window on the current Space, regardless
    /// of what's pinned elsewhere. Placement cascades from a window already on
    /// this Space, or centers on the active screen when the Space is empty.
    private func spawnOnCurrentSpace() {
        makeWindow()
    }

    // MARK: - Session switcher (⌥⌘K)

    private func toggleSwitcher() {
        // Nothing to switch between → behave like the toggle bootstrap.
        if windows.isEmpty {
            makeWindow()
            return
        }
        switcher.toggle()
    }

    /// Snapshot of every session (tab) across every window for the switcher.
    private func sessionEntries() -> [SessionEntry] {
        windows.flatMap { wc in
            wc.tabs.map { tab in
                SessionEntry(window: wc,
                             tab: tab,
                             name: tab.displayName,
                             location: location(of: wc),
                             status: wc.status(of: tab),
                             isTerminal: tab is TerminalController)
            }
        }
    }

    private func location(of wc: TerminalWindowController) -> String {
        // The app this window was pinned over, e.g. "another Space (Chrome)".
        let app = wc.pinnedAppName.map { " (\($0))" } ?? ""
        if wc.isCollapsed { return wc.isPinned ? "in bubble\(app)" : "in bubble" }
        if wc.isTicker { return wc.isPinned ? "in ticker\(app)" : "in ticker" }
        if wc.isGhosted { return "ghosted" }
        if wc.isMinimized || !wc.isVisible { return wc.isPinned ? "hidden\(app)" : "hidden" }
        if wc.isPinned {
            // Judge by actual on-screen presence, not the hidden-panel guess.
            return (wc.presenceOnActiveSpace ?? false) ? "pinned here" : "another Space\(app)"
        }
        return "here"
    }

    /// Brings the chosen session to the user's current Space.
    ///
    /// macOS offers no public API to place a window on a non-active Space, so
    /// "send it back" works at the TAB level: when the session's window is
    /// pinned to another Space, we borrow the tab into a window here while the
    /// source window stays where it is — the header's return arrow re-merges
    /// the tab into it. A single-tab window LENDS its session instead: it
    /// stays behind empty (bubble / ticker / placeholder panel), keeping its
    /// pin, Space, and frame, so Return restores everything exactly as it was.
    private func summon(_ entry: SessionEntry) {
        guard let wc = entry.window,
              windows.contains(where: { $0 === wc }),
              let idx = wc.tabs.firstIndex(where: { $0 === entry.tab }) else { return }
        let tab = entry.tab

        // Is the window away on another Space? Judged by whatever is actually
        // on screen (panel, bubble, or ticker strip) — `panel.isOnActiveSpace`
        // lies for hidden panels, which is what broke pinned+collapsed and
        // pinned+tickered windows. Unknown presence (pinned + minimized) is
        // treated as away: the whole-window path is correct either way.
        let away = wc.isPinned && !(wc.presenceOnActiveSpace ?? false)

        if !away {
            // Roaming (joins all Spaces) or pinned right here: reveal + focus.
            wc.selectTab(at: idx)
            if wc.isGhosted { wc.setGhosted(false) }   // summon = interactive again
            if wc.isCollapsed {
                wc.expandFromAvatar()
            } else if wc.isTicker {
                wc.expandFromTicker()
            } else {
                wc.show()
            }
            return
        }

        // Borrow the tab into a window on this Space. The source window never
        // moves: with other tabs it keeps living normally; with only this one
        // it LENDS it, staying behind empty (still pinned, still collapsed /
        // tickered / minimized, however it was) as the permanent home the
        // Return arrow sends the tab back to. Either way the arrow shows.
        if wc.tabs.count >= 2 {
            wc.releaseTab(tab)
        } else if wc.lendOnlyTab() == nil {
            return
        }
        let borrower = makeWindowAdopting(tab, at: .zero)
        if let frame = summonTargetFrame(size: borrower.panel.frame.size) {
            borrower.panel.setFrame(frame, display: false)
        }
        if windows.contains(where: { $0 === wc }) {
            borrower.markBorrowed(tab, from: wc)
        }
    }

    /// The user's summon grid point on the active screen, sized to `size` —
    /// where borrowed and whole-summoned windows land, away from whatever
    /// terminal is already in view.
    private func summonTargetFrame(size: NSSize) -> NSRect? {
        guard let vis = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return nil }
        return Settings.shared.summonPosition.frame(forSize: size, in: vis)
    }

}
