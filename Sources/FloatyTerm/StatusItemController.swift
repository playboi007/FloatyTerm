import AppKit

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
    var onPreferences: () -> Void = {}

    /// Returns the windows that are currently minimized (hidden via their own
    /// minimize button), so they can be listed for individual restore.
    var hiddenWindowsProvider: () -> [(id: UUID, title: String)] = { [] }

    /// Restores (un-minimizes) the window with the given id.
    var onRestoreWindow: (UUID) -> Void = { _ in }

    override init() {
        super.init()

        if let button = item.button {
            if let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: "FloatyTerm") {
                button.image = img
            } else {
                button.title = "FT"
            }
        }

        // Rebuild on each open so the "Hidden Windows" list is always current.
        menu.delegate = self
        item.menu = menu
        rebuild()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    // MARK: - Menu construction

    private func rebuild() {
        menu.removeAllItems()

        menu.addItem(makeItem("Show / Hide", action: #selector(toggle),
                              key: "7", mods: [.command, .option]))

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

        menu.addItem(.separator())
        menu.addItem(makeItem("New Terminal Tab", action: #selector(newTab),
                              key: "t", mods: [.command]))
        menu.addItem(makeItem("New Browser Tab", action: #selector(newBrowserTab),
                              key: "b", mods: [.command]))
        menu.addItem(makeItem("New Window", action: #selector(newWindow),
                              key: "n", mods: [.command]))
        menu.addItem(.separator())
        menu.addItem(makeItem("Preferences…", action: #selector(preferences),
                              key: ",", mods: [.command]))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit FloatyTerm", action: #selector(quit),
                              key: "q", mods: [.command]))
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
    @objc private func preferences()   { onPreferences()     }
    @objc private func quit()          { NSApp.terminate(nil) }

    @objc private func restoreWindow(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        onRestoreWindow(id)
    }
}
