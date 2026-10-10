import AppKit

/// The user's approval policy for agent actions — opt-in, off by default.
///
/// floaty drives the user's LIVE session (signed-in browser, real apps), so a
/// page or a prompt injection that steers the agent can do real harm through
/// an ordinary click or keystroke. The browser/computer toolsets answer this
/// with a `confirm` callback and a URL policy; this is the same idea, owned by
/// the user: a file the host reads, never a flag the agent passes.
///
///   ~/Library/Application Support/FloatyTerm/agent-policy.json
///   {
///     "ask": ["eval", "navigate", "type", "key", "dialog"],   // or ["*"] = every action
///     "allow_hosts": ["localhost", "127.0.0.1", "*.example.com"],
///     "timeout_seconds": 60
///   }
///
/// `ask`: before a listed verb runs, a prompt asks the user (Deny / Allow once /
/// Allow for this session). It is a non-activating panel: it never takes the
/// user's focus. No answer in time = Deny. `allow_hosts`: `navigate` to any
/// other host is refused without asking. No file = no gate. A file that
/// doesn't parse fails CLOSED: every action asks.
final class AgentPolicy {
    static let shared = AgentPolicy()

    static var fileURL: URL {
        // FLOATY_POLICY_FILE is read from THIS process's environment (the host,
        // or a test harness) — an agent's shell can't reach it.
        if let path = ProcessInfo.processInfo.environment["FLOATY_POLICY_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloatyTerm/agent-policy.json")
    }

    struct Policy {
        var ask: Set<String> = []
        var askAll = false
        var allowHosts: [String]? = nil
        var timeout: TimeInterval = 60
        var parseError: String? = nil
    }

    /// Verbs that only read. They never ask, even under "*".
    static let readOnly: Set<String> = [
        "capture", "list-windows", "query-dom", "som", "read-text", "focused", "tabs", "sessions",
        "peek", "host", "mark", "find",
    ]

    private let lock = NSLock()
    private var cached: (mtime: Date, policy: Policy)?
    /// "Allow for this session" grants, until FloatyTerm quits.
    private var granted: Set<String> = []

