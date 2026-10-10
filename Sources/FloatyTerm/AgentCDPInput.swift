import Foundation

/// `floaty input` — the run half: resolve every target in one round trip, then
/// send the CDPInputScript timeline on a host clock. Runs off the main actor,
/// so the terminal UI can't delay an event, and keeps one CDP session for the
/// whole script (the extension attaches once; a direct port opens one socket).
///
/// Safety: a failure part-way releases every key and mouse button the script
/// still holds, so a stopped script never leaves a key stuck down in the page.
enum AgentCDPInput {

    typealias Point = (x: Double, y: Double)

    static func run(steps: [[String: Any]], port: UInt16, match: String?,
                    viaExtension: Bool) async -> [String: Any] {
        let timeline: [CDPInputScript.Timed]
        do { timeline = try CDPInputScript.compile(steps) } catch {
            return ["error": "input: \(error.localizedDescription)"]
        }
        guard !timeline.isEmpty else { return ["error": "input: the script has no actions"] }
        let budget = (timeline.last?.atMs ?? 0) / 1000 + 20
        do {
            return try await AgentDOM.withTimeout(budget) {
                try await AgentDOM.withConn(port: port, match: match, viaExtension: viaExtension) { conn in
                    try await execute(timeline, steps: steps.count, conn: conn, keepAlive: viaExtension,
                                      via: viaExtension ? "extension" : "port \(port)")
                }
            }
        } catch {
            return ["error": "input: \(error.localizedDescription)", "mode": "background"]
        }
    }

    // MARK: - Resolve targets

    private struct Resolved {
        var viewportHeight = 0.0
        var points: [CDPInputScript.Target: Point] = [:]
        var covered: [String] = []
        var report: [String: Any] = [:]
        var scrolled = false
        var url = ""
        var title = ""
        var hidden = false
    }

