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
        /// A JavaScript alert / confirm / prompt is open: the page answers no
        /// command until someone answers it.
        case dialog(type: String, message: String)
        var errorDescription: String? {
            switch self {
            case .portClosed(let p):
                return "No CDP endpoint on 127.0.0.1:\(p). Launch the app with --remote-debugging-port=\(p)."
            case .noPage: return "No debuggable page found at that port."
            case .noMatchingTab(let s):
                return "No open tab matches \"\(s)\". Run `floaty tabs` to list them."
            case .elementNotFound(let s): return "No element matches selector: \(s)"
            case .cdpError(let s): return "CDP error: \(s)"
            case .dialog(let type, let message):
                return "the page is showing a JavaScript \(type) dialog: \"\(message.prefix(300))\" — it answers no "
                    + "command until the dialog is answered. Answer it with `floaty dialog --accept` or `--dismiss` "
                    + "(prompt text: --text \"…\"), with the same --via-extension/--port/--match. Ask the user first if "
                    + "accepting has real effects (delete, pay, leave the page)."
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
        /// `ref_N` — names this element in `input` (resolved when it acts).
        var ref: String = ""
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
                (function(){var R=\(DOMRefs.tableJS);var els=document.querySelectorAll(\(jsLiteral(selector)));var out=[];\
                for(var i=0;i<els.length&&i<200;i++){var r=els[i].getBoundingClientRect();\
                out.push({x:r.x,y:r.y,w:r.width,h:r.height,ref:R.of(els[i]),\
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
                                 text: (e["t"] as? String) ?? "", ref: (e["ref"] as? String) ?? "")
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


    /// The URL a navigate call may open, or a refusal. Only http(s) and
    /// about:blank by default: a `javascript:` URL runs script in the page and
    /// `file:` reads local files, and neither is what "navigate" means. A
    /// schemeless "example.com" is https, as a browser's address bar reads it.
    static func navigableURL(_ raw: String, allowAnyScheme: Bool = false) -> Result<String, DOMError> {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.lowercased() == "about:blank" { return .success(url) }
        // Local dev servers speak plain http; everything else defaults to https.
        let local = url.hasPrefix("localhost") || url.hasPrefix("[::1]") || url.first?.isNumber == true
        guard let r = url.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) else {
            return .success((local ? "http://" : "https://") + url)
        }
        let scheme = url[r].dropLast().lowercased()
        if scheme == "http" || scheme == "https" || allowAnyScheme { return .success(url) }
        // "localhost:3000" parses as scheme "localhost" — a host with a port, not a scheme.
        if url[r.upperBound...].first?.isNumber == true { return .success("http://" + url) }
        return .failure(.cdpError("navigate refused a \(scheme): URL — only http, https and about:blank "
            + "(a javascript: URL runs script in the page; file: reads local files). Pass --allow-scheme "
            + "if the user asked for this exact URL."))
    }

    /// Navigate and wait until the NEW document is parsed: a document's
    /// `performance.timeOrigin` is unique to it, so a changed origin with
    /// readyState past "loading" means the page you asked for is the one that
    /// answers the next call. (Page.navigate alone returns at once, and the
    /// next read could still see the old page.) Polls, because the extension
    /// bridge forwards no CDP events.
    static func navigate(url: String, port: UInt16, match: String? = nil,
                         viaExtension: Bool = false) async throws -> [String: Any] {
        try await withTimeout(45) {
            try await withConn(port: port, match: match, viaExtension: viaExtension) { conn in
                let probe = "JSON.stringify({o:performance.timeOrigin,u:location.href,r:document.readyState,t:document.title})"
                func state() async -> [String: Any]? {
                    guard let s = try? await withTimeout(3, { try await rawEval(conn, expression: probe) }) as? String
                    else { return nil }
                    return try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
                }
                let before = await state()
                let result = try await conn.call("Page.navigate", ["url": url])
                if let err = result["errorText"] as? String, !err.isEmpty {
                    throw DOMError.cdpError("navigate failed: \(err)")
                }
                let start = Date()
                let newDocument = result["loaderId"] != nil        // absent for a #fragment change
                var last: [String: Any]?
                while Date().timeIntervalSince(start) < 30 {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    guard let now = await state() else { continue }  // mid-swap: no context yet
                    last = now
                    let fresh = !newDocument
                        || (now["o"] as? NSNumber) != (before?["o"] as? NSNumber)
                    if fresh, (now["r"] as? String) != "loading" {
                        return ["ok": true, "url": now["u"] ?? url, "title": now["t"] ?? "",
                                "waited_ms": Int(Date().timeIntervalSince(start) * 1000)]
                    }
                }
                return ["ok": true, "url": last?["u"] ?? url, "committed": false,
                        "note": "the navigation started, but the new page was not parsed within 30 s — "
                            + "check it before reading (`eval --expression document.readyState`)"]
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
        var ref: String = ""
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
    /// `all`: include elements outside the viewport too. `under`: only inside
    /// the element with that ref.
    static func setOfMarks(port: UInt16, match: String? = nil, max: Int = 100,
                           includeImage: Bool = true, viaExtension: Bool = false,
                           all: Bool = false, under: String? = nil) async throws -> SoMResult {
        try await withTimeout(20) {
            try await withConn(port: port, match: match, viaExtension: viaExtension) { conn -> SoMResult in
                // 1. Collect element geometry (and, when the image is wanted,
                //    inject the overlay). awaitPromise: the drawing variant
                //    resolves after a double rAF, so the boxes are actually
                //    painted before we screenshot.
                guard let json = try await rawEval(conn, expression: somInjectJS(max: max, draw: includeImage,
                                                                                 all: all, under: under),
                                                   awaitPromise: true) as? String,
                      let m = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
                else { throw DOMError.cdpError("set-of-mark: could not collect elements") }
                if let u = under, m["under_missing"] != nil { throw DOMError.cdpError(DOMRefs.staleMessage(u)) }

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
                                   center: CGPoint(x: ox + rw / 2, y: oy + rh / 2),
                                   ref: (e["ref"] as? String) ?? "")
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
    private static func somInjectJS(max: Int, draw: Bool = true, all: Bool = false, under: String? = nil) -> String {
        """
        (function(){
          var MAX=\(max);
          var DRAW=\(draw ? "true" : "false");
          var ALL=\(all && !draw ? "true" : "false");
          var R=\(DOMRefs.tableJS);
          var ROOT=document;
          \(under.map { "ROOT=R.get(\(jsLiteral($0)));if(!ROOT)return JSON.stringify({under_missing:true});" } ?? "")
          var old=document.getElementById('__floaty_som__'); if(old) old.remove();
          var sel='a[href],button,input:not([type=hidden]):not([disabled]),select,textarea,'+
            '[role=button],[role=link],[role=textbox],[role=checkbox],[role=radio],[role=tab],'+
            '[role=menuitem],[role=switch],[contenteditable=""],[contenteditable=true],[onclick],'+
            'summary,[tabindex]:not([tabindex="-1"])';
          var nodes=Array.prototype.slice.call(ROOT.querySelectorAll(sel));
          var vw=window.innerWidth, vh=window.innerHeight;
          function vis(el){
            var r=el.getBoundingClientRect();
            if(r.width<5||r.height<5) return null;
            if(!ALL&&(r.bottom<=0||r.right<=0||r.top>=vh||r.left>=vw)) return null;
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
            marks.push({x:r.left,y:r.top,w:r.width,h:r.height,role:role,name:name,ref:R.of(el)});
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
        /// Send without waiting for the reply (order is kept: one socket, one
        /// queue). For mouse moves: Chrome acks a move only at the next frame,
        /// and waiting for that made every hovered click ~1 frame late.
        func post(_ method: String, _ params: [String: Any]) async throws
    }

    /// Direct debug-port transport: one JSON-RPC round-trip over the tab's
    /// `webSocketDebuggerUrl`.
    private struct DirectConn: CDPConn {
        let ws: URLSessionWebSocketTask
        /// A dialog that was already open when the session started.
        var openDialog: DOMError? = nil
        func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
            try await AgentDOM.call(ws, method: method, params: params)
        }
        func post(_ method: String, _ params: [String: Any]) async throws {
            // Its reply arrives later and is skipped by the next call's read loop.
            let data = try JSONSerialization.data(withJSONObject: [
                "id": Int.random(in: 1...Int(Int32.max)), "method": method, "params": params])
            try await ws.send(.string(String(decoding: data, as: UTF8.self)))
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
            do {
                let policy = AgentDOM.dialogPolicy
                var (result, tab) = try await CDPBridge.shared.call(
                    method: method, params: params, match: match, pinnedTab: tabId,
                    onDialog: policy == .stop ? nil : policy.rawValue)
                if let tab { tabId = tab }
                if let answered = result.removeValue(forKey: "__floatyDialogs") as? [[String: Any]] {
                    for d in answered { AgentDOM.dialogLog?.add(d) }
                }
                return result
            } catch CDPBridge.BridgeError.remote(let msg) where msg.hasPrefix(AgentDOM.dialogTag) {
                throw AgentDOM.dialogError(fromJSON: String(msg.dropFirst(AgentDOM.dialogTag.count)))
            }
        }
        func post(_ method: String, _ params: [String: Any]) async throws {
            let policy = AgentDOM.dialogPolicy
            try await CDPBridge.shared.post(method: method, params: params, match: match, pinnedTab: tabId,
                                            onDialog: policy == .stop ? nil : policy.rawValue)
        }
    }

    /// The extension's prefix for "a dialog is open" (extension/background.js).
    static let dialogTag = "FLOATY_DIALOG "

    // MARK: - JavaScript dialogs
    //
    // An alert/confirm/prompt blocks its page: every command waits on it, and
    // Chrome lets ONLY the CDP session that saw the dialog open answer it
    // (measured: a later session gets "No dialog is showing" and is itself
    // blocked; only a reload clears it). So the dialog is answered where it
    // is seen, by policy — dismiss by default, like the browser toolset's
    // driver — and reported. "stop" leaves it open and fails the call.

    enum DialogPolicy: String {
        case dismiss, accept, stop
    }

    /// Dialogs answered during one verb, for its reply.
    final class DialogLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String: Any]] = []
        func add(_ d: [String: Any]) { lock.lock(); items.append(d); lock.unlock() }
        var all: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return items }
    }

    @TaskLocal static var dialogPolicy: DialogPolicy = .dismiss
    @TaskLocal static var dialogLog: DialogLog? = nil

    /// Run a CDP verb with the call's --on-dialog policy; answered dialogs
    /// land in the reply as `dialogs`.
    static func withDialogPolicy(_ b: [String: Any], _ body: () async -> [String: Any]) async -> [String: Any] {
        let policy = DialogPolicy(rawValue: (b["on_dialog"] as? String)?.lowercased() ?? "") ?? .dismiss
        let log = DialogLog()
        var out = await $dialogPolicy.withValue(policy) { await $dialogLog.withValue(log) { await body() } }
        let seen = log.all
        if !seen.isEmpty {
            out["dialogs"] = seen
            let n = (out["note"] as? String).map { $0 + ". " } ?? ""
            out["note"] = n + "the page opened \(seen.count == 1 ? "a JavaScript dialog" : "\(seen.count) JavaScript dialogs"); "
                + "see `dialogs` for what each said and how it was answered (--on-dialog accept|dismiss|stop)"
        }
        return out
    }

    static func dialogError(fromJSON json: String) -> DOMError {
        let d = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
        return .dialog(type: d["type"] as? String ?? "alert", message: d["message"] as? String ?? "")
    }

    /// Connect → run `body` with a live CDP channel → always close. `viaExtension`
    /// picks the extension bridge (the user's live tabs, no debug port); otherwise
    /// discover a debuggable page at `port`. `match` selects which tab.
    /// `tolerateDialog`: start the session even while a JavaScript dialog is
    /// open (the `dialog` verb). Every other caller gets the dialog error at
    /// once instead of a hang.
    static func withConn<T: Sendable>(
        port: UInt16, match: String? = nil, viaExtension: Bool = false, tolerateDialog: Bool = false,
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
        // Page events report a JavaScript dialog (one already open is reported
        // on enable), which `call` turns into a clear error instead of a hang.
        // A dialog that was ALREADY open is not reported on enable (measured:
        // the enable itself just never answers). So a silent enable means the
        // page is blocked — say so now instead of hanging the verb. The
        // `dialog` verb skips this: it must reach a blocked page.
        if !tolerateDialog {
            do { _ = try await withTimeout(3) { try await call(ws, method: "Page.enable") } }
            catch let e as DOMError {
                if case .dialog = e { throw e }
                throw DOMError.cdpError("the page does not answer within 3 s — most likely a JavaScript dialog "
                    + "(alert/confirm/prompt) left open by an earlier call. Over a debug port only the session that saw "
                    + "it can answer it, so `floaty dialog --reload` is the way out (it reloads the tab; unsaved page "
                    + "state is lost). Otherwise the tab is hung or hidden.")
            } catch {}
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
    static func rawEval(_ conn: any CDPConn, expression: String,
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
        // A fresh id per command: a reply that arrives after its caller timed
        // out must never be read as the answer to the next command.
        let id = Int.random(in: 1...Int(Int32.max))
        let payload = try JSONSerialization.data(withJSONObject:
            ["id": id, "method": method, "params": params])
        // A socket read does not end when its task is cancelled, so a timeout
        // (withTimeout cancels) would wait forever on a page that never
        // answers — a JavaScript dialog, a hung renderer. Closing the socket
        // ends the read; the session is unusable after a timeout anyway.
        let policy = dialogPolicy, log = dialogLog
        return try await withTaskCancellationHandler {
            try await exchange(ws, id: id, method: method, payload: payload, policy: policy, log: log)
        } onCancel: {
            ws.cancel(with: .goingAway, reason: nil)
        }
    }

    private static func exchange(_ ws: URLSessionWebSocketTask, id: Int, method: String,
                                 payload: Data, policy: DialogPolicy = .stop,
                                 log: DialogLog? = nil) async throws -> [String: Any] {
        try await ws.send(.string(String(decoding: payload, as: UTF8.self)))

        for _ in 0..<1024 {           // Page events can come between a command and its reply
            let text: String
            switch try await ws.receive() {
            case .string(let s): text = s
            case .data(let d):   text = String(decoding: d, as: UTF8.self)
            @unknown default:    continue
            }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any] else { continue }
            if obj["method"] as? String == "Page.javascriptDialogOpening",
               method != "Page.handleJavaScriptDialog" {
                let p = obj["params"] as? [String: Any] ?? [:]
                let type = p["type"] as? String ?? "alert", message = p["message"] as? String ?? ""
                guard policy != .stop else { throw DOMError.dialog(type: type, message: message) }
                // Answer it in THIS session (no other session can), then keep
                // waiting for the command it was blocking.
                let answer = try JSONSerialization.data(withJSONObject: [
                    "id": Int.random(in: 1...Int(Int32.max)), "method": "Page.handleJavaScriptDialog",
                    "params": ["accept": policy == .accept]])
                try await ws.send(.string(String(decoding: answer, as: UTF8.self)))
                log?.add(["type": type, "message": String(message.prefix(500)),
                          "answered": policy == .accept ? "accepted" : "dismissed"])
                continue
            }
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

    /// `floaty dialog`: report the open JavaScript dialog, or answer it.
    /// `accept` nil = only report.
    static func dialog(accept: Bool?, promptText: String?, reload: Bool = false, port: UInt16, match: String?,
                       viaExtension: Bool) async throws -> [String: Any] {
        try await withTimeout(10) {
            try await withConn(port: port, match: match, viaExtension: viaExtension, tolerateDialog: true) { conn in
                if reload {
                    // The only way out of a dialog no session can answer.
                    _ = try await conn.call("Page.reload", [:])
                    return ["ok": true, "reloaded": true,
                            "note": "the tab was reloaded — the dialog is gone, and so is any unsaved state on the page"]
                }
                guard let accept else {
                    if viaExtension {
                        let r = try await conn.call("Floaty.dialog", [:])
                        guard let d = r["dialog"] as? [String: Any] else { return ["ok": true, "dialog": NSNull()] }
                        return ["ok": true, "dialog": ["type": d["type"] ?? "", "message": d["message"] ?? "",
                                                       "default_prompt": d["defaultPrompt"] ?? ""]]
                    }
                    // Direct port: Chrome reports no dialog that is already open,
                    // but a blocked page doesn't answer a trivial evaluate.
                    do {
                        _ = try await withTimeout(2) { try await conn.call("Runtime.evaluate", ["expression": "0"]) }
                        return ["ok": true, "dialog": NSNull()]
                    } catch DOMError.dialog(let type, let message) {
                        return ["ok": true, "dialog": ["type": type, "message": message]]
                    } catch {
                        return ["ok": true, "dialog": ["type": "unknown", "message": "", "unresponsive": true],
                                "note": "the page does not answer — a dialog is most likely open (its text can't be "
                                    + "read over a debug port once it is showing). --dismiss is the safe answer."]
                    }
                }
                var params: [String: Any] = ["accept": accept]
                if let promptText { params["promptText"] = promptText }
                do { _ = try await conn.call("Page.handleJavaScriptDialog", params) }
                catch {
                    if "\(error)".localizedCaseInsensitiveContains("no dialog") {
                        return ["error": "no dialog this session can answer — either none is open, or it opened in an "
                            + "earlier session (Chrome lets only that session answer it). If the page doesn't respond, "
                            + "`floaty dialog --reload` reloads the tab (unsaved page state is lost)."]
                    }
                    throw error
                }
                return ["ok": true, "answered": accept ? "accepted" : "dismissed"]
            }
        }
    }

    /// JSON-encode a string into a JS string literal (quotes + escaping).
    static func jsLiteral(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed))
            ?? Data("\"\"".utf8), as: UTF8.self)
    }

    /// Race an async operation against a deadline. T is Sendable so it crosses
    /// the task-group boundary cleanly.
    static func withTimeout<T: Sendable>(
        _ seconds: Double, _ op: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DOMError.cdpError("timed out after \(Int(seconds))s")
            }
            defer { group.cancelAll() }
            do { return try await group.next()! }
            catch DOMError.cdpError(let m) where m.hasPrefix("timed out after") {
                throw DOMError.cdpError(m + " — the page did not answer. A JavaScript dialog may be open "
                    + "(`floaty dialog` checks), or the tab is busy or hidden.")
            }
        }
    }
}
