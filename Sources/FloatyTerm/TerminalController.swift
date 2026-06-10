import AppKit
import Darwin
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

    /// User-pinned name (right-click chip → Rename). Wins over auto-labels.
    var customName: String?

    /// Custom name, else a live "process · directory" label while a foreground
    /// job runs ("flutter · myapp"), else the shell-controlled title.
    var displayName: String {
        if let name = customName, !name.isEmpty { return name }
        if let label = processLabel { return label }
        return title
    }

    /// "fgProcess · cwdBasename" while a foreground job is running, nil when
    /// the shell is idle (or the info can't be read).
    private var processLabel: String? {
        guard let proc = foregroundProcessName else { return nil }
        if let cwd = currentWorkingDirectory {
            let dir = (cwd as NSString).lastPathComponent
            return "\(proc) · \(dir)"
        }
        return proc
    }

    /// Name of the pty's foreground process when it differs from the shell.
    private var foregroundProcessName: String? {
        guard let p = terminalView.process, p.running, p.childfd >= 0 else { return nil }
        let fg = tcgetpgrp(p.childfd)
        guard fg > 0, fg != p.shellPid else { return nil }
        var buf = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        guard proc_name(fg, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// Fired (throttle-free) on every output chunk — the transcript reader
    /// subscribes to drive its debounced refresh.
    var onOutputActivity: (() -> Void)?

    // MARK: - Unseen-output tracking

    private(set) var hasUnseenOutput = false

    var isCurrentlyViewed = true {
        didSet { if isCurrentlyViewed { hasUnseenOutput = false } }
    }

    // MARK: - Last output line (ticker mode)

    /// The most recent meaningful line of output, ANSI-stripped — what the
    /// ticker strip displays. Carriage-return rewrites (progress bars) update
    /// it in place.
    private(set) var lastOutputLine: String = ""

    private var lineBytes: [UInt8] = []
    private enum EscState { case none, escape, csi, osc, oscEsc }
    private var escState: EscState = .none

    /// Tiny streaming parser: accumulates printable bytes per line, skipping
    /// ANSI CSI/OSC escape sequences, and publishes the current/last line.
    private func ingestForTicker(_ slice: ArraySlice<UInt8>) {
        for b in slice {
            switch escState {
            case .escape:
                if b == 0x5B { escState = .csi }        // ESC [
                else if b == 0x5D { escState = .osc }   // ESC ]
                else { escState = .none }               // 2-byte escape, done
            case .csi:
                if b >= 0x40 && b <= 0x7E { escState = .none }  // final byte
            case .osc:
                if b == 0x07 { escState = .none }       // BEL terminator
                else if b == 0x1B { escState = .oscEsc }
            case .oscEsc:
                escState = (b == 0x5C) ? .none : .osc   // ESC \ terminator
            case .none:
                switch b {
                case 0x1B: escState = .escape
                case 0x0A: publishLine(); lineBytes.removeAll(keepingCapacity: true)
                case 0x0D: publishLine(); lineBytes.removeAll(keepingCapacity: true)
                case 0x08: if !lineBytes.isEmpty { lineBytes.removeLast() }   // backspace
                default:
                    if b >= 0x20, lineBytes.count < 400 {
                        lineBytes.append(b)
                    }
                }
            }
        }
        publishLine()   // in-progress line (e.g. a progress bar) shows live
    }

    private func publishLine() {
        guard !lineBytes.isEmpty else { return }
        let line = String(decoding: lineBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        if !line.isEmpty { lastOutputLine = line }
    }

    /// Called when the shell exits (e.g. the user types `exit`) so the owner
    /// can close this tab.
    var onTerminated: (() -> Void)?

    /// Called when the terminal title changes, so the tab label can update.
    var onTitleChanged: (() -> Void)?

    /// The directory to start the shell in. nil means $HOME (the default).
    private let startDirectory: String?

    /// Designated initialiser.
    /// - Parameter startDirectory: If provided and it exists as a directory on
    ///   disk, the new shell starts there. Pass nil (the default) to start in
    ///   $HOME, which preserves the original behaviour.
    init(startDirectory: String? = nil) {
        self.startDirectory = startDirectory
        terminalView = FloatyTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 440))
        super.init()
        terminalView.processDelegate = self
        terminalView.onOutput = { [weak self] slice in
            guard let self else { return }
            self.ingestForTicker(slice)
            if !self.isCurrentlyViewed { self.hasUnseenOutput = true }
            self.onOutputActivity?()
        }

        applyFont()
        // Opaque dark background; see-through is handled by fading the whole
        // content area's opacity in the window controller (reliable for this
        // terminal engine), not by the background color's alpha.
        terminalView.nativeBackgroundColor = .black

        startShell()
    }

    // MARK: - Current working directory

    /// Returns the shell process's current working directory by calling
    /// `proc_pidinfo(PROC_PIDVNODEPATHINFO)` on the shell's pid.  This works
    /// because the shell is our own child process — no special entitlement is
    /// needed.  Returns nil when the process is not running or the call fails.
    var currentWorkingDirectory: String? {
        guard let process = terminalView.process, process.running else { return nil }
        let pid = process.shellPid
        guard pid > 0 else { return nil }
        return Self.workingDirectory(ofPID: pid)
    }

    /// Reads the cwd of `pid` via proc_pidinfo / PROC_PIDVNODEPATHINFO.
    private static func workingDirectory(ofPID pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sz) == sz else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        // Validate that the path is a non-empty existing directory.
        guard let p = path, !p.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return p
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
    /// No-ops when the size is unchanged: setting the font reflows the whole
    /// terminal, and this is called on EVERY settings change (opacity sliders,
    /// blur toggle…), not just font edits.
    func applyFont() {
        let size = CGFloat(Settings.shared.fontSize)
        guard terminalView.font.pointSize != size else { return }
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

        // Determine start directory: honour the requested directory when it is a
        // valid existing directory; otherwise fall back to $HOME. SwiftTerm
        // chdir()s in the CHILD after fork, so the app's own working directory
        // is never touched (no process-global side effect).
        let targetDir: String
        if let requested = startDirectory {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: requested, isDirectory: &isDir),
               isDir.boolValue {
                targetDir = requested
            } else {
                targetDir = NSHomeDirectory()
            }
        } else {
            targetDir = NSHomeDirectory()
        }

        // The leading "-" on execName makes this a LOGIN shell, so .zprofile /
        // .zshrc (and therefore Oh My Zsh) are sourced.
        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: env,
            execName: "-\(shellName)",
            currentDirectory: targetDir
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
