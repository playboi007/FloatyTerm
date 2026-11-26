import AppKit
import ApplicationServices

/// Background interaction mode — the agent drives an app on one display while
/// the human keeps working in another app, without the two fighting over the
/// frontmost app, the keyboard focus, or the pointer.
///
/// Foreground mode (the default) posts HID-level CGEvents and activates the
/// target first: the same input path the human's own hands use, so it takes
/// the frontmost app and moves the real cursor. Background mode never does
/// either:
///
///   • a click becomes AXPress on the element under the point (hit-tested with
///     AXUIElementCopyElementAtPosition — the cursor never moves)
///   • text and keys are posted to the target PROCESS (CGEventPostToPid, private
///     event source) — the human's keyboard state and frontmost app stay put
///   • nothing activates or raises the target; a window on another Space is an
///     error, not an auto-raise (AX can't reach it, and raising steals focus)
///   • verbs with no non-interfering equivalent (drag, hover/move, wheel
///     scroll, right/double/modified clicks) are REFUSED with needs_foreground
///     instead of silently falling back to the interfering path
///
/// Measured live 2026-10-09 (Chrome on the built-in display, Cursor frontmost
/// on the external one, a focus sampler polling every 50 ms): AXPress,
/// AXSetValue, AXFocused, AXScrollToVisible and pid-posted keystrokes all
/// landed with Cursor frontmost throughout — including a Flutter web app
/// (press a semantics text field to open its edit session, then type).
/// pid-posted MOUSE events were ignored by Chrome, which is why clicks go
/// through AX. `open -g URL` and AppleScript `make new window` both ACTIVATED
/// Chrome, which is why background navigation goes through the address bar's
/// AX element. Isolation is per-app, not guaranteed: every reply carries an
/// `interference` report and the FocusShield hands focus straight back when an
/// action made the target frontmost.
@MainActor
enum AgentBackground {

    /// `mode:"background"` (CLI `--background`, or FLOATY_MODE=background) or a
    /// bare `background:true`. `mode:"foreground"` wins over both.
    nonisolated static func isBackground(_ b: [String: Any]) -> Bool {
        if let m = (b["mode"] as? String)?.lowercased() { return m == "background" || m == "bg" }
        return (b["background"] as? NSNumber)?.boolValue ?? false
    }

    /// The auto-raise every `--pid` verb does in foreground mode — skipped in
    /// background mode, where raising IS the interference.
    static func surface(pid: pid_t, _ b: [String: Any]) async {
        guard !isBackground(b) else { return }
        _ = await AgentAX.ensureOnScreen(pid: pid)
    }

    // MARK: - Refusals

    nonisolated static func needsForeground(_ verb: String, _ why: String, hint: String) -> [String: Any] {
        ["error": "\(verb) has no background equivalent: \(why). \(hint)",
         "needs_foreground": true, "mode": "background"]
    }

    /// The target has windows, but none on the active Space.
    static func offSpaceError(pid: pid_t, verb: String) -> [String: Any] {
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        let off = AgentCapture.listWindows(includingOffScreen: true).contains { $0.pid == pid && !$0.onScreen }
        let why = off
            ? "\(name)'s windows are all on another Space (or minimized). Accessibility can't reach them there, "
                + "and raising one would take focus from you"
            : "\(name) has no open window"
        return ["error": "\(verb) (background): \(why). Put the agent's window on a visible Space — "
                    + "e.g. your second display — then retry; or run this one call with --foreground.",
                "mode": "background", "off_space": off]
    }

    // MARK: - Targets

    /// Target pid: --pid, else --target/--app by name, else the owner of the
    /// on-screen window under `point`.
    static func targetPID(_ b: [String: Any], at point: CGPoint? = nil) -> pid_t? {
        if let p = (b["pid"] as? NSNumber).map({ pid_t($0.intValue) }) { return p }
        if let name = (b["target"] as? String) ?? (b["app"] as? String),
           let p = try? AgentAX.resolvePID(app: name, pid: nil) { return p }
        if let point { return windowUnder(point)?.pid }
        return nil
    }

