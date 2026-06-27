import Foundation

/// Layer A — element targeting via the Chrome DevTools Protocol.
///
/// CRITICAL INSIGHT for "how do we handle VS Code / Cursor / Slack":
/// those are all **Electron** apps, i.e. Chromium. They speak the SAME CDP
/// protocol as Chrome — they just don't expose the debug port unless launched
/// with a flag. So this one client handles all of them; the only difference is
/// WHICH port we connect to:
///
///     Google Chrome   --remote-debugging-port=9222
///     code (VS Code)  --remote-debugging-port=9223
///     cursor          --remote-debugging-port=9224
///     Slack           --remote-debugging-port=9225
///
/// query-dom therefore takes a `port` (default 9222). The agent picks the port
/// for the app it's driving. An app must be LAUNCHED with the flag — you can't
/// attach to an already-running instance that wasn't. FloatyTerm can offer to
/// relaunch it (same UX as ContextSnap's permission relaunch), or the agent can
/// start it with the flag itself.
///
/// What this returns: a GLOBAL SCREEN rect (CGEvent coordinate space) for the
/// element, so Layer B can click its center directly. Producing that screen
/// rect — not the raw DOMRect — is the whole job, see `screenRect(...)`.
///
/// NOTE ON CONNECTION LIFECYCLE: the architecture brief wanted a persistent
/// warm WebSocket. For a first cut this opens a short-lived CDP session per
/// query (discover target → attach → evaluate → close). That's simpler and
/// robust; if per-command latency matters, cache the URLSessionWebSocketTask
/// per port and reuse it. Marked TODO below.
enum AgentDOM {

    enum DOMError: LocalizedError {
        case portClosed(UInt16)
        case noPage
        case noMatchingTab(String)
        case elementNotFound(String)
        case cdpError(String)
        var errorDescription: String? {
            switch self {
            case .portClosed(let p):
                return "No CDP endpoint on 127.0.0.1:\(p). Launch the app with --remote-debugging-port=\(p)."
            case .noPage: return "No debuggable page found at that port."
            case .noMatchingTab(let s):
                return "No open tab matches \"\(s)\". Run `floaty tabs` to list them."
            case .elementNotFound(let s): return "No element matches selector: \(s)"
            case .cdpError(let s): return "CDP error: \(s)"
            }
        }
    }

    /// Coordinate transform (the crux — getting this wrong is the classic
    /// "clicks 80px too high" bug). For each element we read, in ONE
    /// Runtime.evaluate, its viewport-relative `getBoundingClientRect()` plus
    /// `window.screenX/screenY/outerHeight/innerHeight` (approach "5b" —
    /// robust across Chrome and every Electron app, no Browser-domain quirks).
    /// Then, since screenX/Y and getBoundingClientRect are BOTH in CSS px:
    ///     screenX = window.screenX + r.x
    ///     screenY = window.screenY + (outerHeight - innerHeight) + r.y
    /// compose directly — do NOT multiply by dpr. Click point is the center.
    /// (iframe-nested elements need per-frame contexts; out of scope — use
    /// `eval` for those.)
    ///
    /// One matched element: its screen-space rect, click center, and a short
    /// text snippet (innerText / value / aria-label) so the caller can tell
    /// matches apart without a screenshot. Sendable so it crosses the timeout
    /// task-group boundary.
    struct Match: Sendable {
        let rect: CGRect
        let center: CGPoint
        let text: String
    }

