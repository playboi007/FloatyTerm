import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [TerminalWindowController] = []
    private var hotKey: HotKey!
    private let statusItem = StatusItemController()
    private let settingsWC = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()

        hotKey = HotKey { [weak self] in self?.toggle() }

        statusItem.onToggle        = { [weak self] in self?.toggle() }
        statusItem.onNewWindow     = { [weak self] in self?.makeWindow() }
        statusItem.onNewTab        = { [weak self] in self?.newTerminalTabInCurrentWindow() }
        statusItem.onNewBrowserTab = { [weak self] in self?.newBrowserTabInCurrentWindow() }
        statusItem.onPreferences   = { [weak self] in self?.settingsWC.show() }

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
        hotKey?.reregister()
    }

    // MARK: - Windows

    /// Creates a new floating window.
    /// - Parameter initialDirectory: Starting directory for the new window's
    ///   first terminal tab. Pass nil to use $HOME (the default).
    @discardableResult
    private func makeWindow(initialDirectory: String? = nil) -> TerminalWindowController {
        let wc = TerminalWindowController(initialDirectory: initialDirectory)
        wc.onNewWindow = { [weak self] in
            // When the user requests a new window from this wc, inherit its cwd.
            self?.makeWindow(initialDirectory: wc.activeTerminalWorkingDirectory)
        }
        wc.onClosed = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
        }
        wc.onOpenPreferences = { [weak self] in self?.settingsWC.show() }
        windows.append(wc)
        wc.setupInitialFrame(cascadeIndex: windows.count - 1)
        wc.show()
        return wc
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

    private func toggle() {
        if windows.isEmpty {
            makeWindow()
            return
        }
        if windows.contains(where: { $0.isVisible }) {
            windows.forEach { $0.hide() }     // hide all (sessions preserved)
        } else {
            windows.forEach { $0.show() }     // bring them all back
        }
    }
}