    /// Topmost normal window (not ours) under a global point.
    static func windowUnder(_ point: CGPoint) -> AgentCapture.WindowInfo? {
        // listWindows keeps the window server's front-to-back order.
        AgentCapture.listWindows().first { $0.bounds.contains(point) }
    }

    /// Windows the agent has acted in, per app (AX window frame). Keystrokes
    /// are only posted while the app's key window is the one the agent has
    /// been working in — never the human's own window of the same app.
    static var lastActedWindow: [pid_t: CGRect] = [:]
    /// The element the agent last pressed/focused per app — the read-back
    /// fallback when an app reports no focused element (Electron, measured).
    static var lastActedElement: [pid_t: AXUIElement] = [:]

    static func noteActed(_ el: AXUIElement, pid: pid_t) {
        if let w = AgentAX.windowOf(el), let f = AgentAX.rectOf(w) { lastActedWindow[pid] = f }
        lastActedElement[pid] = el
    }

    static func nameOf(_ el: AXUIElement) -> String {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, "AXHelp"] {
            if let s = AgentAX.copyString(el, attr as CFString), !s.isEmpty { return String(s.prefix(120)) }
        }
        return ""
    }

    private static func roleOf(_ el: AXUIElement) -> String {
        AgentAX.copyString(el, kAXRoleAttribute as CFString) ?? ""
    }

    private static func app(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 2.0)
        // Chromium/Electron build their web tree only for an assistive client —
        // and they build it for a BACKGROUND window too (measured), given a beat.
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return el
    }

    /// The element's frame covers the point (2 pt slack for rounding). An
    /// element with no frame passes — there is nothing to check against.
    private static func covers(_ el: AXUIElement, _ p: CGPoint) -> Bool {
        guard let r = AgentAX.rectOf(el), r.width > 0, r.height > 0 else { return true }
        return r.insetBy(dx: -2, dy: -2).contains(p)
    }

    private static func near(_ a: CGRect, _ b: CGRect, _ tol: CGFloat = 4) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol
            && abs(a.width - b.width) <= tol && abs(a.height - b.height) <= tol
    }

    /// The app's AX windows that are on the active Space (frame matches an
    /// on-screen window-server window of that pid).
    private static func onScreenAXWindows(_ appEl: AXUIElement, pid: pid_t) -> [AXUIElement] {
        let frames = AgentCapture.listWindows().filter { $0.pid == pid }.map(\.bounds)
        return (AgentAX.copyAXArray(appEl, kAXWindowsAttribute as CFString) ?? []).filter { w in
            guard let f = AgentAX.rectOf(w) else { return false }
            return frames.contains { near($0, f) }
        }
    }

    /// The window the agent works in: the last one it acted in when that's
    /// still on screen, else the app's largest on-screen window.
    static func agentWindow(pid: pid_t) -> AXUIElement? {
        let wins = onScreenAXWindows(app(pid), pid: pid)
        if let last = lastActedWindow[pid],
           let w = wins.first(where: { AgentAX.rectOf($0).map { near($0, last) } ?? false }) {
            return w
        }
        return wins.max { a, b in
            let fa = AgentAX.rectOf(a) ?? .zero, fb = AgentAX.rectOf(b) ?? .zero
            return fa.width * fa.height < fb.width * fb.height
        }
    }

    // MARK: - Click → AXPress

    enum BGError: LocalizedError {
        case otherApp(CGPoint, String)
        case nothingPressable(CGPoint, String)
        case pressFailed(String, Int32)
        case missedPoint(CGPoint, String, CGRect)
        var errorDescription: String? {
            switch self {
            case .otherApp(let p, let owner):
                return "the element at \(Int(p.x)),\(Int(p.y)) belongs to \(owner), not the target app"
            case .nothingPressable(let p, let role):
                return "no pressable control at \(Int(p.x)),\(Int(p.y)) (hit \(role.isEmpty ? "nothing" : role)) — "
                    + "in background mode a click is an AXPress on the element under the point, so a bare "
                    + "surface (canvas, page background) can't be clicked. Target the control by name "
                    + "(`query-ax --title … --press`) or use --foreground for coordinate clicks"
            case .pressFailed(let role, let code):
                return "AXPress on \(role) failed (AX error \(code))"
            case .missedPoint(let p, let role, let r):
                return "the control accessibility offers at \(Int(p.x)),\(Int(p.y)) is a \(role) at "
                    + "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height)), which doesn't cover the point — "
                    + "pressing it would click a different control. On a web page use `floaty input` "
                    + "(trusted CDP clicks at the exact point); else target the control by name or use --foreground"
            }
        }
    }

    struct Pressed {
        let role: String
        let name: String
        let center: CGPoint
    }

    /// Roles that are surfaces, not controls: pressing one in Chromium clicks
    /// its CENTER, which is not where the agent pointed.
    private static let surfaceRoles: Set<String> = [
        "AXWebArea", "AXWindow", "AXScrollArea", "AXSplitGroup", "AXApplication", "AXLayoutArea",
    ]

    private static func isSurface(_ el: AXUIElement) -> Bool {
        let role = roleOf(el)
        if surfaceRoles.contains(role) { return true }
        // A large unnamed group is a layout region (or a canvas), not a control.
        if role == "AXGroup" || role == "AXGenericElement" || role == "AXUnknown",
           nameOf(el).isEmpty, let r = AgentAX.rectOf(el), r.width > 600, r.height > 400 {
            return true
        }
        return false
    }

    private static let controlRoles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXMenuItem", "AXTab", "AXTextField", "AXTextArea", "AXComboBox", "AXSearchField",
        "AXSwitch", "AXDisclosureTriangle", "AXSlider", "AXIncrementor",
    ]

    /// The control a click at this point means: the hit element or a near
    /// ancestor with a control role. Chromium advertises AXPress on nearly
    /// every node (labels included); pressing the button rather than its
    /// label is what a human click does.
    private static func controlAncestor(_ el: AXUIElement, maxHops: Int = 4) -> AXUIElement? {
        var cur: AXUIElement? = el
        var hops = 0
        while let c = cur, hops <= maxHops {
            if controlRoles.contains(roleOf(c)) { return c }
            var p: CFTypeRef?
            guard AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &p) == .success,
                  let p, CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
            cur = (p as! AXUIElement)
            hops += 1
        }
        return nil
    }

    /// Hit-test the element under a global point (no cursor movement) and
    /// AXPress it — or the control it belongs to.
    static func press(at point: CGPoint, pid: pid_t) async throws -> Pressed {
        guard AXIsProcessTrusted() else { throw AgentAX.AXError.notTrusted }
        let appEl = app(pid)
        var target: AXUIElement?
        var unadvertised: AXUIElement?     // a non-surface hit that advertises no AXPress
        var missed: AXUIElement?           // a control that doesn't cover the point
        var lastRole = ""
        for attempt in 0..<5 {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(appEl, Float(point.x), Float(point.y), &hit) == .success,
               let hit {
                var hitPID: pid_t = 0
                AXUIElementGetPid(hit, &hitPID)
                if hitPID != pid {
                    let owner = NSRunningApplication(processIdentifier: hitPID)?.localizedName ?? "pid \(hitPID)"
                    throw BGError.otherApp(point, owner)
                }
                lastRole = roleOf(hit)
                if !isSurface(hit), let p = controlAncestor(hit) ?? AgentAX.nearestPressable(hit), !isSurface(p) {
                    // Chromium presses an element at ITS centre. When the control
                    // the tree offers doesn't cover the point (keys drawn over
                    // other keys — a piano's black keys pressed the white key
                    // beside them, measured), that is a different control.
                    if covers(p, point) { target = p; break }
                    missed = p
                    if covers(hit, point) { unadvertised = hit; break }
                    break
                }
                if !isSurface(hit) {
                    unadvertised = hit
                    if attempt >= 1 { break }      // the tree is built; nothing pressable is advertised here
                }
            }
            // A sparse tree hit-tests to the surface: Chromium still building its
            // web tree, or a Flutter app with semantics off. Enable and retry.
            if attempt == 0 { AgentAX.enableEngineSemanticsIfNeeded(appEl) }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        // Electron advertises AXPress only on controls, yet AXPress on a plain
        // div still clicks it (measured). Try the hit element itself; apps
        // that can't press it return an error, which still refuses below.
        if target == nil, let hit = unadvertised,
           AXUIElementPerformAction(hit, kAXPressAction as CFString) == .success {
            noteActed(hit, pid: pid)
            let r = AgentAX.rectOf(hit) ?? CGRect(origin: point, size: .zero)
            return Pressed(role: roleOf(hit), name: nameOf(hit), center: CGPoint(x: r.midX, y: r.midY))
        }
        if target == nil, let m = missed {
            throw BGError.missedPoint(point, roleOf(m), AgentAX.rectOf(m) ?? .zero)
        }
        guard let target else { throw BGError.nothingPressable(point, lastRole) }
        let role = roleOf(target)
        let code = AXUIElementPerformAction(target, kAXPressAction as CFString)
        guard code == .success else { throw BGError.pressFailed(role, code.rawValue) }
        noteActed(target, pid: pid)
        let r = AgentAX.rectOf(target) ?? CGRect(origin: point, size: .zero)
        return Pressed(role: role, name: nameOf(target), center: CGPoint(x: r.midX, y: r.midY))
    }

    // MARK: - Keystrokes → the target process

    /// Where pid-posted keystrokes would land right now.
    struct KeyRoute {
        let role: String
        let name: String
        let value: String
        let editable: Bool
        let window: String
    }

    /// Keystrokes posted to a pid go to that app's KEY window (AXFocusedWindow).
    /// That is safe only while the key window is the agent's: on screen, and
    /// the window the agent last acted in. If the human last used ANOTHER
    /// window of the same app (their own Chrome window on another Space), keys
    /// would land there. And an app that was never activated has NO key window
    /// at all, so keys go nowhere (measured on Electron shown with
    /// showInactive). Both are fixed the same way: AXMain on the agent's window
    /// makes it key without activating the app. If that doesn't take, refuse.
    /// The key WINDOW is the signal, not the focused element: Electron still
    /// reported no focused element after AXMain, yet the keys landed.
    static func keyRoute(pid: pid_t) async -> (route: KeyRoute?, error: String?, note: String?) {
        let appEl = app(pid)
        func keyWindow() -> AXUIElement? {
            var w: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &w) == .success,
                  let w, CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
            return (w as! AXUIElement)
        }
        func title(_ win: AXUIElement) -> String { AgentAX.copyString(win, kAXTitleAttribute as CFString) ?? "" }
        func route(in win: AXUIElement) -> KeyRoute {
            var el: AXUIElement?
            var f: CFTypeRef?
            if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &f) == .success,
               let f, CFGetTypeID(f) == AXUIElementGetTypeID() {
                el = (f as! AXUIElement)
            }
            el = el ?? lastActedElement[pid]
            guard let el else { return KeyRoute(role: "", name: "", value: "", editable: false, window: title(win)) }
            let role = roleOf(el)
            var name = ""
            for attr in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue"] {
                if let s = AgentAX.copyString(el, attr as CFString), !s.isEmpty { name = String(s.prefix(120)); break }
            }
            return KeyRoute(
                role: role, name: name,
                value: String((AgentAX.copyString(el, kAXValueAttribute as CFString) ?? "").prefix(300)),
                editable: ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role),
                window: title(win))
        }
        func onScreen(_ win: AXUIElement) -> Bool {
            guard let f = AgentAX.rectOf(win) else { return false }
            return AgentCapture.listWindows().contains { $0.pid == pid && near($0.bounds, f) }
        }
        func acceptable(_ win: AXUIElement?) -> Bool {
            guard let win, onScreen(win), let f = AgentAX.rectOf(win) else { return false }
            if let last = lastActedWindow[pid] { return near(last, f) }
            return true
        }

        if let w = keyWindow(), acceptable(w) { return (route(in: w), nil, nil) }

        // Make the agent's window the app's key window without activating the app.
        if let win = agentWindow(pid: pid) {
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            try? await Task.sleep(nanoseconds: 150_000_000)
            if let w = keyWindow(), acceptable(w) {
                return (route(in: w), nil,
                        "made \"\(title(w).prefix(60))\" the app's key window (the app stayed in the background)")
            }
        }
        guard let current = keyWindow() else {
            return (nil, "the app has no key window, and making the agent's window key (AXMain) didn't take — "
                + "keystrokes would go nowhere. Press or focus a field in the agent's window, then retry.", nil)
        }
        let why = onScreen(current)
            ? "that isn't the window the agent has been working in"
            : "that window isn't on screen — most likely your own window of this app on another Space"
        return (nil, "background keystrokes would land in \"\(title(current).prefix(60))\" (the app's key window), and \(why). "
            + "Press or focus a field in the agent's window first (`query-ax --title … --focus`), then retry.", nil)
    }

    /// Post text to a process. One event pair per grapheme so surrogate pairs
    /// and combining marks stay together; "\n" becomes Return (a unicode
    /// newline is dropped by most single-line fields).
    static func postText(_ text: String, pid: pid_t) async -> Int {
        let src = CGEventSource(stateID: .privateState)
        var n = 0
        for ch in text {
            if ch == "\n" || ch == "\r\n" {
                _ = postKey("return", modifiers: [], pid: pid)
            } else {
                let utf16 = Array(String(ch).utf16)
                guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
                utf16.withUnsafeBufferPointer { buf in
                    down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                    up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                }
                down.postToPid(pid)
                try? await Task.sleep(nanoseconds: 3_000_000)
                up.postToPid(pid)
            }
            n += 1
            // Paced like the probe that verified it: engines that coalesce input
            // (Flutter's text editing) keep up at ~8 ms per character.
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return n
    }

    @discardableResult
    static func postKey(_ name: String, modifiers: [String], pid: pid_t) -> Bool {
        guard let code = AgentInput.keycode(for: name) else { return false }
        let src = CGEventSource(stateID: .privateState)
        let flags = AgentInput.flags(from: modifiers)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.postToPid(pid)
        usleep(4_000)
        up.postToPid(pid)
        return true
    }

    /// Re-read the focused value after typing (AX lags the events by a beat).
    /// true = the text is there, false = the value didn't change, nil = no
    /// readable value (canvas / secure / transformed field).
    static func verifyTyped(_ text: String, pid: pid_t, before: String) async -> Bool? {
        let head = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !head.isEmpty else { return nil }
        // Some apps report no focused element while the keys still land
        // (Electron, measured) — fall back to the element the agent last
        // pressed/focused.
        func actedValue() -> String? {
            lastActedElement[pid].flatMap { AgentAX.copyString($0, kAXValueAttribute as CFString) }
        }
        var last: AgentAX.FocusedInfo?
        for _ in 0..<8 {
            last = try? AgentAX.focused(app: nil, pid: pid)
            if let v = last?.value, v.contains(head) { return true }
            if let v = actedValue(), v.contains(head) { return true }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        if let info = last, info.hasFocus, info.editable || !info.value.isEmpty {
            return info.value == before ? false : nil
        }
        if let v = actedValue() { return v == before ? false : nil }
        return nil
    }

    // MARK: - Navigation through the address bar

    /// Navigate a Chromium-family browser window without activating it: focus
    /// its address bar via AX, write the URL into it, post Return to the
    /// process. (`open -g URL` and AppleScript both activated Chrome when
    /// measured; this path didn't.)
    static func navigate(pid: pid_t, url: String) async -> [String: Any] {
        guard AXIsProcessTrusted() else { return ["error": AgentAX.AXError.notTrusted.localizedDescription] }
        guard let win = agentWindow(pid: pid) else { return offSpaceError(pid: pid, verb: "navigate") }
        guard let bar = addressBar(in: win) else {
            return ["error": "navigate (background): no address bar in the window — this path drives a "
                + "Chromium-family browser's address bar. For a Chrome tab use --via-extension (CDP, also "
                + "non-activating), or run with --foreground.", "mode": "background"]
        }
        let before = webAreaURL(in: win) ?? ""
        AXUIElementSetAttributeValue(bar, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, url as CFString)
        noteActed(bar, pid: pid)
        try? await Task.sleep(nanoseconds: 150_000_000)
        // Return goes to the app's KEY window — only post it if that's where
        // the address bar we just filled lives.
        let (route, err, note) = await keyRoute(pid: pid)
        guard route != nil else { return ["error": "navigate (background): \(err ?? "no key route")", "mode": "background"] }
        postKey("return", modifiers: [], pid: pid)

        // The page committed when the window's web area reports a different
        // URL — redirects included (127.0.0.1 → localhost/…?token=… was seen
        // live), so any change counts; the reply carries where it landed.
        let start = Date()
        var current = ""
        while Date().timeIntervalSince(start) < 10 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            current = webAreaURL(in: win) ?? ""
            if !current.isEmpty, current != before {
                var out: [String: Any] = ["ok": true, "url": current, "via": "address-bar",
                                          "waited_ms": Int(Date().timeIntervalSince(start) * 1000)]
                if let note { out["note"] = note }
                return out
            }
        }
        var out: [String: Any] = ["ok": true, "url": current, "via": "address-bar", "committed": false,
                                  "note": "Return was posted, but the page URL didn't change within 10s (the same URL "
                                      + "reloads without a change) — check the window (`capture --pid \(pid)`)"]
        if let note { out["note"] = (out["note"] as! String) + ". " + note }
        return out
    }

    private static func addressBar(in win: AXUIElement) -> AXUIElement? {
        var found: AXUIElement?
        var visited = 0
        func walk(_ el: AXUIElement) {
            if found != nil || visited > 600 { return }
            visited += 1
            let role = roleOf(el)
            if role == "AXWebArea" { return }            // page content, not browser chrome
            if role == "AXTextField" {
                let n = ((AgentAX.copyString(el, kAXDescriptionAttribute as CFString) ?? "") + " "
                         + (AgentAX.copyString(el, kAXTitleAttribute as CFString) ?? "")).lowercased()
                if n.contains("address") || n.contains("smart search") { found = el; return }
            }
            for k in AgentAX.copyChildren(el) ?? [] { walk(k) }
        }
        walk(win)
        return found
    }

    private static func webAreaURL(in win: AXUIElement) -> String? {
        var found: String?
        var visited = 0
        func walk(_ el: AXUIElement) {
            if found != nil || visited > 400 { return }
            visited += 1
            if roleOf(el) == "AXWebArea" {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, "AXURL" as CFString, &v) == .success {
                    found = (v as? URL)?.absoluteString ?? (v as? String)
                }
                return
            }
            for k in AgentAX.copyChildren(el) ?? [] { walk(k) }
        }
        walk(win)
        return found
    }
}

