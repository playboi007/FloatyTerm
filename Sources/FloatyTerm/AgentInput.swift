import AppKit
import Carbon.HIToolbox   // kVK_* virtual keycodes (same import HotKey.swift uses)

/// Layer B — synthetic input via CoreGraphics events.
///
/// The mouse-event vocabulary (move/click/drag/scroll/down/up, interpolation,
/// button + modifier handling) is adapted from socsieng/sendkeys
/// (https://github.com/socsieng/sendkeys, Apache-2.0). We reimplement it
/// IN-PROCESS rather than shelling out to the `sendkeys` binary, because a
/// spawned binary has its OWN code signature and would need its OWN
/// Accessibility (TCC) grant — reintroducing exactly the permission pain this
/// whole framework exists to remove. In-process, every event is posted by
/// FloatyTerm.app under FloatyTerm's single signature and single grant.
///
/// DESIGN: instant by default, optionally human-paced.
///   For an agent, instant events are usually right. But human pacing isn't
///   just cosmetic — some apps DEBOUNCE or drop input that arrives implausibly
///   fast: autocomplete menus need keystroke gaps to populate, drag targets
///   only fire if the cursor actually travels (not teleports), scroll-linked
///   UIs snap oddly on instant jumps. So `Pacing` is a real reliability knob,
///   exposed via an optional flag, off by default.
///
/// PERMISSION: CGEvent injection requires the macOS Accessibility grant — the
/// first FloatyTerm feature to need it (HotKey uses Carbon to avoid it;
/// ContextSnap only needs Screen Recording). Gated by `ensureAccessibility()`,
/// modeled on `ContextSnap.ensurePermission` (prompt + relaunch; grant is keyed
/// to the code signature and only applies after a fresh launch).
@MainActor
enum AgentInput {

    // MARK: - Pacing

    /// How an action is paced. `.instant` posts events back-to-back (agent
    /// default). `.human(duration:)` spreads movement/keystrokes over real time
    /// with small jitter so input looks and behaves like a person's.
    enum Pacing {
        case instant
        case human(duration: TimeInterval)   // total seconds for the gesture
        var isHuman: Bool { if case .human = self { return true }; return false }
    }

    /// Frame interval for animated movement (matches sendkeys'
    /// --animation-interval default). Lower = smoother + more events.
    private static let animationInterval: TimeInterval = 0.01

    // MARK: - Permission gate (mirrors ContextSnap.ensurePermission)

