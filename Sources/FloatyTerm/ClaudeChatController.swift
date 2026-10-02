import AppKit
import WebKit

/// A tab that runs an agent without its TUI: replies render as skimmable
/// Markdown, tool calls as a live timeline, and approvals as cards (the
/// "Markdown, made skimmable" design, `Resources/SkimRender/chat.js`).
///
/// `ChatAgent` selects the existing Claude SDK driver or the Codex exec driver.
/// Both use the user's installed CLI. Native events are normalized before the
/// shared page renders them; page actions return over the `skim` bridge.
///
/// "Open in TUI" hands the session to a terminal tab running `claude --resume`,
/// and this tab stops its sidecar — two processes must not append to one
/// session file. Sending a message here afterwards resumes it and takes it back.
///
/// Side chats are forks of the main session (`forkSession`), each in its own
/// sidecar and session file, so they run next to main without touching it.
final class ClaudeChatController: NSObject, TabContent, WKNavigationDelegate {

    let cwd: String
    let agent: ChatAgent
    private let container = NSView()
    private let webView: WKWebView

    /// One conversation and its sidecar: "main", or a side chat ("side-1", …)
    /// forked from main. Each has its own session file, so they can run at once.
    private final class Channel {
        let id: String
        var sidecar: any AgentSidecar
        var sessionID: String?
        /// A side chat's source: the main session it forks on its first start.
        var forkOf: String?
        /// The user's choices, kept so a restarted sidecar keeps them.
        var permissionMode: String?
        var model: String?
        var effort: String?
        /// Thinking summaries on/off, once the user has chosen here; nil follows the settings.
        var thinking: Bool?
        var handedOff = false
        init(id: String, agent: ChatAgent) { self.id = id; sidecar = agent.runner() }
    }
    private var channels: [String: Channel] = [:]
    private let main: Channel

    private var pageReady = false
    private var queued: [(channel: String, line: String)] = []

    /// Live state, reported by the page for all conversations; drives the tab's attention dot.
    private(set) var isBusy = false
    private(set) var awaitingApproval = false

    /// Opens `claude --resume <sessionID>` in a terminal tab in `cwd`.
    var onOpenTUI: ((_ cwd: String, _ sessionID: String) -> Void)?

    init(cwd: String, agent: ChatAgent = .claude) {
        self.cwd = cwd
        self.agent = agent
        main = Channel(id: "main", agent: agent)
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        channels[main.id] = main
        SkimAssets.install(in: config, chat: true) { [weak self] action in self?.handle(action) }
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        webView.loadHTMLString(SkimAssets.chatDocument(cwd: cwd, agent: agent.rawValue), baseURL: URL(fileURLWithPath: cwd, isDirectory: true))
        start(main, resume: nil)
    }

    static var isAvailable: Bool { SkimAssets.isChatAvailable }

    // MARK: - Sidecars

    private func start(_ ch: Channel, resume: String?, fork: Bool = false) {
        let s = agent.runner()
        s.onLines = { [weak self, weak s, weak ch] lines in
            guard let self, let s, let ch, s === ch.sidecar else { return }
            self.receive(lines, on: ch)
        }
        s.onExit = { [weak self, weak s, weak ch] status, stderr in
            guard let self, let s, let ch, s === ch.sidecar, !ch.handedOff else { return }
            let detail = stderr.split(separator: "\n").suffix(3).joined(separator: " · ")
            self.hostNotice(ch.id, status == 0 ? "info" : "error",
                            status == 0 ? "Session ended." : "The \(self.agent.rawValue.capitalized) session stopped (exit \(status)). \(detail)")
        }
        ch.sidecar = s
        do {
            try s.start(cwd: cwd, resume: resume, fork: fork, permissionMode: ch.permissionMode, model: ch.model, effort: ch.effort, thinking: ch.thinking)
        } catch { hostNotice(ch.id, "error", String(describing: error)) }
    }