    /// Resolve `selector` to the screen rects of ALL matching elements (document
    /// order, capped at 200), not just the first — so an agent can loop over or
    /// pick among results. Throws `.elementNotFound` when nothing matches.
    static func screenRects(selector: String, port: UInt16, match: String? = nil) async throws -> [Match] {
        // A CDP endpoint that answers /json but never replies on the WS would
        // hang the relay (and the blocking CLI); cap the whole exchange.
        try await withTimeout(8) {
            try await withSession(port: port, match: match) { ws in
                // One round-trip: every match's viewport-relative rect PLUS the
                // window's screen origin and chrome inset (approach 5b).
                let expression = """
                (function(){var els=document.querySelectorAll(\(jsLiteral(selector)));var out=[];\
                for(var i=0;i<els.length&&i<200;i++){var r=els[i].getBoundingClientRect();\
                out.push({x:r.x,y:r.y,w:r.width,h:r.height,\
                t:(els[i].innerText||els[i].value||els[i].getAttribute('aria-label')||'').trim().slice(0,200)});}\
                return JSON.stringify({matches:out,screenX:window.screenX,screenY:window.screenY,\
                outerHeight:window.outerHeight,innerHeight:window.innerHeight});})()
                """
                guard let json = try await rawEval(ws, expression: expression) as? String,
                      let m = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
                else { throw DOMError.cdpError("could not parse element measurements") }

                func d(_ dict: [String: Any], _ k: String) -> Double {
                    (dict[k] as? NSNumber)?.doubleValue ?? 0
                }
                // Compose in CSS px == screen px; do NOT scale by dpr.
                let chrome = d(m, "outerHeight") - d(m, "innerHeight")
                let sx = d(m, "screenX"), sy = d(m, "screenY")
                let matches: [Match] = ((m["matches"] as? [[String: Any]]) ?? []).map { e in
                    let rw = d(e, "w"), rh = d(e, "h")
                    let ox = sx + d(e, "x"), oy = sy + chrome + d(e, "y")
                    return Match(rect: CGRect(x: ox, y: oy, width: rw, height: rh),
                                 center: CGPoint(x: ox + rw / 2, y: oy + rh / 2),
                                 text: (e["t"] as? String) ?? "")
                }
                guard !matches.isEmpty else { throw DOMError.elementNotFound(selector) }
                return matches
            }
        }
    }

    /// Run arbitrary JavaScript in the page and return its result as a JSON
    /// string (the value re-serialized), or nil for null/undefined. This is the
    /// escape hatch agents were reaching for via raw Python websockets —
    /// querySelectorAll scraping, reading page text, clicking via the DOM.
    /// Promises are awaited.
    static func runJavaScript(expression: String, port: UInt16, match: String? = nil) async throws -> String? {
        try await withTimeout(15) {
            try await withSession(port: port, match: match) { ws -> String? in
                let value = try await rawEval(ws, expression: expression, awaitPromise: true)
                guard let value, !(value is NSNull) else { return nil }
                let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
                return String(decoding: data, as: UTF8.self)
            }
        }
    }

    /// Navigate the debuggable page to `url` via CDP `Page.navigate` — works even
    /// when the tab sits on a chrome:// page that blocks `query-dom`. Returns
    /// once the navigation is accepted (not necessarily fully loaded).
    static func navigate(url: String, port: UInt16, match: String? = nil) async throws {
        try await withTimeout(15) {
            try await withSession(port: port, match: match) { ws in
                let result = try await call(ws, method: "Page.navigate", params: ["url": url])
                if let err = result["errorText"] as? String, !err.isEmpty {
                    throw DOMError.cdpError("navigate failed: \(err)")
                }
            }
        }
    }

