import AppKit

// Entry point. We run as an "accessory" app: no Dock icon, no app menu bar
// takeover. It lives quietly in the background and is summoned by the hotkey.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
