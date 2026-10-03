import AppKit

/// Hidden Edit menu routes ⌘Z/⌘C/⌘V key equivalents to first responders;
/// installed as NSApp.mainMenu. Never displayed.
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