    /// List the debuggable page targets (tabs) at this port: `id`, `title`,
    /// `url`. Lets an agent see the open tabs and pick one to drive by
    /// `--match` (a url/title substring) — the answer to "point at my YouTube
    /// tab / GCP console tab". Just a GET /json; no WebSocket.
    static func tabs(port: UInt16) async throws -> [[String: Any]] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json") else {
            throw DOMError.portClosed(port)
        }
        let data: Data
        do { (data, _) = try await URLSession.shared.data(from: url) }
        catch { throw DOMError.portClosed(port) }
        guard let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DOMError.noPage
        }
        return targets.filter { ($0["type"] as? String) == "page" }.map {
            ["id": ($0["id"] as? String) ?? "",
             "title": ($0["title"] as? String) ?? "",
             "url": ($0["url"] as? String) ?? ""]
        }
    }

    /// Bring a specific tab's window to the front (CDP `Page.bringToFront`).
    /// This is how you aim KEYSTROKES at the debug Chrome when two Chromes share
    /// the app name: focus the right tab over CDP, then inject without --target
    /// (it's now frontmost). Selected by `match` like the other CDP verbs.
    static func bringToFront(port: UInt16, match: String? = nil) async throws {
        try await withTimeout(8) {
            try await withSession(port: port, match: match) { ws in
                _ = try await call(ws, method: "Page.bringToFront")
            }
        }
    }

    // MARK: - CDP plumbing (shared by all operations)

    /// Discover → connect → run `body` with a live CDP socket → always close.
    /// `match` selects which tab (url/title substring); nil = the first real page.
    private static func withSession<T: Sendable>(
        port: UInt16, match: String? = nil, _ body: (URLSessionWebSocketTask) async throws -> T
    ) async throws -> T {
        let wsURL = try await discoverPageWebSocket(port: port, match: match)
        let session = URLSession(configuration: .ephemeral)
        let ws = session.webSocketTask(with: wsURL)
        ws.resume()
        defer {
            ws.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        return try await body(ws)
    }

    /// GET /json on the port → a debuggable page's WebSocket URL. When `match`
    /// is given, picks the tab whose url OR title contains it (case-insensitive)
    /// — that's how you target a specific open tab. Otherwise prefers a real
    /// http(s)/file page over a chrome:// / devtools target.
    private static func discoverPageWebSocket(port: UInt16, match: String? = nil) async throws -> URL {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json") else {
            throw DOMError.portClosed(port)
        }
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(from: url)
        } catch {
            throw DOMError.portClosed(port)   // refused / unreachable
        }
        guard let targets = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw DOMError.noPage
        }
        let pages = targets.filter {
            ($0["type"] as? String) == "page" && $0["webSocketDebuggerUrl"] is String
        }
        let pick: [String: Any]?
        if let match, !match.isEmpty {
            let m = match.lowercased()
            guard let hit = pages.first(where: {
                (($0["url"] as? String) ?? "").lowercased().contains(m)
                    || (($0["title"] as? String) ?? "").lowercased().contains(m)
            }) else { throw DOMError.noMatchingTab(match) }
            pick = hit
        } else {
            pick = pages.first {
                let u = ($0["url"] as? String) ?? ""
                return u.hasPrefix("http") || u.hasPrefix("file")
            } ?? pages.first ?? targets.first { $0["webSocketDebuggerUrl"] is String }
        }
        guard let pick,
              let wsString = pick["webSocketDebuggerUrl"] as? String,
              let wsURL = URL(string: wsString)
        else { throw DOMError.noPage }
        return wsURL
    }

    /// Runtime.evaluate → the raw JS value (String / Number / Bool / Array /
    /// Dict by value), or nil for null/undefined. Throws on a page exception.
    private static func rawEval(_ ws: URLSessionWebSocketTask, expression: String,
                                awaitPromise: Bool = false) async throws -> Any? {
        let result = try await call(ws, method: "Runtime.evaluate",
            params: ["expression": expression, "returnByValue": true, "awaitPromise": awaitPromise])
        if let exc = result["exceptionDetails"] as? [String: Any] {
            throw DOMError.cdpError((exc["text"] as? String) ?? "evaluation threw")
        }
        return (result["result"] as? [String: Any])?["value"]
    }

    /// One CDP request/response. JSON-RPC over WS: tag with an `id`, read frames
    /// until the reply with that id arrives (interleaved domain events skipped).
    private static func call(_ ws: URLSessionWebSocketTask, method: String,
                             params: [String: Any] = [:]) async throws -> [String: Any] {
        let id = 1
        let payload = try JSONSerialization.data(withJSONObject:
            ["id": id, "method": method, "params": params])
        try await ws.send(.string(String(decoding: payload, as: UTF8.self)))

        for _ in 0..<128 {
            let text: String
            switch try await ws.receive() {
            case .string(let s): text = s
            case .data(let d):   text = String(decoding: d, as: UTF8.self)
            @unknown default:    continue
            }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any] else { continue }
            guard (obj["id"] as? NSNumber)?.intValue == id else { continue }  // skip events
            if let err = obj["error"] as? [String: Any] {
                throw DOMError.cdpError((err["message"] as? String) ?? "unknown CDP error")
            }
            guard let result = obj["result"] as? [String: Any] else {
                throw DOMError.cdpError("malformed CDP reply to \(method)")
            }
            return result
        }
        throw DOMError.cdpError("no reply to \(method)")
    }

    /// JSON-encode a string into a JS string literal (quotes + escaping).
    private static func jsLiteral(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed))
            ?? Data("\"\"".utf8), as: UTF8.self)
    }

    /// Race an async operation against a deadline. T is Sendable so it crosses
    /// the task-group boundary cleanly.
    private static func withTimeout<T: Sendable>(
        _ seconds: Double, _ op: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DOMError.cdpError("timed out after \(Int(seconds))s")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
