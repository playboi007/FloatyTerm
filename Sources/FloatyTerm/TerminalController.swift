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

    // MARK: - Agent awareness ("waiting on you")

    /// Known agent CLIs, matched against the foreground process name by exact
    /// name or prefix (proc_name truncates to 16 chars, so a longer binary
    /// name arrives clipped — prefix matching absorbs that).
    private static let knownAgentCLIs = [
        "claude", "cursor-agent", "codex", "aider", "gemini", "copilot", "amp"
    ]

    /// The foreground process name when it is a known agent CLI, else nil.
    var agentName: String? {
        guard let proc = foregroundProcessName else { return nil }
        let lower = proc.lowercased()
        let matches = Self.knownAgentCLIs.contains {
            lower == $0 || lower.hasPrefix($0)
        }
        return matches ? proc : nil
    }

    /// True while a known agent CLI is the pty's foreground process.
    var isAgentSession: Bool { agentName != nil }

    /// True when an agent in the foreground appears blocked waiting on the
    /// user (a question, a permission prompt, or just sustained silence).
    /// Recomputed by `updateAttentionState()` on the window's 2s tick.
    private(set) var awaitingInput = false

    /// Recomputes `awaitingInput` from the live screen and output recency.
    ///
    /// Key insight: agent TUIs animate spinners while working, which keeps
    /// `lastOutputAt` fresh on every repaint — so sustained quiet with an
    /// agent still in the foreground means it has stopped working and is
    /// waiting on the user. Explicit prompt text on the live screen lowers
    /// the quiet threshold; explicit busy markers ("esc to interrupt", a
    /// braille spinner glyph) veto both rules, because a prompt phrase can
    /// linger on screen from an earlier exchange while the agent works.
    func updateAttentionState() {
        guard isAgentSession, hasRunningForegroundJob else {
            awaitingInput = false
            return
        }
        let quiet = Date().timeIntervalSince(lastOutputAt)
        let tail = transcriptVolatile.suffix(15).map { $0.lowercased() }

        // BUSY vetoes: the agent is actively working.
        let busyMarkers = ["esc to interrupt", "ctrl+c to stop"]
        let busy = tail.contains { line in
            busyMarkers.contains(where: line.contains)
                // Braille spinner chars (U+2800…U+28FF) — the classic TUI
                // working animation.
                || line.unicodeScalars.contains { (0x2800...0x28FF).contains($0.value) }
        }
        if busy {
            awaitingInput = false
            return
        }

        // PROMPT patterns: the agent is explicitly asking for something.
        let promptMarkers = [
            "do you want", "(y/n", "[y/n", "proceed?", "❯ 1.", "permission",
            "add a follow-up", "? for shortcuts", "press enter", "waiting for",
            "approve"
        ]
        let promptSeen = tail.contains { line in
            promptMarkers.contains(where: line.contains)
        }

        awaitingInput = (promptSeen && quiet > 2) || quiet > 8
    }

    // MARK: - Notify when done

    /// Armed by the user (tab chip → "Notify When Done"): the next time this
    /// session finishes, the window summons itself to the user's current
    /// Space. One-shot — fires once, then disarms.
    var notifyWhenDone = false {
        didSet {
            guard notifyWhenDone != oldValue else { return }
            armedSawJob = notifyWhenDone && hasRunningForegroundJob
            armedSawOutput = false
            markerDoneSinceArm = false
        }
    }

    /// A foreground job has existed at some point since arming — guards
    /// against firing immediately when the user arms an idle session.
    private var armedSawJob = false
    /// Output has streamed since arming — guards the quiet rule against an
    /// agent that was ALREADY sitting silent at its prompt when armed.
    private var armedSawOutput = false
    private var lastOutputAt = Date.distantPast

    /// "Done" means: an OSC 133;D marker arrived (shell integration —
    /// deterministic, no quiet-wait), OR the foreground job exited (builds,
    /// tests, scripts), OR a job is still attached but output has been quiet
    /// for a while after streaming (an agent CLI like Claude/Cursor stays in
    /// the foreground even when it's finished and waiting for input — and no
    /// prompt cycle runs while the agent owns the pty, so markers can't help
    /// there). Called from the window's 2s activity tick; returns true
    /// exactly once per arm.
    func checkDoneIfArmed() -> Bool {
        guard notifyWhenDone else { return false }
        let busy = hasRunningForegroundJob
        if busy { armedSawJob = true }
        let markerDone = armedSawJob && markerDoneSinceArm
        let jobFinished = armedSawJob && !busy
        let agentIdle = armedSawJob && busy && armedSawOutput
            && Date().timeIntervalSince(lastOutputAt) > 10
        guard markerDone || jobFinished || agentIdle else { return false }
        notifyWhenDone = false   // didSet also clears markerDoneSinceArm
        markerDoneSinceArm = false
        return true
    }

    // MARK: - Fire-and-forget

    /// Types `command` into the session's pty (with a trailing newline), as
    /// if the user had entered it. Used by fire-and-forget background tasks;
    /// the pty buffers input, so sending while the shell is still starting
    /// is safe.
    func run(command: String) {
        terminalView.send(txt: command + "\n")
    }

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

    // MARK: - Transcript store (always-on, from shell start)

    /// Stable identity for this session across relaunches. Persisted in the
    /// tab record so a restored tab finds its transcript log on disk; the
    /// live process never survives a relaunch, but its history does.
    let sessionID: String

    /// Disk mirror of the committed transcript (one append per committed
    /// line) — continuous appends are the crash protection, so history
    /// survives even an unclean shutdown.
    private let transcriptDisk: TranscriptDisk

    /// Headless terminal fed the same pty bytes as the visible one. Unlike a
    /// strip-the-escapes parser, it fully interprets cursor movement and
    /// erase sequences — so a TUI repainting its status frame (spinner,
    /// footer hints) overwrites the same screen rows instead of producing an
    /// endless stream of near-duplicate lines. Only output that genuinely
    /// scrolls off this screen is committed to the transcript.
    private var mirror: Terminal!
    private let mirrorDelegate = MirrorTerminalDelegate()
    private var mirrorNextRow = 0    // next scroll-invariant row to commit
    private var mirrorProbedEnd = 0  // rows examined so far

    /// Committed output lines: everything that has scrolled off the mirror's
    /// live screen since the shell started — so a transcript reader opened
    /// mid-session still has the full history. Each line commits exactly
    /// once; runs of blank lines are collapsed.
    private(set) var transcriptLines: [String] = []

    /// How many lines have been dropped off the front of `transcriptLines`
    /// (by the memory cap or the TTL) — readers use it to keep absolute
    /// line indices.
    private(set) var transcriptDropped = 0

    /// Absolute line index up to which the user has seen the transcript
    /// (set by the transcript reader on close, and continuously while the
    /// user follows the tail live). Lets a reopened reader mark where
    /// "new since last look" begins.
    var transcriptLastReadIndex = 0

    /// Committed lines older than this age out — the transcript is a live
    /// working view, not an archive, so a long-lived but quiet session must
    /// not hold hours-old output in memory forever.
    private static let transcriptTTL: TimeInterval = 60 * 60   // 1 hour

    /// Commit time per line, parallel to `transcriptLines`.
    private var transcriptTimes: [TimeInterval] = []

    /// The mirror's live screen — content that hasn't scrolled off yet
    /// (including a TUI's whole current frame). The reader renders this as a
    /// volatile tail it rewrites in place, so the frame updates live without
    /// committing repaint spam.
    var transcriptVolatile: [String] {
        var lines: [String] = []
        if mirror.isCurrentBufferAlternate {
            // Alt-screen apps (vim, less…) paint a screen, not a log: show it
            // live, commit nothing.
            for row in 0..<mirror.rows {
                guard let line = mirror.getLine(row: row) else { break }
                lines.append(line.translateToString(trimRight: true))
            }
        } else {
            var row = mirrorNextRow
            while let line = mirror.getScrollInvariantLine(row: row) {
                lines.append(line.translateToString(trimRight: true))
                row += 1
            }
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines
    }

    /// Commits every line that has scrolled off the mirror's live screen.
    /// Called after each output chunk is fed to the mirror.
    private func harvestTranscript() {
        guard !mirror.isCurrentBufferAlternate else { return }

        // Extend to the current end of the mirror's scroll buffer.
        var end = max(mirrorProbedEnd, mirrorNextRow)
        while mirror.getScrollInvariantLine(row: end) != nil { end += 1 }
        mirrorProbedEnd = end

        // If the mirror's scrollback overflowed past our cursor (a huge burst
        // between harvests), skip the lost gap.
        while mirrorNextRow < end,
              mirror.getScrollInvariantLine(row: mirrorNextRow) == nil {
            mirrorNextRow += 1
        }

        // Rows above the live screen can never change again — commit them.
        let stableEnd = max(mirrorNextRow, end - mirror.rows)
        while mirrorNextRow < stableEnd {
            if let line = mirror.getScrollInvariantLine(row: mirrorNextRow) {
                commitTranscriptLine(line.translateToString(trimRight: true))
            }
            mirrorNextRow += 1
        }
    }

    private var lineBytes: [UInt8] = []
    /// A \r was seen and not yet resolved. The pty's ONLCR mode makes nearly
    /// every line arrive as \r\n, so \r alone can't mean "discard the line":
    /// \r then \n is a normal line ending (commit); \r then printable text is
    /// a progress-bar style overwrite (restart the line).
    private var pendingCR = false
    private enum EscState { case none, escape, csi, osc, oscEsc }
    private var escState: EscState = .none

    // MARK: - OSC 133 semantic prompt markers (shell integration)
    //
    // Shells with integration installed (iTerm2's, WezTerm's, Kitty's,
    // starship, oh-my-zsh plugins…) emit OSC 133 escape sequences around the
    // prompt cycle: `ESC ] 133 ; X [; args] BEL`, where
    //   A = prompt start, B = command start (user typing),
    //   C = command executed (output begins), D;<exit> = command finished.
    // When present these give deterministic "done" detection with exit codes,
    // instead of the tcgetpgrp/quiet-time heuristics.
    //
    // Users without any integration can add this zsh one-liner:
    //   # ~/.zshrc — emit command lifecycle markers (FloatyTerm, iTerm2, WezTerm…)
    //   preexec() { print -n '\e]133;C\a' }
    //   precmd()  { print -n "\e]133;D;$?\a" }

    /// Accumulates the current OSC payload (between `ESC ]` and BEL/ST).
    /// 133 sequences are tiny; anything past the cap is skipped, not stored.
    private var oscBytes: [UInt8] = []
    private static let oscCap = 64

    /// Exit code from the most recent `133;D;<code>` marker. Nil until one
    /// arrives, or when a `133;D` arrives without a code.
    private(set) var lastExitCode: Int32?
    /// True once any OSC 133 marker has been seen this session — i.e. the
    /// shell has integration installed and marker-based detection is viable.
    private(set) var sawShellIntegration = false
    /// True between `133;C` (command output began) and `133;D` (finished).
    /// Only meaningful when `sawShellIntegration` is true.
    private(set) var commandRunning = false
    /// A `133;D` arrived while notify-when-done was armed with a job seen —
    /// consumed by `checkDoneIfArmed()` as the deterministic trigger.
    private var markerDoneSinceArm = false

    /// Decodes a completed OSC payload; only `133;…` prompt markers are
    /// handled, every other OSC (title sets etc.) is ignored.
    private func handleOSC() {
        defer { oscBytes.removeAll(keepingCapacity: true) }
        guard oscBytes.count >= 5 else { return }   // "133;" + command char
        let payload = String(decoding: oscBytes, as: UTF8.self)
        guard payload.hasPrefix("133;") else { return }
        let body = payload.dropFirst(4)
        switch body.first {
        case "A", "B":   // prompt start / command start
            sawShellIntegration = true
        case "C":        // command executed — output begins
            sawShellIntegration = true
            commandRunning = true
        case "D":        // command finished, optionally with `;<exit code>`
            sawShellIntegration = true
            commandRunning = false
            let rest = body.dropFirst()
            if rest.first == ";" {
                // `Int32("")` is nil, so `133;D;` (no digits) clears the code.
                lastExitCode = Int32(rest.dropFirst().prefix(while: \.isNumber))
            } else {
                lastExitCode = nil
            }
            if notifyWhenDone && armedSawJob { markerDoneSinceArm = true }
        default:
            break
        }
    }

    /// Tiny streaming parser: accumulates printable bytes per line, skipping
    /// ANSI CSI/OSC escape sequences, and publishes the current/last line.
    private func ingestOutput(_ slice: ArraySlice<UInt8>) {
        for b in slice {
            switch escState {
            case .escape:
                if b == 0x5B { escState = .csi }        // ESC [
                else if b == 0x5D {                     // ESC ] — OSC start
                    escState = .osc
                    oscBytes.removeAll(keepingCapacity: true)
                } else { escState = .none }             // 2-byte escape, done
            case .csi:
                if b >= 0x40 && b <= 0x7E { escState = .none }  // final byte
            case .osc:
                if b == 0x07 {                          // BEL terminator
                    escState = .none
                    handleOSC()
                } else if b == 0x1B {
                    escState = .oscEsc
                } else if oscBytes.count < Self.oscCap {
                    oscBytes.append(b)
                }
            case .oscEsc:
                if b == 0x5C {                          // ESC \ terminator (ST)
                    escState = .none
                    handleOSC()
                } else {
                    // False alarm: the ESC wasn't the start of ST. Drop the
                    // ESC from the payload (133 payloads never contain ESC)
                    // but keep this byte.
                    escState = .osc
                    if oscBytes.count < Self.oscCap { oscBytes.append(b) }
                }
            case .none:
                switch b {
                case 0x1B: escState = .escape
                case 0x0A:   // line end (\n or the \n of \r\n)
                    publishLine()
                    lineBytes.removeAll(keepingCapacity: true)
                    pendingCR = false
                case 0x0D:   // defer: \n commits it, printable text overwrites it
                    pendingCR = true
                case 0x08: if !lineBytes.isEmpty { lineBytes.removeLast() }   // backspace
                default:
                    if b >= 0x20 {
                        if pendingCR {   // overwrite frame (progress bar): restart
                            publishLine()
                            lineBytes.removeAll(keepingCapacity: true)
                            pendingCR = false
                        }
                        if lineBytes.count < 400 { lineBytes.append(b) }
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

    /// Appends the current line to the transcript. Consecutive duplicates are
    /// dropped (TUI frameworks repaint the same lines on every frame); memory
    /// is bounded by trimming the oldest lines in bulk.
    private func commitTranscriptLine(_ line: String) {
        purgeExpiredTranscript()
        // Keep blank lines (they're real separators) but collapse runs.
        if line.isEmpty, transcriptLines.last?.isEmpty != false { return }
        let now = Date().timeIntervalSinceReferenceDate
        transcriptLines.append(line)
        transcriptTimes.append(now)
        if transcriptLines.count > 10_000 {
            transcriptLines.removeFirst(2_000)
            transcriptTimes.removeFirst(2_000)
            transcriptDropped += 2_000
        }
        // Mirror the commit to disk. The memory trims above deliberately do
        // NOT touch the file (rewriting on every purge would defeat the
        // append-only crash protection) — disk trimming happens only here,
        // via rotation, once the file has grown enough to be worth it.
        transcriptDisk.append(time: now, line: line)
        if transcriptDisk.wantsCompaction {
            transcriptDisk.compact(lines: transcriptLines, times: transcriptTimes)
        }
    }

    /// Preloads the committed store from this session's log file (restored
    /// tabs only — fresh sessionIDs have no file). Applies the same TTL and a
    /// 5_000-line cap so a relaunch can't resurrect more than the live store
    /// would ever hold, then marks the seam so old and new output don't read
    /// as one continuous run. The mirror starts fresh on purpose: restored
    /// lines can never scroll off a screen again, so they live only here.
    private func restoreTranscriptFromDisk() {
        let (lines, times) = transcriptDisk.restore(ttl: Self.transcriptTTL,
                                                    maxLines: 5_000)
        guard !lines.isEmpty else { return }
        transcriptLines = lines
        transcriptTimes = times
        commitTranscriptLine("─── earlier session · restored ───")
    }

    /// Drops lines past their TTL. Lines commit in time order, so expiry is
    /// always a prefix and folds into the same `transcriptDropped` accounting
    /// as the memory cap. Runs on every commit and on every reader refresh,
    /// so both active and merely-watched sessions stay pruned.
    func purgeExpiredTranscript() {
        let cutoff = Date().timeIntervalSinceReferenceDate - Self.transcriptTTL
        var n = 0
        while n < transcriptTimes.count, transcriptTimes[n] < cutoff { n += 1 }
        guard n > 0 else { return }
        transcriptLines.removeFirst(n)
        transcriptTimes.removeFirst(n)
        transcriptDropped += n
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
    /// - Parameter sessionID: A persisted identity when restoring a saved tab
    ///   (the session reclaims its transcript log); nil (the default) mints a
    ///   fresh one.
    init(startDirectory: String? = nil, sessionID: String? = nil) {
        self.startDirectory = startDirectory
        let isRestored = sessionID != nil
        self.sessionID = sessionID ?? UUID().uuidString
        self.transcriptDisk = TranscriptDisk(sessionID: self.sessionID)
        terminalView = FloatyTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 440))
        super.init()
        terminalView.processDelegate = self

        // "Notify When Done" in the terminal's right-click menu — reachable
        // even when this is the window's only tab (no chip to right-click).
        terminalView.notifyWhenDoneState = { [weak self] in self?.notifyWhenDone ?? false }
        terminalView.onToggleNotifyWhenDone = { [weak self] in self?.notifyWhenDone.toggle() }

        // Restore the previous run's transcript before any shell output can
        // commit, so old history sits cleanly below the new session's lines.
        if isRestored { restoreTranscriptFromDisk() }

        // The transcript mirror: a headless terminal interpreting the same
        // byte stream, sized to match (sizeChanged keeps it in sync) with a
        // scrollback matching the transcript cap.
        var mirrorOptions = TerminalOptions.default
        mirrorOptions.scrollback = 10_000
        // Match the real terminal's geometry FROM THE START — sizeChanged only
        // fires on later resizes. A mirror narrower than the real terminal
        // wraps TUI frames onto extra rows the TUI's cursor-up repaint can't
        // reach, so every repaint would scroll phantom lines into the
        // transcript.
        let real = terminalView.getTerminal()
        mirrorOptions.cols = real.cols
        mirrorOptions.rows = real.rows
        mirror = Terminal(delegate: mirrorDelegate, options: mirrorOptions)

        terminalView.onOutput = { [weak self] slice in
            guard let self else { return }
            self.mirror.feed(buffer: slice)
            self.harvestTranscript()
            self.ingestOutput(slice)
            self.lastOutputAt = Date()
            if self.notifyWhenDone { self.armedSawOutput = true }
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
        // The shell process itself needs nothing: it's cleaned up when the
        // view is deallocated and the pty fd closes. The transcript log does:
        // a session the user discards (tab closed, window closed) is gone for
        // good, so its file goes too — but at quit the saved records may
        // reference it for the next launch, so the file stays (orphans from
        // "Quit Without Saving" are swept at the next launch instead).
        if AppRuntime.isQuitting {
            transcriptDisk.close()
        } else {
            transcriptDisk.closeAndDelete()
        }
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

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // Keep the transcript mirror's geometry in lockstep so line wrapping
        // and the "scrolled off screen" boundary match the real terminal.
        if newCols > 0, newRows > 0 { mirror.resize(cols: newCols, rows: newRows) }
    }

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

/// Delegate for the headless transcript mirror. The mirror is read-only —
/// nothing a program writes should ever be answered (terminal queries are
/// already answered by the real terminal view).
private final class MirrorTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

/// One session's transcript log on disk: `<sessionID>.log` under Application
/// Support, one `<unix-epoch-seconds>\t<line>\n` record per committed line.
/// Append-only during normal operation — every commit lands on disk
/// immediately (no fsync; the continuous appends ARE the crash protection),
/// so an unclean shutdown loses at most the kernel's unflushed tail.
final class TranscriptDisk {

    /// ~/Library/Application Support/FloatyTerm/Transcripts — created on
    /// demand (first append), never eagerly.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("FloatyTerm/Transcripts", isDirectory: true)
    }

    /// Deletes logs no saved tab record claims. Sessions closed mid-run delete
    /// their own file; this launch-time sweep catches what they can't — "Quit
    /// Without Saving", crashes, and records pruned while the app was gone.
    static func purgeOrphans(keeping liveIDs: Set<String>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: nil)
        else { return }   // no directory yet — nothing to sweep
        for url in files where url.pathExtension == "log" {
            if !liveIDs.contains(url.deletingPathExtension().lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// File timestamps are unix epoch (stable across relaunches and readable
    /// in a text editor); memory uses reference-date intervals. This bridges.
    private static let epochOffset = Date.timeIntervalBetween1970AndReferenceDate

    private let url: URL
    private var handle: FileHandle?
    /// Set once the session is closed for good — late pty output draining
    /// through `commitTranscriptLine` must not resurrect a deleted file.
    private var retired = false
    /// Appends since the handle (re)opened, for the rotation trigger.
    private var linesSinceOpen = 0

    init(sessionID: String) {
        url = Self.directory.appendingPathComponent("\(sessionID).log")
    }

    /// Appends one committed line. The handle opens lazily on the first
    /// commit and stays open for the session's lifetime.
    func append(time: TimeInterval, line: String) {
        guard !retired else { return }
        if handle == nil { openForAppending() }
        guard let handle,
              let data = "\(Int(time + Self.epochOffset))\t\(line)\n".data(using: .utf8)
        else { return }
        try? handle.write(contentsOf: data)
        linesSinceOpen += 1
    }

    /// Rotation trigger: enough NEW appends to matter AND a file big enough
    /// to be worth rewriting. Either alone would compact too eagerly — a
    /// restored 1 MB file with ten new lines, or 5_000 tiny prompt lines.
    /// We only ever append, so the handle's offset is the file size.
    var wantsCompaction: Bool {
        guard linesSinceOpen > 5_000, let handle else { return false }
        return ((try? handle.offset()) ?? 0) > 1_000_000
    }

    /// Rewrites the file from the in-memory store (already TTL-purged and
    /// capped), then resumes appending. This is the ONLY place the file
    /// shrinks — the in-memory purges never touch disk.
    func compact(lines: [String], times: [TimeInterval]) {
        guard !retired else { return }
        try? handle?.close()
        handle = nil
        var out = ""
        for (i, line) in lines.enumerated() {
            out += "\(Int(times[i] + Self.epochOffset))\t\(line)\n"
        }
        try? out.data(using: .utf8)?.write(to: url, options: .atomic)
        openForAppending()
    }

    /// Parses the log for a restored session: lines past `ttl` are dropped
    /// (same rule as the live store) and at most the last `maxLines` survive.
    /// Malformed lines (partial trailing write from a crash) are skipped —
    /// content is everything past the FIRST tab, so tabs inside a line are fine.
    func restore(ttl: TimeInterval, maxLines: Int) -> ([String], [TimeInterval]) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return ([], [])
        }
        let cutoff = Date().timeIntervalSinceReferenceDate - ttl
        var lines: [String] = []
        var times: [TimeInterval] = []
        for raw in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let tab = raw.firstIndex(of: "\t"),
                  let epoch = Int(raw[..<tab]) else { continue }
            let time = TimeInterval(epoch) - Self.epochOffset
            guard time >= cutoff else { continue }
            times.append(time)
            lines.append(String(raw[raw.index(after: tab)...]))
        }
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
            times.removeFirst(times.count - maxLines)
        }
        return (lines, times)
    }

    /// Quit path: flush the handle but KEEP the file — it's the next launch's
    /// restore source.
    func close() {
        try? handle?.close()
        handle = nil
        retired = true
    }

    /// Discard path (tab/window closed by the user): the session is gone for
    /// good, so its history goes with it.
    func closeAndDelete() {
        close()
        try? FileManager.default.removeItem(at: url)
    }

    private func openForAppending() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        linesSinceOpen = 0
    }
}