    static func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Accessibility permission needed"
        alert.informativeText = """
            FloatyTerm needs Accessibility access to send clicks and keystrokes \
            on your behalf (the agent control commands: floaty click / type / \
            move / drag / scroll / key).

            1. Grant FloatyTerm access under System Settings → Privacy & \
            Security → Accessibility.
            2. Relaunch FloatyTerm — macOS only applies the grant to a \
            freshly-started app.

            Already granted but still seeing this? That's step 2: relaunch.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Relaunch FloatyTerm")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
        return false
    }

    private static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(bundlePath)\""]
        try? task.run()
        AppRuntime.isQuitting = true
        NSApp.terminate(nil)
    }

    // MARK: - Target activation

    @discardableResult
    static func activate(_ identifier: String?, pid: pid_t? = nil) -> Bool {
        // Resolve the target process. A PID wins: it disambiguates two apps that
        // share a name (the two-Chrome problem) and pins keystrokes to that exact
        // instance — the fix for "type went to the wrong Chrome." Otherwise match
        // a running app by localized name / bundle id.
        let app: NSRunningApplication
        if let pid {
            guard let a = NSRunningApplication(processIdentifier: pid) else {
                NSLog("FloatyTerm: agent target pid \(pid) not running")
                return false
            }
            app = a
        } else if let identifier {
            guard let a = (NSWorkspace.shared.runningApplications.first {
                $0.localizedName == identifier || $0.bundleIdentifier == identifier
            }) else {
                NSLog("FloatyTerm: agent target not running: \(identifier)")
                return false
            }
            app = a
        } else {
            return true   // no target → inject into whatever is frontmost
        }
        let label = identifier ?? "pid \(app.processIdentifier)"

        // macOS 14 made activation COOPERATIVE: .activateIgnoringOtherApps is a
        // no-op, so a background/accessory app (which FloatyTerm is) can no
        // longer just steal focus — app.activate() alone only bounces the Dock
        // icon. Two mechanisms, belt and suspenders:
        //
        //  1. NSApp.yieldActivation(to:) — works only when FloatyTerm is itself
        //     the active app (e.g. you run `floaty` from FloatyTerm's terminal),
        //     handing our activation token to the target.
        //  2. AX frontmost — works regardless of who is active. We ALREADY hold
        //     the Accessibility grant for input injection, and that same grant
        //     lets us set kAXFrontmostAttribute on the target's application
        //     element to raise it. This covers `floaty` run from any terminal.
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
        }
        app.activate()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        // Activation is async and run-loop driven. Spin the run loop (don't
        // busy-sleep — that would starve the very events that deliver focus)
        // until the target is genuinely frontmost, then bail false on timeout.
        // This is the safety guarantee: we NEVER inject into whatever app
        // happened to be focused. Without it, a failed activation silently
        // typed into the caller's own terminal.
        let deadline = Date().addingTimeInterval(2.0)
        while NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            if Date() >= deadline {
                NSLog("FloatyTerm: target \(label) did not come to front")
                return false
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        usleep(40_000)  // let the now-frontmost window settle before input
        return true
    }

    // MARK: - Modifier parsing (shared by mouse + key)

    static func flags(from modifiers: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        for m in modifiers {
            switch m.lowercased() {
            case "cmd", "command":       f.insert(.maskCommand)
            case "shift":                f.insert(.maskShift)
            case "opt", "option", "alt": f.insert(.maskAlternate)
            case "ctrl", "control":      f.insert(.maskControl)
            default: break
            }
        }
        return f
    }

    enum MouseButton: String {
        case left, right, center
        var cg: CGMouseButton {
            switch self { case .left: return .left; case .right: return .right; case .center: return .center }
        }
        var downType: CGEventType {
            switch self { case .left: return .leftMouseDown; case .right: return .rightMouseDown; case .center: return .otherMouseDown }
        }
        var upType: CGEventType {
            switch self { case .left: return .leftMouseUp; case .right: return .rightMouseUp; case .center: return .otherMouseUp }
        }
        var dragType: CGEventType {
            switch self { case .left: return .leftMouseDragged; case .right: return .rightMouseDragged; case .center: return .otherMouseDragged }
        }
    }

    /// Current cursor position in CGEvent (top-left, y-down) coords.
    private static func currentMouse() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: - Mouse: move

    static func move(to point: CGPoint, pacing: Pacing = .instant, target: String? = nil, targetPID: pid_t? = nil) -> Bool {
        guard ensureAccessibility(), activate(target, pid: targetPID) else { return false }
        interpolatedMove(from: currentMouse(), to: point, pacing: pacing, dragging: nil, modifiers: [])
        return true
    }

    /// Shared interpolation for move and drag. When `dragging` is set, the
    /// intermediate events are drag events with the button held; else mouseMoved.
    private static func interpolatedMove(from: CGPoint, to: CGPoint, pacing: Pacing,
                                         dragging: MouseButton?, modifiers: [String]) {
        let src = CGEventSource(stateID: .hidSystemState)
        let flags = flags(from: modifiers)
        let type: CGEventType = dragging?.dragType ?? .mouseMoved
        func post(_ p: CGPoint) {
            let e = CGEvent(mouseEventSource: src, mouseType: type,
                            mouseCursorPosition: p, mouseButton: dragging?.cg ?? .left)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        switch pacing {
        case .instant:
            post(to)
        case .human(let duration):
            // Ease-in-out so the cursor accelerates/decelerates like a hand.
            let steps = max(1, Int(duration / animationInterval))
            for i in 1...steps {
                let t = easeInOut(Double(i) / Double(steps))
                post(CGPoint(x: from.x + (to.x - from.x) * t,
                             y: from.y + (to.y - from.y) * t))
                usleep(useconds_t(animationInterval * 1_000_000))
            }
        }
    }

    private static func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    // MARK: - Mouse: click (button, modifiers, multi-click)

    static func click(at point: CGPoint, button: MouseButton = .left,
                      modifiers: [String] = [], clicks: Int = 1,
                      pacing: Pacing = .instant, target: String? = nil, targetPID: pid_t? = nil) -> Bool {
        guard ensureAccessibility(), activate(target, pid: targetPID) else { return false }
        if pacing.isHuman {
            interpolatedMove(from: currentMouse(), to: point, pacing: pacing, dragging: nil, modifiers: [])
        }
        let src = CGEventSource(stateID: .hidSystemState)
        let flags = flags(from: modifiers)
        for n in 1...max(1, clicks) {
            let down = CGEvent(mouseEventSource: src, mouseType: button.downType,
                               mouseCursorPosition: point, mouseButton: button.cg)
            let up = CGEvent(mouseEventSource: src, mouseType: button.upType,
                             mouseCursorPosition: point, mouseButton: button.cg)
            down?.flags = flags
            up?.flags = flags
            // click-state turns N rapid clicks into a real double/triple click.
            down?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            up?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            down?.post(tap: .cghidEventTap)
            usleep(15_000)
            up?.post(tap: .cghidEventTap)
            if n < clicks { usleep(40_000) }  // within the double-click threshold
        }
        return true
    }

    // MARK: - Mouse: down / up (compose custom gestures)

    static func mouseDown(at point: CGPoint, button: MouseButton = .left,
                          modifiers: [String] = [], target: String? = nil, targetPID: pid_t? = nil) -> Bool {
        guard ensureAccessibility(), activate(target, pid: targetPID) else { return false }
        let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                        mouseType: button.downType, mouseCursorPosition: point, mouseButton: button.cg)
        e?.flags = flags(from: modifiers)
        e?.post(tap: .cghidEventTap)
        return true
    }

    static func mouseUp(at point: CGPoint, button: MouseButton = .left,
                        modifiers: [String] = [], target: String? = nil, targetPID: pid_t? = nil) -> Bool {
        guard ensureAccessibility(), activate(target, pid: targetPID) else { return false }
        let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                        mouseType: button.upType, mouseCursorPosition: point, mouseButton: button.cg)
        e?.flags = flags(from: modifiers)
        e?.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Mouse: drag

    static func drag(from: CGPoint, to: CGPoint, button: MouseButton = .left,
                     modifiers: [String] = [], pacing: Pacing = .instant, target: String? = nil, targetPID: pid_t? = nil) -> Bool {
        guard ensureAccessibility(), activate(target, pid: targetPID) else { return false }
        let src = CGEventSource(stateID: .hidSystemState)
        let f = flags(from: modifiers)
        let down = CGEvent(mouseEventSource: src, mouseType: button.downType,
                           mouseCursorPosition: from, mouseButton: button.cg)
        down?.flags = f
        down?.post(tap: .cghidEventTap)
        usleep(15_000)
        // Emit at least one drag event even when instant, or targets read
        // down+up at different points as a click, not a drag.
        let p: Pacing = pacing.isHuman ? pacing : .human(duration: animationInterval * 2)
        interpolatedMove(from: from, to: to, pacing: p, dragging: button, modifiers: modifiers)
        let up = CGEvent(mouseEventSource: src, mouseType: button.upType,
                         mouseCursorPosition: to, mouseButton: button.cg)
        up?.flags = f
        up?.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Mouse: scroll

    /// Positive y scrolls DOWN, positive x scrolls RIGHT (matches sendkeys).
    /// Human pacing splits one scroll into many small wheel events — closer to a
    /// trackpad and less likely to overshoot momentum-scrolling UIs.
    ///
    /// Wheel events are delivered to the view UNDER THE CURSOR, not the focused
    /// element — so a scroll "does nothing" whenever the pointer is parked
    /// somewhere else (a real gotcha agents hit). Pass `at` to move the cursor
    /// over the area you want to scroll first; it makes scrolling reliable
    /// without needing a focusing click.
    static func scroll(dx: Int, dy: Int, at point: CGPoint? = nil,
                       pacing: Pacing = .instant, target: String? = nil, targetPID: pid_t? = nil) -> Bool {
        guard ensureAccessibility(), activate(target, pid: targetPID) else { return false }
        let src = CGEventSource(stateID: .hidSystemState)
        if let point {
            CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                    mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(20_000)
        }
        func wheel(_ x: Int32, _ y: Int32) {
            // wheel1 vertical, wheel2 horizontal; negate so +y means down.
            CGEvent(scrollWheelEvent2Source: src, units: .pixel,
                    wheelCount: 2, wheel1: -y, wheel2: -x, wheel3: 0)?
                .post(tap: .cghidEventTap)
        }
        switch pacing {
        case .instant:
            wheel(Int32(dx), Int32(dy))
        case .human(let duration):
            let steps = max(1, Int(duration / animationInterval))
            for _ in 1...steps {
                wheel(Int32(dx / steps), Int32(dy / steps))
                usleep(useconds_t(animationInterval * 1_000_000))
            }
        }
        return true
    }

    // MARK: - Text (layout-independent, optionally human-paced)

    struct TypeOutcome {
        let ok: Bool
        let typed: Int      // characters of `text` that actually landed
        let stopped: Bool   // true when the user hit Stop on the replay HUD
    }

    /// Type `text`. Instant pacing posts events back-to-back and returns.
    /// Human pacing runs as a pausable REPLAY SESSION on a background thread —
    /// with a recorded profile it reproduces the user's real rhythm (dwell +
    /// flight + backspace-and-retype corrections, which only ever delete and
    /// re-type the SAME characters, so the final text is always exactly
    /// `text`); without one it falls back to flat jitter. `showControls`
    /// overlays play/pause/stop/speed transport on the terminal window for
    /// the session's duration (see TypingReplay.swift).
    static func type(_ text: String, pacing: Pacing = .instant, target: String? = nil,
                     targetPID: pid_t? = nil, showControls: Bool = true) async -> TypeOutcome {
        guard ensureAccessibility(), activate(target, pid: targetPID) else {
            return TypeOutcome(ok: false, typed: 0, stopped: false)
        }
        let src = CGEventSource(stateID: .hidSystemState)
        if pacing.isHuman {
            let r = await TypingReplayController.shared.run(
                text: text, profile: TypingProfile.current(), source: src,
                showControls: showControls)
            return TypeOutcome(ok: true, typed: r.typed, stopped: !r.completed)
        }
        for scalar in text.unicodeScalars {
            postUnicode(String(scalar), source: src)
        }
        return TypeOutcome(ok: true, typed: text.count, stopped: false)
    }

    /// nonisolated: the replay session posts from its playback thread
    /// (CGEvent.post is thread-safe).
    nonisolated static func postUnicode(_ s: String, source: CGEventSource?, dwellUs: useconds_t = 0) {
        let utf16 = Array(s.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        if dwellUs > 0 { usleep(dwellUs) }
        up.post(tap: .cghidEventTap)
    }

    /// Press a key by virtual keycode, optionally holding it `dwellUs` first.
    /// nonisolated for the same reason as postUnicode.
    nonisolated static func postKeycode(_ code: CGKeyCode, source: CGEventSource?, dwellUs: useconds_t = 0) {
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        down?.post(tap: .cghidEventTap)
        if dwellUs > 0 { usleep(dwellUs) }
        up?.post(tap: .cghidEventTap)
    }

    // MARK: - Named keys & chords (keycode-based)

    static func pressKey(_ name: String, modifiers: [String] = [], target: String? = nil, targetPID: pid_t? = nil) -> Bool {
        guard ensureAccessibility(), activate(target, pid: targetPID) else { return false }
        guard let code = keycode(for: name) else {
            NSLog("FloatyTerm: unknown key \(name)")
            return false
        }
        let src = CGEventSource(stateID: .hidSystemState)
        let f = flags(from: modifiers)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = f
        up?.flags = f
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return true
    }

    /// Whether `name` maps to a key we can synthesize — lets callers reject an
    /// unknown key with a precise error before attempting (and failing) to press.
    static func isKnownKey(_ name: String) -> Bool { keycode(for: name) != nil }

    static func keycode(for name: String) -> CGKeyCode? {
        keyCodes[name.lowercased()]
    }

    /// Full key table so `floaty key` can drive real app shortcuts — cmd+L
    /// (address bar), cmd+T (new tab), cmd+R (reload), cmd+W, cmd+shift+T, etc.
    /// Covers named/navigation keys, every letter and digit, the punctuation
    /// keys, and F1–F20. Letters/digits/punct are reachable both by the literal
    /// character ("l", "/", "5") and, where natural, a word ("slash"). For
    /// arbitrary text use `type`, not `key`.
    private static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "return": CGKeyCode(kVK_Return), "enter": CGKeyCode(kVK_Return),
            "tab": CGKeyCode(kVK_Tab),
            "space": CGKeyCode(kVK_Space),
            "delete": CGKeyCode(kVK_Delete), "backspace": CGKeyCode(kVK_Delete),
            "forwarddelete": CGKeyCode(kVK_ForwardDelete), "fwddelete": CGKeyCode(kVK_ForwardDelete),
            "escape": CGKeyCode(kVK_Escape), "esc": CGKeyCode(kVK_Escape),
            "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
            "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
            "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End),
            "pgup": CGKeyCode(kVK_PageUp), "pageup": CGKeyCode(kVK_PageUp),
            "pgdown": CGKeyCode(kVK_PageDown), "pagedown": CGKeyCode(kVK_PageDown),
            // Punctuation — both the literal glyph and a spelled-out name.
            "minus": CGKeyCode(kVK_ANSI_Minus), "-": CGKeyCode(kVK_ANSI_Minus),
            "equal": CGKeyCode(kVK_ANSI_Equal), "=": CGKeyCode(kVK_ANSI_Equal),
            "leftbracket": CGKeyCode(kVK_ANSI_LeftBracket), "[": CGKeyCode(kVK_ANSI_LeftBracket),
            "rightbracket": CGKeyCode(kVK_ANSI_RightBracket), "]": CGKeyCode(kVK_ANSI_RightBracket),
            "backslash": CGKeyCode(kVK_ANSI_Backslash), "\\": CGKeyCode(kVK_ANSI_Backslash),
            "semicolon": CGKeyCode(kVK_ANSI_Semicolon), ";": CGKeyCode(kVK_ANSI_Semicolon),
            "quote": CGKeyCode(kVK_ANSI_Quote), "'": CGKeyCode(kVK_ANSI_Quote),
            "comma": CGKeyCode(kVK_ANSI_Comma), ",": CGKeyCode(kVK_ANSI_Comma),
            "period": CGKeyCode(kVK_ANSI_Period), ".": CGKeyCode(kVK_ANSI_Period),
            "slash": CGKeyCode(kVK_ANSI_Slash), "/": CGKeyCode(kVK_ANSI_Slash),
            "grave": CGKeyCode(kVK_ANSI_Grave), "backtick": CGKeyCode(kVK_ANSI_Grave),
            "`": CGKeyCode(kVK_ANSI_Grave),
        ]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D),
            ("e", kVK_ANSI_E), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H),
            ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
            ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P),
            ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
            ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),
        ]
        let digits: [(String, Int)] = [
            ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7),
            ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
        ]
        let fkeys: [(String, Int)] = [
            ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4),
            ("f5", kVK_F5), ("f6", kVK_F6), ("f7", kVK_F7), ("f8", kVK_F8),
            ("f9", kVK_F9), ("f10", kVK_F10), ("f11", kVK_F11), ("f12", kVK_F12),
            ("f13", kVK_F13), ("f14", kVK_F14), ("f15", kVK_F15), ("f16", kVK_F16),
            ("f17", kVK_F17), ("f18", kVK_F18), ("f19", kVK_F19), ("f20", kVK_F20),
        ]
        for (s, c) in letters + digits + fkeys { m[s] = CGKeyCode(c) }
        return m
    }()
}
