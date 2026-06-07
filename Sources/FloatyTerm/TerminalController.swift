import AppKit
import SwiftTerm

/// Hosts one SwiftTerm terminal session (i.e. one tab) and launches the user's
/// login shell, so the existing zsh + Oh My Zsh configuration loads as usual.
final class TerminalController: NSObject, LocalProcessTerminalViewDelegate, TabContent {

    // MARK: - TabContent conformance

    /// The terminal view, typed as NSView to satisfy the TabContent protocol.
    /// Use `terminalView` for typed access internally.
    var view: NSView { terminalView }

    // MARK: - Typed accessor

    /// The actual FloatyTerminalView; use this within TerminalController and
    /// TerminalWindowController (via downcast) when SwiftTerm-specific APIs are needed.
    let terminalView: FloatyTerminalView

    /// Display title for this session's tab (updated by the shell/programs).
    private(set) var title: String = "Terminal"

    /// Called when the shell exits (e.g. the user types `exit`) so the owner
    /// can close this tab.
    var onTerminated: (() -> Void)?

    /// Called when the terminal title changes, so the tab label can update.
    var onTitleChanged: (() -> Void)?

    override init() {
        terminalView = FloatyTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 440))
        super.init()
        terminalView.processDelegate = self

        applyFont()
        // Opaque dark background; see-through is handled by fading the whole
        // content area's opacity in the window controller (reliable for this
        // terminal engine), not by the background color's alpha.
        terminalView.nativeBackgroundColor = .black

        startShell()
    }

    // MARK: - TabContent

    func focus(in panel: NSWindow) {
        panel.makeFirstResponder(terminalView)
    }

    func cleanup() {
        // Nothing extra needed: the shell process will be cleaned up when the
        // view is deallocated and the pty fd closes.
    }

    // MARK: - Font

    /// Applies the font/size from Settings (prefers SF Mono).
    func applyFont() {
        let size = CGFloat(Settings.shared.fontSize)
        terminalView.font = NSFont(name: "SFMono-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// True if a foreground command (other than the shell itself) is running —
    /// i.e. the pty's foreground process group differs from the shell's pid.
    var hasRunningForegroundJob: Bool {
        guard let p = terminalView.process, p.running, p.childfd >= 0 else { return false }
        let fg = tcgetpgrp(p.childfd)
        return fg > 0 && fg != p.shellPid
    }

    private func startShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent

        // Start from the inherited environment so HOME / USER / PATH survive
        // (a minimal env would drop HOME and break Oh My Zsh's `source $ZSH/...`).
        // Then make sure terminal-related vars advertise a capable terminal.
        var vars = ProcessInfo.processInfo.environment
        vars["TERM"] = "xterm-256color"
        vars["COLORTERM"] = "truecolor"
        vars["LANG"] = vars["LANG"] ?? "en_US.UTF-8"
        let env = vars.map { "\($0.key)=\($0.value)" }

        // Start in the user's home directory. The child shell inherits the
        // app's current directory, which would otherwise be "/" when launched
        // via `open`.
        FileManager.default.changeCurrentDirectoryPath(NSHomeDirectory())

        // The leading "-" on execName makes this a LOGIN shell, so .zprofile /
        // .zshrc (and therefore Oh My Zsh) are sourced.
        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: env,
            execName: "-\(shellName)"
        )
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.title = trimmed
        onTitleChanged?()
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Shell exited: ask the owner to close this tab.
        onTerminated?()
    }
}
