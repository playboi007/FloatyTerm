import Foundation

/// Runs one Claude Code session through `Resources/ClaudeSidecar/sidecar.mjs`
/// (Node + the Claude Agent SDK) and speaks its line protocol: one JSON object
/// per line each way. See sidecar.mjs for the message list.
///
/// The SDK drives the user's own `claude` executable (`pathToClaudeCodeExecutable`),
/// so the Claude tab and the TUI always run the same version, with the same
/// login, settings, CLAUDE.md files, skills and hooks.
///
/// Output lines are delivered raw and batched per run-loop turn — a streaming
/// reply produces hundreds of small events, and the page wants them in groups.
final class ClaudeSidecar {

    enum StartError: Error, CustomStringConvertible {
        case missingSidecar, missingNode, missingClaude, launch(Error)
        var description: String {
            switch self {
            case .missingSidecar: return "The Claude sidecar files are missing (Resources/ClaudeSidecar with node_modules). Rebuild with ./build.sh."
            case .missingNode:    return "Node.js was not found. Install it (brew install node) to use the Claude tab."
            case .missingClaude:  return "The claude command was not found. Install Claude Code to use the Claude tab."
            case .launch(let e):  return "The Claude sidecar did not start: \(e.localizedDescription)"
            }
        }
    }

    /// Raw JSON lines from the sidecar, in order, on the main thread.
    var onLines: (([String]) -> Void)?
    /// The sidecar exited: its status and the end of its stderr.
    var onExit: ((Int32, String) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var pending: [String] = []
    private var flushScheduled = false
    private var stderrTail = ""

    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Locating the pieces

    /// The sidecar directory: in the app bundle, or the source tree for a dev run.
    static let directory: URL? = {
        let fm = FileManager.default
        let ok = { (u: URL) in
            fm.fileExists(atPath: u.appendingPathComponent("sidecar.mjs").path)
                && fm.fileExists(atPath: u.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk").path)
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ClaudeSidecar"), ok(bundled) { return bundled }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ClaudeSidecar")
        return ok(dev) ? dev : nil
    }()

    static let nodePath: String? = locate("node")
    static let claudePath: String? = locate("claude")

    /// Common install locations first — an app started from Finder has a bare
    /// PATH — then the user's login shell as the last resort.
    private static func locate(_ name: String) -> String? {
        let home = NSHomeDirectory()
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local",
                          "\(home)/.volta/bin", "\(home)/.bun/bin", "/usr/bin"].map { "\($0)/\(name)" }
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", "command -v \(name)"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let path = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    // MARK: - Lifecycle

    func start(cwd: String, resume: String? = nil, permissionMode: String? = nil,
               model: String? = nil, effort: String? = nil) throws {
        guard let dir = Self.directory else { throw StartError.missingSidecar }
        guard let node = Self.nodePath else { throw StartError.missingNode }
        guard let claude = Self.claudePath else { throw StartError.missingClaude }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [dir.appendingPathComponent("sidecar.mjs").path]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.environment = Self.environment()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async { self?.ingest(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(4000))
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                self.flush()
                self.onExit?(proc.terminationStatus, self.stderrTail)
            }
        }
        do { try p.run() } catch { throw StartError.launch(error) }
        process = p
        input = stdin.fileHandleForWriting

        var start: [String: Any] = ["type": "start", "cwd": cwd, "claudePath": claude]
        if let resume { start["resume"] = resume }
        if let permissionMode { start["permissionMode"] = permissionMode }
        if let model { start["model"] = model }
        if let effort { start["effort"] = effort }
        send(start)
    }

    /// Writes one message. Silently dropped once the sidecar has gone.
    func send(_ message: [String: Any]) {
        guard let input, isRunning,
              var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    /// Closes stdin (the sidecar denies anything pending and exits), then
    /// terminates it if it is still there a moment later.
    func stop() {
        try? input?.close()
        input = nil
        let p = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if p?.isRunning == true { p?.terminate() } }
    }

    // MARK: - Output

    private func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let s = String(data: line, encoding: .utf8), !s.isEmpty { pending.append(s) }
        }
        guard !pending.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flush() }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let lines = pending
        pending.removeAll()
        onLines?(lines)
    }

    /// The app's environment with the usual tool locations on PATH, minus the
    /// markers of an enclosing Claude Code session (FloatyTerm may have been
    /// launched from one) so the new session starts clean.
    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") { env.removeValue(forKey: key) }
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let current = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (current + extra.filter { !current.contains($0) }).joined(separator: ":")
        return env
    }
}
