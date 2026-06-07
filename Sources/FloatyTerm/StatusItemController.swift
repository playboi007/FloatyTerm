import AppKit

/// The menu-bar (status) item. Since FloatyTerm has no Dock icon, this is the
/// visible home for New Window / New Tab / Preferences / Quit.
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    var onToggle: () -> Void = {}
    var onNewTab: () -> Void = {}
    var onNewWindow: () -> Void = {}
    var onPreferences: () -> Void = {}

    override init() {
        super.init()

        if let button = item.button {
            if let img = NSImage(systemSymbolName: "terminal", accessibilityDescription: "FloatyTerm") {
                button.image = img
            } else {
                button.title = "FT"
            }
        }

        let menu = NSMenu()
        menu.addItem(makeItem("Show / Hide", action: #selector(toggle),
                              key: "7", mods: [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(makeItem("New Tab", action: #selector(newTab),
                              key: "t", mods: [.command]))
        menu.addItem(makeItem("New Window", action: #selector(newWindow),
                              key: "n", mods: [.command]))
        menu.addItem(.separator())
        menu.addItem(makeItem("Preferences…", action: #selector(preferences),
                              key: ",", mods: [.command]))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit FloatyTerm", action: #selector(quit),
                              key: "q", mods: [.command]))
        item.menu = menu
    }

    private func makeItem(_ title: String, action: Selector,
                          key: String, mods: NSEvent.ModifierFlags) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = self
        return it
    }

    @objc private func toggle() { onToggle() }
    @objc private func newTab() { onNewTab() }
    @objc private func newWindow() { onNewWindow() }
    @objc private func preferences() { onPreferences() }
    @objc private func quit() { NSApp.terminate(nil) }
}
