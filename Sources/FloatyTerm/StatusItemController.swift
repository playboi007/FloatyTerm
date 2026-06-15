import AppKit
import Carbon.HIToolbox

/// The menu-bar (status) item. Since FloatyTerm has no Dock icon, this is the
/// visible home for New Window / New Tab / Preferences / Quit — and the place
/// to restore windows that have been individually minimized.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    var onToggle: () -> Void = {}
    var onNewTab: () -> Void = {}
    var onNewBrowserTab: () -> Void = {}
    var onNewWindow: () -> Void = {}
    var onRunBackgroundTask: () -> Void = {}
    var onPreferences: () -> Void = {}

    /// Returns the windows that are currently minimized (hidden via their own
    /// minimize button), so they can be listed for individual restore.
    var hiddenWindowsProvider: () -> [(id: UUID, title: String)] = { [] }

    /// Restores (un-minimizes) the window with the given id.
    var onRestoreWindow: (UUID) -> Void = { _ in }

    /// Returns the currently-ghosted (click-through) windows. They can't be
    /// clicked directly, so this menu is their primary restore path.
    var ghostedWindowsProvider: () -> [(id: UUID, title: String)] = { [] }

    /// Un-ghosts the window with the given id.
    var onUnghostWindow: (UUID) -> Void = { _ in }

    override init() {
        super.init()

        if let button = item.button {
            if let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: "FloatyTerm") {
                button.image = img
            } else {
                button.title = "FT"
            }
            // Fleet summary text renders beside the icon, not instead of it.
            button.imagePosition = .imageLeading
        }

        // Rebuild on each open so the "Hidden Windows" list is always current.
        menu.delegate = self
        item.menu = menu
        rebuild()
    }

    // MARK: - Fleet summary

    /// Compact fleet readout beside the menu-bar icon: "2⚒ 1⏳" — sessions
    /// with an agent/job working vs. sessions blocked waiting on the user.
    /// Only nonzero parts are shown; both zero clears the title entirely.
    func updateSummary(working: Int, waiting: Int) {
        guard let button = item.button else { return }
        var parts: [String] = []
        if working > 0 { parts.append("\(working)⚒") }
        if waiting > 0 { parts.append("\(waiting)⏳") }
        guard !parts.isEmpty else {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.attributedTitle = NSAttributedString(
            string: " " + parts.joined(separator: " "),
            attributes: [.font: font]
        )
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    // MARK: - Menu construction

    private func rebuild() {
        menu.removeAllItems()

        // Mirror the user's actual toggle hotkey (it's rebindable), instead of
        // a hardcoded ⌥⌘7 that goes stale after a rebind.
        let (toggleKey, toggleMods) = Self.toggleKeyEquivalent()
        menu.addItem(makeItem("Show / Hide", action: #selector(toggle),
                              key: toggleKey, mods: toggleMods))

        // Section: individually-minimized windows, each restorable on its own.
        let hidden = hiddenWindowsProvider()
        if !hidden.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Hidden Windows", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for win in hidden {
                let it = NSMenuItem(title: win.title,
                                    action: #selector(restoreWindow(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = win.id
                it.image = NSImage(systemSymbolName: "macwindow",
                                   accessibilityDescription: nil)
                menu.addItem(it)
            }
        }

        // Section: ghosted (click-through) windows — restorable only from here.
        let ghosted = ghostedWindowsProvider()
        if !ghosted.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Ghosted Windows", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for win in ghosted {
                let it = NSMenuItem(title: win.title,
                                    action: #selector(unghostWindow(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = win.id
                it.image = NSImage(systemSymbolName: "eye",
                                   accessibilityDescription: nil)
                menu.addItem(it)
            }
        }

        menu.addItem(.separator())
        menu.addItem(makeItem("New Terminal Tab", action: #selector(newTab),
                              key: "t", mods: [.command]))
        menu.addItem(makeItem("New Browser Tab", action: #selector(newBrowserTab),
                              key: "b", mods: [.command]))
        menu.addItem(makeItem("New Window", action: #selector(newWindow),
                              key: "n", mods: [.command]))
        // Fire-and-forget: run a command in a fresh session collapsed to a
        // bubble; it summons the user when it finishes.
        let runTask = NSMenuItem(title: "Run Task in Background…",
                                 action: #selector(runBackgroundTask),
                                 keyEquivalent: "")
        runTask.target = self
        runTask.image = NSImage(systemSymbolName: "play.circle",
                                accessibilityDescription: "Run task in background")
        menu.addItem(runTask)
        menu.addItem(.separator())
        // Privacy toggle: windows excluded from screen recordings and
        // screen-sharing (Zoom, Meet…) while staying visible to the user.
        let hideCapture = NSMenuItem(title: "Hide from Screen Sharing",
                                     action: #selector(toggleHideFromCapture),
                                     keyEquivalent: "")
        hideCapture.target = self
        hideCapture.state = Settings.shared.hideFromScreenCapture ? .on : .off
        hideCapture.image = NSImage(systemSymbolName: "eye.slash",
                                    accessibilityDescription: "Hide from screen sharing")
        menu.addItem(hideCapture)
        menu.addItem(.separator())
        menu.addItem(makeItem("Preferences…", action: #selector(preferences),
                              key: ",", mods: [.command]))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit FloatyTerm", action: #selector(quit),
                              key: "q", mods: [.command]))
    }

    /// Derives the menu key-equivalent for the toggle from Settings: the key
    /// character comes from the display string ("⌥⌘7" → "7"), the modifiers
    /// from the stored Carbon mask.
    private static func toggleKeyEquivalent() -> (String, NSEvent.ModifierFlags) {
        let key = Settings.shared.hotKeyDisplay.last.map { String($0).lowercased() } ?? "7"
        let carbon = Settings.shared.hotKeyModifiers
        var mods: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey)     != 0 { mods.insert(.command) }
        if carbon & UInt32(optionKey)  != 0 { mods.insert(.option)  }
        if carbon & UInt32(controlKey) != 0 { mods.insert(.control) }
        if carbon & UInt32(shiftKey)   != 0 { mods.insert(.shift)   }
        return (key, mods)
    }

    private func makeItem(_ title: String, action: Selector,
                          key: String, mods: NSEvent.ModifierFlags) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = self
        return it
    }

    // MARK: - Actions

    @objc private func toggle()        { onToggle()         }
    @objc private func newTab()        { onNewTab()          }
    @objc private func newBrowserTab() { onNewBrowserTab()   }
    @objc private func newWindow()     { onNewWindow()       }
    @objc private func runBackgroundTask() { onRunBackgroundTask() }
    @objc private func preferences()   { onPreferences()     }
    @objc private func quit()          { NSApp.terminate(nil) }

    @objc private func toggleHideFromCapture() {
        Settings.shared.hideFromScreenCapture.toggle()
        // Settings.didChange propagates to every window's settingsChanged().
    }

    @objc private func restoreWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onRestoreWindow(id)
    }

    @objc private func unghostWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onUnghostWindow(id)
    }
}
