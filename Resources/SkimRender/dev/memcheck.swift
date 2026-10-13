// Measures the memory of the Claude/Codex tab page: a real WKWebView, fed the way ClaudeChatController
// feeds it (JSON batches through AgentChat.receive). Prints the page process after each phase:
// footprint now and peak, DOM size, graphics (layers, tiles) and WebKit Malloc (JS heap, DOM, layout).
//
//   swiftc -O Resources/SkimRender/dev/memcheck.swift -o /tmp/memcheck && /tmp/memcheck
//
// Phases, each optional (environment variables):
//   HIST=<file>    a resume history message, as the sidecar sends it (memcheck-history.mjs makes one)
//   LIVE=<jsonl>   a whole Claude transcript fed live, untrimmed (a long-running tab)
//   REPLIES=4 MD=<file> MDLEN=24000   streamed replies, ~30 characters per delta
//   SHOTS=20       screenshot tool results (a 2000×1250 PNG)     OUTS=150   26 KB Bash outputs
// Options:
//   LIVEMEM=1      force a GC and a scavenge before each reading (live memory only; steadier numbers).
//                  It posts org.WebKit.lowMemory, so other WebKit apps drop caches too.
//   SKIM=<dir>     another SkimRender copy (compare before and after)   CSS=<rules>   extra CSS
//   NOIMG=1 / ONLY=text|thinking|tools / CUTOUT=n   trim what LIVE feeds    CHECK=1   page errors and checks
//   COUNTS=1       timers and animations still running (counts.js beside this file is not needed)
// The last phase hides the web view, as a background tab; the real app also purges graphics then.
import AppKit
import WebKit

let R = ProcessInfo.processInfo.environment["SKIM"] ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let work = FileManager.default.temporaryDirectory.appendingPathComponent("skim-memcheck")
let env = ProcessInfo.processInfo.environment
let label = env["LABEL"] ?? "run"

func sh(_ cmd: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", cmd]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
func allWeb() -> Set<pid_t> { Set(sh("pgrep -f com.apple.WebKit.WebContent").split(separator: "\n").compactMap { pid_t($0) }) }
let preexisting = allWeb()
func webPids() -> [pid_t] { Array(allWeb().subtracting(preexisting)) }
func mb(_ pid: pid_t) -> (Double, Double) {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
    if ok == 0 { return (Double(info.ri_phys_footprint) / 1048576, Double(info.ri_lifetime_max_phys_footprint) / 1048576) }
    let out = sh("vmmap --summary \(pid) 2>/dev/null | grep -E '^Physical footprint'")
    func val(_ key: String) -> Double {
        guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix(key) }) else { return 0 }
        let s = line.split(separator: " ").last.map(String.init) ?? ""
        let n = Double(s.dropLast()) ?? 0
        switch s.last { case "G": return n * 1024; case "K": return n / 1024; default: return n }
    }
    return (val("Physical footprint:"), val("Physical footprint (peak):"))
}

