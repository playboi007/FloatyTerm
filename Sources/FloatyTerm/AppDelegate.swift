import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [TerminalWindowController] = []
    private var hotKey: HotKey!
    private let statusItem = StatusItemController()
    private let settingsWC = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeWindow()

        hotKey = HotKey { [weak self] in self?.toggle() }

        statusItem.onToggle = { [weak self] in self?.toggle() }
        statusItem.onNewWindow = { [weak self] in self?.makeWindow() }
        statusItem.onNewTab = { [weak self] in self?.newTabInCurrentWindow() }
        statusItem.onPreferences = { [weak self] in self?.settingsWC.show() }

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

    @discardableResult
    private func makeWindow() -> TerminalWindowController {
        let wc = TerminalWindowController()
        wc.onNewWindow = { [weak self] in self?.makeWindow() }
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

    private func newTabInCurrentWindow() {
        if let wc = currentWindow() {
            wc.openNewTab()
            wc.show()
        } else {
            makeWindow()
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