    /// The policy now, re-read when the file changes. nil = no file, no gate.
    func current() -> Policy? {
        let url = Self.fileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else {
            lock.lock(); cached = nil; lock.unlock()
            return nil
        }
        lock.lock()
        if let c = cached, c.mtime == mtime { lock.unlock(); return c.policy }
        lock.unlock()
        var p = Policy()
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ask = (obj["ask"] as? [Any])?.compactMap { $0 as? String } ?? []
            p.askAll = ask.contains("*")
            p.ask = Set(ask.filter { $0 != "*" })
            p.allowHosts = (obj["allow_hosts"] as? [Any])?.compactMap { ($0 as? String)?.lowercased() }
            if let t = (obj["timeout_seconds"] as? NSNumber)?.doubleValue { p.timeout = min(max(t, 5), 600) }
        } else {
            p.askAll = true
            p.parseError = "agent-policy.json does not parse as a JSON object — every action asks until it is fixed"
        }
        lock.lock(); cached = (mtime, p); lock.unlock()
        return p
    }

    /// For `floaty host --policy`: what the agent may plan around.
    func describe() -> [String: Any] {
        guard let p = current() else { return ["policy": NSNull(), "path": Self.fileURL.path] }
        var d: [String: Any] = ["path": Self.fileURL.path, "ask": p.askAll ? ["*"] : p.ask.sorted(),
                                "timeout_seconds": Int(p.timeout)]
        if let h = p.allowHosts { d["allow_hosts"] = h }
        if let e = p.parseError { d["error"] = e }
        lock.lock(); d["granted_this_session"] = granted.sorted(); lock.unlock()
        return ["policy": d]
    }

    // MARK: - The gate

    /// Called by the relay before a route runs, on its connection thread.
    /// nil = go ahead; a dict = the reply to send instead. Blocks while the
    /// user decides (the relay's connections each have their own queue).
    func gate(route: String, args: [String: Any]) -> [String: Any]? {
        guard let p = current() else { return nil }
        // navigate: the host list first — refused outright, no prompt.
        if route == "navigate", let allow = p.allowHosts, let raw = args["url"] as? String {
            let host = Self.host(of: raw)
            if !Self.hostAllowed(host, allow) {
                return ["error": "navigate refused by the user's policy: \(host.isEmpty ? raw : host) is not in "
                    + "allow_hosts (\(Self.fileURL.path)). Do not try another way to reach it; ask the user.",
                        "denied_by_policy": true]
            }
        }
        guard needsAsk(route, args, p) else { return nil }
        let key = grantKey(route, args)
        lock.lock()
        let already = granted.contains(key)
        lock.unlock()
        if already { return nil }

        let summary = Self.summary(route, args)
        var decision: ApprovalPanel.Decision = .deny
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            Task { @MainActor in
                decision = await ApprovalPanel.queue.ask(verb: route, detail: summary, timeout: p.timeout)
                sem.signal()
            }
        }
        sem.wait()
        switch decision {
        case .allowOnce:
            return nil
        case .allowSession:
            lock.lock(); granted.insert(key); lock.unlock()
            return nil
        case .deny:
            return ["error": "The user did not grant permission to run '\(route)'. Do not retry it unless the user "
                + "asks you to.", "denied_by_user": true]
        case .timeout:
            return ["error": "No answer to the permission prompt for '\(route)' within \(Int(p.timeout)) s — treated "
                + "as a refusal. Do not retry it unless the user asks you to.", "denied_by_user": true]
        }
    }

    func needsAsk(_ route: String, _ args: [String: Any], _ p: Policy) -> Bool {
        if Self.readOnly.contains(route) { return false }
        // Verbs that are read-only unless they act.
        switch route {
        case "query-ax":
            guard ["press", "focus", "set_value", "scroll_to", "action"].contains(where: { args[$0] != nil }) else { return false }
        case "dialog":
            guard args["accept"] != nil || args["dismiss"] != nil || args["reload"] != nil else { return false }
        case "net":
            if let a = args["action"] as? String, ["status", "export"].contains(a) { return false }
        default: break
        }
        if p.askAll || p.ask.contains(route) { return true }
        // A plan or a script must not be a way around a listed verb: ask when
        // any step does what the user listed.
        switch route {
        case "run":
            let verbs = Self.steps(args).compactMap { ($0["do"] as? [String: Any])?["verb"] as? String }
            return verbs.contains { p.ask.contains($0 == "press" ? "query-ax" : $0) }
        case "input":
            let page: [String: String] = ["click": "click", "down": "click", "drag": "drag", "wheel": "scroll",
                                          "key": "key", "keydown": "key", "type": "type", "text": "type", "fill": "type"]
            return Self.steps(args).contains { step in step.keys.contains { k in page[k].map(p.ask.contains) ?? false } }
        default:
            return false
        }
    }

    private static func steps(_ args: [String: Any]) -> [[String: Any]] {
        if let a = args["steps"] as? [[String: Any]] { return a }
        if let s = args["steps"] as? String, let d = s.data(using: .utf8),
           let a = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] { return a }
        return []
    }

    /// A session grant covers the verb — and, for navigate, the host.
    private func grantKey(_ route: String, _ args: [String: Any]) -> String {
        if route == "navigate", let u = args["url"] as? String { return "navigate:" + Self.host(of: u) }
        return route
    }

    static func host(of raw: String) -> String {
        let withScheme = raw.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) != nil
            ? raw : "http://" + raw
        return URL(string: withScheme)?.host?.lowercased() ?? ""
    }

    static func hostAllowed(_ host: String, _ allow: [String]) -> Bool {
        guard !host.isEmpty else { return false }
        return allow.contains { pattern in
            if pattern.hasPrefix("*.") {
                let base = String(pattern.dropFirst(2))
                return host == base || host.hasSuffix("." + base)
            }
            return host == pattern
        }
    }

    /// What the prompt shows. Everything outside printable ASCII is escaped:
    /// arguments can carry text that came from a page.
    static func summary(_ route: String, _ b: [String: Any]) -> String {
        var parts: [String] = []
        if let pid = (b["pid"] as? NSNumber).map({ pid_t($0.intValue) }) {
            parts.append("app: " + (NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"))
        } else if let t = (b["target"] as? String) ?? (b["app"] as? String) {
            parts.append("app: " + t)
        }
        if let m = b["match"] as? String { parts.append("tab: " + m) }
        if (b["via_extension"] as? NSNumber)?.boolValue == true { parts.append("your live Chrome") }
        for k in ["url", "key", "text", "expression", "set_value", "steps", "ref", "title", "action"] {
            if let v = b[k] { parts.append("\(k): " + String("\(v)".prefix(160))) }
        }
        if let x = b["x"], let y = b["y"] { parts.append("at \(x),\(y)") }
        if AgentBackground.isBackground(b) { parts.append("background mode") }
        return parts.map(escape).joined(separator: "\n")
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            if u == "\n" { out += " " }
            else if (0x20...0x7E).contains(u.value) { out.unicodeScalars.append(u) }
            else { out += String(format: "\\u{%X}", u.value) }
        }
        return out
    }
}

