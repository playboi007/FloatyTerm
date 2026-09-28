import AppKit

/// FloatyTerm is a menu-bar app, so it has no visible menu bar. macOS still
/// routes key equivalents through `NSApp.mainMenu`, and the Edit menu is what
/// turns ⌘Z, ⌘C, ⌘V and the other editing keys into `undo:`, `copy:`, `paste:`…
/// for the first responder. Without it, text fields and web views (the Claude
/// tab's composer, browser tabs, the Markdown Viewer) get none of them.
///
/// The menu is never shown. Terminal views keep their own ⌘C/⌘V/⌘Z: a view's
/// `performKeyEquivalent` runs before the main menu is consulted.
enum EditMenu {
    static func install() {
        guard NSApp.mainMenu == nil else { return }
        let edit = NSMenu(title: "Edit")
        func add(_ title: String, _ action: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
            let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            edit.addItem(item)
        }
        add("Undo", "undo:", "z")
        add("Redo", "redo:", "z", [.command, .shift])
        edit.addItem(.separator())
        add("Cut", "cut:", "x")
        add("Copy", "copy:", "c")
        add("Paste", "paste:", "v")
        add("Paste and Match Style", "pasteAsPlainText:", "v", [.command, .option, .shift])
        add("Select All", "selectAll:", "a")

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "FloatyTerm", action: nil, keyEquivalent: ""))   // the app menu slot
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
