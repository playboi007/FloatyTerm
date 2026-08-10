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
    static func screenRects(selector: String, port: UInt16, match: String? = nil,
                            viaExtension: Bool = false) async throws -> [Match] {
        // A CDP endpoint that answers /json but never replies on the WS would
        // hang the relay (and the blocking CLI); cap the whole exchange.
        try await withTimeout(8) {
            try await withConn(port: port, match: match, viaExtension: viaExtension) { conn in
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
                guard let json = try await rawEval(conn, expression: expression) as? String,
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
    static func runJavaScript(expression: String, port: UInt16, match: String? = nil,
                              viaExtension: Bool = false) async throws -> String? {
        try await withTimeout(15) {
            try await withConn(port: port, match: match, viaExtension: viaExtension) { conn -> String? in
                let value = try await rawEval(conn, expression: expression, awaitPromise: true)
                guard let value, !(value is NSNull) else { return nil }
                let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
                return String(decoding: data, as: UTF8.self)
            }
        }
    }


    static func navigate(url: String, port: UInt16, match: String? = nil,
                         viaExtension: Bool = false) async throws {
        try await withTimeout(15) {
            try await withConn(port: port, match: match, viaExtension: viaExtension) { conn in
                let result = try await conn.call("Page.navigate", ["url": url])
                if let err = result["errorText"] as? String, !err.isEmpty {
                    throw DOMError.cdpError("navigate failed: \(err)")
                }
            }
        }
    }

    /// List the debuggable page targets (tabs) at this port: `id`, `title`
    static func tabs(port: UInt16, viaExtension: Bool = false) async throws -> [[String: Any]] {
        if viaExtension {
            guard await CDPBridge.shared.isConnected else { throw CDPBridge.BridgeError.notConnected }
            // The extension has no /json endpoint; it enumerates via chrome.tabs
            // and answers a synthetic Floaty.listTabs command.
            let r = try await CDPBridge.shared.call(method: "Floaty.listTabs", params: [:], match: nil).result
            return (r["tabs"] as? [[String: Any]]) ?? []
        }
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
    static func bringToFront(port: UInt16, match: String? = nil,
                             viaExtension: Bool = false) async throws {
        try await withTimeout(8) {
            try await withConn(port: port, match: match, viaExtension: viaExtension) { conn in
                _ = try await conn.call("Page.bringToFront", [:])
            }
        }
    }

    // MARK: - Set-of-Mark (annotate interactable elements with numbered boxes)

    /// One annotated element: its screen rect/center (so a later `click-mark`
    /// can act without the model emitting a coordinate) plus role + name so the
    /// agent can read the table alongside the image. Sendable to cross the
    /// timeout task-group boundary, like `Match`.
    struct SoMMark: Sendable {
        let role: String
        let name: String
        let rect: CGRect
        let center: CGPoint
    }

    /// The raw result of one set-of-mark pass: the annotated PNG (base64, decoded
    /// + saved by the caller on the main actor), the mark table in SCREEN space,
    /// and the page state used to invalidate the marks if the page later moves /
    /// scrolls / navigates (`click-mark`'s staleness guard).
    struct SoMResult: Sendable {
        let pngBase64: String
        let marks: [SoMMark]
        let url: String
        let screenX: Double
        let screenY: Double
        let scrollX: Double
        let scrollY: Double
    }

    /// Set-of-Mark prompting, DOM-backed. Draws a numbered box over each visible
    /// interactable element, screenshots the page WITH the overlay, then strips
    /// the overlay — so the model picks a NUMBER off the image instead of
    /// regressing a pixel. Element rects come from the same approach-5b CSS→screen
    /// transform `screenRects` uses, so a mark's stored center is click-accurate.
    /// (The native analog is the AX tree; this is the Chrome/Electron path.)
    ///
    /// `includeImage: false` collects the mark table WITHOUT the overlay or the
    /// screenshot (no rAF wait, no multi-MB PNG over the socket) — the cheap
    /// first pass of table-first SoM: when marks are well-named the table alone
    /// is what the model needs, and the pixels are skipped entirely.
    static func setOfMarks(port: UInt16, match: String? = nil, max: Int = 100,
                           includeImage: Bool = true, viaExtension: Bool = false) async throws -> SoMResult {
        try await withTimeout(20) {
            try await withConn(port: port, match: match, viaExtension: viaExtension) { conn -> SoMResult in
                // 1. Collect element geometry (and, when the image is wanted,
                //    inject the overlay). awaitPromise: the drawing variant
                //    resolves after a double rAF, so the boxes are actually
                //    painted before we screenshot.
                guard let json = try await rawEval(conn, expression: somInjectJS(max: max, draw: includeImage),
                                                   awaitPromise: true) as? String,
                      let m = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
                else { throw DOMError.cdpError("set-of-mark: could not collect elements") }

                var b64 = ""
                if includeImage {
                    // 2. Screenshot the page with the marks visible.
                    let shot = try await conn.call("Page.captureScreenshot",
                                              ["format": "png", "captureBeyondViewport": false])
                    b64 = (shot["data"] as? String) ?? ""

                    // 3. Remove the overlay — best effort, never fail over cleanup.
                    _ = try? await rawEval(conn, expression:
                        "(function(){var e=document.getElementById('__floaty_som__');if(e)e.remove();return 1;})()")

                    guard !b64.isEmpty else { throw DOMError.cdpError("set-of-mark: no screenshot data") }
                }

                func d(_ dict: [String: Any], _ k: String) -> Double { (dict[k] as? NSNumber)?.doubleValue ?? 0 }
                // Compose screen coords exactly like screenRects (CSS px == screen px).
                let chrome = d(m, "outerHeight") - d(m, "innerHeight")
                let sx = d(m, "screenX"), sy = d(m, "screenY")
                let marks: [SoMMark] = ((m["marks"] as? [[String: Any]]) ?? []).map { e in
                    let rw = d(e, "w"), rh = d(e, "h")
                    let ox = sx + d(e, "x"), oy = sy + chrome + d(e, "y")
                    return SoMMark(role: (e["role"] as? String) ?? "",
                                   name: (e["name"] as? String) ?? "",
                                   rect: CGRect(x: ox, y: oy, width: rw, height: rh),
                                   center: CGPoint(x: ox + rw / 2, y: oy + rh / 2))
                }
                return SoMResult(pngBase64: b64, marks: marks,
                                 url: (m["url"] as? String) ?? "",
                                 screenX: sx, screenY: sy,
                                 scrollX: d(m, "scrollX"), scrollY: d(m, "scrollY"))
            }
        }
    }

    /// JS run in the page: find visible interactable elements, optionally draw a
    /// numbered box over each (a single removable overlay container), and return
    /// the mark table + window/scroll state. With `draw`, resolves after a double
    /// rAF so the screenshot catches the painted boxes; without, returns the
    /// payload immediately (collect-only). `\\s` is a JS regex escape, not Swift.
    private static func somInjectJS(max: Int, draw: Bool = true) -> String {
        """
        (function(){
          var MAX=\(max);
          var DRAW=\(draw ? "true" : "false");
          var old=document.getElementById('__floaty_som__'); if(old) old.remove();
          var sel='a[href],button,input:not([type=hidden]):not([disabled]),select,textarea,'+
            '[role=button],[role=link],[role=textbox],[role=checkbox],[role=radio],[role=tab],'+
            '[role=menuitem],[role=switch],[contenteditable=""],[contenteditable=true],[onclick],'+
            'summary,[tabindex]:not([tabindex="-1"])';
          var nodes=Array.prototype.slice.call(document.querySelectorAll(sel));
          var vw=window.innerWidth, vh=window.innerHeight;
          function vis(el){
            var r=el.getBoundingClientRect();
            if(r.width<5||r.height<5) return null;
            if(r.bottom<=0||r.right<=0||r.top>=vh||r.left>=vw) return null;
            var s=getComputedStyle(el);
            if(s.visibility==='hidden'||s.display==='none'||parseFloat(s.opacity||'1')===0) return null;
            return r;
          }
          var marks=[], seen=[];
          for(var i=0;i<nodes.length;i++){
            var el=nodes[i], r=vis(el); if(!r) continue;
            var dup=false;
            for(var j=0;j<seen.length;j++){var q=seen[j];
              if(Math.abs(q.left-r.left)<2&&Math.abs(q.top-r.top)<2&&Math.abs(q.width-r.width)<2&&Math.abs(q.height-r.height)<2){dup=true;break;}}
            if(dup) continue; seen.push(r);
            var role=el.getAttribute('role')||el.tagName.toLowerCase();
            var name=(el.getAttribute('aria-label')||el.innerText||el.value||el.placeholder||el.getAttribute('title')||el.getAttribute('name')||'').replace(/\\s+/g,' ').trim().slice(0,80);
            marks.push({x:r.left,y:r.top,w:r.width,h:r.height,role:role,name:name});
            if(marks.length>=MAX) break;
          }
          var payload=JSON.stringify({marks:marks,screenX:window.screenX,screenY:window.screenY,outerHeight:window.outerHeight,innerHeight:window.innerHeight,scrollX:window.scrollX,scrollY:window.scrollY,url:location.href});
          if(!DRAW) return payload;
          var box=document.createElement('div'); box.id='__floaty_som__';
          box.style.cssText='position:fixed;left:0;top:0;z-index:2147483647;pointer-events:none;';
          var pal=['#e6194B','#3cb44b','#4363d8','#f58231','#911eb4','#42d4f4','#f032e6','#469990','#9A6324','#800000'];
          for(var k=0;k<marks.length;k++){
            var mm=marks[k], c=pal[k%pal.length];
            var b=document.createElement('div');
            b.style.cssText='position:fixed;left:'+mm.x+'px;top:'+mm.y+'px;width:'+mm.w+'px;height:'+mm.h+'px;border:2px solid '+c+';box-sizing:border-box;pointer-events:none;';
            var lab=document.createElement('div'); lab.textContent=String(k+1);
            lab.style.cssText='position:fixed;left:'+mm.x+'px;top:'+Math.max(0,mm.y-14)+'px;background:'+c+';color:#fff;font:bold 11px/14px monospace;padding:0 3px;pointer-events:none;white-space:nowrap;';
            box.appendChild(b); box.appendChild(lab);
          }
          document.documentElement.appendChild(box);
          return new Promise(function(res){requestAnimationFrame(function(){requestAnimationFrame(function(){res(payload);});});});
        })()
        """
    }

    // MARK: - CDP plumbing (shared by all operations)

    /// A CDP command channel. Two implementations — a direct debug-port WebSocket
    /// and the extension bridge — so every operation below is transport-agnostic:
    /// it issues `conn.call("Runtime.evaluate", …)` and doesn't care whether the
    /// bytes go to `--remote-debugging-port` or through the user's live Chrome via
    /// the FloatyTerm extension.
    protocol CDPConn {
        func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any]
    }

    /// Direct debug-port transport: one JSON-RPC round-trip over the tab's
    /// `webSocketDebuggerUrl`.
    private struct DirectConn: CDPConn {
        let ws: URLSessionWebSocketTask
        func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            try await AgentDOM.call(ws, method: method, params: params)
        }
    }

    /// Extension transport: forward the command to the extension service worker,
    /// which resolves `match` → a tab and `chrome.debugger.sendCommand`s it.
    /// The first reply's tabId pins every later call in the SAME session to that
    /// exact tab — without it, a multi-call op like `som` (collect → screenshot)
    /// would re-resolve per command and could straddle two tabs if the user
    /// switched mid-flight. A class (not struct) so the pin survives across calls.
    private final class BridgeConn: CDPConn {
        let match: String?
        private var tabId: Int?
        init(match: String?) { self.match = match }
        func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            let (result, tab) = try await CDPBridge.shared.call(
                method: method, params: params, match: match, pinnedTab: tabId)
            if let tab { tabId = tab }
            return result
        }
    }

    /// Connect → run `body` with a live CDP channel → always close. `viaExtension`
    /// picks the extension bridge (the user's live tabs, no debug port); otherwise
    /// discover a debuggable page at `port`. `match` selects which tab.
    private static func withConn<T: Sendable>(
        port: UInt16, match: String? = nil, viaExtension: Bool = false,
        _ body: (any CDPConn) async throws -> T
    ) async throws -> T {
        if viaExtension {
            guard await CDPBridge.shared.isConnected else { throw CDPBridge.BridgeError.notConnected }
            return try await body(BridgeConn(match: match))
        }
        let wsURL = try await discoverPageWebSocket(port: port, match: match)
        let session = URLSession(configuration: .ephemeral)
        let ws = session.webSocketTask(with: wsURL)
        // Page.captureScreenshot (set-of-mark) returns a base64 PNG that easily
        // exceeds URLSessionWebSocketTask's 1 MiB default message cap — a
        // full-page Retina shot is several MB. Without this the receive throws
        // and `som` silently fails on any non-trivial page.
        ws.maximumMessageSize = 16 * 1024 * 1024
        ws.resume()
        defer {
            ws.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }
        return try await body(DirectConn(ws: ws))
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
    private static func rawEval(_ conn: any CDPConn, expression: String,
                                awaitPromise: Bool = false) async throws -> Any? {
        let result = try await conn.call("Runtime.evaluate",
            ["expression": expression, "returnByValue": true, "awaitPromise": awaitPromise])
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
