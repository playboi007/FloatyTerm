import AppKit
import WebKit

/// A tab that runs an agent (Claude or Codex) without its TUI, on the shared SkimRender page.
/// Side chats fork main; "Open in TUI" hands the session over, and a message here takes it back.
final class ClaudeChatController: NSObject, TabContent, WKNavigationDelegate {

    let cwd: String
    let agent: ChatAgent
    private let container = NSView()
    private let webView: DropWebView
    private var appearanceToken: NSObjectProtocol?

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
    /// The mic button: one dictation for the tab, made on first use.
    private var realtime: (channel: Channel, audio: CodexRealtimeAudio)?
    private var dictation: Dictation?
    private var queued: [(channel: String, line: String)] = []

    /// Live state, reported by the page for all conversations; drives the tab's attention dot.
    private(set) var isBusy = false
    private(set) var awaitingApproval = false

    /// Opens `claude --resume <sessionID>` in a terminal tab in `cwd`.
    var onOpenHostFile: ((URL) -> Bool)?

    var onOpenTUI: ((_ cwd: String, _ sessionID: String) -> Void)?

    init(cwd: String, agent: ChatAgent = .claude) {
        self.cwd = cwd
        self.agent = agent
        main = Channel(id: "main", agent: agent)
        let config = WKWebViewConfiguration()
        webView = DropWebView(frame: .zero, configuration: config)
        super.init()
        webView.onDropFiles = { [weak self] urls in self?.dropFiles(urls) }
        channels[main.id] = main
        SkimAssets.install(in: config, chat: true) { [weak self] action in self?.handle(action) }
        webView.navigationDelegate = self
        appearanceToken = SkimAssets.followAppearance(webView)
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

    private func start(_ ch: Channel, resume: String?, fork: Bool = false, extras: [String: Any] = [:]) {
        if realtime?.channel === ch { stopRealtime() }
        let s = agent.runner()
        (s as? ClaudeSidecar)?.startExtras = extras
        s.onLines = { [weak self, weak s, weak ch] lines in
            guard let self, let s, let ch, s === ch.sidecar else { return }
            self.receive(lines, on: ch)
        }
        s.onExit = { [weak self, weak s, weak ch] status, stderr in
            guard let self, let s, let ch, s === ch.sidecar, !ch.handedOff else { return }
            if self.realtime?.channel === ch { self.stopRealtime(send: false) }
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
        // Every turn starts with init; /clear or fork init changes session ID.
        var pageLines: [String] = []
        for line in lines {
            if let data = line.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if agent == .codex, obj["type"] as? String == "native.realtime" {
                    if let voice = realtime, voice.channel === ch, obj["requestId"] as? String == voice.audio.requestID {
                        switch obj["state"] as? String {
                        case "active": voice.audio.setSending(true)
                        case "clearPlayback": voice.audio.clearPlayback()
                        case "audio": if let audio = obj["audio"] as? [String: Any] { voice.audio.play(audio) }
                        case "closed", "error": stopRealtime(send: false)
                        default: break
                        }
                    }
                    continue
                }
                if agent == .codex, obj["type"] as? String == "native.account.login" {
                    if let address = obj["url"] as? String, let url = URL(string: address), url.scheme == "https",
                       ["auth.openai.com", "auth0.openai.com"].contains(url.host ?? ""), url.user == nil, url.password == nil {
                        if !NSWorkspace.shared.open(url) { hostNotice(ch.id, "error", "The sign-in browser could not open."); ch.sidecar.send(["type": "surfaceAction", "action": "accountLoginCancel"]) }
                    }
                    continue
                }
                if agent == .codex, obj["type"] as? String == "host.tool.request" {
                    handleHostTool(obj, on: ch)
                    continue
                }
                if obj["type"] as? String == "session", let sessionID = obj["sessionId"] as? String {
                    ch.sessionID = sessionID
                } else if let msg = obj["msg"] as? [String: Any], msg["subtype"] as? String == "init" {
                    ch.sessionID = msg["session_id"] as? String
                } else if let event = obj["event"] as? [String: Any], event["type"] as? String == "thread.started" {
                    ch.sessionID = event["thread_id"] as? String
                }
            }
            pageLines.append(line)
        }
        if !isCurrentlyViewed, pageLines.contains(where: { $0.contains("\"type\":\"result\"") || $0.contains("turn.completed") || $0.contains("turn.end") }) {
            hasUnseenOutput = true
            onTitleChanged?()
        }
        if !pageLines.isEmpty { deliver(pageLines, to: ch.id) }
    }

    private func handleHostTool(_ request: [String: Any], on ch: Channel) {
        guard let requestID = request["requestId"] as? String, UUID(uuidString: requestID) != nil else { return }
        var success = false
        var text: String
        do {
            guard let threadID = request["rootThreadId"] as? String, threadID == ch.sessionID,
                  let expiresAt = request["expiresAt"] as? Double, expiresAt > Date().timeIntervalSince1970 * 1000,
                  let tool = request["tool"] as? String,
                  let arguments = request["arguments"] as? [String: Any] else { throw CodexHostTools.ToolError.invalidArguments }
            let context: [String: Any] = ["application": "FloatyTerm", "agent": agent.rawValue, "cwd": cwd,
                "channel": ch.id, "sessionId": request["threadId"] ?? (ch.sessionID as Any? ?? NSNull()),
                "model": request["model"] ?? (ch.model as Any? ?? NSNull()), "permissionMode": request["permissionMode"] ?? ch.permissionMode ?? "default",
                "viewed": isCurrentlyViewed]
            let result = try CodexHostTools.execute(tool: tool, arguments: arguments, cwd: cwd, context: context,
                                                   openViewer: { [weak self] url in self?.onOpenHostFile?(url) ?? false })
            let data = try JSONSerialization.data(withJSONObject: result)
            text = String(decoding: data, as: UTF8.self)
            success = true
        } catch { text = error.localizedDescription }
        ch.sidecar.send(["type": "hostToolResult", "requestId": requestID, "success": success, "text": text])
    }

    /// Hands lines to the page, in order, once it has booted.
    private func deliver(_ lines: [String], to channel: String) {
        guard pageReady else { queued.append(contentsOf: lines.map { (channel, $0) }); return }
        // Each line is one JSON object, so the joined list is a JS array literal.
        webView.evaluateJavaScript("AgentChat.receive([\(lines.joined(separator: ","))], \"\(channel)\")", completionHandler: nil)
    }

    /// Session and message IDs from the page: UUIDs only.
    private static func isID(_ s: String) -> Bool { !s.isEmpty && s.count <= 64 && s.allSatisfy { $0.isHexDigit || $0 == "-" } }

    private func deliverJSON(_ obj: [String: Any], to channel: String) {
        if let data = try? JSONSerialization.data(withJSONObject: obj), let line = String(data: data, encoding: .utf8) {
            deliver([line], to: channel)
        }
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
            var m: [String: Any] = ["type": "user", "text": text]
            if let uuid = action["uuid"] as? String, Self.isID(uuid) { m["uuid"] = uuid }
            if let images = action["images"] as? [[String: Any]], !images.isEmpty { m["images"] = images }
            if let display = action["display"] as? String { m["display"] = display }
            if let priority = action["priority"] as? String { m["priority"] = priority }
            if let query = action["shouldQuery"] as? Bool { m["shouldQuery"] = query }
            ch.sidecar.send(m)
        case "permission":
            var m: [String: Any] = ["type": "permission"]
            for key in ["id", "decision", "message", "updatedInput", "updatedPermissions", "response"] { if let v = action[key] { m[key] = v } }
            ch.sidecar.send(m)
        case "realtimeStart":
            guard agent == .codex, ch.sidecar.isRunning else { return }
            startRealtime(on: ch)
        case "realtimeStop":
            if realtime?.channel === ch { stopRealtime() }
        case "realtimeMute":
            guard let voice = realtime, voice.channel === ch else { return }
            let muted = action["muted"] as? Bool ?? true
            voice.audio.setSending(!muted)
            ch.sidecar.send(["type": "realtimeState", "requestId": voice.audio.requestID, "muted": muted])
        case "surfaceAction":
            guard agent == .codex else { return }
            if action["action"] as? String == "accountLogin" { stopRealtime() }
            if action["action"] as? String == "realtimeStop", realtime?.channel === ch { stopRealtime(); return }
            var m: [String: Any] = ["type": "surfaceAction"]
            for key in ["action", "id", "text"] { if let v = action[key] { m[key] = v } }
            ch.sidecar.send(m)
        case "interrupt":
            ch.sidecar.send(["type": "interrupt"])
        case "background":
            var m: [String: Any] = ["type": "background"]
            if let tool = action["toolUseId"] as? String { m["toolUseId"] = tool }
            ch.sidecar.send(m)
        case "stopTask":
            guard let task = action["taskId"] as? String, !task.isEmpty else { return }
            ch.sidecar.send(["type": "stopTask", "taskId": task])
        case "shell", "shellKill":
            // A ! command: the conversation's own sidecar runs it in the session folder, else any running one.
            guard let sid = action["id"] as? String else { return }
            guard let runner = ch.sidecar.isRunning ? ch : channels.values.first(where: { $0.sidecar.isRunning }) else {
                if type == "shell" { deliverJSON(["type": "shell", "id": sid, "done": true, "error": "the session is not running here. Send a message to start it."], to: id) }
                return
            }
            var m: [String: Any] = ["type": type, "id": sid]
            if let command = action["command"] as? String { m["command"] = command }
            runner.sidecar.send(m)
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
        case "files":
            // @-mention search: the conversation's own sidecar, else any running one.
            var m: [String: Any] = ["type": "files", "query": action["query"] as? String ?? ""]
            if let rid = action["id"] { m["id"] = rid }
            (ch.sidecar.isRunning ? ch : channels.values.first { $0.sidecar.isRunning } ?? ch).sidecar.send(m)
        case "title", "rename":
            // The session's name (the ⋮ menu, /rename): its own sidecar knows the session.
            guard ch.sidecar.isRunning else {
                if type == "rename" { hostNotice(id, "info", "The session is not running here. Send a message to take it back, then rename it.") }
                return
            }
            var m: [String: Any] = ["type": type]
            if let title = action["title"] as? String { m["title"] = title }
            ch.sidecar.send(m)
        case "btw":
            // A side question: the conversation's own sidecar answers it, outside the conversation.
            guard let question = action["question"] as? String else { return }
            var m: [String: Any] = ["type": "btw", "question": question]
            if let rid = action["id"] { m["id"] = rid }
            if let history = action["history"] as? [[String: Any]] { m["history"] = history }
            guard ch.sidecar.isRunning else {
                deliverJSON(["type": "btw", "id": m["id"] ?? NSNull(), "error": "the session is not running here. Send a message to start it."], to: id)
                return
            }
            ch.sidecar.send(m)
        case "rewindFiles":
            // Rewind: the files part. The conversation part is "restartAt".
            guard let uuid = action["uuid"] as? String, Self.isID(uuid) else { return }
            var m: [String: Any] = ["type": "rewindFiles", "uuid": uuid, "dryRun": action["dryRun"] as? Bool ?? false]
            if let rid = action["id"] { m["id"] = rid }
            guard ch.sidecar.isRunning else {
                deliverJSON(["type": "rewind", "id": m["id"] ?? NSNull(), "uuid": uuid, "dryRun": m["dryRun"]!, "canRewind": false,
                             "error": "the session is not running here"], to: id)
                return
            }
            ch.sidecar.send(m)
        case "restartAt":
            if realtime?.channel === ch { stopRealtime() }
            // Rewind conversation; session resumes from entry before dropped prompt.
            let at = (action["resumeAt"] as? String).flatMap { Self.isID($0) ? $0 : nil }
            let drops = (action["dropsTurn"] as? String).flatMap { Self.isID($0) ? $0 : nil }
            ch.sidecar.onExit = nil
            ch.sidecar.stop()
            ch.handedOff = false
            if let at, let sid = ch.sessionID {
                var extras: [String: Any] = ["resumeAt": at]
                if let drops { extras["dropsTurn"] = drops }
                start(ch, resume: sid, extras: extras)
            } else if action["plain"] as? Bool ?? false, let sid = ch.sessionID {
                start(ch, resume: sid)   // a refused cut: the whole session again
            } else if let source = ch.forkOf {
                ch.sessionID = nil
                start(ch, resume: source, fork: true)
            } else {
                ch.sessionID = nil
                start(ch, resume: nil)
            }
        case "voice":
            stopRealtime()
            if action["on"] as? Bool ?? false {
                if dictation == nil {
                    let d = Dictation()
                    d.onEvent = { [weak self] event in self?.voiceEvent(event) }
                    dictation = d
                }
                dictation?.start()
            } else { dictation?.stop() }
        case "git", "sessions", "promptHistory":
            // Any running sidecar can read git and the session list of the shared folder.
            (ch.sidecar.isRunning ? ch : channels.values.first { $0.sidecar.isRunning } ?? ch).sidecar.send(["type": type])
        case "resume":
            stopRealtime()
            // /resume: continue another conversation; sidecar restarts; page draws history.
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
            if realtime?.channel === ch { stopRealtime() }
            guard agent == .codex else { return }
            ch.sidecar.send(["type": type])
        case "closeSide":
            if realtime?.channel === ch { stopRealtime() }
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
            if realtime?.channel === ch { stopRealtime() }
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

    // MARK: - Realtime voice

    private func realtimeState(_ ch: Channel, _ status: String, _ message: String? = nil) {
        var data: [String: Any] = ["status": status]
        if let message { data["message"] = message }
        deliverJSON(["v": 1, "agent": "codex", "type": "surface.snapshot", "id": "codex:voice:" + (ch.sessionID ?? "pending"),
                     "threadId": ch.sessionID ?? NSNull() as Any, "surface": "realtime", "title": "Voice conversation", "method": "floaty/realtime", "placement": "session", "data": data], to: ch.id)
    }

    private func startRealtime(on ch: Channel) {
        guard realtime == nil else { return }
        guard ch.sessionID != nil else { hostNotice(ch.id, "info", "Wait for Codex to connect before starting voice."); return }
        dictation?.cancel()
        voiceEvent(.stopped)
        let audio = CodexRealtimeAudio()
        let runner = ch.sidecar
        realtime = (ch, audio)
        realtimeState(ch, "starting", "Starting microphone…")
        audio.onReady = { [weak self, weak audio, weak ch, weak runner] in
            guard let self, let audio, let ch, let runner, self.realtime?.audio === audio, runner === ch.sidecar else { return }
            if !audio.echoCancellationEnabled {
                self.hostNotice(ch.id, "info", "Voice is using standard audio because echo cancellation could not start on this audio route. Use headphones to keep Codex from hearing its own playback.")
            }
            runner.send(["type": "realtimeStart", "requestId": audio.requestID])
        }
        audio.onAudio = { [weak self, weak audio, weak ch, weak runner] chunk in
            guard let self, let audio, let ch, let runner, self.realtime?.audio === audio, runner === ch.sidecar else { return }
            runner.send(["type": "realtimeAudio", "requestId": audio.requestID, "audio": chunk])
        }
        audio.onError = { [weak self, weak audio, weak ch] message in
            guard let self, let ch, let audio, self.realtime?.audio === audio else { return }
            self.stopRealtime()
            self.realtimeState(ch, "error", message)
        }
        audio.start()
    }

    private func stopRealtime(send: Bool = true) {
        guard let voice = realtime else { return }
        realtime = nil
        voice.audio.stop()
        if send { voice.channel.sidecar.send(["type": "realtimeStop"]) }
        realtimeState(voice.channel, "closed")
    }

    // MARK: - Dictation

    private func voiceEvent(_ event: Dictation.Event) {
        var obj: [String: Any]
        switch event {
        case .listening: obj = ["state": "listening"]
        case .text(let text, let final): obj = ["state": final ? "idle" : "listening", "text": text, "final": final]
        case .stopped: obj = ["state": "idle"]
        case .failed(let message): obj = ["state": "error", "message": message]
        }
        guard pageReady, let json = try? JSONSerialization.data(withJSONObject: obj),
              let arg = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.AgentChat && AgentChat.voice && AgentChat.voice(\(arg))", completionHandler: nil)
    }

    // MARK: - Dropped files

    /// Finder drops: files become @-mentions (relative to session folder); images attach.
    private func dropFiles(_ urls: [URL]) {
        guard pageReady else { return }
        let base = cwd.hasSuffix("/") ? cwd : cwd + "/"
        let imageTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"]
        let items: [[String: Any]] = urls.prefix(20).map { url in
            let path = url.standardizedFileURL.path
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            var rel = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
            if isDir.boolValue && !rel.hasSuffix("/") { rel += "/" }
            var item: [String: Any] = ["path": path, "rel": rel, "isDir": isDir.boolValue]
            // The page downscales big images; anything over 20 MB stays a mention.
            if !isDir.boolValue, let type = imageTypes[url.pathExtension.lowercased()],
               let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 20_000_000,
               let data = try? Data(contentsOf: url) {
                item["image"] = ["mediaType": type, "data": data.base64EncodedString(), "name": url.lastPathComponent]
            }
            return item
        }
        guard let json = try? JSONSerialization.data(withJSONObject: items),
              let list = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.AgentChat && AgentChat.dropFiles && AgentChat.dropFiles(\(list))", completionHandler: nil)
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
        didSet { if isCurrentlyViewed { hasUnseenOutput = false } else { stopRealtime() } }
    }

    var onTitleChanged: (() -> Void)?
    var onTerminated: (() -> Void)?

    var restorableRecord: TabRecord? { nil }

    func focus(in panel: NSWindow) {
        panel.makeFirstResponder(webView)
        webView.evaluateJavaScript("window.AgentChat && AgentChat.focus()", completionHandler: nil)
    }

    func cleanup() {
        if let appearanceToken { NotificationCenter.default.removeObserver(appearanceToken) }
        stopRealtime()
        dictation?.cancel()
        for ch in channels.values {
            ch.sidecar.onExit = nil
            ch.sidecar.stop()
        }
        webView.stopLoading()
        webView.navigationDelegate = nil
        SkimAssets.uninstall(from: webView.configuration)
    }
}

/// Chat tab's web view: takes file drags (Finder) instead of WebKit
/// (which would open file in place); other drags go to page as usual.
private final class DropWebView: WKWebView {
    var onDropFiles: (([URL]) -> Void)?

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        onDropFiles?(urls)
        return true
    }
}