/// Measures and protects the human's focus around every background action.
///
/// begin → act → finish: if the frontmost app after the action is the TARGET
/// (and wasn't before), the action activated it — hand focus straight back to
/// the app the human was in. A third app coming forward is the human switching
/// on purpose; that's reported, never undone. Some apps activate themselves a
/// beat late, so the shield stays armed for 1.5 s and catches those too
/// (reported as late_restores on the next reply). A physical mouse click in
/// that window means the human chose the app — the shield stands down.
///
/// The 180 ms wait before the check is paid only until an app has earned
/// trust: after `trustAfter` clean actions in a row the check runs at once
/// (the armed observer still catches and undoes a late steal). The fixed wait
/// was most of every background click and key — 196 ms of host time, 16 ms
/// of it actual work (calls.ndjson, 2026-10-09).
@MainActor
final class FocusShield {
    static let shared = FocusShield()

    private static let trustAfter = 3
    /// Clean actions in a row per target pid; reset by any steal.
    private var cleanRuns: [pid_t: Int] = [:]

    struct Ticket {
        let target: pid_t
        let frontBefore: pid_t
        let frontName: String
        let started: Date
    }

    private var observer: NSObjectProtocol?
    private var armedUntil = Date.distantPast
    private var armedTarget: pid_t = 0
    private var armedHuman: pid_t = 0
    private var lateRestores = 0

