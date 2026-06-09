import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [TerminalWindowController] = []
    private var hotKey: HotKey!
    private let statusItem = StatusItemController()
    private let settingsWC = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()

        hotKey = HotKey()
        registerHotKeys()

        statusItem.onToggle        = { [weak self] in self?.toggle() }
        statusItem.onNewWindow     = { [weak self] in self?.makeWindow() }
        statusItem.onNewTab        = { [weak self] in self?.newTerminalTabInCurrentWindow() }
        statusItem.onNewBrowserTab = { [weak self] in self?.newBrowserTabInCurrentWindow() }
        statusItem.onPreferences   = { [weak self] in self?.settingsWC.show() }

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

        // Re-register the global hotkey if it changes in Preferences.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChange, object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppRuntime.isQuitting = true  // skip per-window close prompts on quit
        return .terminateNow
    }

    @objc private func settingsChanged() {
        registerHotKeys()
    }

    /// Registers both global hotkeys:
    ///  - id 1: the toggle (⌥⌘7 by default, customizable) — localized hide/show.
    ///  - id 2: spawn-on-this-Space, fixed at ⌥⌘5.
    /// Re-called whenever Settings change so a rebind of the toggle updates it.
    private func registerHotKeys() {
        let code = Settings.shared.hotKeyCode
        let mods = Settings.shared.hotKeyModifiers
        hotKey.register(id: 1, keyCode: code, modifiers: mods) { [weak self] in
            self?.toggle()
        }
        hotKey.register(id: 2, keyCode: UInt32(kVK_ANSI_5),
                        modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.spawnOnCurrentSpace()
        }
    }

    // MARK: - Windows

    /// Creates a new floating window.
    /// - Parameter initialDirectory: Starting directory for the new window's
    ///   first terminal tab. Pass nil to use $HOME (the default).
    @discardableResult
    private func makeWindow(initialDirectory: String? = nil) -> TerminalWindowController {
        let isLaunchWindow = windows.isEmpty
        // Cascade from the window the user is currently looking at (if any) so a
        // new window lands where they are — not from a stale shared frame that
        // might belong to a pinned window on another Space.
        let reference = isLaunchWindow ? nil : frontWindowFrameOnCurrentSpace()
        let wc = TerminalWindowController(initialDirectory: initialDirectory)
        wireCallbacks(wc)
        windows.append(wc)
        wc.placeInitialFrame(reference: reference, isLaunchWindow: isLaunchWindow)
        wc.show()
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
        // Position the new window near the drop point.
        let windowSize = wc.panel.frame.size
        let origin = NSPoint(x: screenPoint.x - 20,
                             y: screenPoint.y - windowSize.height + 20)
        wc.panel.setFrameOrigin(origin)
        wc.adoptTab(tab)
        wc.show()
        return wc
    }

    /// Wires the three standard callbacks that all windows share.
    private func wireCallbacks(_ wc: TerminalWindowController) {
        wc.onNewWindow = { [weak self] in
            self?.makeWindow(initialDirectory: wc.activeTerminalWorkingDirectory)
        }
        wc.onClosed = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        wc.onOpenPreferences = { [weak self] in self?.settingsWC.show() }
        wc.onDetachTab = { [weak self] tab, screenPoint in
            self?.makeWindowAdopting(tab, at: screenPoint)
        }
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
    private func toggle() {
        // Bootstrap: no windows exist at all → create the first one.
        if windows.isEmpty {
            makeWindow()
            return
        }

        // If something is already visible on this Space, dismiss only those.
        // Pinned windows bound to OTHER Spaces are left untouched.
        if windows.contains(where: isPresentOnCurrentSpace) {
            windows.filter(isPresentOnCurrentSpace).forEach { $0.hide() }
            return
        }

        // Nothing here: summon any roaming (unpinned) windows — they join all
        // Spaces, so they appear right here. Collapsed windows are skipped (they
        // live in their avatar bubble). If there's nothing to summon, this is
        // intentionally a no-op: use ⌥⌘5 to spawn one on this Space.
        windows.filter { !$0.isPinned && !$0.isCollapsed }.forEach { $0.show() }
    }

    /// ⌥⌘5 — explicitly spawn a fresh window on the current Space, regardless
    /// of what's pinned elsewhere. Placement cascades from a window already on
    /// this Space, or centers on the active screen when the Space is empty.
    private func spawnOnCurrentSpace() {
        makeWindow()
    }
}