    /// Selectors and refs → viewport points, screen points → viewport points,
    /// in ONE evaluate. A selector or ref target outside the viewport is
    /// scrolled into view (centre), and everything is measured again, as a
    /// hand would scroll before it clicks; targets that still don't fit in one
    /// view are an error. Also the first command of the session, so the
    /// extension's attach happens before the clock starts, not on the first note.
    private static func resolve(_ targets: [CDPInputScript.Target], conn: any AgentDOM.CDPConn) async throws -> Resolved {
        var specs: [[String: Any]] = []
        for t in targets {
            switch t {
            case .selector(let sel, let fx, let fy): specs.append(["sel": sel, "fx": fx, "fy": fy])
            case .ref(let ref, let fx, let fy): specs.append(["ref": ref, "fx": fx, "fy": fy])
            default: break
            }
        }
        let specJSON = String(decoding: (try? JSONSerialization.data(withJSONObject: specs)) ?? Data("[]".utf8),
                              as: UTF8.self)
        let js = """
        (function(specs){var R=\(DOMRefs.tableJS);\
        function el(s){return s.ref?R.get(s.ref):document.querySelector(s.sel);}\
        function measure(){var pts=[],off=-1;for(var i=0;i<specs.length;i++){var s=specs[i],e=null;\
        try{e=el(s);}catch(x){pts.push({bad:true});continue;}if(!e){pts.push(null);continue;}\
        var r=e.getBoundingClientRect(),x=r.left+r.width*s.fx,y=r.top+r.height*s.fy;\
        var inside=x>=0&&y>=0&&x<innerWidth&&y<innerHeight;if(!inside&&off<0)off=i;\
        var hit=inside?document.elementFromPoint(x,y):null;\
        pts.push({x:x,y:y,w:r.width,h:r.height,covered:!!hit&&hit!==e&&!e.contains(hit)});}return{pts:pts,off:off};}\
        var m=measure(),scrolled=false;\
        if(m.off>=0){var t=el(specs[m.off]);if(t){t.scrollIntoView({block:'center',inline:'center',behavior:'instant'});\
        scrolled=true;m=measure();}}\
        return JSON.stringify({pts:m.pts,scrolled:scrolled,u:location.href,t:document.title,\
        h:document.visibilityState==='hidden',sx:window.screenX,sy:window.screenY,oh:window.outerHeight,\
        ih:window.innerHeight,vw:window.innerWidth,vh:window.innerHeight});})(\(specJSON))
        """
        guard let json = try await AgentDOM.rawEval(conn, expression: js) as? String,
              let m = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw CDPInputScript.ScriptError(message: "could not read the page (is the tab loaded?)")
        }
        func d(_ k: String) -> Double { (m[k] as? NSNumber)?.doubleValue ?? 0 }
        let vw = d("vw"), vh = d("vh")
        let insetY = d("oh") - d("ih")         // tab strip + toolbar (+ the debugging banner)
        let pts = (m["pts"] as? [Any]) ?? []
        var out = Resolved()
        out.viewportHeight = vh
        out.scrolled = (m["scrolled"] as? NSNumber)?.boolValue ?? false
        out.url = m["u"] as? String ?? ""
        out.hidden = (m["h"] as? NSNumber)?.boolValue ?? false
        out.title = m["t"] as? String ?? ""
        var shown: [String: Any] = [:]
        var specIndex = 0
        for t in targets {
            switch t {
            case .selector(let label, _, _), .ref(let label, _, _):
                let isRef: Bool
                if case .ref = t { isRef = true } else { isRef = false }
                let p = specIndex < pts.count ? pts[specIndex] as? [String: Any] : nil
                specIndex += 1
                guard let p else {
                    throw CDPInputScript.ScriptError(message: isRef ? DOMRefs.staleMessage(label) : "no element matches \(label)")
                }
                if p["bad"] != nil { throw CDPInputScript.ScriptError(message: "bad CSS selector: \(label)") }
                let x = (p["x"] as? NSNumber)?.doubleValue ?? 0, y = (p["y"] as? NSNumber)?.doubleValue ?? 0
                guard x >= 0, y >= 0, x < vw, y < vh else {
                    let why = out.scrolled
                        ? " even after scrolling — the targets of one call must fit in one view; split the script" : ""
                    throw CDPInputScript.ScriptError(message: "\(label) is outside the viewport (at \(Int(x)),\(Int(y)); "
                        + "viewport \(Int(vw))×\(Int(vh)))\(why). Nothing was sent.")
                }
                out.points[t] = (x, y)
                if (p["covered"] as? NSNumber)?.boolValue == true { out.covered.append(label) }
                if shown.count < 30 { shown[label] = [Int(x.rounded()), Int(y.rounded())] }
            case .screen(let sx, let sy):
                // CSS px == screen points (the same transform query-dom uses).
                let x = sx - d("sx"), y = sy - d("sy") - insetY
                guard x >= 0, y >= 0, x < vw, y < vh else {
                    throw CDPInputScript.ScriptError(message: "screen point \(Int(sx)),\(Int(sy)) is outside the page's "
                        + "viewport — the tab's content starts at \(Int(d("sx"))),\(Int(d("sy") + insetY))")
                }
                out.points[t] = (x, y)
            default:
                break
            }
        }
        out.report = shown
        return out
    }

    /// `fill`: focus the element and select what it holds (JS — focus and
    /// selection are not input), then insert the value as trusted input. A
    /// <select> gets its option set directly. → nil, or why it couldn't.
    private static func prepareFill(_ t: CDPInputScript.Target, value: String,
                                    conn: any AgentDOM.CDPConn) async throws -> String? {
        let find: String
        switch t {
        case .ref(let r, _, _): find = "R.get(\(AgentDOM.jsLiteral(r)))"
        case .selector(let s, _, _): find = "document.querySelector(\(AgentDOM.jsLiteral(s)))"
        default: return "fill needs an element"
        }
        let js = """
        (function(){var R=\(DOMRefs.tableJS);var e=\(find);if(!e)return 'gone';\
        if(e.tagName==='SELECT'){var v=\(AgentDOM.jsLiteral(value)),o=Array.prototype.find.call(e.options,\
        function(x){return x.value===v||x.text.trim()===v;});if(!o)return 'nooption';e.value=o.value;\
        e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return 'select';}\
        e.focus();if(typeof e.select==='function'){e.select();}else if(e.isContentEditable){var g=document.createRange();\
        g.selectNodeContents(e);var s=getSelection();s.removeAllRanges();s.addRange(g);}\
        return (document.activeElement===e||e.contains(document.activeElement))?'ok':'nofocus';})()
        """
        let r = try await AgentDOM.rawEval(conn, expression: js) as? String
        switch r {
        case "ok": return nil
        case "select": return "select"
        case "gone":
            if case .ref(let ref, _, _) = t { return DOMRefs.staleMessage(ref) }
            return "the element is gone"
        case "nooption": return "the <select> has no option with that value or text"
        default: return "the element did not take focus (disabled, or not a field)"
        }
    }

    private static func point(_ t: CDPInputScript.Target, _ r: Resolved, last: Point) -> Point {
        switch t {
        case .viewport(let x, let y): return (x, y)
        case .last: return last
        case .between(let a, let b, let f):
            let p = point(a, r, last: last), q = point(b, r, last: last)
            return (p.x + (q.x - p.x) * f, p.y + (q.y - p.y) * f)
        default: return r.points[t] ?? last
        }
    }

    // MARK: - Run the timeline

    private static func execute(_ timeline: [CDPInputScript.Timed], steps: Int, conn: any AgentDOM.CDPConn,
                                keepAlive: Bool, via: String) async throws -> [String: Any] {
        let targets = CDPInputScript.selectors(in: timeline)
        var resolved = try await resolve(targets, conn: conn)
        // A fresh extension attach shows Chrome's "is debugging this browser"
        // banner, which makes the page shorter a frame or two LATER — after the
        // points above were measured. Re-measure if the viewport moved.
        if keepAlive {
            var height = resolved.viewportHeight
            var moved = false
            for _ in 0..<4 {
                try await Task.sleep(nanoseconds: 120_000_000)
                let r = try await conn.call("Runtime.evaluate", ["expression": "innerHeight", "returnByValue": true])
                let h = ((r["result"] as? [String: Any])?["value"] as? NSNumber)?.doubleValue ?? height
                if h == height { break }
                height = h
                moved = true
            }
            if moved { resolved = try await resolve(targets, conn: conn) }
        }

        var held = 0                                   // mouse buttons down (CDP bit mask)
        var heldKeys: [String: CDPInputScript.KeyDef] = [:]
        var last: Point = (0, 0)
        var late: [Double] = []
        late.reserveCapacity(timeline.count)
        // How late each held key / button went down: its release waits that
        // much longer, so a hold is measured from the real press (a press
        // queued behind a busy moment must not come out shorter).
        var pressLag: [String: Duration] = [:]
        func holdKey(_ p: CDPInputScript.Prim) -> String? {
            switch p {
            case .keyDown(let k, _, _), .keyUp(let k, _): return "k" + k.code
            case .mousePressed(_, let b, _, _), .mouseReleased(_, let b, _, _): return "b" + b.rawValue
            default: return nil
            }
        }

        func send(_ method: String, _ params: [String: Any]) async throws {
            _ = try await AgentDOM.withTimeout(5) { try await conn.call(method, params) }
        }
        func buttonName(_ mask: Int) -> String {
            mask & 1 != 0 ? "left" : mask & 2 != 0 ? "right" : mask & 4 != 0 ? "middle" : "none"
        }
        func keyParams(_ type: String, _ k: CDPInputScript.KeyDef, _ mods: Int) -> [String: Any] {
            var p: [String: Any] = ["type": type, "key": k.key, "code": k.code,
                                    "windowsVirtualKeyCode": k.vk, "modifiers": mods]
            if type == "keyDown", let text = k.text { p["text"] = text; p["unmodifiedText"] = text }
            return p
        }

        /// Release every key and button still down. → what was released.
        func releaseAll() async -> [String] {
            var names: [String] = []
            for k in heldKeys.values {
                try? await send("Input.dispatchKeyEvent", keyParams("keyUp", k, 0))
                names.append(k.key)
            }
            heldKeys.removeAll()
            for b in [CDPInputScript.MouseButton.left, .right, .middle] where held & b.mask != 0 {
                held &= ~b.mask
                try? await send("Input.dispatchMouseEvent", [
                    "type": "mouseReleased", "x": last.x, "y": last.y, "button": b.rawValue,
                    "buttons": held, "clickCount": 1])
                names.append("mouse " + b.rawValue)
            }
            return names
        }

        let clock = ContinuousClock()
        let start = clock.now
        var sent = 0
        do {
            for (index, ev) in timeline.enumerated() {
                var due = start + .microseconds(Int64(ev.atMs * 1000))
                let hk = holdKey(ev.prim)
                switch ev.prim {
                case .keyUp, .mouseReleased:
                    if let hk, let lag = pressLag.removeValue(forKey: hk) { due = due + lag }
                default: break
                }
                // Long gaps: the extension drops its debugger session after 8 s
                // idle, and re-attaching shows the debugging banner again, which
                // shifts the page under the resolved points. Keep it busy.
                while keepAlive, due - clock.now > .seconds(5) {
                    try await Task.sleep(for: .seconds(4))
                    try await send("Runtime.evaluate", ["expression": "0", "returnByValue": true])
                }
                if clock.now < due {
                    try await Task.sleep(until: due, tolerance: .microseconds(500), clock: .continuous)
                }
                let lag = clock.now - due
                late.append(Double(lag.components.seconds) * 1000 + Double(lag.components.attoseconds) / 1e15)
                switch ev.prim {
                case .keyDown, .mousePressed: if let hk { pressLag[hk] = lag }
                default: break
                }

                switch ev.prim {
                case .mousePressed(let t, let b, let count, let mods):
                    last = point(t, resolved, last: last)
                    held |= b.mask
                    try await send("Input.dispatchMouseEvent", [
                        "type": "mousePressed", "x": last.x, "y": last.y, "button": b.rawValue,
                        "buttons": held, "clickCount": count, "modifiers": mods])
                case .mouseReleased(let t, let b, let count, let mods):
                    last = point(t, resolved, last: last)
                    held &= ~b.mask
                    try await send("Input.dispatchMouseEvent", [
                        "type": "mouseReleased", "x": last.x, "y": last.y, "button": b.rawValue,
                        "buttons": held, "clickCount": count, "modifiers": mods])
                case .mouseMoved(let t, let mods):
                    last = point(t, resolved, last: last)
                    let params: [String: Any] = ["type": "mouseMoved", "x": last.x, "y": last.y,
                                                 "button": buttonName(held), "buttons": held, "modifiers": mods]
                    // Chrome acks a move only at the next frame. When a press,
                    // release or wheel comes next, that event flushes the move in
                    // order, so don't wait (see CDPConn.post) — waiting made every
                    // hovered click ~1 frame late. A move with nothing after it
                    // (a hover) is awaited, so it has landed when the call returns.
                    var flushedByNext = false
                    if index + 1 < timeline.count {
                        switch timeline[index + 1].prim {
                        case .mousePressed, .mouseReleased, .wheel: flushedByNext = true
                        default: break
                        }
                    }
                    if flushedByNext { try await conn.post("Input.dispatchMouseEvent", params) }
                    else { try await send("Input.dispatchMouseEvent", params) }
                case .wheel(let t, let dx, let dy, let mods):
                    last = point(t, resolved, last: last)
                    try await send("Input.dispatchMouseEvent", [
                        "type": "mouseWheel", "x": last.x, "y": last.y, "deltaX": dx, "deltaY": dy,
                        "modifiers": mods])
                case .keyDown(let k, let mods, let commands):
                    // A key that types text is a keyDown (keydown + keypress +
                    // input); with ⌘/⌃ held, or a key that types nothing, it's a
                    // rawKeyDown — what a real keyboard produces.
                    let type = (k.text != nil && mods & 6 == 0) ? "keyDown" : "rawKeyDown"
                    var p = keyParams(type, k, mods)
                    if !commands.isEmpty { p["commands"] = commands }
                    heldKeys[k.code] = k
                    try await send("Input.dispatchKeyEvent", p)
                case .keyUp(let k, let mods):
                    heldKeys[k.code] = nil
                    try await send("Input.dispatchKeyEvent", keyParams("keyUp", k, mods))
                case .insertText(let text):
                    try await send("Input.insertText", ["text": text])
                case .fill(let t, let value):
                    if let why = try await prepareFill(t, value: value, conn: conn) {
                        if why != "select" { throw CDPInputScript.ScriptError(message: "fill: \(why)") }
                    } else if value.isEmpty {
                        // Delete the selection: insertText("") does nothing.
                        let bs = CDPInputScript.KeyDef(key: "Backspace", code: "Backspace", vk: 8, text: nil)
                        try await send("Input.dispatchKeyEvent", keyParams("rawKeyDown", bs, 0))
                        try await send("Input.dispatchKeyEvent", keyParams("keyUp", bs, 0))
                    } else {
                        try await send("Input.insertText", ["text": value])
                    }
                }
                sent += 1
            }
        } catch {
            let step = sent < timeline.count ? timeline[sent].step : steps
            // A dialog blocks the page: a release would only wait on it too.
            if case AgentDOM.DOMError.dialog = error {
                let stillHeld = heldKeys.values.map(\.key) + (held != 0 ? ["mouse"] : [])
                throw CDPInputScript.ScriptError(message: "stopped at step \(step) after \(sent) of \(timeline.count) "
                    + "events: \(error.localizedDescription)"
                    + (stillHeld.isEmpty ? "" : " Still held in the page (release after answering): "
                        + stillHeld.joined(separator: ", ") + ".")
                    + " The step's own action may be what opened it.")
            }
            // Release whatever is still down, best effort, then report.
            _ = await releaseAll()
            throw CDPInputScript.ScriptError(message: "stopped at step \(step) after \(sent) of \(timeline.count) "
                + "events: \(error.localizedDescription). Held keys and buttons were released.")
        }

        // A keydown / down with no matching release would stay stuck in the
        // page after the call; each call starts and ends with nothing held.
        let leftDown = await releaseAll()
        let elapsed = clock.now - start
        // What the script changed on the page (the toolset's state report).
        var changes: [String] = []
        if let s = try? await AgentDOM.withTimeout(2, {
            try await AgentDOM.rawEval(conn, expression: "JSON.stringify({u:location.href,t:document.title})")
        }) as? String, let m = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
            let u = m["u"] as? String ?? "", t = m["t"] as? String ?? ""
            if !u.isEmpty, u != resolved.url { changes.append("the page is now \(u.prefix(200))") }
            else if t != resolved.title { changes.append("the page title is now \"\(t.prefix(80))\"") }
        }
        let sorted = late.sorted()
        func pct(_ q: Double) -> Double {
            sorted.isEmpty ? 0 : (sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] * 10).rounded() / 10
        }
        var out: [String: Any] = [
            "ok": true, "mode": "background", "via": via, "steps": steps, "events": sent,
            "duration_ms": Int(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15),
            "late_ms": ["p50": pct(0.5), "p95": pct(0.95), "max": pct(1.0)],
        ]
        if !resolved.report.isEmpty { out["resolved"] = resolved.report }
        if !changes.isEmpty { out["changes"] = changes }
        var notes: [String] = []
        if resolved.hidden {
            out["hidden_tab"] = true
            notes.append("the tab is hidden (not the visible tab of its window, or the window is minimized): Chrome "
                + "gives it no frames, so hover, wheel and drag may not land and moves arrive late — make it the "
                + "visible tab of a window on screen")
        }
        if resolved.scrolled {
            out["scrolled"] = true
            notes.append("a target was outside the view, so the page was scrolled to centre it first")
        }
        if !leftDown.isEmpty {
            out["released_at_end"] = leftDown
            notes.append("released at the end (pressed, never released): \(leftDown.joined(separator: ", "))")
        }
        if !resolved.covered.isEmpty {
            out["covered"] = resolved.covered
            notes.append("another element is on top at the point of: \(resolved.covered.prefix(5).joined(separator: ", ")) — "
                + "events go to the TOP element; pass {\"selector\":…,\"pos\":[fx,fy]} to aim at an uncovered part")
        }
        if pct(1.0) > 25 {
            notes.append("some events were up to \(Int(pct(1.0))) ms late — each event waits for the page to "
                + "accept the one before; a busy page or a hidden tab slows that down")
        }
        if !notes.isEmpty { out["note"] = notes.joined(separator: ". ") }
        return out
    }
}