    func begin(target: pid_t) -> Ticket {
        installObserverIfNeeded()
        let front = NSWorkspace.shared.frontmostApplication
        return Ticket(target: target, frontBefore: front?.processIdentifier ?? 0,
                      frontName: front?.localizedName ?? "?", started: Date())
    }

    func finish(_ t: Ticket) async -> [String: Any] {
        // Activation lands asynchronously — give a steal a beat to surface,
        // until this app has shown it doesn't steal.
        if (cleanRuns[t.target] ?? 0) < Self.trustAfter {
            try? await Task.sleep(nanoseconds: 180_000_000)
        }
        let now = NSWorkspace.shared.frontmostApplication
        let nowPID = now?.processIdentifier ?? 0
        var r: [String: Any] = ["human_app": t.frontName]
        if t.frontBefore == t.target {
            r["focus_kept"] = true
            r["note"] = "the target app was already frontmost — someone is using it; background mode can't "
                + "keep the agent out of their way inside the same app"
        } else if nowPID == t.frontBefore {
            r["focus_kept"] = true
        } else if nowPID == t.target, t.frontBefore != 0, !Self.humanClicked(since: t.started) {
            r["focus_kept"] = false
            r["stolen_by_target"] = true
            r["restored"] = Self.giveFocus(to: t.frontBefore)
            cleanRuns[t.target] = 0
        } else {
            r["focus_kept"] = true
            r["front_now"] = now?.localizedName ?? "?"
            r["note"] = "the frontmost app changed during the action, but not to the target — the human switched apps"
        }
        if r["stolen_by_target"] == nil, t.frontBefore != t.target {
            if cleanRuns.count > 64 { cleanRuns.removeAll() }   // pids come and go; keep it small
            cleanRuns[t.target, default: 0] += 1
        }
        if t.frontBefore != t.target, t.frontBefore != 0 {
            armedUntil = Date().addingTimeInterval(1.5)
            armedTarget = t.target
            armedHuman = t.frontBefore
        }
        if lateRestores > 0 {
            r["late_restores"] = lateRestores
            lateRestores = 0
        }
        return r
    }

    private func installObserverIfNeeded() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { self?.activated(pid) }
        }
    }

    private func activated(_ pid: pid_t?) {
        guard let pid, Date() < armedUntil, pid == armedTarget, armedHuman != 0 else { return }
        armedUntil = .distantPast
        guard !Self.humanClicked(within: 1.0) else { return }   // the human chose it
        cleanRuns[pid] = 0          // it steals late: wait before checking again
        if Self.giveFocus(to: armedHuman) { lateRestores += 1 }
    }

    /// A physical click since `start` (or within `within` seconds). Our
    /// background path posts no HID events, so this is the human's hand.
    private static func humanClicked(since start: Date) -> Bool {
        humanClicked(within: Date().timeIntervalSince(start) + 0.3)
    }

    private static func humanClicked(within seconds: TimeInterval) -> Bool {
        [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].contains {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) < seconds
        }
    }

    @discardableResult
    static func giveFocus(to pid: pid_t) -> Bool {
        if pid == ProcessInfo.processInfo.processIdentifier {
            // AX against our own process from the main thread can deadlock.
            NSApp.activate()
            return true
        }
        let r = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid),
                                             kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        return r == .success
    }
}
