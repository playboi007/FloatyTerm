import Foundation

/// Hosts the dependency-free Node bridge to Codex app-server.
final class CodexSidecar: AgentSidecar {
    enum StartError: Error, CustomStringConvertible {
        case missingSidecar, missingNode, missingCodex, launch(Error)
        var description: String {
            switch self {
            case .missingSidecar: "The Codex sidecar is missing. Rebuild with ./build.sh."
            case .missingNode: "Node.js was not found. Install it to use the Codex tab."
            case .missingCodex: "The codex command was not found. Install Codex CLI to use the Codex tab."
            case .launch(let error): "The Codex sidecar did not start: \(error.localizedDescription)"
            }
        }
    }

    var onLines: (([String]) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var pending: [String] = []
    private var flushScheduled = false
    private var stderrTail = ""
    var isRunning: Bool { process?.isRunning ?? false }

    private static var directory: URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("CodexSidecar")
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/CodexSidecar")
        return [bundled, dev].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("sidecar.mjs").path)
        }
    }

    func start(cwd: String, resume: String? = nil, fork: Bool = false,
               permissionMode: String? = nil, model: String? = nil,
               effort: String? = nil, thinking: Bool? = nil) throws {
        guard let dir = Self.directory else { throw StartError.missingSidecar }
        guard let node = ClaudeSidecar.nodePath else { throw StartError.missingNode }
        guard let codex = ClaudeSidecar.locate("codex") else { throw StartError.missingCodex }
        let p = Process()
        buffer.removeAll()
        pending.removeAll()
        stderrTail = ""
        flushScheduled = false
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [dir.appendingPathComponent("sidecar.mjs").path]
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin", "/usr/bin", "/bin"]
        let current = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (current + extra.filter { !current.contains($0) }).joined(separator: ":")
        p.environment = env
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.ingest(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.process === p else { return }
                self.stderrTail = String((self.stderrTail + text).suffix(4000))
            }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                guard let self, self.process === proc else { return }
                self.flush()
                self.onExit?(proc.terminationStatus, self.stderrTail)
            }
        }
        do { try p.run() } catch { throw StartError.launch(error) }
        process = p
        input = stdin.fileHandleForWriting
        var start: [String: Any] = ["type": "start", "cwd": cwd, "codexPath": codex, "hostTools": true, "nativeAudio": true]
        if let resume { start["resume"] = resume }
        if fork { start["fork"] = true }
        if let model { start["model"] = model }
        if let effort { start["effort"] = effort }
        if let permissionMode { start["permissionMode"] = permissionMode }
        if let thinking { start["thinking"] = thinking }
        send(start)
    }

    func send(_ message: [String: Any]) {
        guard let input, isRunning,
              var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? input.write(contentsOf: data)
    }

    func stop() {
        send(["type": "interrupt"])
        try? input?.close()
        input = nil
        let p = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if p?.isRunning == true { p?.terminate() }
        }
    }

    private func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let string = String(data: line, encoding: .utf8), !string.isEmpty { pending.append(string) }
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
}