/// The prompt: a small non-activating panel at the top of the screen with the
/// pointer. Its buttons take the first click, so answering never makes
/// FloatyTerm the active app or moves the user's keyboard focus. One prompt at
/// a time; the rest wait their turn.
@MainActor
final class ApprovalPanel {
    enum Decision { case allowOnce, allowSession, deny, timeout }

    static let queue = ApprovalPanel()
    private var tail: Task<Void, Never>?

    func ask(verb: String, detail: String, timeout: TimeInterval) async -> Decision {
        let previous = tail
        let mine = Task { @MainActor () -> Decision in
            await previous?.value
            return await Self.show(verb: verb, detail: detail, timeout: timeout)
        }
        tail = Task { _ = await mine.value }
        return await mine.value
    }

    private static func show(verb: String, detail: String, timeout: TimeInterval) async -> Decision {
        await withCheckedContinuation { cont in
            let view = PromptView(verb: verb, detail: detail, timeout: timeout)
            let panel = PromptPanel(contentRect: NSRect(origin: .zero, size: view.frame.size),
                                    styleMask: [.nonactivatingPanel, .borderless],
                                    backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.contentView = view
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let f = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: f.midX - view.frame.width / 2, y: f.maxY - view.frame.height - 12))
            }
            var done = false
            func finish(_ d: Decision) {
                guard !done else { return }
                done = true
                panel.orderOut(nil)
                cont.resume(returning: d)
            }
            view.onDecide = { finish($0) }
            panel.orderFrontRegardless()
            NSSound(named: "Tink")?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(.timeout) }
        }
    }
}

private final class PromptPanel: NSPanel {
    override var canBecomeKey: Bool { false }      // never take the user's keyboard
}

/// Buttons that act on the first click, in a window that isn't key.
private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class PromptView: NSView {
    var onDecide: ((ApprovalPanel.Decision) -> Void)?

    init(verb: String, detail: String, timeout: TimeInterval) {
        let width: CGFloat = 440
        let title = NSTextField(labelWithString: "An agent wants to run “\(verb)”")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: detail.isEmpty ? "(no details)" : detail)
        body.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = width - 32
        body.maximumNumberOfLines = 8
        let hint = NSTextField(labelWithString: "No answer in \(Int(timeout)) s = Deny · from your agent-policy.json")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        let bodyHeight = min(body.fittingSize.height, 130)
        let height: CGFloat = 16 + 18 + 8 + bodyHeight + 10 + 14 + 12 + 28 + 14
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderColor = NSColor.systemOrange.cgColor
        layer?.borderWidth = 1.5

        var y = height - 16 - 18
        title.frame = NSRect(x: 16, y: y, width: width - 32, height: 18); addSubview(title)
        y -= 8 + bodyHeight
        body.frame = NSRect(x: 16, y: y, width: width - 32, height: bodyHeight); addSubview(body)
        y -= 10 + 14
        hint.frame = NSRect(x: 16, y: y, width: width - 32, height: 14); addSubview(hint)

        let buttons: [(String, ApprovalPanel.Decision)] = [
            ("Deny", .deny), ("Allow once", .allowOnce), ("Allow for this session", .allowSession),
        ]
        var x = width - 16
        for (label, decision) in buttons.reversed() {
            let b = FirstClickButton(title: label, target: nil, action: nil)
            b.bezelStyle = .rounded
            b.sizeToFit()
            x -= b.frame.width
            b.frame.origin = NSPoint(x: x, y: 14)
            x -= 8
            b.target = self
            b.action = #selector(pressed(_:))
            b.tag = decision == .deny ? 0 : decision == .allowOnce ? 1 : 2
            addSubview(b)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pressed(_ sender: NSButton) {
        onDecide?(sender.tag == 0 ? .deny : sender.tag == 1 ? .allowOnce : .allowSession)
    }
}