final class Sampler {
    var maxG = 0.0, maxM = 0.0, maxT = 0.0, maxJS = 0.0; let q = DispatchQueue(label: "s"); var on = true
    func parse(_ s: String) -> Double { let p = s.split(separator: " "); guard p.count >= 2, let n = Double(p[0]) else { return 0 }
        switch p[1] { case "GB": return n * 1024; case "KB": return n / 1024; case "B": return 0; default: return n } }
    func start() { q.async { while self.on { if let pid = webPids().first {
        let out = sh("footprint -p \(pid) 2>/dev/null")
        for line in out.split(separator: "\n") { let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasSuffix("(graphics)") { self.maxG = max(self.maxG, self.parse(l)) }
            if l.hasSuffix("WebKit Malloc") { self.maxM = max(self.maxM, self.parse(l)) }
            if l.hasSuffix("TOTAL") { self.maxT = max(self.maxT, self.parse(l)) } } }
        usleep(250_000) } } }
    func take() -> String { q.sync { let s = String(format: "sampled max: total %.0f gfx %.0f malloc %.0f", maxT, maxG, maxM); maxG = 0; maxM = 0; maxT = 0; return s } }
}
let sampler = Sampler()
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    var lastState: Any?
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        if let b = m.body as? [String: Any], let a = b["action"] as? [String: Any], a["type"] as? String == "state" { lastState = a }
        replyHandler(nil, nil)
    }
}
let retentionJS = """
(() => { if (!window.__rs) { window.__rs = new Set(); const r = AgentEvents.reduce; AgentEvents.reduce = (s, e) => { window.__rs.add(s); return r(s, e); }; } })()
"""
let retentionSumJS = """
(() => { let n = 0; for (const s of (window.__rs || [])) n += JSON.stringify({ t: [...s.tools.values()], s: [...s.surfaces.values()], m: [...s.media.values()], d: [...s.turnDiffs.values()], p: [...s.plans.values()] }).length; return (n / 1e6).toFixed(1); })()
"""
let bridge = Bridge()
let countsJS = """
JSON.stringify({ intervals: __iv.size, anims: document.getAnimations().length, rows: document.querySelectorAll('.ck-row').length,
  kinds: Object.entries(document.getAnimations().reduce((m, a) => { const t = a.effect && a.effect.target; const k = (a.animationName || a.constructor.name) + ' @' + (t ? String(t.className) : '?') + ' ' + a.playState; m[k] = (m[k] || 0) + 1; return m; }, {})).sort((x, y) => y[1] - x[1]).slice(0, 12) })
"""
final class H: NSObject, WKNavigationDelegate {
    let web: WKWebView; let window: NSWindow
    var loaded: CheckedContinuation<Void, Never>?
    override init() {
        let c = WKWebViewConfiguration()
        for k in ["hiddenPageDOMTimerThrottlingEnabled", "hiddenPageDOMTimerThrottlingAutoIncreases", "pageVisibilityBasedProcessSuppressionEnabled"] { c.preferences.setValue(false, forKey: k) }
        c.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "skim")
        c.userContentController.addUserScript(WKUserScript(source: "window.__errors = []; window.addEventListener('error', e => __errors.push(e.message)); const ce = console.error; console.error = (...a) => { __errors.push(a.map(String).join(' ')); ce(...a); };", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        c.userContentController.addUserScript(WKUserScript(source: "window.__iv = new Set(); const si = setInterval, ci = clearInterval; window.setInterval = (f, ms, ...a) => { const id = si(f, ms, ...a); __iv.add(id); return id; }; window.clearInterval = id => { __iv.delete(id); ci(id); };", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 900), configuration: c)
        window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.contentView = web; window.alphaValue = 0.01; window.ignoresMouseEvents = true; window.level = .screenSaver; window.orderFrontRegardless()
        web.navigationDelegate = self
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { loaded?.resume(); loaded = nil }
    @MainActor func js(_ s: String) async { _ = try? await web.evaluateJavaScript(s) }
    @MainActor func receive(_ lines: [String]) async {
        if env["RECV"] != "src" {
            _ = try? await web.callAsyncJavaScript("AgentChat.receive(JSON.parse(b), 'main')", arguments: ["b": "[" + lines.joined(separator: ",") + "]"], in: nil, contentWorld: .page)
        } else { await js("AgentChat.receive([\(lines.joined(separator: ","))], \"main\"); 0") }
    }
    func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }
    @MainActor func report(_ phase: String) async {
        await sleep(4)
        if env["LIVEMEM"] == "1" { _ = sh("notifyutil -p org.WebKit.lowMemory"); await sleep(5) }
        let pids = webPids()
        let v = pids.map(mb).reduce((0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1) }
        let dom = (try? await web.evaluateJavaScript("document.getElementsByTagName('*').length")) as? Int ?? -1
        if env["COUNTS"] == "1", let c = try? await web.evaluateJavaScript(countsJS) { print(c) }
        let fp = pids.first.map { sh("footprint -p \($0) 2>/dev/null") } ?? ""
        func cat(_ suffix: String) -> String { fp.split(separator: "\n").first(where: { $0.hasSuffix(suffix) }).map { $0.split(separator: " ", omittingEmptySubsequences: true).prefix(2).joined(separator: " ") } ?? "0" }
        let parts = ["gfx " + cat("(unmapped) (graphics)"), "wkmalloc " + cat("WebKit Malloc")]
        print(String(format: "%@ | %-28@ | now %6.0f MB | peak %6.0f MB | DOM %5d | %@", label, phase, v.0, v.1, dom, parts.joined(separator: " / ")))
        fflush(stdout)
    }
}

/// A screenshot-sized PNG (about 1 MB): coloured boxes and lines of text.
func testImage() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 1250, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    srand48(7)
    for _ in 0..<600 { NSColor(red: drand48(), green: drand48(), blue: drand48(), alpha: 1).setFill(); NSRect(x: drand48() * 2000, y: drand48() * 1250, width: drand48() * 300, height: drand48() * 120).fill() }
    for y in stride(from: 0, to: 1250, by: 18) { ("Lorem ipsum \(y) dolor sit amet " + String(repeating: "x\(y % 97) ", count: 30)).draw(at: NSPoint(x: 10, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: 13)]) }
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