    private func receive(_ lines: [String], on ch: Channel) {
        // Every turn starts with an init; /clear changes its session ID, and a
        // fork's first init carries the new session's ID.
        for line in lines {
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if obj["type"] as? String == "session", let sessionID = obj["sessionId"] as? String {
                    ch.sessionID = sessionID
                } else if let msg = obj["msg"] as? [String: Any], msg["subtype"] as? String == "init" {
                    ch.sessionID = msg["session_id"] as? String
                } else if let event = obj["event"] as? [String: Any], event["type"] as? String == "thread.started" {
                    ch.sessionID = event["thread_id"] as? String
                }
            }
        }
        if !isCurrentlyViewed, lines.contains(where: { $0.contains("\"type\":\"result\"") || $0.contains("turn.completed") || $0.contains("turn.end") }) {
            hasUnseenOutput = true
            onTitleChanged?()
        }
        deliver(lines, to: ch.id)
    }

    /// Hands lines to the page, in order, once it has booted.
    private func deliver(_ lines: [String], to channel: String) {
        guard pageReady else { queued.append(contentsOf: lines.map { (channel, $0) }); return }
        // Each line is one JSON object, so the joined list is a JS array literal.
        webView.evaluateJavaScript("AgentChat.receive([\(lines.joined(separator: ","))], \"\(channel)\")", completionHandler: nil)
    }

    private func hostNotice(_ channel: String, _ kind: String, _ message: String) {
        let obj: [String: Any] = ["type": "host", "kind": kind, "message": message]
        if let data = try? JSONSerialization.data(withJSONObject: obj), let line = String(data: data, encoding: .utf8) {
            deliver([line], to: channel)
        }
    }

    // MARK: - Page actions

    private func handle(_ action: [String: Any]) {
        guard let type = action["type"] as? String else { return }
        let id = action["channel"] as? String ?? main.id
        // Channel IDs come from the page; they go back into a JS string, so keep them plain.
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return }
        if type == "openSide" { openSide(id, action); return }
        guard let ch = channels[id] else { return }
        switch type {
        case "send":
            guard let text = action["text"] as? String else { return }
            if ch.handedOff || !ch.sidecar.isRunning {
                // Take the session back from the TUI (or restart a dead one).
                ch.handedOff = false
                if let sid = ch.sessionID { start(ch, resume: sid) }
                else { start(ch, resume: ch.forkOf, fork: ch.forkOf != nil) }
            }
            ch.sidecar.send(["type": "user", "text": text])
        case "permission":
            var m: [String: Any] = ["type": "permission"]
            for key in ["id", "decision", "message", "response"] { if let v = action[key] { m[key] = v } }
            ch.sidecar.send(m)
        case "surfaceAction":
            guard agent == .codex else { return }
            var m: [String: Any] = ["type": "surfaceAction"]
            for key in ["action", "id", "text"] { if let v = action[key] { m[key] = v } }
            ch.sidecar.send(m)
        case "interrupt":
            ch.sidecar.send(["type": "interrupt"])
        case "setPermissionMode":
            ch.permissionMode = action["mode"] as? String
            ch.sidecar.send(["type": "setPermissionMode", "mode": ch.permissionMode ?? "default"])
        case "setModel":
            ch.model = action["model"] as? String
            ch.sidecar.send(["type": "setModel", "model": ch.model ?? ""])
        case "setEffort":
            ch.effort = action["effort"] as? String
            ch.sidecar.send(["type": "setEffort", "effort": ch.effort ?? ""])
        case "usage":
            ch.sidecar.send(["type": "usage", "plan": action["plan"] as? Bool ?? false])
        case "setThinking":
            let on = action["on"] as? Bool ?? false
            ch.thinking = on
            ch.sidecar.send(["type": "setThinking", "on": on])
        case "git", "sessions":
            // Any running sidecar can read git and the session list of the shared folder.
            (ch.sidecar.isRunning ? ch : channels.values.first { $0.sidecar.isRunning } ?? ch).sidecar.send(["type": type])
        case "resume":
            // /resume: main continues another conversation of this folder. Its own
            // sidecar restarts on that session; the page draws the history it sends.
            guard ch === main, let sid = action["sessionId"] as? String, !sid.isEmpty,
                  sid.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return }
            main.sidecar.onExit = nil
            main.sidecar.stop()
            main.handedOff = false
            main.sessionID = sid
            main.forkOf = nil
            start(main, resume: sid)
            main.sidecar.send(["type": "history", "sessionId": sid])
        case "newConversation", "compact":
            guard agent == .codex else { return }
            ch.sidecar.send(["type": type])
        case "closeSide":
            guard ch !== main else { return }
            ch.sidecar.onExit = nil
            ch.sidecar.stop()
            channels[id] = nil
        case "copy":
            guard let text = action["text"] as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case "reveal":
            let path = (action["path"] as? String).map { ($0 as NSString).expandingTildeInPath } ?? cwd
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case "openTUI":
            guard let sid = ch.sessionID else { hostNotice(id, "info", "The session has no ID yet. Send a message first."); return }
            if action["busy"] as? Bool ?? isBusy { hostNotice(id, "info", "The agent is still working. Wait for it to finish, or stop it (Esc), then open the TUI."); return }
            ch.handedOff = true
            ch.sidecar.stop()
            hostNotice(id, "info", "This session now continues in the TUI tab. Send a message here to take it back.")
            onOpenTUI?(cwd, sid)
        case "close":
            // /exit or /quit: close the tab, as they end the TUI.
            onTerminated?()
        case "state":
            isBusy = action["busy"] as? Bool ?? false
            awaitingApproval = action["waiting"] as? Bool ?? false
            onTitleChanged?()
        default:
            break
        }
    }

    /// A side chat: a fork of the main session as it is now, with main's model
    /// and effort (so it reads main's prompt cache) and manual approvals.
    private func openSide(_ id: String, _ action: [String: Any]) {
        guard id != main.id, channels[id] == nil else { return }
        guard let source = main.sessionID else {
            hostNotice(id, "error", "The main conversation has no session yet. Send it a message first; a side chat forks it.")
            return
        }
        let ch = Channel(id: id, agent: agent)
        ch.forkOf = source
        ch.model = action["model"] as? String ?? main.model
        ch.effort = action["effort"] as? String ?? main.effort
        ch.thinking = action["thinking"] as? Bool ?? main.thinking
        ch.permissionMode = "default"
        channels[id] = ch
        start(ch, resume: source, fork: true)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        let lines = queued
        queued.removeAll()
        for (channel, line) in lines { deliver([line], to: channel) }
        if let panel = container.window { focus(in: panel) }
    }

    /// The page is the whole tab: a clicked link opens outside it instead of
    /// replacing the conversation.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        // Only the page's own first load may navigate this view.
        decisionHandler(pageReady ? .cancel : .allow)
    }

    // MARK: - TabContent

    var view: NSView { container }
    var title: String { agent.rawValue.capitalized + " · " + (cwd as NSString).lastPathComponent }
    var customName: String?
    var displayName: String { customName ?? title }

    var hasUnseenOutput = false
    var isCurrentlyViewed: Bool = false {
        didSet { if isCurrentlyViewed { hasUnseenOutput = false } }
    }

    var onTitleChanged: (() -> Void)?
    var onTerminated: (() -> Void)?

    var restorableRecord: TabRecord? { nil }

    func focus(in panel: NSWindow) {
        panel.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.AgentChat && AgentChat.focus()", completionHandler: nil)
    }

    func cleanup() {
        for ch in channels.values {
            ch.sidecar.onExit = nil
            ch.sidecar.stop()
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        SkimAssets.uninstall(from: webView.configuration)
    }
}
