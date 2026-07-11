import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [TerminalWindowController] = []
    private var hotKey: HotKey!
    private let statusItem = StatusItemController()
    private let settingsWC = SettingsWindowController()
    private let switcher = SessionSwitcherController()
    private let ruler = RulerController()

    /// Drives the menu-bar fleet summary (working / waiting counts across
    /// every terminal tab in every window). Strong reference — a scheduled
    /// Timer is only retained by its run loop while valid.
    private var fleetSummaryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Loopback relay for remote devtools awareness: external pages that
        // include http://127.0.0.1:7777/floaty.js stream console/network
        // events into agent-tailable logs under App Support/FloatyTerm/Devtools.
        DevtoolsRelay.shared.start()
        // Shell shim (`ftdiff a b`) POSTs to the relay's /diff route; open the
        // resulting side-by-side diff in the current (or a fresh) window.
        DevtoolsRelay.shared.onOpenDiff = { [weak self] left, right in
            self?.compareFilesInCurrentWindow(left: left, right: right)
        }

        // Agent-host control routes: the `floaty` CLI POSTs to /agent/* on the
        // relay and FloatyTerm (holding the Accessibility + Screen Recording
        // grants) drives the OS — input injection (Layer B / AgentInput),
        // window capture (Layer C / AgentCapture), and CDP element targeting
        // (Layer A / AgentDOM). All closures run on the main actor.
        DevtoolsRelay.shared.onAgentClick = { [weak self] b in
            self?.performAction("click", b) ?? ["error": "no self"]
        }
        DevtoolsRelay.shared.onAgentMove = { [weak self] b in
            guard let self, let p = self.point(b) else { return ["error": "expected {x,y}"] }
            let ok = AgentInput.move(to: p, pacing: self.pacing(b),
                                     target: self.target(b), targetPID: self.targetPID(b))
            return ok ? ["ok": true] : self.inputFailure("move", b)
        }
        DevtoolsRelay.shared.onAgentDrag = { [weak self] b in
            self?.performAction("drag", b) ?? ["error": "no self"]
        }
        DevtoolsRelay.shared.onAgentScroll = { [weak self] b in
            self?.performAction("scroll", b) ?? ["error": "no self"]
        }
        DevtoolsRelay.shared.onAgentType = { [weak self] b in
            guard let self, let text = b["text"] as? String else { return ["error": "expected {text}"] }
            // --human sessions get overlaid replay controls (play/pause/stop/
            // speed) on the terminal window; --no-controls opts out.
            let noControls = (b["no_controls"] as? NSNumber)?.boolValue ?? false
            let r = await AgentInput.type(text, pacing: self.pacing(b),
                                          target: self.target(b), targetPID: self.targetPID(b),
                                          showControls: !noControls)
            guard r.ok else { return self.inputFailure("type", b) }
            var out: [String: Any] = ["ok": true, "typed": r.typed]
            if r.stopped { out["stopped"] = true; out["total"] = text.count }
            return out
        }
        DevtoolsRelay.shared.onAgentKey = { [weak self] b in
            self?.performAction("key", b) ?? ["error": "no self"]
        }
        DevtoolsRelay.shared.onAgentCapture = { b in
            let window = b["window"] as? String
            var windowID = (b["window_id"] as? NSNumber)?.uint32Value
            // Accept --pid like the other targeting verbs (som/query-ax/read-text/
            // raise/focused all take it) — resolve to that process's largest
            // on-screen window. Removes a needless "capture rejects --pid" stumble.
            if windowID == nil, let pid = (b["pid"] as? NSNumber).map({ pid_t($0.intValue) }) {
                var win = AgentCapture.listWindows().filter({ $0.pid == pid }).max(by: { $0.area < $1.area })
                if win == nil {
                    // Default for --pid: auto-raise an off-Space window (Stage Manager
                    // / other desktop — usually a stray click shoved it there) instead
                    // of erroring with "run raise". Surfaces it AND keeps the agent's
                    // in-flight target in front. No-op if it's already on-screen.
                    _ = await AgentAX.ensureOnScreen(pid: pid)
                    win = AgentCapture.listWindows().filter({ $0.pid == pid }).max(by: { $0.area < $1.area })
                }
                if let win { windowID = win.id }
                else { return ["error": "no window for pid \(pid) (it may have no open window — ⌘N in the app)"] }
            }
            guard window != nil || windowID != nil else {
                return ["error": "expected {window}, {window_id}, or {pid} (see `floaty list-windows`)"]
            }
            let ocr = (b["ocr"] as? NSNumber)?.boolValue ?? false
            let fullRes = (b["full_res"] as? NSNumber)?.boolValue ?? false
            var region: CGRect? = nil
            if let rs = b["region"] as? String {
                guard let r = Self.parseRegion(rs) else {
                    return ["error": "bad --region \"\(rs)\" — expected x,y,WxH in GLOBAL screen points, e.g. 100,200,400x300"]
                }
                region = r
            }
            do {
                let ifChanged = (b["if_changed"] as? NSNumber)?.boolValue ?? false
                let r = try await AgentCapture.captureWindow(named: window, windowID: windowID,
                                                             ocr: ocr, region: region, fullRes: fullRes,
                                                             ifChanged: ifChanged)
                // --if-changed short-circuit: same pixels as last time → one
                // line, no image, and the previous frame stays valid.
                if r.unchanged {
                    return ["ok": true, "unchanged": true, "screen_hash": r.screenHash,
                            "note": "pixels match the previous capture of this target — "
                                + "your prior screenshot and frame_id are still valid"]
                }
                guard let f = r.frame else { return ["error": "capture returned no frame"] }
                // The capture frame: everything click-in-frame needs to map an
                // image-pixel coordinate back to a global screen point.
                var out: [String: Any] = [
                    "ok": true, "path": r.imagePath, "frame_id": f.id,
                    "origin_x": f.origin.x, "origin_y": f.origin.y,
                    "width": f.size.width, "height": f.size.height, "scale": f.scale,
                    "image_width": f.imageWidth, "image_height": f.imageHeight,
                    "screen_hash": r.screenHash,
                ]
                if ifChanged { out["changed"] = true }
                if let t = r.textPath { out["text_path"] = t }          // OCR found text
                else if ocr { out["note"] = "no text recognized in the capture" }
                return out
            } catch { return ["error": error.localizedDescription] }
        }
        // capture --wait-change: long-poll until the window's pixels change
        // (hash-only polls, ~0.6s apart — nothing saved while waiting), then
        // return ONE fresh capture of the new state. Replaces the agent-side
        // screenshot-poll loop during page loads / long operations: one call,
        // one image, instead of N captures burned while nothing changed.
        DevtoolsRelay.shared.onAgentCaptureWait = { b, reply in
            Task { @MainActor in
                let window = b["window"] as? String
                var windowID = (b["window_id"] as? NSNumber)?.uint32Value
                if windowID == nil, let pid = (b["pid"] as? NSNumber).map({ pid_t($0.intValue) }) {
                    var win = AgentCapture.listWindows().filter({ $0.pid == pid }).max(by: { $0.area < $1.area })
                    if win == nil {
                        _ = await AgentAX.ensureOnScreen(pid: pid)
                        win = AgentCapture.listWindows().filter({ $0.pid == pid }).max(by: { $0.area < $1.area })
                    }
                    if let win { windowID = win.id }
                    else { reply(["error": "no window for pid \(pid) (it may have no open window — ⌘N in the app)"]); return }
                }
                if windowID == nil, let window, let win = AgentCapture.bestMatch(named: window) {
                    windowID = win.id
                }
                guard let wid = windowID else {
                    reply(["error": "expected {window}, {window_id}, or {pid} (see `floaty list-windows`)"]); return
                }
                var region: CGRect? = nil
                if let rs = b["region"] as? String {
                    guard let r = Self.parseRegion(rs) else {
                        reply(["error": "bad --region \"\(rs)\" — expected x,y,WxH in GLOBAL screen points"]); return
                    }
                    region = r
                }
                let timeout = min(max((b["timeout"] as? NSNumber)?.doubleValue ?? 20, 1), 120)
                do {
                    // Explicit --region → strict comparison: the 8×8 hash grid
                    // covers just that rect, so a 1-bit flip is real motion
                    // (a whole-window hash needs the 3-bit noise allowance).
                    let tol = region != nil ? 0 : 3
                    let baseline = try await AgentCapture.hashWindow(windowID: wid, region: region)
                    let start = Date()
                    while Date().timeIntervalSince(start) < timeout {
                        try await Task.sleep(nanoseconds: 600_000_000)
                        let now = try await AgentCapture.hashWindow(windowID: wid, region: region)
                        guard !AgentPerception.isUnchanged(baseline, now, tolerance: tol) else { continue }
                        // Changed — return one fresh capture of the NEW state.
                        let r = try await AgentCapture.captureWindow(named: window, windowID: wid,
                                                                     region: region)
                        guard let f = r.frame else { reply(["error": "capture returned no frame"]); return }
                        reply(["ok": true, "changed": true,
                               "waited_ms": Int(Date().timeIntervalSince(start) * 1000),
                               "path": r.imagePath, "frame_id": f.id,
                               "origin_x": f.origin.x, "origin_y": f.origin.y,
                               "width": f.size.width, "height": f.size.height,
                               "image_width": f.imageWidth, "image_height": f.imageHeight,
                               "screen_hash": r.screenHash])
                        return
                    }
                    reply(["ok": true, "changed": false,
                           "waited_ms": Int(Date().timeIntervalSince(start) * 1000),
                           "screen_hash": baseline,
                           "note": "no visible change within \(Int(timeout))s — the screen still looks the same; no image returned"])
                } catch { reply(["error": error.localizedDescription]) }
            }
        }
        // click/drag/key/scroll --until-change / --settle: "act to an edge".
        // The model declares one exact action plus a pixel edge, and the host
        // runs the deterministic middle of the loop that used to burn a model
        // round trip per iteration (drag → capture → drag → capture …):
        //   --until-change  repeat the action verbatim until the watched
        //                   pixels differ from the pre-loop baseline
        //   --settle        after acting (or after the edge fires), wait for
        //                   the pixels to hold still before the final capture,
        //                   so the returned image is post-animation
        //   --watch x,y,WxH the sensor rect (global points). Contract: pick a
        //                   rect that only changes when the goal state arrives.
        //                   Explicit rects compare strictly (any bit = change);
        //                   whole windows keep the 3-bit noise allowance.
        // The host never invents or adjusts action parameters — it repeats the
        // given action and reports the edge. Change → one fresh capture; no
        // change → no image and the prior frame stays valid.
        DevtoolsRelay.shared.onAgentActUntil = { [weak self] b, reply in
            Task { @MainActor in
                guard let self else { reply(["error": "no self"]); return }
                let action = b["_action"] as? String ?? ""
                guard let wid = await self.resolveObservedWindow(b) else {
                    reply(["error": "\(action) --until-change/--settle needs a window to watch — pass --pid, --window-id, --window, or --target"]); return
                }
                var watch: CGRect? = nil
                if let ws = b["watch"] as? String {
                    guard let r = Self.parseRegion(ws) else {
                        reply(["error": "bad --watch \"\(ws)\" — expected x,y,WxH in GLOBAL screen points"]); return
                    }
                    watch = r
                }
                let untilChange = (b["until_change"] as? NSNumber)?.boolValue ?? false
                let settle = (b["settle"] as? NSNumber)?.boolValue ?? false
                let every = min(max((b["every"] as? NSNumber)?.doubleValue ?? 0.6, 0.15), 5)
                let maxIters = untilChange ? min(max((b["max"] as? NSNumber)?.intValue ?? 10, 1), 25) : 1
                let timeout = min(max((b["timeout"] as? NSNumber)?.doubleValue ?? 20, 1), 120)
                let tol = watch != nil ? 0 : 3
                do {
                    let baseline = try await AgentCapture.hashWindow(windowID: wid, region: watch)
                    let start = Date()
                    var iterations = 0
                    var lastHash = baseline
                    var edge = false
                    repeat {
                        let r = self.performAction(action, b)
                        if r["error"] != nil {
                            var out = r; out["iterations"] = iterations
                            reply(out); return
                        }
                        iterations += 1
                        try await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
                        lastHash = try await AgentCapture.hashWindow(windowID: wid, region: watch)
                        if !AgentPerception.isUnchanged(baseline, lastHash, tolerance: tol) {
                            edge = true; break
                        }
                    } while untilChange && iterations < maxIters
                        && Date().timeIntervalSince(start) < timeout
                    var settled = false
                    if settle {
                        // Stillness = two consecutive equal polls (~0.8s quiet).
                        var prev = lastHash, stable = 0
                        let settleStart = Date()
                        while Date().timeIntervalSince(settleStart) < 10 {
                            try await Task.sleep(nanoseconds: 400_000_000)
                            let now = try await AgentCapture.hashWindow(windowID: wid, region: watch)
                            stable = AgentPerception.isUnchanged(prev, now, tolerance: tol) ? stable + 1 : 0
                            prev = now
                            if stable >= 2 { settled = true; break }
                        }
                        lastHash = prev
                        edge = edge || !AgentPerception.isUnchanged(baseline, lastHash, tolerance: tol)
                    }
                    let waitedMs = Int(Date().timeIntervalSince(start) * 1000)
                    if edge {
                        // Edge reached — return one fresh capture of the new
                        // state (full window: the watch rect is a sensor, not
                        // the observation).
                        let r = try await AgentCapture.captureWindow(named: nil, windowID: wid)
                        guard let f = r.frame else { reply(["error": "capture returned no frame"]); return }
                        var out: [String: Any] = [
                            "ok": true, "changed": true, "iterations": iterations,
                            "waited_ms": waitedMs, "path": r.imagePath, "frame_id": f.id,
                            "origin_x": f.origin.x, "origin_y": f.origin.y,
                            "width": f.size.width, "height": f.size.height,
                            "image_width": f.imageWidth, "image_height": f.imageHeight,
                            "screen_hash": r.screenHash,
                        ]
                        if settle { out["settled"] = settled }
                        reply(out)
                    } else {
                        // The action DID run — only the change detection came up
                        // empty. On a full-window hash that can be blindness, not
                        // stasis (a selection highlight moves ~0 of 64 bits —
                        // seen live), so say so rather than reading as failure.
                        let caveat = watch == nil
                            ? " at coarse full-window granularity — subtle changes (a selection, a highlight) "
                                + "can be invisible to it; pass --watch \"x,y,WxH\" on the area that should "
                                + "change, or verify with capture --region"
                            : " in the watched rect"
                        reply(["ok": true, "changed": false, "iterations": iterations,
                               "waited_ms": waitedMs, "screen_hash": lastHash,
                               "note": "performed \(action) ×\(iterations); no change detected\(caveat). "
                                   + "No image returned — your prior frame is still valid"])
                    }
                } catch { reply(["error": error.localizedDescription]) }
            }
        }
        // run: execute a pre-compiled LINEAR plan host-side — the model's motor
        // program. Each step = one actuator call (repeated verbatim on retry;
        // the host never invents or adjusts parameters) + an expected-outcome
        // checkpoint resolved on the perception ladder: AX predicate
        // (appears/disappears — resolved FRESH at execution time, never a
        // stored mark id) or strict-hashed watch rect (canvas apps, where AX
        // and full-window hashes are both blind) or pixel stillness (settle).
        // The first divergence stops the run loudly with a state bundle; a
        // success reply carries only the endgame (final capture + aggregates).
        // Per-step forensics land in calls.ndjson as route "run.step" — free
        // until someone greps them. No branching by design: a host that picks
        // paths on proxy predicates executes confidently in the wrong world;
        // anything unexpected must be an EXIT back to the model, not a guess.
        DevtoolsRelay.shared.onAgentRun = { [weak self] b, reply in
            Task { @MainActor in
                guard let self else { reply(["error": "no self"]); return }
                // Steps arrive as a JSON array, or a JSON string of one (CLI).
                var rawSteps: [[String: Any]] = []
                if let arr = b["steps"] as? [[String: Any]] { rawSteps = arr }
                else if let s = b["steps"] as? String, let d = s.data(using: .utf8),
                        let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] {
                    rawSteps = arr
                }
                guard !rawSteps.isEmpty else {
                    reply(["error": "expected {steps: [...]} — a JSON array of "
                        + "{do:{verb,…}, expect:{appears|disappears:{role,title} | watch:\"x,y,WxH\" | settle:true, timeout:N}, retry:N}"]); return
                }
                guard rawSteps.count <= 12 else {
                    reply(["error": "plan too long (\(rawSteps.count) steps, max 12) — split it; long open-loop runs drift from reality"]); return
                }
                // Top-level target defaults merge into each step, so a plan
                // for one app names it once.
                var defaults: [String: Any] = [:]
                for k in ["pid", "app", "target", "window", "window_id"] where b[k] != nil { defaults[k] = b[k]! }
                let knownVerbs = ["click", "drag", "key", "scroll", "type", "press"]
                // Validate the WHOLE plan before acting — a malformed step 5
                // must not leave steps 1–4 half-executed.
                var steps: [(doPart: [String: Any], verb: String, expect: [String: Any]?, retry: Int)] = []
                for (i, step) in rawSteps.enumerated() {
                    guard var doPart = step["do"] as? [String: Any] else {
                        reply(["error": "step \(i + 1): missing {do:{verb,…}}"]); return
                    }
                    // The actuator edge flags don't run inside plans — refuse
                    // rather than silently ignore them (seen live: a step's do
                    // carried settle:true and did nothing).
                    if doPart["until_change"] != nil || doPart["settle"] != nil {
                        reply(["error": "step \(i + 1): until_change/settle belong in the step's expect "
                            + "(watch/settle checkpoints), not in do — inside a plan they would be ignored"]); return
                    }
                    for (k, v) in defaults where doPart[k] == nil { doPart[k] = v }
                    let verb = doPart["verb"] as? String ?? ""
                    guard knownVerbs.contains(verb) else {
                        reply(["error": "step \(i + 1): unknown verb \"\(verb)\" — one of \(knownVerbs.joined(separator: "/"))"]); return
                    }
                    var expect = step["expect"] as? [String: Any]
                    if var e = expect {
                        for (k, v) in defaults where e[k] == nil { e[k] = v }
                        // One PRIMARY checkpoint per step; settle:true may ride
                        // along any of them ("changed, then let the animation
                        // finish" — same composite as --until-change --settle),
                        // or stand alone as stillness-only.
                        let kinds = ["appears", "disappears", "watch", "focused"].filter { e[$0] != nil }
                        guard kinds.count == 1 || (kinds.isEmpty && e["settle"] != nil) else {
                            reply(["error": "step \(i + 1): expect needs ONE of appears/disappears/watch/focused "
                                + "(settle:true may accompany any of them, or stand alone) — got "
                                + (kinds.isEmpty ? "none" : kinds.joined(separator: "+"))]); return
                        }
                        if let ws = e["watch"] as? String, Self.parseRegion(ws) == nil {
                            reply(["error": "step \(i + 1): bad watch \"\(ws)\" — expected x,y,WxH in GLOBAL screen points"]); return
                        }
                        expect = e
                    }
                    let retry = min(max((step["retry"] as? NSNumber)?.intValue ?? 0, 0), 3)
                    steps.append((doPart, verb, expect, retry))
                }
                // Pixel checkpoints (watch/settle) and the endgame capture need
                // an observable window; resolve once up front.
                let observedWID = await self.resolveObservedWindow(defaults)
                if steps.contains(where: { $0.expect?["watch"] != nil || $0.expect?["settle"] != nil }),
                   observedWID == nil {
                    reply(["error": "the plan has watch/settle checkpoints but no window could be resolved to observe — "
                        + "the given pid/window/target has no on-screen window (closed? still opening? — "
                        + "`floaty list-windows` to check, `floaty raise` to surface it, ⌘N if none exist)"]); return
                }

                // One actuator step (press = AX predicate resolved fresh).
                @MainActor
                func performStep(_ verb: String, _ d: [String: Any]) async -> [String: Any] {
                    switch verb {
                    case "press":
                        let role = d["role"] as? String
                        let title = (d["title"] as? String) ?? (d["name"] as? String)
                        do {
                            let (matches, pressed) = try await AgentAX.query(
                                app: (d["app"] as? String) ?? (d["target"] as? String),
                                pid: (d["pid"] as? NSNumber).map { pid_t($0.intValue) },
                                role: role, title: title, max: 5, press: true)
                            if let p = pressed { return ["ok": true, "pressed": p.name] }
                            return ["error": "press matched no element (role \(role ?? "*"), title \"\(title ?? "*")\") — \(matches.count) candidates"]
                        } catch { return ["error": error.localizedDescription] }
                    case "type":
                        guard let text = d["text"] as? String else { return ["error": "type step needs {text}"] }
                        let r = await AgentInput.type(text, pacing: self.pacing(d),
                                                      target: self.target(d), targetPID: self.targetPID(d),
                                                      showControls: false)
                        return r.ok ? ["ok": true, "typed": r.typed] : self.inputFailure("type", d)
                    default:
                        return self.performAction(verb, d)
                    }
                }
                @MainActor
                func stepPID(_ d: [String: Any]) -> pid_t? {
                    if let p = (d["pid"] as? NSNumber).map({ pid_t($0.intValue) }) { return p }
                    if let name = (d["target"] as? String) ?? (d["app"] as? String) {
                        return try? AgentAX.resolvePID(app: name, pid: nil)
                    }
                    return nil
                }
                // Host-side verification of a step's own effect — the guard
                // against a silently-lost action (seen live: the user stole
                // focus mid-plan, a `type` landed nowhere, and the plan sailed
                // on to a false completed:true). Verdicts: true = confirmed,
                // false = FAILED (fails the step), nil = unverifiable here —
                // never fails the step, but a non-empty reason is surfaced as
                // unverified_steps so the model knows the success is soft.
                @MainActor
                func verifyStep(_ verb: String, _ d: [String: Any], preValue: String?) async -> (Bool?, String) {
                    guard verb == "type" || verb == "key" else { return (nil, "") }
                    guard let pid = stepPID(d) else { return (nil, "") }
                    // Keystrokes route to the FRONTMOST app: focus moved =
                    // the keys landed somewhere else, though the events
                    // posted fine.
                    if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != pid {
                        return (false, "focus is on \(front.localizedName ?? "pid \(front.processIdentifier)"), not the target — "
                            + "the keystrokes likely landed there")
                    }
                    guard verb == "type", let text = d["text"] as? String else { return (nil, "") }
                    let head = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
                    guard !head.isEmpty else { return (nil, "") }
                    // Re-read the focused element's value. AX lags the
                    // keystrokes — poll ~1s before concluding (set-text's
                    // hard-won lesson).
                    var last: AgentAX.FocusedInfo? = nil
                    for _ in 0..<8 {
                        last = try? AgentAX.focused(app: nil, pid: pid)
                        if let v = last?.value, v.contains(head) { return (true, "") }
                        try? await Task.sleep(nanoseconds: 120_000_000)
                    }
                    guard let info = last, info.hasFocus, info.editable || !info.value.isEmpty else {
                        return (nil, "typed text isn't host-verifiable here (focused element exposes no AX value — canvas/engine-drawn?)")
                    }
                    if let pre = preValue, info.value != pre {
                        // Something landed but the echo is transformed
                        // (secure field, formatter) — don't fail on it.
                        return (nil, "the field's value changed but doesn't echo the typed text (secure/transformed field?)")
                    }
                    return (false, "the focused element's value is unchanged after typing — the keystrokes didn't land")
                }
                // Wait for a checkpoint: (satisfied, why-not description).
                @MainActor
                func awaitExpect(_ e: [String: Any]?, preHash: String?) async -> (Bool, String) {
                    guard let e else {
                        try? await Task.sleep(nanoseconds: 300_000_000)   // bare pacing
                        return (true, "")
                    }
                    let timeout = min(max((e["timeout"] as? NSNumber)?.doubleValue ?? 8, 1), 60)
                    let start = Date()
                    let watch = (e["watch"] as? String).flatMap { Self.parseRegion($0) }
                    let tol = watch != nil ? 0 : 3
                    let wantSettle = e["settle"] != nil
                    // Stillness: two consecutive equal polls (~0.8s quiet, 10s
                    // cap). As a RIDER on a passed primary checkpoint it can't
                    // fail the step — it just holds the next action until the
                    // animation the change kicked off has finished.
                    func settlePhase(seed: String?) async -> Bool {
                        guard let wid = observedWID else { return false }
                        var prev = seed ?? "", stable = 0
                        let settleStart = Date()
                        while Date().timeIntervalSince(settleStart) < 10 {
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            guard let now = try? await AgentCapture.hashWindow(windowID: wid, region: watch) else { continue }
                            stable = (!prev.isEmpty && AgentPerception.isUnchanged(prev, now, tolerance: tol)) ? stable + 1 : 0
                            prev = now
                            if stable >= 2 { return true }
                        }
                        return false
                    }
                    // focused: the target app's focused element matches — THE
                    // checkpoint for "click/key opened a text editor". A caret
                    // is pixel-invisible (watch falsely diverges on it — seen
                    // live on excalidraw) but focus state is AX-readable even
                    // in canvas apps, which edit text via a hidden textarea.
                    // Accepts true (shorthand for {editable:true}) or
                    // {editable:…, role:…}.
                    if e["focused"] != nil {
                        let want = e["focused"] as? [String: Any] ?? [:]
                        let wantRole = want["role"] as? String
                        let wantEditable = (want["editable"] as? NSNumber)?.boolValue
                            ?? ((e["focused"] as? NSNumber)?.boolValue == true ? true : nil)
                        let pid = (e["pid"] as? NSNumber).map { pid_t($0.intValue) }
                        let app = (e["app"] as? String) ?? (e["target"] as? String)
                        while true {
                            if let info = try? AgentAX.focused(app: app, pid: pid), info.hasFocus,
                               wantRole.map({ info.role == $0 }) ?? true,
                               wantEditable.map({ info.editable == $0 }) ?? true {
                                if wantSettle { _ = await settlePhase(seed: nil) }
                                return (true, "")
                            }
                            if Date().timeIntervalSince(start) >= timeout {
                                let desc = [wantRole.map { "role \($0)" },
                                            wantEditable.map { "editable \($0)" }]
                                    .compactMap { $0 }.joined(separator: ", ")
                                return (false, "focused {\(desc.isEmpty ? "any" : desc)} not met within \(Int(timeout))s")
                            }
                            try? await Task.sleep(nanoseconds: 400_000_000)
                        }
                    }
                    if let pred = (e["appears"] as? [String: Any]) ?? (e["disappears"] as? [String: Any]) {
                        let wantGone = e["disappears"] != nil
                        let role = pred["role"] as? String
                        let title = (pred["title"] as? String) ?? (pred["name"] as? String)
                        while true {
                            let found = (try? await AgentAX.query(
                                app: (e["app"] as? String) ?? (e["target"] as? String),
                                pid: (e["pid"] as? NSNumber).map { pid_t($0.intValue) },
                                role: role, title: title, max: 3)) .map { !$0.matches.isEmpty }
                            if let found, found != wantGone {
                                if wantSettle { _ = await settlePhase(seed: nil) }
                                return (true, "")
                            }
                            if Date().timeIntervalSince(start) >= timeout {
                                return (false, "\(wantGone ? "disappears" : "appears") {role \(role ?? "*"), title \"\(title ?? "*")\"} not met within \(Int(timeout))s")
                            }
                            try? await Task.sleep(nanoseconds: 700_000_000)
                        }
                    }
                    if e["watch"] != nil {
                        guard let base = preHash else { return (false, "no pre-action hash") }
                        guard let wid = observedWID else { return (false, "no observable window") }
                        while Date().timeIntervalSince(start) < timeout {
                            if let now = try? await AgentCapture.hashWindow(windowID: wid, region: watch),
                               !AgentPerception.isUnchanged(base, now, tolerance: tol) {
                                if wantSettle { _ = await settlePhase(seed: now) }
                                return (true, "")
                            }
                            try? await Task.sleep(nanoseconds: 400_000_000)
                        }
                        return (false, "watch rect never changed within \(Int(timeout))s")
                    }
                    // settle ALONE remains a hard checkpoint — stillness itself
                    // is the declared expectation.
                    guard observedWID != nil else { return (false, "no observable window") }
                    return await settlePhase(seed: preHash) ? (true, "")
                        : (false, "pixels never settled within \(Int(timeout))s")
                }
                // Failure bundle: which step, why, and a capture of where the
                // world diverged from the plan.
                @MainActor
                func failBundle(_ stepIndex: Int, _ reason: String, _ retriesTotal: Int, _ runStart: Date) async -> [String: Any] {
                    var out: [String: Any] = [
                        "ok": true, "completed": false,
                        "failed_step": stepIndex + 1, "steps_done": stepIndex, "steps": steps.count,
                        "reason": reason, "retries_total": retriesTotal,
                        "waited_ms": Int(Date().timeIntervalSince(runStart) * 1000),
                        "note": "stopped at step \(stepIndex + 1)/\(steps.count) — the world diverged from the plan; "
                            + "the capture shows where. Per-step forensics: route run.step in calls.ndjson",
                    ]
                    if let wid = observedWID,
                       let r = try? await AgentCapture.captureWindow(named: nil, windowID: wid),
                       let f = r.frame {
                        out["path"] = r.imagePath; out["frame_id"] = f.id
                        out["origin_x"] = f.origin.x; out["origin_y"] = f.origin.y
                        out["width"] = f.size.width; out["height"] = f.size.height
                        out["image_width"] = f.imageWidth; out["image_height"] = f.imageHeight
                        out["screen_hash"] = r.screenHash
                    }
                    return out
                }

                if let pid = (defaults["pid"] as? NSNumber).map({ pid_t($0.intValue) }) {
                    _ = await AgentAX.ensureOnScreen(pid: pid)
                }
                let runStart = Date()
                var retriesTotal = 0
                var unverified: [Int] = []       // steps whose effect the host couldn't check
                for (i, step) in steps.enumerated() {
                    guard Date().timeIntervalSince(runStart) < 300 else {
                        reply(await failBundle(i, "run budget exhausted (300s)", retriesTotal, runStart)); return
                    }
                    var attempt = 0
                    var lastReason = ""
                    var stepOK = false
                    var stepUnverifiable = ""
                    while attempt <= step.retry {
                        let stepStart = Date()
                        // Watch checkpoints hash BEFORE acting, fresh per attempt.
                        var preHash: String? = nil
                        if step.expect?["watch"] != nil || step.expect?["settle"] != nil, let wid = observedWID {
                            let watch = (step.expect?["watch"] as? String).flatMap { Self.parseRegion($0) }
                            preHash = try? await AgentCapture.hashWindow(windowID: wid, region: watch)
                        }
                        // Snapshot the focused value before a type step, so
                        // verifyStep can tell "didn't land" from "landed but
                        // echoed transformed".
                        var preValue: String? = nil
                        if step.verb == "type", let pid = stepPID(step.doPart) {
                            preValue = (try? AgentAX.focused(app: nil, pid: pid))?.value
                        }
                        let r = await performStep(step.verb, step.doPart)
                        var satisfied = false
                        var ledger: [String: Any] = [:]
                        if let err = r["error"] as? String {
                            lastReason = "action failed: \(err)"
                        } else {
                            let (verdict, why) = await verifyStep(step.verb, step.doPart, preValue: preValue)
                            if verdict == false {
                                lastReason = "host verification failed: \(why)"
                                ledger["verified"] = false
                            } else {
                                if let v = verdict { ledger["verified"] = v }
                                else if !why.isEmpty { ledger["verified"] = "unverifiable"; stepUnverifiable = why }
                                let (ok, why2) = await awaitExpect(step.expect, preHash: preHash)
                                satisfied = ok
                                if !ok { lastReason = "expect not met: \(why2)" }
                            }
                        }
                        ledger["ok"] = r["error"] == nil
                        ledger["satisfied"] = satisfied
                        if !satisfied { ledger["reason"] = lastReason }
                        DevtoolsRelay.shared.logRunStep(
                            args: ["step": i + 1, "verb": step.verb, "attempt": attempt]
                                .merging(DevtoolsRelay.summarizeAgentArgs(step.doPart)) { a, _ in a },
                            ms: Int(Date().timeIntervalSince(stepStart) * 1000),
                            result: ledger)
                        if satisfied { stepOK = true; break }
                        attempt += 1
                    }
                    retriesTotal += min(attempt, step.retry)
                    if !stepOK {
                        reply(await failBundle(i, lastReason, retriesTotal, runStart)); return
                    }
                    if !stepUnverifiable.isEmpty { unverified.append(i + 1) }
                }
                // Endgame: aggregates + ONE final capture (the "last final
                // pieces" — fishy numbers here are the cue to grep run.step).
                var out: [String: Any] = [
                    "ok": true, "completed": true, "steps": steps.count,
                    "retries_total": retriesTotal,
                    "waited_ms": Int(Date().timeIntervalSince(runStart) * 1000),
                ]
                if let wid = observedWID,
                   let r = try? await AgentCapture.captureWindow(named: nil, windowID: wid),
                   let f = r.frame {
                    out["path"] = r.imagePath; out["frame_id"] = f.id
                    out["origin_x"] = f.origin.x; out["origin_y"] = f.origin.y
                    out["width"] = f.size.width; out["height"] = f.size.height
                    out["image_width"] = f.imageWidth; out["image_height"] = f.imageHeight
                    out["screen_hash"] = r.screenHash
                }
                var notes: [String] = []
                if retriesTotal > 0 {
                    notes.append("completed, but \(retriesTotal) retr\(retriesTotal == 1 ? "y" : "ies") were needed — "
                        + "if the final state looks off, grep route run.step in calls.ndjson")
                }
                if !unverified.isEmpty {
                    out["unverified_steps"] = unverified
                    notes.append("step\(unverified.count == 1 ? "" : "s") \(unverified.map(String.init).joined(separator: ",")) "
                        + "couldn't be host-verified (no readable AX value — canvas?): completed means the checkpoints "
                        + "passed, NOT that those effects landed — re-check them (read-text / capture --region) before trusting the result")
                }
                if !notes.isEmpty { out["note"] = notes.joined(separator: ". ") }
                reply(out)
            }
        }
        DevtoolsRelay.shared.onAgentMark = { [weak self] b in
            guard let self, let p = self.point(b) else { return ["error": "expected {x,y}"] }
            let duration = (b["duration"] as? NSNumber)?.doubleValue ?? 1.2
            let label = b["label"] as? String
            _ = AgentMarker.show(at: p, duration: duration, label: label)
            return ["ok": true, "x": p.x, "y": p.y]
        }
        // click-in-frame / move-in-frame: the agent passes a coordinate its
        // vision model read off a captured PNG (image pixels) plus the frame_id;
        // FloatyTerm inverts to a screen point and acts. Breaks the capture →
        // guess → nudge → re-capture loop on native/canvas apps.
        DevtoolsRelay.shared.onAgentClickInFrame = { [weak self] b in
            guard let self else { return ["error": "no self"] }
            do {
                let (p, owner) = try self.resolveFrame(b)
                let clicks = (b["clicks"] as? NSNumber)?.intValue ?? 1
                let ok = AgentInput.click(at: p, button: self.button(b), modifiers: self.mods(b),
                                          clicks: clicks, pacing: self.pacing(b), target: owner)
                return ok ? ["ok": true, "screen_x": p.x, "screen_y": p.y]
                          : self.inputFailure("click-in-frame", b)
            } catch { return ["error": error.localizedDescription] }
        }
        DevtoolsRelay.shared.onAgentMoveInFrame = { [weak self] b in
            guard let self else { return ["error": "no self"] }
            do {
                let (p, owner) = try self.resolveFrame(b)
                let ok = AgentInput.move(to: p, pacing: self.pacing(b), target: owner)
                return ok ? ["ok": true, "screen_x": p.x, "screen_y": p.y]
                          : self.inputFailure("move-in-frame", b)
            } catch { return ["error": error.localizedDescription] }
        }
        DevtoolsRelay.shared.onAgentListWindows = { b in
            // Optional `filter` narrows to windows whose owner/title contains it.
            let filter = (b["filter"] as? String)?.lowercased()
            // Include off-screen windows (other Spaces / minimized / off-stage)
            // so the agent sees a window exists even under Stage Manager — each
            // carries `on_screen`; only on_screen windows can be captured/clicked.
            let windows = AgentCapture.listWindows(includingOffScreen: true)
                .filter { filter == nil
                    || $0.owner.lowercased().contains(filter!)
                    || $0.title.lowercased().contains(filter!) }
                .sorted {                                   // on-screen first, then largest
                    $0.onScreen != $1.onScreen ? $0.onScreen : $0.area > $1.area
                }
                .map { w -> [String: Any] in
                    ["id": Int(w.id), "pid": Int(w.pid), "owner": w.owner, "title": w.title,
                     "on_screen": w.onScreen,
                     "x": w.bounds.origin.x, "y": w.bounds.origin.y,
                     "width": w.bounds.width, "height": w.bounds.height]
                }
            return ["ok": true, "windows": windows]
        }
        DevtoolsRelay.shared.onAgentQueryDOM = { b in
            guard let selector = b["selector"] as? String else { return ["error": "expected {selector}"] }
            let port = UInt16((b["port"] as? NSNumber)?.intValue ?? 9222)
            let match = b["match"] as? String
            let viaExt = (b["via_extension"] as? NSNumber)?.boolValue ?? false
            do {
                let matches = try await AgentDOM.screenRects(selector: selector, port: port, match: match, viaExtension: viaExt)
                // Top-level fields mirror the FIRST match (back-compat with the
                // single-result shape). The full list is compact by default — one
                // line per element; --json restores the verbose matches[].
                let f = matches[0]
                var out: [String: Any] = ["ok": true, "count": matches.count,
                        "x": f.rect.origin.x, "y": f.rect.origin.y,
                        "width": f.rect.size.width, "height": f.rect.size.height,
                        "center_x": f.center.x, "center_y": f.center.y]
                if (b["json"] as? NSNumber)?.boolValue ?? false {
                    out["matches"] = matches.map { m -> [String: Any] in
                        ["x": m.rect.origin.x, "y": m.rect.origin.y,
                         "width": m.rect.size.width, "height": m.rect.size.height,
                         "center_x": m.center.x, "center_y": m.center.y, "text": m.text]
                    }
                } else {
                    out["elements"] = Self.elementLines(
                        matches.enumerated().map { (id: $0.offset + 1, role: "",
                                                    name: $0.element.text, rect: $0.element.rect) },
                        brief: (b["brief"] as? NSNumber)?.boolValue ?? false)
                }
                return out
            } catch { return ["error": error.localizedDescription] }
        }
        DevtoolsRelay.shared.onAgentEval = { b in
            guard let expr = (b["expression"] as? String) ?? (b["js"] as? String) else {
                return ["error": "expected {expression}"]
            }
            let port = UInt16((b["port"] as? NSNumber)?.intValue ?? 9222)
            let match = b["match"] as? String
            let viaExt = (b["via_extension"] as? NSNumber)?.boolValue ?? false
            do {
                let json = try await AgentDOM.runJavaScript(expression: expr, port: port, match: match, viaExtension: viaExt)
                // Re-parse so the value embeds natively in the response (an
                // array stays an array), not as an escaped string.
                if let json, let val = try? JSONSerialization.jsonObject(
                    with: Data(json.utf8), options: [.fragmentsAllowed]) {
                    return ["ok": true, "result": val]
                }
                return ["ok": true, "result": NSNull()]
            } catch { return ["error": error.localizedDescription] }
        }
        DevtoolsRelay.shared.onAgentNavigate = { b in
            guard let url = b["url"] as? String else { return ["error": "expected {url}"] }
            let port = UInt16((b["port"] as? NSNumber)?.intValue ?? 9222)
            let match = b["match"] as? String
            let viaExt = (b["via_extension"] as? NSNumber)?.boolValue ?? false
            do { try await AgentDOM.navigate(url: url, port: port, match: match, viaExtension: viaExt); return ["ok": true, "url": url] }
            catch { return ["error": error.localizedDescription] }
        }
        DevtoolsRelay.shared.onAgentTabs = { b in
            let port = UInt16((b["port"] as? NSNumber)?.intValue ?? 9222)
            let viaExt = (b["via_extension"] as? NSNumber)?.boolValue ?? false
            do { return ["ok": true, "tabs": try await AgentDOM.tabs(port: port, viaExtension: viaExt)] }
            catch { return ["error": error.localizedDescription] }
        }
        DevtoolsRelay.shared.onAgentFocus = { b in
            let port = UInt16((b["port"] as? NSNumber)?.intValue ?? 9222)
            let match = b["match"] as? String
            let viaExt = (b["via_extension"] as? NSNumber)?.boolValue ?? false
            do {
                try await AgentDOM.bringToFront(port: port, match: match, viaExtension: viaExt)
                return ["ok": true]
            } catch { return ["error": error.localizedDescription] }
        }
        // Set-of-Mark: annotate the page's interactable elements with numbered
        // boxes (drawn in-page, screenshotted, then stripped) and return the PNG
        // + a mark table in SCREEN coords. The model reads a NUMBER off the image
        // instead of regressing a pixel; `click-mark --id N` resolves N → a click.
        DevtoolsRelay.shared.onAgentSom = { b in
            let maxMarks = (b["max"] as? NSNumber)?.intValue ?? 100
            let app = b["app"] as? String
            let axPID = (b["pid"] as? NSNumber).map { pid_t($0.intValue) }
            // Table-first SoM: the annotated screenshot is the EXPENSIVE half of
            // this verb (image tokens + several MB of transfer per loop step) and
            // redundant whenever the mark table carries usable names — the model
            // acts by id either way. So the image is produced only when names are
            // sparse (icon toolbars, canvas apps) or explicitly requested.
            //   --image  force the annotated screenshot
            //   --json   verbose marks[] array (scripts) instead of the text table
            //   --brief  drop geometry from the table (id/role/name only)
            //   --diff   only what changed since the last som of this target
            let wantImage = (b["image"] as? NSNumber)?.boolValue ?? false
            let wantJSON = (b["json"] as? NSNumber)?.boolValue ?? false
            let brief = (b["brief"] as? NSNumber)?.boolValue ?? false
            let wantDiff = (b["diff"] as? NSNumber)?.boolValue ?? false

            func emitMarks(_ stored: [AgentCapture.Mark], into out: inout [String: Any]) {
                if wantJSON {
                    out["marks"] = stored.map { m -> [String: Any] in
                        ["id": m.id, "role": m.role, "name": m.name,
                         "x": m.rect.origin.x, "y": m.rect.origin.y,
                         "width": m.rect.size.width, "height": m.rect.size.height,
                         "center_x": m.center.x, "center_y": m.center.y]
                    }
                } else {
                    out["elements"] = Self.elementLines(
                        stored.map { (id: $0.id, role: $0.role, name: $0.name, rect: $0.rect) },
                        brief: brief)
                }
            }

            // With --diff: compare against the last som of the same target and
            // return only added/removed rows — after a click the delta is
            // usually "a menu's worth of rows", tens of tokens instead of the
            // full table. Every som (diff or not) refreshes the baseline.
            func emitMarksOrDiff(_ stored: [AgentCapture.Mark], key: String,
                                 into out: inout [String: Any], notes: inout [String]) {
                let els = stored.map { AgentPerception.Element(role: $0.role, name: $0.name, rect: $0.rect) }
                if wantDiff {
                    let d = AgentPerception.diffAndStore(key: key, current: els)
                    if d.hadBaseline {
                        out["diff"] = true
                        out["added"] = d.added.count
                        out["removed"] = d.removed.count
                        out["unchanged"] = d.unchangedCount
                        let addedHashes = Set(d.added.map(\.hash))
                        let addedMarks = stored.filter {
                            addedHashes.contains(AgentPerception.Element(
                                role: $0.role, name: $0.name, rect: $0.rect).hash)
                        }
                        if !addedMarks.isEmpty {
                            out["elements_added"] = Self.elementLines(
                                addedMarks.map { (id: $0.id, role: $0.role, name: $0.name, rect: $0.rect) },
                                brief: brief)
                        }
                        if !d.removed.isEmpty {
                            out["elements_removed"] = Self.elementLines(
                                d.removed.enumerated().map { (id: $0.offset + 1, role: $0.element.role,
                                                              name: $0.element.name, rect: $0.element.rect) },
                                brief: brief)
                        }
                        notes.append("diff vs the previous som of this target — added ids are "
                            + "click-mark ids in THIS frame; removed rows are informational "
                            + "(a moved element shows as removed+added)")
                        return
                    }
                    out["diff"] = "baseline"
                    notes.append("no previous som snapshot for this target — stored one; returning the full table")
                } else {
                    AgentPerception.store(key: key, current: els)
                }
                emitMarks(stored, into: &out)
            }

            // AX-backed Set-of-Mark: read the target app's tree (by PID — works on
            // native apps AND the live default-profile Chrome). The tree is read
            // FIRST; the window is screenshotted + annotated only when needed.
            if app != nil || axPID != nil {
                do {
                    let pid = try AgentAX.resolvePID(app: app, pid: axPID)
                    var win = AgentCapture.listWindows()
                        .filter({ $0.pid == pid }).max(by: { $0.area < $1.area })
                    if win == nil {
                        // Default for --pid/--app: auto-raise an off-Space window (it
                        // can't be screenshotted off-stage) instead of erroring.
                        _ = await AgentAX.ensureOnScreen(pid: pid)
                        win = AgentCapture.listWindows().filter({ $0.pid == pid }).max(by: { $0.area < $1.area })
                    }
                    guard let win else {
                        return ["error": "no window for that app/pid (it may have no open windows — ⌘N in the app)"]
                    }
                    // Query generously, then keep only this window's elements.
                    let (matches, _) = try await AgentAX.query(app: nil, pid: pid, role: nil,
                                                               title: nil, max: 500, press: false)
                    let winRect = win.bounds
                    var stored: [AgentCapture.Mark] = []
                    for m in matches {
                        guard winRect.contains(m.center) else { continue }   // this window's elements only
                        stored.append(AgentCapture.Mark(id: stored.count + 1, role: m.role, name: m.name,
                                                        rect: m.rect, center: m.center))
                        if stored.count >= maxMarks { break }
                    }
                    let named = stored.filter { !$0.name.isEmpty }.count
                    // --diff is a text feature: no auto-image (only --image forces one).
                    let needImage = wantImage
                        || (!wantDiff && Self.somNeedsImage(named: named, total: stored.count))

                    var out: [String: Any] = ["ok": true, "source": "ax", "count": stored.count]
                    var notes: [String] = []
                    if needImage {
                        let shot = try await AgentCapture.rawCapture(windowID: win.id, fallbackName: app)
                        // Downscale BEFORE annotating so boxes and labels render at
                        // the resolution the model actually sees.
                        let img = AgentCapture.downscale(shot.image)
                        let pppX = Double(img.width) / Double(max(shot.size.width, 1))
                        let pppY = Double(img.height) / Double(max(shot.size.height, 1))
                        let boxes: [(label: Int, rect: CGRect)] = stored.map { m in
                            (label: m.id,
                             rect: CGRect(x: (m.rect.origin.x - shot.origin.x) * pppX,
                                          y: (m.rect.origin.y - shot.origin.y) * pppY,
                                          width: m.rect.size.width * pppX,
                                          height: m.rect.size.height * pppY))
                        }
                        let annotated = AgentCapture.annotate(image: img, boxes: boxes) ?? img
                        guard let url = ContextSnap.saveImage(annotated) else {
                            return ["error": "som: could not save the annotated screenshot"]
                        }
                        out["image"] = true
                        out["path"] = url.path
                        out["image_width"] = annotated.width
                        out["image_height"] = annotated.height
                    } else {
                        out["image"] = false
                        notes.append("marks are well-named; table only — pass --image for the annotated screenshot")
                    }
                    let fid = AgentCapture.nextMarkFrameID()
                    AgentCapture.rememberMarks(AgentCapture.MarkFrame(
                        id: fid, source: "ax", marks: stored, capturedAt: Date(),
                        pid: pid, owner: win.owner, windowID: win.id, windowBounds: winRect))
                    out["frame_id"] = fid
                    emitMarksOrDiff(stored, key: "som:ax:\(pid)", into: &out, notes: &notes)
                    if stored.count >= maxMarks {
                        out["truncated"] = true
                        notes.append("capped at \(maxMarks) marks; pass --max to raise")
                    }
                    if !notes.isEmpty { out["note"] = notes.joined(separator: "; ") }
                    return out
                } catch { return ["error": error.localizedDescription] }
            }

            // CDP-backed Set-of-Mark (DOM apps): collect the mark table first (no
            // overlay, no screenshot); only when the table can't stand alone does
            // a second pass draw the in-page overlay and screenshot it.
            let port = UInt16((b["port"] as? NSNumber)?.intValue ?? 9222)
            let match = b["match"] as? String
            let viaExt = (b["via_extension"] as? NSNumber)?.boolValue ?? false
            do {
                var r = try await AgentDOM.setOfMarks(port: port, match: match,
                                                      max: maxMarks, includeImage: false, viaExtension: viaExt)
                let named = r.marks.filter { !$0.name.isEmpty }.count
                // --diff is a text feature: no auto-image (only --image forces one).
                let needImage = wantImage
                    || (!wantDiff && Self.somNeedsImage(named: named, total: r.marks.count))
                if needImage {
                    // Re-run with the overlay + screenshot; ITS marks are the
                    // authoritative set (the page may have shifted between passes).
                    r = try await AgentDOM.setOfMarks(port: port, match: match,
                                                      max: maxMarks, includeImage: true, viaExtension: viaExt)
                }

                // Assign 1-based ids (matching the drawn labels) and store the frame.
                var stored: [AgentCapture.Mark] = []
                for (i, m) in r.marks.enumerated() {
                    stored.append(AgentCapture.Mark(id: i + 1, role: m.role, name: m.name,
                                                    rect: m.rect, center: m.center))
                }

                var out: [String: Any] = ["ok": true, "source": "cdp", "count": stored.count]
                var notes: [String] = []
                if needImage {
                    // Decode, downscale, and save through ContextSnap so it joins
                    // snap history and pruning, like a normal capture.
                    guard let data = Data(base64Encoded: r.pngBase64),
                          let rep = NSBitmapImageRep(data: data),
                          let raw = rep.cgImage
                    else { return ["error": "som: could not save the annotated screenshot"] }
                    let img = AgentCapture.downscale(raw)
                    guard let url = ContextSnap.saveImage(img) else {
                        return ["error": "som: could not save the annotated screenshot"]
                    }
                    out["image"] = true
                    out["path"] = url.path
                    out["image_width"] = img.width
                    out["image_height"] = img.height
                } else {
                    out["image"] = false
                    notes.append("marks are well-named; table only — pass --image for the annotated screenshot")
                }
                let fid = AgentCapture.nextMarkFrameID()
                AgentCapture.rememberMarks(AgentCapture.MarkFrame(
                    id: fid, source: "cdp", marks: stored, capturedAt: Date(),
                    port: port, match: match, viaExtension: viaExt, url: r.url,
                    screenX: r.screenX, screenY: r.screenY,
                    scrollX: r.scrollX, scrollY: r.scrollY))
                out["frame_id"] = fid
                emitMarksOrDiff(stored, key: "som:cdp:\(viaExt ? "ext" : String(port)):\(match ?? "*")",
                                into: &out, notes: &notes)
                if stored.count >= maxMarks {
                    out["truncated"] = true
                    notes.append("capped at \(maxMarks) marks; pass --max to raise")
                }
                if !notes.isEmpty { out["note"] = notes.joined(separator: "; ") }
                return out
            } catch { return ["error": error.localizedDescription] }
        }
        // query-ax: read a target app's Accessibility tree (the native analog of
        // query-dom) by PID — so it disambiguates two same-named Chromes and
        // drives the live default-profile Chrome that Chrome 136+ won't expose
        // over CDP. AXPosition/AXSize are already global screen points. With
        // --press it AXPress-es the first match: a targeted activation that
        // ignores which window is frontmost.
        DevtoolsRelay.shared.onAgentQueryAX = { b in
            let app = b["app"] as? String
            let pid = (b["pid"] as? NSNumber).map { pid_t($0.intValue) }
            guard app != nil || pid != nil else {
                return ["error": "expected {app} or {pid} (see `floaty list-windows` for pids)"]
            }
            let role = b["role"] as? String
            let title = (b["title"] as? String) ?? (b["name"] as? String)
            let maxN = (b["max"] as? NSNumber)?.intValue ?? 100
            let press = (b["press"] as? NSNumber)?.boolValue ?? false
            do {
                // Auto-raise (default for --pid/--app): Chromium/Flutter expose their
                // a11y tree only when foreground, so surface an off-Space window first.
                let resolvedPID = try? AgentAX.resolvePID(app: app, pid: pid)
                if let rp = resolvedPID {
                    _ = await AgentAX.ensureOnScreen(pid: rp)
                }
                let (matches, pressed) = try await AgentAX.query(
                    app: app, pid: pid, role: role, title: title, max: maxN, press: press)
                var out: [String: Any] = ["ok": true, "count": matches.count]
                let brief = (b["brief"] as? NSNumber)?.boolValue ?? false
                // Snapshot key: same target + same filters = comparable observations.
                let els = matches.map { AgentPerception.Element(role: $0.role, name: $0.name, rect: $0.rect) }
                let targetKey = "ax:\(resolvedPID.map(String.init) ?? app ?? "?"):\(role ?? "*"):\(title ?? "*")"
                var emittedDiff = false
                if (b["diff"] as? NSNumber)?.boolValue ?? false {
                    // --diff: only what changed since the last identical query —
                    // after a click the delta is usually a handful of rows.
                    let d = AgentPerception.diffAndStore(key: targetKey, current: els)
                    if d.hadBaseline {
                        out["diff"] = true
                        out["added"] = d.added.count
                        out["removed"] = d.removed.count
                        out["unchanged"] = d.unchangedCount
                        if !d.added.isEmpty {
                            out["elements_added"] = Self.elementLines(
                                d.added.enumerated().map { (id: $0.offset + 1, role: $0.element.role,
                                                            name: $0.element.name, rect: $0.element.rect) },
                                brief: brief)
                        }
                        if !d.removed.isEmpty {
                            out["elements_removed"] = Self.elementLines(
                                d.removed.enumerated().map { (id: $0.offset + 1, role: $0.element.role,
                                                              name: $0.element.name, rect: $0.element.rect) },
                                brief: brief)
                        }
                        out["note"] = "diff vs the previous identical query (a moved element shows as removed+added); pass no --diff for the full table"
                        emittedDiff = true
                    } else {
                        out["diff"] = "baseline"
                        out["note"] = "no previous snapshot for this target/filter — stored one; returning the full table"
                    }
                } else {
                    AgentPerception.store(key: targetKey, current: els)
                }
                // Compact by default: one line per element (~4× fewer tokens than
                // the object array). --json restores the verbose matches[] for
                // scripts; --brief drops geometry (id/role/name only).
                if !emittedDiff {
                    if (b["json"] as? NSNumber)?.boolValue ?? false {
                        out["matches"] = matches.map { m -> [String: Any] in
                            ["role": m.role, "name": m.name,
                             "x": m.rect.origin.x, "y": m.rect.origin.y,
                             "width": m.rect.size.width, "height": m.rect.size.height,
                             "center_x": m.center.x, "center_y": m.center.y]
                        }
                    } else {
                        out["elements"] = Self.elementLines(
                            matches.enumerated().map { (id: $0.offset + 1, role: $0.element.role,
                                                        name: $0.element.name, rect: $0.element.rect) },
                            brief: brief)
                    }
                }
                if let f = matches.first {   // mirror first match (parity with query-dom)
                    out["x"] = f.rect.origin.x; out["y"] = f.rect.origin.y
                    out["width"] = f.rect.size.width; out["height"] = f.rect.size.height
                    out["center_x"] = f.center.x; out["center_y"] = f.center.y
                }
                if let pressed {
                    out["pressed"] = ["role": pressed.role, "name": pressed.name,
                                      "center_x": pressed.center.x, "center_y": pressed.center.y]
                }
                return out
            } catch { return ["error": error.localizedDescription] }
        }
        // host: Agent Ghost mode. `floaty host --ghost on` makes the front window
        // click-through + non-key (so synthetic input passes to the app being
        // driven and can't be stolen back) while staying visible; a floating
        // unlock badge signals it and releases on click. `--ghost off` releases
        // every agent-ghosted window. The standard pre-typing step for an agent
        // driving the GUI from a terminal inside FloatyTerm.
        DevtoolsRelay.shared.onAgentHost = { [weak self] b in
            guard let self else { return ["error": "no self"] }
            let on: Bool
            if let s = b["ghost"] as? String { on = ["on", "true", "1", "yes"].contains(s.lowercased()) }
            else if let n = b["ghost"] as? NSNumber { on = n.boolValue }
            else { return ["error": "expected {ghost: on|off}"] }
            if on {
                // Ghost EVERY window, not just currentWindow(): when the agent is
                // driving another app, no FloatyTerm window is key, so the old
                // `first(isKey) ?? last` heuristic could ghost a window the user
                // isn't even looking at (or none usefully) — which is why ghost
                // looked like it "didn't engage". Ghosting all guarantees the
                // agent's window is covered, and they all share the banner.
                let targets = self.windows.filter { $0.isVisible }   // on-screen only — no stray banner on a hidden one
                guard !targets.isEmpty else { return ["error": "no visible FloatyTerm window to ghost"] }
                targets.forEach { $0.setAgentGhost(true) }
                let ghosted = self.windows.filter { $0.isAgentGhosted }.count
                return ["ok": true, "ghost": true, "ghosted": ghosted, "windows": self.windows.count]
            } else {
                let released = self.windows.filter { $0.isAgentGhosted }
                released.forEach { $0.setAgentGhost(false) }
                return ["ok": true, "ghost": false, "released": released.count]
            }
        }
        // sessions/peek: the terminal tunnel — one agent reading another
        // session's command output. `sessions` lists every terminal with its
        // stable id; `peek` returns a command block (OSC 133-delimited, with
        // exit code) or a raw line window from any of them, and `--wait`
        // long-polls until the target's next command completes. An agent
        // identifies itself via $FLOATYTERM_SESSION_ID (injected into every
        // pty) and passes it as --exclude to mean "everyone but me".
        DevtoolsRelay.shared.onAgentSessions = { [weak self] _ in
            guard let self else { return ["error": "no self"] }
            let items: [[String: Any]] = self.sessionEntries().compactMap { e in
                guard let term = e.tab as? TerminalController else { return nil }
                var item: [String: Any] = [
                    "id": term.sessionID,
                    "name": e.name,
                    "location": e.location,
                    "status": String(describing: e.status),
                    "is_agent": e.isAgent,
                    "shell_integration": term.sawShellIntegration,
                    "transcript_end": term.transcriptAbsoluteEnd,
                ]
                if let last = term.commandBlocks.last {
                    item["last_block"] = last.id
                    item["running"] = last.endLine == nil
                    if let code = last.exitCode { item["last_exit_code"] = Int(code) }
                }
                return item
            }
            return ["ok": true, "count": items.count, "sessions": items]
        }
        DevtoolsRelay.shared.onAgentPeek = { [weak self] b, reply in
            guard let self else { reply(["error": "no self"]); return }
            let resolved = self.resolvePeekTarget(b)
            guard let term = resolved.term else {
                reply(resolved.error ?? ["error": "no session"]); return
            }
            let wantsWait = (b["wait"] as? NSNumber)?.boolValue ?? false
            guard wantsWait else {
                reply(self.peekResult(term: term, body: b)); return
            }
            guard term.sawShellIntegration else {
                reply(["error": "--wait needs OSC 133 shell integration in the target session (none seen); poll with --since instead"])
                return
            }
            let timeout = min(max((b["timeout"] as? NSNumber)?.doubleValue ?? 60, 1), 300)
            // Both closures run on the main thread, so the flag needs no lock.
            var done = false
            let token = term.awaitNextCompletedBlock { [weak self] block in
                guard !done, let self else { return }
                done = true
                var body = b
                body["block"] = NSNumber(value: block.id)
                reply(self.peekResult(term: term, body: body))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak term] in
                guard !done else { return }
                done = true
                term?.cancelBlockWait(token)
                reply(["error": "timeout: no command completed in the target session within \(Int(timeout))s"])
            }
        }
        // focused: report the target app's focused element (AXFocusedUIElement)
        // so the agent can confirm a text cursor exists before typing — the
        // click → focused check → type pattern, instead of click-and-pray.
        DevtoolsRelay.shared.onAgentFocused = { b in
            let app = b["app"] as? String
            let pid = (b["pid"] as? NSNumber).map { pid_t($0.intValue) }
            guard app != nil || pid != nil else {
                return ["error": "expected {app} or {pid} (see `floaty list-windows` for pids)"]
            }
            do {
                let f = try AgentAX.focused(app: app, pid: pid)
                return ["ok": true, "has_focus": f.hasFocus, "role": f.role,
                        "name": f.name, "value": f.value, "editable": f.editable]
            } catch { return ["error": error.localizedDescription] }
        }
        // set-text: write into the focused field by SETTING its AXValue directly,
        // bypassing synthetic keystrokes. The reliable text-entry path for
        // Chromium/Electron, where `type`'s CGEvents route to the wrong responder
        // and it reports success without anything landing. Re-reads to report
        // `landed` honestly; `settable:false` means fall back to paste.
        DevtoolsRelay.shared.onAgentSetText = { b in
            let app = b["app"] as? String
            let pid = (b["pid"] as? NSNumber).map { pid_t($0.intValue) }
            guard let text = b["text"] as? String else { return ["error": "expected {text}"] }
            guard app != nil || pid != nil else {
                return ["error": "expected {app} or {pid} (see `floaty list-windows` for pids). "
                    + "Focus the field first (click → `floaty focused`), then set-text writes into it."]
            }
            do {
                let r = try await AgentAX.setText(app: app, pid: pid, text: text)
                if r.landed {
                    return ["ok": true, "landed": true, "settable": r.settable,
                            "role": r.role, "value": r.value]
                }
                // Wrote but the field didn't take it — tell the agent to paste, don't
                // let it think text entry succeeded.
                return ["ok": false, "landed": false, "settable": r.settable, "role": r.role,
                        "value": r.value,
                        "error": r.settable
                            ? "AXValue write didn't stick on a \(r.role) (custom web input ignores it). "
                                + "Fall back to paste: `printf %s \"$TEXT\" | pbcopy; floaty key --key v --modifiers cmd --pid <N>`."
                            : "focused \(r.role) doesn't expose a settable value. Fall back to paste "
                                + "(pbcopy + ⌘V) — and confirm the field was focused first (`floaty focused`)."]
            } catch { return ["error": error.localizedDescription] }
        }
        // enable-cdp: relaunch an Electron app (Slack, VS Code, Cursor, Discord…)
        // with a remote debugging port so it can be driven over CDP — the reliable
        // path that moots synthetic-keystroke flakiness. Browsers are refused (the
        // personal-profile / singleton-lock problem); they stay on osascript/AX.
        DevtoolsRelay.shared.onAgentEnableCDP = { b in
            guard let app = b["app"] as? String else {
                return ["error": "expected {app} (the Electron app to relaunch with a debug port, e.g. Slack)"]
            }
            // Port: honor an explicit --port, else the conventional one per app
            // (matches the ports table in the skill), else 9229.
            let conventional: [String: UInt16] = [
                "slack": 9225, "code": 9223, "visual studio code": 9223,
                "cursor": 9224, "discord": 9226,
            ]
            let port: UInt16 = (b["port"] as? NSNumber).map { UInt16(truncating: $0) }
                ?? conventional[app.lowercased()] ?? 9229
            do {
                let r = try await AgentElectron.enableCDP(appName: app, port: Int(port) > 0 ? port : 9229)
                if r.cdpUp {
                    return ["ok": true, "app": r.app, "pid": Int(r.pid), "port": Int(r.port),
                            "cdp": true, "relaunched": r.relaunched,
                            "note": "CDP is live on \(r.port) — drive it with `floaty tabs --port \(r.port)`, "
                                + "`query-dom --port \(r.port)`, `eval --port \(r.port)`, `navigate --port \(r.port)`."]
                }
                return ["ok": false, "app": r.app, "pid": Int(r.pid), "port": Int(r.port),
                        "cdp": false, "relaunched": r.relaunched,
                        "error": "relaunched \(r.app) but no CDP endpoint answered on \(r.port) within ~9s. "
                            + "It may not accept the flag, or needs longer — retry `floaty tabs --port \(r.port)`. "
                            + "If it stays dead, fall back to set-text/paste."]
            } catch { return ["error": error.localizedDescription] }
        }
        // raise: surface a target app/window onto the ACTIVE Space — the public
        // equivalent of clicking a notification. The agent's self-recovery for an
        // off-stage / other-Space / inactive-full-screen window: list-windows sees
        // on_screen:false → raise → capture/som/click now work (no manual step).
        DevtoolsRelay.shared.onAgentRaise = { b in
            let app = b["app"] as? String
            let pid = (b["pid"] as? NSNumber).map { pid_t($0.intValue) }
            guard app != nil || pid != nil else {
                return ["error": "expected {app} or {pid} (see `floaty list-windows` for pids)"]
            }
            do {
                let r = try await AgentAX.raise(app: app, pid: pid)
                return ["ok": true, "pid": Int(r.pid), "on_screen": r.onScreen, "title": r.title,
                        "note": r.onScreen
                            ? "window is on the active Space now — capture/som/click will work"
                            : "activated, but no window on the active Space yet (it may have no open window — ⌘N — or be mid-switch); re-check `floaty list-windows`"]
            } catch { return ["error": error.localizedDescription] }
        }
        // read-text: pull readable text from a target. AX-tree extraction first
        // (lossless, fast — the right "read this page" path for live Chrome that
        // Chrome 136+ won't expose over CDP); if the tree carries ~no text, fall
        // back to OCR of the on-screen window.
        DevtoolsRelay.shared.onAgentReadText = { b in
            let app = b["app"] as? String
            let pid = (b["pid"] as? NSNumber).map { pid_t($0.intValue) }
            guard app != nil || pid != nil else {
                return ["error": "expected {app} or {pid} (see `floaty list-windows` for pids)"]
            }
            let wantSections = (b["sections"] as? Bool) ?? false
            do {
                // Auto-raise (default for --pid/--app): surface an off-Space window
                // first. For Chrome/Flutter the tree only populates when foreground,
                // and the OCR fallback needs it on-screen — so this makes the read
                // richer, not just the fallback work. No-op if already on-screen.
                if let rp = try? AgentAX.resolvePID(app: app, pid: pid) {
                    _ = await AgentAX.ensureOnScreen(pid: rp)
                }
                // --sections: labeled regions (by ARIA landmark) so the caller can
                // pick "the thread/detail pane" without awk-ing the flat dump.
                if wantSections {
                    let secs = try await AgentAX.extractSections(app: app, pid: pid)
                    let total = secs.reduce(0) { $0 + $1.chars }
                    if total >= 40 {
                        return ["ok": true, "source": "ax", "chars": total,
                                "sections": secs.map { ["label": $0.label, "chars": $0.chars, "text": $0.text] }]
                    }
                    // fall through to OCR if the tree was empty
                }
                let axText = try await AgentAX.extractText(app: app, pid: pid)
                if axText.count >= 40 {   // real content from the tree
                    return ["ok": true, "source": "ax", "chars": axText.count, "text": axText]
                }
                // AX sparse → OCR the on-screen window as fallback.
                let resolvedPID = try AgentAX.resolvePID(app: app, pid: pid)
                guard let win = AgentCapture.listWindows()
                        .filter({ $0.pid == resolvedPID }).max(by: { $0.area < $1.area }) else {
                    let off = AgentCapture.listWindows(includingOffScreen: true)
                        .filter { $0.pid == resolvedPID && !$0.onScreen }
                    if !off.isEmpty {
                        return ["error": "\(app ?? "pid \(resolvedPID)") is off the current Space/Stage; run "
                            + "`floaty raise --pid \(resolvedPID)` to surface it, then retry (need it visible to OCR)."]
                    }
                    return ["ok": true, "source": "ax", "chars": axText.count, "text": axText,
                            "note": "little AX text and no on-screen window to OCR"]
                }
                let shot = try await AgentCapture.rawCapture(windowID: win.id, fallbackName: app)
                let ocr: String? = await withCheckedContinuation { cont in
                    ContextSnap.recognizeText(in: shot.image) { cont.resume(returning: $0) }
                }
                if let ocr, !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let capped = String(ocr.prefix(40000))
                    return ["ok": true, "source": "ocr", "chars": capped.count, "text": capped,
                            "note": "AX text was sparse; fell back to OCR"]
                }
                return ["ok": true, "source": "ax", "chars": axText.count, "text": axText,
                        "note": "AX sparse and OCR found no text"]
            } catch { return ["error": error.localizedDescription] }
        }
        // click-mark: the model picked a NUMBER off the som screenshot; resolve it
        // to the stored screen center and click. Refuses (no silent misclick) if
        // the page navigated/scrolled/moved since the marks were captured.
        DevtoolsRelay.shared.onAgentClickMark = { [weak self] b in
            guard let self else { return ["error": "no self"] }
            guard let fid = (b["frame_id"] as? String) ?? (b["frame"] as? String),
                  let id = (b["id"] as? NSNumber)?.intValue
            else { return ["error": "expected {frame_id, id} (id is a mark number from `floaty som`)"] }
            guard let frame = AgentCapture.markFrame(id: fid) else {
                return ["error": "unknown or expired frame_id; re-run `floaty som`"]
            }
            guard let mark = frame.marks.first(where: { $0.id == id }) else {
                return ["error": "no mark #\(id) in this frame (it has \(frame.marks.count); ids 1–\(frame.marks.count))"]
            }

            // AX-backed frame: validate the window hasn't moved/resized/closed
            // (the native analog of the capture-frame guard), raise that exact
            // PROCESS (pid-precise → no two-Chrome ambiguity), then click.
            if frame.source == "ax" {
                guard let cur = AgentCapture.listWindows().first(where: { $0.id == frame.windowID }) else {
                    return ["error": "the window closed since `floaty som`; re-run `floaty som`"]
                }
                let tol: CGFloat = 4
                if abs(cur.bounds.origin.x - frame.windowBounds.origin.x) > tol
                    || abs(cur.bounds.origin.y - frame.windowBounds.origin.y) > tol
                    || abs(cur.bounds.size.width - frame.windowBounds.size.width) > tol
                    || abs(cur.bounds.size.height - frame.windowBounds.size.height) > tol {
                    return ["error": "the window moved or resized since `floaty som`; re-run `floaty som`"]
                }
                // Raise that EXACT process (pid-precise → no two-Chrome ambiguity)
                // via the full cooperative-activation path, then click its center.
                let clicks = (b["clicks"] as? NSNumber)?.intValue ?? 1
                let ok = AgentInput.click(at: mark.center, button: self.button(b), modifiers: self.mods(b),
                                          clicks: clicks, pacing: self.pacing(b),
                                          target: nil, targetPID: frame.pid != 0 ? frame.pid : nil)
                return ok ? ["ok": true, "id": id, "screen_x": mark.center.x, "screen_y": mark.center.y,
                             "role": mark.role, "name": mark.name]
                          : self.inputFailure("click-mark", b)
            }

            // CDP-backed frame.
            // Staleness guard: one eval re-reading the page's window origin, scroll,
            // and url — any drift means the stored screen coords are wrong now.
            do {
                // Return a plain object — runJavaScript re-serializes the value,
                // so JSON.stringify here would double-encode to a String and the
                // [String:Any] cast below would silently fail (skipping the guard).
                let probe = "({sx:window.screenX,sy:window.screenY,scx:window.scrollX,scy:window.scrollY,url:location.href})"
                if let json = try await AgentDOM.runJavaScript(expression: probe, port: frame.port, match: frame.match, viaExtension: frame.viaExtension),
                   let st = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                    func d(_ k: String) -> Double { (st[k] as? NSNumber)?.doubleValue ?? .nan }
                    let tol = 2.0
                    if (st["url"] as? String) != frame.url
                        || abs(d("sx") - frame.screenX) > tol || abs(d("sy") - frame.screenY) > tol
                        || abs(d("scx") - frame.scrollX) > tol || abs(d("scy") - frame.scrollY) > tol {
                        return ["error": "page changed since `floaty som` (navigated, scrolled, or window moved); re-run `floaty som`"]
                    }
                }
            } catch { return ["error": "click-mark: \(error.localizedDescription)"] }
            // Raise the tab's window so the screen-point click lands on it.
            try? await AgentDOM.bringToFront(port: frame.port, match: frame.match, viaExtension: frame.viaExtension)
            let clicks = (b["clicks"] as? NSNumber)?.intValue ?? 1
            let ok = AgentInput.click(at: mark.center, button: self.button(b), modifiers: self.mods(b),
                                      clicks: clicks, pacing: self.pacing(b), target: self.target(b))
            return ok ? ["ok": true, "id": id, "screen_x": mark.center.x, "screen_y": mark.center.y,
                         "role": mark.role, "name": mark.name]
                      : self.inputFailure("click-mark", b)
        }

        // Keep per-feature data (Devtools logs, Browser Context captures,
        // Context Snaps) within the user's retention/size budget: one sweep
        // now, then hourly.
        StorageJanitor.shared.start()

        // Restore every window from the per-window records (frame + avatar
        // style). No records (first run / legacy install) → one fresh window,
        // which falls back to the old shared-frame slot for migration.
        let records = WindowStateStore.load()

        // Sweep transcript logs no saved tab claims. Sessions discarded while
        // the app runs delete their own file; this catches what they can't —
        // "Quit Without Saving", crashed-away windows, pinned windows dropped
        // at quit. Runs before any restored tab re-opens its log.
        let liveSessionIDs = Set(records.flatMap { $0.tabs ?? [] }
                                        .compactMap { $0.sessionID })
        TranscriptDisk.purgeOrphans(keeping: liveSessionIDs)

        if records.isEmpty {
            makeWindow()
        } else {
            for record in records { makeWindow(restoring: record) }
        }

        hotKey = HotKey()
        registerHotKeys()

        statusItem.onToggle        = { [weak self] in self?.toggle() }
        statusItem.onNewWindow     = { [weak self] in self?.makeWindow() }
        statusItem.onRunBackgroundTask = { [weak self] in self?.runBackgroundTask() }
        statusItem.onNewTab        = { [weak self] in self?.newTerminalTabInCurrentWindow() }
        statusItem.onNewBrowserTab = { [weak self] in self?.newBrowserTabInCurrentWindow() }
        statusItem.onNewNote       = { [weak self] in self?.newNoteTabInCurrentWindow() }
        statusItem.onMirrorWindow  = { [weak self] in self?.newMirrorTabInCurrentWindow() }
        statusItem.onCompareFiles  = { [weak self] in self?.compareFilesInCurrentWindow() }
        statusItem.onShowRuler     = { [weak self] in self?.ruler.toggle() }
        statusItem.onPreferences   = { [weak self] in self?.settingsWC.show() }

        // The `ruler` terminal helper emits a private OSC that TerminalController
        // turns into this notification — summon (toggle) the ruler from any shell.
        NotificationCenter.default.addObserver(
            forName: .floatySummonRuler, object: nil, queue: .main
        ) { [weak self] _ in self?.ruler.toggle() }

        switcher.sessionsProvider = { [weak self] in self?.sessionEntries() ?? [] }
        switcher.onSummon = { [weak self] entry in self?.summon(entry) }
        switcher.onClose = { [weak self] entry in
            guard let self, let wc = entry.window,
                  self.windows.contains(where: { $0 === wc }) else { return }
            wc.closeSession(entry.tab)
        }

        // Feed the menu the list of individually-minimized windows so each can
        // be restored on its own, and provide the restore action.
        statusItem.hiddenWindowsProvider = { [weak self] in
            (self?.windows ?? [])
                .filter { $0.isMinimized }
                .map { (id: $0.id, title: $0.displayTitle) }
        }
        statusItem.onRestoreWindow = { [weak self] id in
            self?.windows.first { $0.id == id }?.show()
        }

        // Ghosted windows can't be clicked (manual ghost = click-through; Agent
        // Ghost = non-activating + a pass-through banner). Either way this menu
        // section is how they come back — important for Agent Ghost now that the
        // banner is non-interactive (it can't release itself by design).
        statusItem.ghostedWindowsProvider = { [weak self] in
            (self?.windows ?? [])
                .filter { $0.isGhosted || $0.isAgentGhosted }
                .map { (id: $0.id, title: $0.displayTitle) }
        }
        statusItem.onUnghostWindow = { [weak self] id in
            guard let wc = self?.windows.first(where: { $0.id == id }) else { return }
            if wc.isGhosted { wc.setGhosted(false) }
            if wc.isAgentGhosted { wc.setAgentGhost(false) }
        }

        // Fleet summary: periodically count terminal sessions that are
        // working vs. blocked waiting on the user, and surface the totals
        // beside the menu-bar icon.
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let terminals = self.windows.flatMap(\.tabs)
                .compactMap { $0 as? TerminalController }
            let waiting = terminals.filter(\.awaitingInput).count
            let working = terminals.filter { $0.hasRunningForegroundJob && !$0.awaitingInput }.count
            self.statusItem.updateSummary(working: working, waiting: waiting)

            // Auto-surface: when an agent-ghosted window's session stops for user
            // input, release Agent Ghost and pulse it so the user sees the prompt
            // and can respond — the window can't be interacted with while ghosted.
            //
            // BUT skip this while the agent is actively driving: a driving session
            // reads as `awaitingInput` in the gaps between `floaty` calls, so an
            // unconditional release here tore the ghost down within one timer tick
            // (banner never stayed up, synthetic keystrokes scattered). Only surface
            // once the agent has gone quiet — then awaitingInput means the user.
            if !DevtoolsRelay.shared.agentIsDriving() {
                for wc in self.windows where wc.isAgentGhosted {
                    let waitingHere = wc.tabs
                        .compactMap { $0 as? TerminalController }
                        .contains { $0.awaitingInput }
                    if waitingHere {
                        wc.setAgentGhost(false)
                        wc.pulseAttention()
                    }
                }
            }
        }
        timer.tolerance = 1
        fleetSummaryTimer = timer

        // Re-register the global hotkey if it changes in Preferences.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChange, object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Ask whether to save the session — only when there's something worth
        // saving (any unpinned window; pinned windows are dropped regardless,
        // since their Space can't be re-targeted after relaunch).
        let savable = windows.filter { !$0.isPinned }
        if !savable.isEmpty {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Save windows for next launch?"
            alert.informativeText = """
                Saved windows reopen with their tabs: terminals restart in \
                their last directory (running processes end), browser tabs \
                reload their page. Windows pinned to a Space are dropped — \
                Spaces can't be re-targeted after a relaunch.
                """
            alert.addButton(withTitle: "Save & Quit")
            alert.addButton(withTitle: "Quit Without Saving")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                AppRuntime.isQuitting = true
                WindowStateStore.save(savable.map { $0.stateRecord })
                return .terminateNow
            case .alertSecondButtonReturn:
                AppRuntime.isQuitting = true
                // Keep only the front window's geometry (no tabs), so the next
                // launch opens one fresh window in a familiar spot.
                if let first = savable.first {
                    var record = first.stateRecord
                    record.tabs = nil
                    record.activeIndex = nil
                    WindowStateStore.save([record])
                } else {
                    WindowStateStore.save([])
                }
                return .terminateNow
            default:
                return .terminateCancel
            }
        }
        AppRuntime.isQuitting = true
        return .terminateNow
    }

    /// Writes the current per-window records (frame + avatar + tabs) to disk.
    /// Called whenever a window reports a state change, and on close — this
    /// continuous snapshot doubles as crash recovery; the quit prompt decides
    /// what the FINAL saved session looks like. Pinned windows are excluded
    /// (their Space identity can't survive a relaunch).
    private func persistWindowState() {
        WindowStateStore.save(windows.filter { !$0.isPinned }.map { $0.stateRecord })
    }

    /// The toggle combo currently registered with Carbon, so unrelated settings
    /// changes (font slider ticks, opacity drags…) don't unregister/re-register
    /// the hotkeys dozens of times per second.
    private var registeredToggleCombo: (code: UInt32, mods: UInt32)?

    @objc private func settingsChanged() {
        let code = Settings.shared.hotKeyCode
        let mods = Settings.shared.hotKeyModifiers
        guard registeredToggleCombo?.code != code
           || registeredToggleCombo?.mods != mods else { return }
        registerHotKeys()
    }

    /// Registers the global hotkeys:
    ///  - id 1: the toggle (⌥⌘7 by default, customizable) — localized hide/show.
    ///  - id 2: spawn-on-this-Space, fixed at ⌥⌘5.
    ///  - id 3: session switcher, fixed at ⌥⌘K.
    /// Re-called whenever Settings change so a rebind of the toggle updates it.
    private func registerHotKeys() {
        let code = Settings.shared.hotKeyCode
        let mods = Settings.shared.hotKeyModifiers
        hotKey.register(id: 1, keyCode: code, modifiers: mods, action: { [weak self] in
            self?.handleTogglePressed()
        }, onRelease: { [weak self] in
            self?.handleToggleReleased()
        })
        registeredToggleCombo = (code, mods)
        hotKey.register(id: 2, keyCode: UInt32(kVK_ANSI_5),
                        modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.spawnOnCurrentSpace()
        }
        hotKey.register(id: 3, keyCode: UInt32(kVK_ANSI_K),
                        modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.toggleSwitcher()
        }
    }

    // MARK: - Windows

    /// Creates a new floating window.
    /// - Parameter initialDirectory: Starting directory for the new window's
    ///   first terminal tab. Pass nil to use $HOME (the default).
    /// - Parameter record: When restoring at launch, the persisted record whose
    ///   frame and avatar style this window adopts (skips normal placement).
    @discardableResult
    private func makeWindow(initialDirectory: String? = nil,
                            restoring record: WindowRecord? = nil) -> TerminalWindowController {
        let isLaunchWindow = windows.isEmpty
        // Cascade from the window the user is currently looking at (if any) so a
        // new window lands where they are — not from a stale shared frame that
        // might belong to a pinned window on another Space.
        let reference = (isLaunchWindow || record != nil) ? nil : frontWindowFrameOnCurrentSpace()
        // A record with saved tabs starts empty — restoreTabs() rebuilds them.
        let restoredTabs = record?.tabs ?? []
        let wc = TerminalWindowController(initialDirectory: initialDirectory,
                                          startEmpty: !restoredTabs.isEmpty)
        wireCallbacks(wc)
        windows.append(wc)
        if let record {
            wc.applyRestored(record)
            if !restoredTabs.isEmpty {
                wc.restoreTabs(restoredTabs, activeIndex: record.activeIndex ?? 0)
            }
        } else {
            wc.placeInitialFrame(reference: reference, isLaunchWindow: isLaunchWindow)
        }
        wc.show()
        persistWindowState()
        return wc
    }

    /// Frame of the window currently visible on the user's Space, preferring the
    /// key window. Returns nil when no FloatyTerm window is on the active Space
    /// (e.g. a fresh Space where all existing windows are pinned elsewhere).
    private func frontWindowFrameOnCurrentSpace() -> NSRect? {
        if let key = windows.first(where: { $0.isKey }) { return key.panel.frame }
        if let here = windows.first(where: isPresentOnCurrentSpace) { return here.panel.frame }
        return nil
    }

    /// Creates a new floating window that starts empty and immediately adopts
    /// `tab`.  The panel is positioned so `screenPoint` (the drop location) sits
    /// near the top-left of the new window.
    @discardableResult
    private func makeWindowAdopting(_ tab: any TabContent, at screenPoint: NSPoint) -> TerminalWindowController {
        let wc = TerminalWindowController(startEmpty: true)
        wireCallbacks(wc)
        windows.append(wc)
        // Position the new window near the drop point, kept fully on-screen
        // (a drop near a screen edge must not strand the window off-screen).
        let windowSize = wc.panel.frame.size
        let raw = NSRect(x: screenPoint.x - 20,
                         y: screenPoint.y - windowSize.height + 20,
                         width: windowSize.width, height: windowSize.height)
        wc.panel.setFrame(wc.panel.clampToVisibleScreen(raw), display: false)
        wc.adoptTab(tab)
        wc.show()
        persistWindowState()
        return wc
    }

    /// Wires the three standard callbacks that all windows share.
    /// `wc` must be captured weakly: these closures are stored ON wc itself,
    /// so a strong capture is a retain cycle that leaks every closed window.
    private func wireCallbacks(_ wc: TerminalWindowController) {
        wc.onNewWindow = { [weak self, weak wc] in
            self?.makeWindow(initialDirectory: wc?.activeTerminalWorkingDirectory)
        }
        wc.onClosed = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
            self?.persistWindowState()
        }
        wc.onOpenPreferences = { [weak self] in self?.settingsWC.show() }
        wc.onDetachTab = { [weak self] tab, screenPoint in
            self?.makeWindowAdopting(tab, at: screenPoint)
        }
        wc.onStateChanged = { [weak self] in self?.persistWindowState() }
        wc.onOpenSwitcher = { [weak self] in self?.toggleSwitcher() }
        wc.onSessionDone = { [weak self] tab in self?.summonForAttention(tab) }
    }

    /// An armed "notify when done" session finished: bring it to the user's
    /// current Space via the switcher's summon path (which handles every
    /// window state — hidden, collapsed, tickered, pinned-away via borrow),
    /// then pulse whichever window hosts the tab now so the arrival is seen.
    private func summonForAttention(_ tab: any TabContent) {
        guard let wc = windows.first(where: { w in w.tabs.contains { $0 === tab } }) else { return }
        summon(SessionEntry(window: wc, tab: tab, name: tab.displayName,
                            location: "", status: .idle,
                            isTerminal: tab is TerminalController,
                            isAgent: (tab as? TerminalController)?.isAgentSession == true,
                            windowSymbol: wc.avatarStyle.symbol,
                            windowColor: wc.avatarStyle.color))
        // Re-resolve the host: a pinned-away source lends the tab to a fresh
        // borrower window created by summon().
        windows.first(where: { w in w.tabs.contains { $0 === tab } })?.pulseAttention()
    }

    private func currentWindow() -> TerminalWindowController? {
        windows.first(where: { $0.isKey }) ?? windows.last
    }

    /// Fire-and-forget: ask for a command, run it in a fresh session that
    /// immediately collapses to a bubble, armed to summon the user when it
    /// finishes (the window's 2s tick → onSessionDone → summonForAttention
    /// handles the rest).
    private func runBackgroundTask() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Run Task in Background"
        alert.informativeText = "Runs in a new session collapsed to a bubble; "
            + "it will summon you when it finishes."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "e.g. npm test"
        alert.accessoryView = field
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let command = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        // Inherit the directory the user is currently working in.
        let wc = makeWindow(initialDirectory: currentWindow()?.activeTerminalWorkingDirectory)
        // Give the shell a beat to start (the pty buffers input regardless),
        // then type the command, arm notify-when-done, and get out of the way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak wc] in
            guard let self, let wc, self.windows.contains(where: { $0 === wc }),
                  let session = wc.tabs.first as? TerminalController else { return }
            session.run(command: command)
            session.notifyWhenDone = true
            wc.collapseToAvatar()
        }
    }

    private func newTerminalTabInCurrentWindow() {
        if let wc = currentWindow() {
            wc.openNewTab()
            wc.show()
        } else {
            makeWindow()
        }
    }

    private func newBrowserTabInCurrentWindow() {
        if let wc = currentWindow() {
            wc.openNewBrowserTab()
            wc.show()
        } else {
            // No window yet — make one (starts with a terminal tab), then add browser.
            let wc = makeWindow()
            wc.openNewBrowserTab()
        }
    }

    private func newNoteTabInCurrentWindow() {
        if let wc = currentWindow() {
            wc.openNewNote()
            wc.show()
        } else {
            // No window yet — make one (starts with a terminal tab), then add note.
            let wc = makeWindow()
            wc.openNewNote()
        }
    }

    private func newMirrorTabInCurrentWindow() {
        if let wc = currentWindow() {
            wc.openNewMirror()
            wc.show()
        } else {
            // No window yet — make one (starts with a terminal tab), then add mirror.
            let wc = makeWindow()
            wc.openNewMirror()
        }
    }

    /// Menu / ⇧⌘D entry: present the two-file picker in the current window
    /// (creating one if none exists), then open a diff tab.
    private func compareFilesInCurrentWindow() {
        let wc = currentWindow() ?? makeWindow()
        wc.show()
        wc.openCompareFilesPanel()
    }

    /// Relay entry (shell shim): paths are already resolved — open the diff tab
    /// directly in the current window, creating one if needed.
    private func compareFilesInCurrentWindow(left: URL, right: URL) {
        let wc = currentWindow() ?? makeWindow()
        wc.show()
        wc.addDiffTab(left: left, right: right)
    }

    /// A FloatyTerm window the user can actually see on the CURRENT Space:
    /// any visible roaming (unpinned, all-Spaces) window, or a pinned window
    /// that happens to live on the active Space.
    private func isPresentOnCurrentSpace(_ wc: TerminalWindowController) -> Bool {
        wc.isVisible && (!wc.isPinned || wc.isOnActiveSpace)
    }

    /// ⌥⌘7 — a localized toggle for the CURRENT Space. It only hides or shows
    /// terminals relevant to where the user is; it never spawns (that's ⌥⌘5)
    /// and never yanks pinned windows bound to other Spaces.
    /// Returns the windows it revealed (empty when it hid or spawned), so the
    /// hold-to-peek path knows what to put away again on key release.
    @discardableResult
    private func toggle() -> [TerminalWindowController] {
        // Bootstrap: no windows exist at all → create the first one.
        if windows.isEmpty {
            makeWindow()
            return []
        }

        // If something is already visible on this Space, dismiss only those.
        // Pinned windows bound to OTHER Spaces are left untouched.
        if windows.contains(where: isPresentOnCurrentSpace) {
            windows.filter(isPresentOnCurrentSpace).forEach { $0.hide() }
            return []
        }

        // Nothing here: reveal everything that was hidden — roaming windows
        // (which join all Spaces, so they reappear here) AND pinned windows
        // hidden by a previous ⌥⌘7 (each reappears on its own Space). We skip
        // windows tucked away via their own controls (minimize / collapse
        // bubble / ticker strip), which are restored differently. This keeps
        // ⌥⌘7 a symmetric toggle: whatever it hides, it brings back.
        let toShow = windows.filter {
            !$0.isVisible && !$0.isMinimized && !$0.isCollapsed && !$0.isTicker
        }
        toShow.forEach { $0.show() }
        return toShow
    }

    // MARK: - Hold-to-peek (toggle hotkey held = show while held)

    private var toggleKeyIsDown = false
    private var togglePressTime: Date?
    private var peekCandidates: [TerminalWindowController] = []

    private func handleTogglePressed() {
        guard !toggleKeyIsDown else { return }   // ignore key auto-repeat
        toggleKeyIsDown = true
        togglePressTime = Date()
        peekCandidates = toggle()
    }

    /// Released after holding ≥0.45s on a press that REVEALED windows → that
    /// was a peek: tuck them away again. A quick tap keeps them (normal toggle).
    private func handleToggleReleased() {
        toggleKeyIsDown = false
        guard let pressed = togglePressTime else { return }
        togglePressTime = nil
        if Date().timeIntervalSince(pressed) >= 0.45, !peekCandidates.isEmpty {
            peekCandidates.filter { $0.isVisible }.forEach { $0.hide() }
        }
        peekCandidates = []
    }

    /// ⌥⌘5 — explicitly spawn a fresh window on the current Space, regardless
    /// of what's pinned elsewhere. Placement cascades from a window already on
    /// this Space, or centers on the active screen when the Space is empty.
    private func spawnOnCurrentSpace() {
        makeWindow()
    }

    // MARK: - Session switcher (⌥⌘K)

    private func toggleSwitcher() {
        // Nothing to switch between → behave like the toggle bootstrap.
        if windows.isEmpty {
            makeWindow()
            return
        }
        switcher.toggle()
    }

    /// Snapshot of every session (tab) across every window for the switcher.
    /// With multiple windows the location carries a "win N" prefix, and every
    /// row gets its window's avatar identity — together they pin down exactly
    /// which window (and overlaid app) a session lives in.
    private func sessionEntries() -> [SessionEntry] {
        let many = windows.count > 1
        return windows.enumerated().flatMap { i, wc in
            let prefix = many ? "win \(i + 1) · " : ""
            return wc.tabs.map { tab in
                SessionEntry(window: wc,
                             tab: tab,
                             name: tab.displayName,
                             location: prefix + location(of: wc),
                             status: wc.status(of: tab),
                             isTerminal: tab is TerminalController,
                             isAgent: (tab as? TerminalController)?.isAgentSession == true,
                             windowSymbol: wc.avatarStyle.symbol,
                             windowColor: wc.avatarStyle.color)
            }
        }
    }

    // MARK: - Session tunnel (peek) helpers

    /// Resolves peek's target session: by exact sessionID, id prefix (≥6
    /// chars), exact tab name, then name substring — after removing the
    /// caller's own session (--exclude $FLOATYTERM_SESSION_ID). With no
    /// --session and exactly one candidate left, that one wins, which is
    /// what makes `peek --exclude $FLOATYTERM_SESSION_ID` just work in a
    /// two-terminal setup.
    private func resolvePeekTarget(_ b: [String: Any]) -> (term: TerminalController?, error: [String: Any]?) {
        var entries = sessionEntries().filter { $0.tab is TerminalController }
        if let excluded = b["exclude"] as? String, !excluded.isEmpty {
            entries.removeAll { ($0.tab as? TerminalController)?.sessionID == excluded }
        }
        let terms: [(name: String, term: TerminalController)] = entries.compactMap { e in
            (e.tab as? TerminalController).map { (e.name, $0) }
        }
        // Ambiguity replies carry the machine-readable roster, so a calling
        // agent picks a session from THIS reply instead of prose-parsing or
        // making a second `floaty sessions` round-trip.
        let roster: [[String: Any]] = entries.compactMap { e in
            guard let t = e.tab as? TerminalController else { return nil }
            return ["id": t.sessionID, "name": e.name,
                    "status": String(describing: e.status), "is_agent": e.isAgent]
        }
        guard !terms.isEmpty else {
            return (nil, ["error": "no terminal sessions to peek (after --exclude)"])
        }
        guard let query = (b["session"] as? String)?
                .trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            if terms.count == 1 { return (terms[0].term, nil) }
            return (nil, ["error": "several sessions — pass --session <name|id>",
                          "sessions": roster])
        }
        let q = query.lowercased()
        if let hit = terms.first(where: { $0.term.sessionID.lowercased() == q })
            ?? (q.count >= 6 ? terms.first(where: { $0.term.sessionID.lowercased().hasPrefix(q) }) : nil)
            ?? terms.first(where: { $0.name.lowercased() == q })
            ?? terms.first(where: { $0.name.lowercased().contains(q) }) {
            return (hit.term, nil)
        }
        return (nil, ["error": "no session matches \"\(query)\"", "sessions": roster])
    }

    /// Builds the peek reply: a command block (default: the latest), a raw
    /// absolute-index line window (--since), or — when the target shell has
    /// no OSC 133 integration — the transcript tail.
    private func peekResult(term: TerminalController, body b: [String: Any]) -> [String: Any] {
        func epoch(_ t: TimeInterval) -> Double {
            Date(timeIntervalSinceReferenceDate: t).timeIntervalSince1970.rounded()
        }
        let maxLines = min(max((b["max_lines"] as? NSNumber)?.intValue ?? 500, 1), 5000)
        var out: [String: Any] = [
            "ok": true,
            "session": ["id": term.sessionID, "name": term.displayName],
            "transcript_end": term.transcriptAbsoluteEnd,
        ]

        // --since: raw line window in absolute transcript coordinates,
        // reading forward; next_since makes polling a one-liner. Always
        // verbatim rows — joining/collapsing would break the index math.
        if let since = (b["since"] as? NSNumber)?.intValue {
            let (lines, _, dropped) = term.blockLines(start: max(0, since), end: nil)
            let page = Array(lines.prefix(maxLines))
            out["mode"] = "since"
            out["since"] = since
            out["dropped_prefix"] = dropped
            out["lines"] = page
            out["next_since"] = max(0, since) + dropped + page.count
            out["more"] = lines.count > page.count
            return out
        }

        // Lines are cleaned for agent consumption by default — soft-wrapped
        // rows joined back into logical lines, repaint dupes and blank runs
        // folded. --raw returns the verbatim screen rows.
        let raw = (b["raw"] as? NSNumber)?.boolValue ?? false
        func present(_ lines: [String], _ wraps: [Bool]) -> (lines: [String], collapsed: Int) {
            if raw { return (lines, 0) }
            return TerminalController.cleanedForPeek(
                TerminalController.logicalLines(lines, wraps: wraps))
        }

        let blocks = term.commandBlocks
        guard !blocks.isEmpty else {
            // No 133 markers seen: still useful — return the tail.
            let start = max(0, term.transcriptAbsoluteEnd - min(maxLines, 200))
            let (lines, wraps, _) = term.blockLines(start: start, end: nil)
            let (page, collapsed) = present(lines, wraps)
            out["mode"] = "tail"
            out["no_blocks"] = true
            out["hint"] = "no OSC 133 shell integration in this session; returned the transcript tail (page with --since)"
            out["lines"] = Array(page.suffix(maxLines))
            if collapsed > 0 { out["noise_collapsed"] = collapsed }
            return out
        }

        let block: TerminalController.CommandBlock?
        switch b["block"] {
        case let n as NSNumber:
            block = blocks.first { $0.id == n.intValue }
        case let s as String where s.lowercased() != "last":
            block = Int(s).flatMap { id in blocks.first { $0.id == id } }
        default:
            block = blocks.last
        }
        guard let block else {
            return ["error": "no such block — this session has blocks \(blocks.first!.id)…\(blocks.last!.id)"]
        }

        let (rawLines, wraps, dropped) = term.blockText(block)
        let (lines, collapsed) = present(rawLines, wraps)
        let tail = Array(lines.suffix(maxLines))
        var blk: [String: Any] = [
            "id": block.id,
            "running": block.endLine == nil,
            "start_line": block.startLine,
            "line_count": lines.count,
            "dropped_prefix": dropped,
            "head_truncated": max(0, lines.count - tail.count),
            "started_at": epoch(block.startedAt),
            "lines": tail,
        ]
        if collapsed > 0 { blk["noise_collapsed"] = collapsed }
        if let c = block.command { blk["command"] = c }
        if let e = block.endLine { blk["end_line"] = e }
        if let x = block.exitCode { blk["exit_code"] = Int(x) }
        if let t = block.endedAt { blk["ended_at"] = epoch(t) }
        out["mode"] = "block"
        out["block"] = blk
        out["blocks"] = ["first": blocks.first!.id, "last": blocks.last!.id]
        return out
    }

    private func location(of wc: TerminalWindowController) -> String {
        // The app this window was pinned over, e.g. "another Space (Chrome)".
        let app = wc.pinnedAppName.map { " (\($0))" } ?? ""
        if wc.isCollapsed { return wc.isPinned ? "in bubble\(app)" : "in bubble" }
        if wc.isTicker { return wc.isPinned ? "in ticker\(app)" : "in ticker" }
        if wc.isGhosted { return "ghosted" }
        if let linked = wc.linkedAppName {
            return wc.isVisible ? "over \(linked)" : "waiting for \(linked)"
        }
        if wc.isMinimized || !wc.isVisible { return wc.isPinned ? "hidden\(app)" : "hidden" }
        if wc.isPinned {
            // Judge by actual on-screen presence, not the hidden-panel guess.
            return (wc.presenceOnActiveSpace ?? false) ? "pinned here" : "another Space\(app)"
        }
        return "here"
    }

    /// Brings the chosen session to the user's current Space.
    ///
    /// macOS offers no public API to place a window on a non-active Space, so
    /// "send it back" works at the TAB level: when the session's window is
    /// pinned to another Space, we borrow the tab into a window here while the
    /// source window stays where it is — the header's return arrow re-merges
    /// the tab into it. A single-tab window LENDS its session instead: it
    /// stays behind empty (bubble / ticker / placeholder panel), keeping its
    /// pin, Space, and frame, so Return restores everything exactly as it was.
    private func summon(_ entry: SessionEntry) {
        guard let wc = entry.window,
              windows.contains(where: { $0 === wc }),
              let idx = wc.tabs.firstIndex(where: { $0 === entry.tab }) else { return }
        let tab = entry.tab

        // Is the window away on another Space? Judged by whatever is actually
        // on screen (panel, bubble, or ticker strip) — `panel.isOnActiveSpace`
        // lies for hidden panels, which is what broke pinned+collapsed and
        // pinned+tickered windows. Unknown presence (pinned + minimized) is
        // treated as away: the whole-window path is correct either way.
        let away = wc.isPinned && !(wc.presenceOnActiveSpace ?? false)

        if !away {
            // Roaming (joins all Spaces) or pinned right here: reveal + focus.
            wc.selectTab(at: idx)
            if wc.isGhosted { wc.setGhosted(false) }   // summon = interactive again
            if wc.isCollapsed {
                wc.expandFromAvatar(to: crossScreenSummonTarget(for: wc))
            } else if wc.isTicker {
                wc.expandFromTicker(to: crossScreenSummonTarget(for: wc))
            } else {
                wc.show()
            }
            return
        }

        // Borrow the tab into a window on this Space. The source window never
        // moves: with other tabs it keeps living normally; with only this one
        // it LENDS it, staying behind empty (still pinned, still collapsed /
        // tickered / minimized, however it was) as the permanent home the
        // Return arrow sends the tab back to. Either way the arrow shows.
        if wc.tabs.count >= 2 {
            wc.releaseTab(tab)
        } else if wc.lendOnlyTab() == nil {
            return
        }
        let borrower = makeWindowAdopting(tab, at: .zero)
        if let frame = summonTargetFrame(size: borrower.panel.frame.size) {
            borrower.panel.setFrame(frame, display: false)
        }
        if windows.contains(where: { $0 === wc }) {
            borrower.markBorrowed(tab, from: wc)
        }
    }

    /// Expanding a collapsed session normally unfolds it in place, around its
    /// bubble / ticker strip. But when that representative sits on a DIFFERENT
    /// screen than the user (roaming bubbles don't follow the mouse across
    /// displays), in-place expansion would land the window over there — so give
    /// the expand an explicit destination at the summon grid point instead.
    /// nil = same screen; expand in place.
    private func crossScreenSummonTarget(for wc: TerminalWindowController) -> NSRect? {
        guard let repFrame = wc.collapsedRepresentativeFrame else { return nil }
        let mouse = NSEvent.mouseLocation
        guard let userScreen = NSScreen.screens.first(where: {
            NSMouseInRect(mouse, $0.frame, false)
        }), !userScreen.frame.intersects(repFrame) else { return nil }
        return summonTargetFrame(size: wc.expandedSize)
    }

    /// The user's summon grid point on the active screen, sized to `size` —
    /// where borrowed and whole-summoned windows land, away from whatever
    /// terminal is already in view. The screen under the mouse is "where the
    /// user is" — NSScreen.main tracks the key window, which is wrong when
    /// summoning over another app (e.g. fullscreen on a second display).
    private func summonTargetFrame(size: NSSize) -> NSRect? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let vis = screen?.visibleFrame else { return nil }
        return Settings.shared.summonPosition.frame(forSize: size, in: vis)
    }

    // MARK: - Agent route body parsing

    /// One line per element — the token-lean default the model reads (roughly
    /// 4× fewer tokens than the equivalent object array). Geometry stays for
    /// spatial reasoning; centers are host-side concerns (the model acts by
    /// mark id / --press / first-match mirror, never by emitting a coordinate).
    /// `brief` drops geometry too: id, role, name only.
    static func elementLines(_ rows: [(id: Int, role: String, name: String, rect: CGRect)],
                             brief: Bool) -> String {
        rows.map { r in
            let name = r.name
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
            var line = r.role.isEmpty ? "\(r.id)\t\"\(name)\"" : "\(r.id)\t\(r.role)\t\"\(name)\""
            if !brief {
                line += "\t@\(Int(r.rect.origin.x.rounded())),\(Int(r.rect.origin.y.rounded()))"
                    + " \(Int(r.rect.width.rounded()))x\(Int(r.rect.height.rounded()))"
            }
            return line
        }.joined(separator: "\n")
    }

    /// Table-first SoM's image decision: pixels are needed only when the mark
    /// table can't stand alone — few marks (canvas app whose semantics are off)
    /// or mostly-unnamed marks (icon-only toolbars).
    static func somNeedsImage(named: Int, total: Int) -> Bool {
        total < 3 || Double(named) < 0.8 * Double(total)
    }

    /// Parse a `--region` string — "x,y,WxH" (or "x,y,w,h") in GLOBAL screen
    /// points — into a rect. nil = malformed.
    static func parseRegion(_ s: String) -> CGRect? {
        let nums = s.lowercased()
            .replacingOccurrences(of: "x", with: ",")
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 4, nums[2] > 0, nums[3] > 0 else { return nil }
        return CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
    }

    /// Resolve the window a perception check should observe: window_id /
    /// pid (auto-raising an off-Space window) / window name, falling back to
    /// the action's --target app name. Shared by act-until and run plans.
    @MainActor
    private func resolveObservedWindow(_ b: [String: Any]) async -> UInt32? {
        if let wid = (b["window_id"] as? NSNumber)?.uint32Value { return wid }
        if let pid = (b["pid"] as? NSNumber).map({ pid_t($0.intValue) }) {
            var win = AgentCapture.listWindows().filter({ $0.pid == pid }).max(by: { $0.area < $1.area })
            if win == nil {
                _ = await AgentAX.ensureOnScreen(pid: pid)
                win = AgentCapture.listWindows().filter({ $0.pid == pid }).max(by: { $0.area < $1.area })
            }
            if let win { return win.id }
        }
        if let name = (b["window"] as? String) ?? (b["target"] as? String) ?? (b["app"] as? String) {
            if let win = AgentCapture.bestMatch(named: name) { return win.id }
            // Name matched no on-screen window — the app may be on another
            // Space (seen live: `run --target MarkEdit` failed while MarkEdit
            // sat off-Space). Resolve to a pid and raise, like the pid path.
            if let pid = try? AgentAX.resolvePID(app: name, pid: nil) {
                _ = await AgentAX.ensureOnScreen(pid: pid)
                if let win = AgentCapture.listWindows().filter({ $0.pid == pid }).max(by: { $0.area < $1.area }) {
                    return win.id
                }
            }
        }
        return nil
    }

    /// One actuator step, shared by the plain one-shot routes and the
    /// act-until edge loop (which repeats it verbatim).
    @MainActor
    private func performAction(_ action: String, _ b: [String: Any]) -> [String: Any] {
        switch action {
        case "click":
            guard let p = point(b) else { return ["error": "expected {x,y}"] }
            let clicks = (b["clicks"] as? NSNumber)?.intValue ?? 1
            let ok = AgentInput.click(at: p, button: button(b), modifiers: mods(b),
                                      clicks: clicks, pacing: pacing(b),
                                      target: target(b), targetPID: targetPID(b))
            return ok ? ["ok": true] : inputFailure("click", b)
        case "drag":
            guard let fx = (b["from_x"] as? NSNumber)?.doubleValue,
                  let fy = (b["from_y"] as? NSNumber)?.doubleValue,
                  let tx = (b["to_x"] as? NSNumber)?.doubleValue,
                  let ty = (b["to_y"] as? NSNumber)?.doubleValue
            else { return ["error": "expected {from_x,from_y,to_x,to_y}"] }
            let ok = AgentInput.drag(from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty),
                                     button: button(b), modifiers: mods(b),
                                     pacing: pacing(b), target: target(b),
                                     targetPID: targetPID(b))
            return ok ? ["ok": true] : inputFailure("drag", b)
        case "key":
            guard let key = b["key"] as? String else { return ["error": "expected {key}"] }
            // Check the key name first so an unknown key reports its own precise
            // cause instead of being lumped under the activation failure path.
            guard AgentInput.isKnownKey(key) else {
                return ["error": "key failed: \"\(key)\" is not a known key name. Use a single "
                    + "character (a–z, 0–9, punctuation like / or -), a function key (f1–f12), or a "
                    + "named key (return, tab, space, delete, escape, left/right/up/down, home, end, "
                    + "pgup, pgdown). For arbitrary text use `type`, not `key`."]
            }
            let ok = AgentInput.pressKey(key, modifiers: mods(b),
                                         target: target(b), targetPID: targetPID(b))
            return ok ? ["ok": true, "key": key] : inputFailure("key", b)
        case "scroll":
            let dx = (b["dx"] as? NSNumber)?.intValue ?? 0
            let dy = (b["dy"] as? NSNumber)?.intValue ?? 0
            let ok = AgentInput.scroll(dx: dx, dy: dy, at: point(b),
                                       pacing: pacing(b), target: target(b),
                                       targetPID: targetPID(b))
            return ok ? ["ok": true] : inputFailure("scroll", b)
        default:
            return ["error": "unknown action \"\(action)\""]
        }
    }

    /// Optional pacing from the JSON body: `duration` (seconds) wins, else a
    /// truthy `human` flag uses a default duration; absent → instant.
    private func pacing(_ b: [String: Any]) -> AgentInput.Pacing {
        if let d = (b["duration"] as? NSNumber)?.doubleValue { return .human(duration: d) }
        if (b["human"] as? NSNumber)?.boolValue == true { return .human(duration: 0.4) }
        return .instant
    }
    private func point(_ b: [String: Any]) -> CGPoint? {
        guard let x = (b["x"] as? NSNumber)?.doubleValue,
              let y = (b["y"] as? NSNumber)?.doubleValue else { return nil }
        return CGPoint(x: x, y: y)
    }
    private func button(_ b: [String: Any]) -> AgentInput.MouseButton {
        AgentInput.MouseButton(rawValue: (b["button"] as? String) ?? "left") ?? .left
    }
    private func mods(_ b: [String: Any]) -> [String] {
        if let arr = b["modifiers"] as? [Any] { return arr.compactMap { $0 as? String } }
        // Hand-written plan JSON often says "modifiers":"cmd" (string, not
        // array). Accept it: silently dropping the modifier would turn ⌘S
        // into a literal "s" typed into the document (observed live in a P8
        // run) — the worst failure class, wrong action with no error.
        if let s = b["modifiers"] as? String {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }
    private func target(_ b: [String: Any]) -> String? { b["target"] as? String }
    /// PID target (wins over `--target` name): pins input to one exact process,
    /// so keystrokes can't land in the wrong same-named app (two Chromes).
    private func targetPID(_ b: [String: Any]) -> pid_t? {
        (b["pid"] as? NSNumber).map { pid_t($0.intValue) }
    }

    /// Parse a frame body ({frame_id|frame, x, y} in image pixels) and resolve
    /// it to a global screen point + the owning app (to raise before acting).
    /// Throws a descriptive error for missing fields or a stale/unknown frame.
    @MainActor
    private func resolveFrame(_ b: [String: Any]) throws -> (point: CGPoint, owner: String?) {
        guard let frameID = (b["frame_id"] as? String) ?? (b["frame"] as? String),
              let ix = (b["x"] as? NSNumber)?.doubleValue,
              let iy = (b["y"] as? NSNumber)?.doubleValue
        else { throw SimpleError("expected {frame_id, x, y} (x/y in image pixels)") }
        return try AgentCapture.resolveInFrame(frameID: frameID, imageX: ix, imageY: iy)
    }

    /// Minimal error so a missing-field message surfaces as the relay's JSON error.
    private struct SimpleError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// An input command returned false. CGEvent drops are silent, so re-derive
    /// the most likely cause at failure time and report it — otherwise the agent
    /// gets a bare "type failed" and can't tell a missing permission from a
    /// not-running target from a target that wouldn't come to the front (the
    /// last of which is how stray keystrokes used to land in the caller's own
    /// terminal). `extra` appends a command-specific cause (e.g. unknown key).
    private func inputFailure(_ verb: String, _ b: [String: Any], extra: String? = nil) -> [String: Any] {
        let tail = extra.map { " (\($0))" } ?? ""
        if !AXIsProcessTrusted() {
            return ["error": "\(verb) failed: FloatyTerm needs Accessibility access — grant it under "
                + "System Settings → Privacy & Security → Accessibility, then relaunch.\(tail)"]
        }
        if let pid = targetPID(b) {
            let running = NSRunningApplication(processIdentifier: pid) != nil
            return ["error": running
                ? "\(verb) failed: couldn't bring pid \(pid) to the front\(tail)."
                : "\(verb) failed: no running process with pid \(pid)\(tail)."]
        }
        if let t = target(b) {
            let running = NSWorkspace.shared.runningApplications.contains {
                $0.localizedName == t || $0.bundleIdentifier == t
            }
            return ["error": running
                ? "\(verb) failed: couldn't bring \"\(t)\" to the front\(tail)."
                : "\(verb) failed: target app \"\(t)\" isn't running\(tail)."]
        }
        return ["error": "\(verb) failed\(tail)."]
    }

}