func j(_ o: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }
func sdk(_ msg: [String: Any]) -> String { j(["type": "sdk", "msg": msg]) }

@MainActor func run() async {
    let h = H()
    let scripts = ["vendor/marked.min.js", "vendor/purify.min.js", "vendor/highlight.min.js", "vendor/hljs-dart.min.js", "skim-classify.js", "skim-render.js",
                   "agent-events.js", "agent-claude.js", "agent-codex.js", "chat.js"].map { "<script src=\"file://\(R)/\($0)\"></script>" }.joined()
    let html = """
    <!DOCTYPE html><html><head><meta charset="utf-8"><link rel="stylesheet" href="file://\(R)/fonts.css"><link rel="stylesheet" href="file://\(R)/skim.css"><link rel="stylesheet" href="file://\(R)/chat.css">\(scripts)</head>
    <body><script>AgentChat.boot({cwd:'/tmp', home:'\(NSHomeDirectory())', intro:'', agent:'claude', voice:true});</script></body></html>
    """
    try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let pageURL = work.appendingPathComponent("page.html")
    try! html.write(to: pageURL, atomically: true, encoding: .utf8)
    await withCheckedContinuation { c in h.loaded = c; h.web.loadFileURL(pageURL, allowingReadAccessTo: URL(fileURLWithPath: "/")) }
    await h.receive([sdk(["type": "system", "subtype": "init", "session_id": "S1", "model": "claude-opus-5-5", "permissionMode": "default", "cwd": "/tmp"])])
    if let css = env["CSS"] { await h.js("document.head.append(Object.assign(document.createElement('style'), {textContent: \(j([css]))[0]})); 0") }
    await h.report("0 boot")

    // 1. Resume history (the sidecar's trimmed payload).
    if let hist = try? String(contentsOfFile: env["HIST"] ?? "-", encoding: .utf8) {
        await h.receive([hist]); await h.report("1 history")
    }

    // 1b. A real session, fed live (full messages, no trimming), as a long-running tab gets it.
    if let live = env["LIVE"], let text = try? String(contentsOfFile: live, encoding: .utf8) {
        var batch: [String] = []; var n = 0
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = o["type"] as? String, t == "user" || t == "assistant", o["isSidechain"] as? Bool != true else { continue }
            var m = o; m.removeValue(forKey: "toolUseResult")
            if let only = env["ONLY"], var msg = m["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] {
                let keep: (String) -> Bool = { t in only == "text" ? ["text"].contains(t) : only == "thinking" ? t == "thinking" : ["tool_use", "tool_result"].contains(t) }
                let kept = content.filter { keep($0["type"] as? String ?? "") }
                if kept.isEmpty { continue }
                msg["content"] = kept; m["message"] = msg
            }
            if env["NOIMG"] == "1" || env["CUTOUT"] != nil, var msg = m["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] {
                let cutN = Int(env["CUTOUT"] ?? "") ?? Int.max
                msg["content"] = content.map { c -> [String: Any] in
                    guard c["type"] as? String == "tool_result" else { return c }
                    var c = c
                    if let s = c["content"] as? String { c["content"] = String(s.prefix(cutN)) }
                    if let arr = c["content"] as? [[String: Any]] {
                        c["content"] = arr.compactMap { b -> [String: Any]? in
                            if b["type"] as? String == "image" { return env["NOIMG"] == "1" ? ["type": "text", "text": "[img]"] : b }
                            if let t = b["text"] as? String { var b = b; b["text"] = String(t.prefix(cutN)); return b }
                            return b }
                    }
                    return c }
                m["message"] = msg
            }
            batch.append(sdk(m)); n += 1
            if t == "assistant", let msg = o["message"] as? [String: Any], (msg["stop_reason"] as? String) == "end_turn" {
                batch.append(sdk(["type": "result", "subtype": "success", "num_turns": 1, "duration_ms": 1000]))
            }
            if batch.count >= 20 { await h.receive(batch); batch = [] }
        }
        if !batch.isEmpty { await h.receive(batch) }
        await h.report("1b live \(n) msgs")
    }
    // 2. Streamed replies, ~30 characters per delta, one delivery per frame.
    let md = (try? String(contentsOfFile: env["MD"] ?? R + "/README.md", encoding: .utf8)) ?? ""
    let text = String(md.prefix(Int(env["MDLEN"] ?? "24000") ?? 24000))
    let replies = Int(env["REPLIES"] ?? "4") ?? 4
    for r in 0..<replies {
        let mid = "msg_\(r)"
        await h.receive([sdk(["type": "stream_event", "event": ["type": "message_start", "message": ["id": mid]]]),
                         sdk(["type": "stream_event", "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]]])])
        var i = text.startIndex
        while i < text.endIndex {
            let e = text.index(i, offsetBy: 30, limitedBy: text.endIndex) ?? text.endIndex
            await h.receive([sdk(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": String(text[i..<e])]]])])
            try? await Task.sleep(nanoseconds: 8_000_000)
            i = e
        }
        await h.receive([sdk(["type": "stream_event", "event": ["type": "content_block_stop", "index": 0]]),
                         sdk(["type": "assistant", "uuid": "u\(r)", "message": ["id": mid, "content": [["type": "text", "text": text]]]]),
                         sdk(["type": "result", "subtype": "success", "num_turns": 1, "duration_ms": 1000])])
    }
    await h.report("2 streamed \(replies)×\(text.count / 1000)k")

    // 3. Screenshot tool results.
    let png = testImage().base64EncodedString()
    let shots = Int(env["SHOTS"] ?? "20") ?? 20
    for s in 0..<shots {
        let id = "toolu_img_\(s)"
        await h.receive([sdk(["type": "assistant", "message": ["id": "mi\(s)", "content": [["type": "tool_use", "id": id, "name": "Read", "input": ["file_path": "/tmp/shot.png"]]]]]),
                         sdk(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png]]]]]]])])
    }
    await h.report("3 \(shots) screenshots \(png.count / 1_000_000)MB b64")

    // 4. Big tool outputs (Bash).
    let outs = Int(env["OUTS"] ?? "150") ?? 150
    let blob = String(repeating: "drwxr-xr-x  12 mac staff  384 Oct  7 12:00 some-directory-name\n", count: 400)   // ~26 KB
    for s in 0..<outs {
        let id = "toolu_bash_\(s)"
        await h.receive([sdk(["type": "assistant", "message": ["id": "mb\(s)", "content": [["type": "tool_use", "id": id, "name": "Bash", "input": ["command": "ls -la \(s)"]]]]]),
                         sdk(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": blob]]]])])
    }
    await h.report("4 \(outs) bash outputs 26KB")

    // 4b. Codex-shaped canonical events: each turn keeps a big tool output, a turn surface, a session
    // surface, a media snapshot and a diff. The reducer should prune the turn-scoped ones at turn.end.
    if let n = Int(env["V1"] ?? "") {
        let outSize = Int(env["V1OUT"] ?? "1500000") ?? 1_500_000
        await h.js(retentionJS)
        for t in 0..<n {
            let th = "thread-1", turn = "turn-\(t)", tool = "tool-\(t)"
            // Unique content per turn: repeated identical strings can share backing stores in JSC.
            let uni = String(UnicodeScalar(65 + t % 26)!)
            let payload = String(repeating: uni, count: 16000)
            let output = String(repeating: uni, count: outSize)
            var batch: [String] = []
            func v1(_ type: String, _ fields: [String: Any]) {
                var o: [String: Any] = ["v": 1, "agent": "codex", "t": 0, "type": type]
                o.merge(fields) { _, b in b }
                batch.append(j(o))
            }
            v1("turn.start", ["threadId": th, "turnId": turn])
            v1("tool.start", ["id": tool, "name": "Bash", "input": ["command": "cat big-\(t)"]])
            v1("tool.result", ["id": tool, "name": "Bash", "output": output, "isError": false])
            v1("surface.snapshot", ["id": "turn-surf-\(t)", "surface": "mcp", "title": "MCP", "placement": "turn", "threadId": th, "turnId": turn, "ownerId": tool, "data": ["item": ["text": payload, "status": "completed"]]])
            v1("surface.snapshot", ["id": "sess", "surface": "account", "title": "Account", "placement": "session", "threadId": th, "turnId": turn, "data": ["status": "signedIn", "note": payload]])
            v1("turn.diff.snapshot", ["threadId": th, "turnId": turn, "diff": "diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n"])
            v1("media.snapshot", ["id": "media-\(t)", "threadId": th, "turnId": turn, "url": "blob:media-\(t)", "caption": "shot"])
            v1("turn.end", ["threadId": th, "turnId": turn, "status": "success"])
            await h.receive(batch)
        }
        await h.report("4b v1 \(n) turns")
        if let r = try? await h.web.evaluateJavaScript(retentionSumJS) { print("\(label) | 4b reducer retention \(r) MB") }
    }

    await h.sleep(6)
    await h.report("5 settled")
    if env["CHECK"] == "1" {
        let r = try? await h.web.callAsyncJavaScript("""
            const img = document.querySelector('.ck-media img');
            let loaded = null;
            if (img) { const t = new Image(); t.src = img.src; try { await t.decode(); loaded = t.naturalWidth + 'x' + t.naturalHeight; } catch (e) { loaded = 'fail ' + e; } }
            return JSON.stringify({ errors: __errors.slice(0, 5), nErrors: __errors.length, img: img ? img.src.slice(0, 12) : null, loaded,
              fresh: document.querySelectorAll('.sk-fresh').length, cv: document.documentElement.classList.contains('ck-cv') });
            """, arguments: [:], in: nil, contentWorld: .page)
        print("CHECK", r ?? "nil", "state:", String(decoding: try! JSONSerialization.data(withJSONObject: bridge.lastState ?? [:]), as: UTF8.self))
        await h.receive([sdk(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "busy1"]]]),
                         sdk(["type": "assistant", "message": ["id": "busy2", "content": [["type": "tool_use", "id": "toolu_cron", "name": "CronCreate", "input": ["cron": "*/5 * * * *"]]]]])])
        await h.sleep(1)
        print("BUSY state:", String(decoding: try! JSONSerialization.data(withJSONObject: bridge.lastState ?? [:]), as: UTF8.self))
        await h.receive([sdk(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_cron", "content": "ok"]]]]),
                         sdk(["type": "result", "subtype": "success", "num_turns": 1, "duration_ms": 10])])
        await h.sleep(1)
        print("AFTER CronCreate state:", String(decoding: try! JSONSerialization.data(withJSONObject: bridge.lastState ?? [:]), as: UTF8.self))
    }
    let holder = NSView(frame: h.web.frame); h.window.contentView = holder; holder.addSubview(h.web); h.web.isHidden = true
    await h.sleep(15)
    await h.report("6 hidden")
    if env["HOLD"] != nil, let pid = webPids().first {
        print(sh("vmmap --summary \(pid) 2>/dev/null | grep -E '^(JS|WebKit|Malloc|IOSurface|IOAccel|CoreAnimation|Image|Dispatch|TOTAL, minus)' | awk '{ if ($0 ~ /TOTAL/) print; else if ($0 ~ /[0-9]/) print }' | cut -c1-110"))
        print(sh("footprint -p \(pid) 2>/dev/null | head -40"))
    }
    exit(0)
}
NSApplication.shared.setActivationPolicy(.accessory)
Task { @MainActor in await run() }
NSApplication.shared.run()
