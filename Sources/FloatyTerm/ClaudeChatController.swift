import AppKit
import WebKit

/// A tab that runs Claude Code without its TUI: replies render as skimmable
/// Markdown, tool calls as a live timeline, and approvals as cards (the
/// "Markdown, made skimmable" design, `Resources/SkimRender/chat.js`).
///
/// The session runs in a `ClaudeSidecar` (Node + the Claude Agent SDK) that
/// drives the user's own `claude`, so it has the TUI's login, settings, CLAUDE.md
/// files, skills and hooks. The page and the sidecar never talk directly:
/// sidecar lines go to `ClaudeChat.receive`, page actions come back over the
/// `skim` bridge.
///
/// "Open in TUI" hands the session to a terminal tab running `claude --resume`,
/// and this tab stops its sidecar — two processes must not append to one
/// session file. Sending a message here afterwards resumes it and takes it back.
final class ClaudeChatController: NSObject, TabContent, WKNavigationDelegate {

    let cwd: String
    private let container = NSView()
    private let webView: WKWebView
    private var sidecar = ClaudeSidecar()

    private var pageReady = false
    private var queued: [String] = []
    private(set) var sessionID: String?
    /// The user's choices in this tab, kept so a restarted sidecar keeps them.
    private var permissionMode: String?
    private var model: String?
    private var effort: String?
    private var handedOff = false

    /// Live state, reported by the page; drives the tab's attention dot.
    private(set) var isBusy = false
    private(set) var awaitingApproval = false

    /// Opens `claude --resume <sessionID>` in a terminal tab in `cwd`.
    var onOpenTUI: ((_ cwd: String, _ sessionID: String) -> Void)?

    init(cwd: String) {
        self.cwd = cwd
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
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
        webView.loadHTMLString(SkimAssets.chatDocument(cwd: cwd), baseURL: URL(fileURLWithPath: cwd, isDirectory: true))
        startSidecar(resume: nil)
    }

    static var isAvailable: Bool { SkimAssets.isAvailable }

    // MARK: - Sidecar

    private func startSidecar(resume: String?) {
        let s = ClaudeSidecar()
        s.onLines = { [weak self] lines in self?.receive(lines) }
        s.onExit = { [weak self, weak s] status, stderr in
            guard let self, let s, s === self.sidecar, !self.handedOff else { return }
            let detail = stderr.split(separator: "\n").suffix(3).joined(separator: " · ")
            self.hostNotice(status == 0 ? "info" : "error",
                            status == 0 ? "Session ended." : "The Claude session stopped (exit \(status)). \(detail)")
        }
        sidecar = s
        do { try s.start(cwd: cwd, resume: resume, permissionMode: permissionMode, model: model, effort: effort) }
        catch { hostNotice("error", String(describing: error)) }
    }

    private func receive(_ lines: [String]) {
        // Every turn starts with an init; /clear changes its session ID.
        for line in lines where line.contains("\"init\"") {
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let msg = obj["msg"] as? [String: Any], msg["subtype"] as? String == "init" {
                sessionID = msg["session_id"] as? String
            }
        }
        if !isCurrentlyViewed, lines.contains(where: { $0.contains("\"type\":\"result\"") }) {
            hasUnseenOutput = true
            onTitleChanged?()
        }
        deliver(lines)
    }

    /// Hands lines to the page, in order, once it has booted.
    private func deliver(_ lines: [String]) {
        guard pageReady else { queued.append(contentsOf: lines); return }
        // Each line is one JSON object, so the joined list is a JS array literal.
        webView.evaluateJavaScript("ClaudeChat.receive([\(lines.joined(separator: ","))])", completionHandler: nil)
    }

    private func hostNotice(_ kind: String, _ message: String) {
        let obj: [String: Any] = ["type": "host", "kind": kind, "message": message]
        if let data = try? JSONSerialization.data(withJSONObject: obj), let line = String(data: data, encoding: .utf8) {
            deliver([line])
        }
    }

    // MARK: - Page actions

    private func handle(_ action: [String: Any]) {
        guard let type = action["type"] as? String else { return }
        switch type {
        case "send":
            guard let text = action["text"] as? String else { return }
            if handedOff || !sidecar.isRunning {
                // Take the session back from the TUI (or restart a dead one).
                handedOff = false
                startSidecar(resume: sessionID)
            }
            sidecar.send(["type": "user", "text": text])
        case "permission":
            var m: [String: Any] = ["type": "permission"]
            for key in ["id", "decision", "message"] { if let v = action[key] { m[key] = v } }
            sidecar.send(m)
        case "interrupt":
            sidecar.send(["type": "interrupt"])
        case "setPermissionMode":
            permissionMode = action["mode"] as? String
            sidecar.send(["type": "setPermissionMode", "mode": permissionMode ?? "default"])
        case "setModel":
            model = action["model"] as? String
            sidecar.send(["type": "setModel", "model": model ?? ""])
        case "setEffort":
            effort = action["effort"] as? String
            sidecar.send(["type": "setEffort", "effort": effort ?? ""])
        case "usage":
            sidecar.send(["type": "usage", "plan": action["plan"] as? Bool ?? false])
        case "openTUI":
            guard let sessionID else { hostNotice("info", "The session has no ID yet. Send a message first."); return }
            if isBusy { hostNotice("info", "Claude is still working. Wait for it to finish, or stop it (Esc), then open the TUI."); return }
            handedOff = true
            sidecar.stop()
            hostNotice("info", "This session now continues in the TUI tab. Send a message here to take it back.")
            onOpenTUI?(cwd, sessionID)
        case "state":
            isBusy = action["busy"] as? Bool ?? false
            awaitingApproval = action["waiting"] as? Bool ?? false
            onTitleChanged?()
        default:
            break
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        let lines = queued
        queued.removeAll()
        if !lines.isEmpty { deliver(lines) }
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
    var title: String { "Claude · " + (cwd as NSString).lastPathComponent }
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
        webView.evaluateJavaScript("window.ClaudeChat && ClaudeChat.focus()", completionHandler: nil)
    }

    func cleanup() {
        sidecar.onExit = nil
        sidecar.stop()
        webView.stopLoading()
        webView.navigationDelegate = nil
        SkimAssets.uninstall(from: webView.configuration)
    }
}
