import AppKit
import SwiftTerm

/// Hosts one SwiftTerm terminal session (i.e. one tab) and launches the user's
/// login shell, so the existing zsh + Oh My Zsh configuration loads as usual.
final class TerminalController: NSObject, LocalProcessTerminalViewDelegate {
    let view: FloatyTerminalView

    /// Display title for this session's tab (updated by the shell/programs).
    private(set) var title: String = "Terminal"

    /// Called when the shell exits (e.g. the user types `exit`) so the owner
    /// can close this tab.
    var onTerminated: (() -> Void)?

    /// Called when the terminal title changes, so the tab label can update.
    var onTitleChanged: (() -> Void)?

    override init() {
        view = FloatyTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 440))
        super.init()
        view.processDelegate = self

        applyFont()
        // Opaque dark background; see-through is handled by fading the whole
        // content area's opacity in the window controller (reliable for this
        // terminal engine), not by the background color's alpha.
        view.nativeBackgroundColor = .black

        startShell()
    }

    /// Applies the font/size from Settings (prefers SF Mono).
    func applyFont() {
        let size = CGFloat(Settings.shared.fontSize)
        view.font = NSFont(name: "SFMono-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// True if a foreground command (other than the shell itself) is running —
    /// i.e. the pty's foreground process group differs from the shell's pid.
    var hasRunningForegroundJob: Bool {
        guard let p = view.process, p.running, p.childfd >= 0 else { return false }
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
        view.startProcess(
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
