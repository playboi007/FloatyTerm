import Foundation

/// `floaty input` — the script half: parse the steps, check them all, and
/// flatten them into one timeline of CDP `Input.*` commands. Pure (no CDP, no
/// AppKit), so it is testable on its own; AgentCDPInput runs the timeline.
///
/// Why CDP input: events a page script dispatches are untrusted
/// (`isTrusted == false`), and many pages ignore them — the virtual piano did.
/// Input.dispatchMouseEvent / dispatchKeyEvent / insertText reach the page as
/// TRUSTED events at an exact viewport point, without the real cursor or the
/// frontmost app (measured on Chrome and Electron, docs/background-mode.md).
///
/// Time model: every step starts at `t` (ms from the script start) or, without
/// `t`, at the previous step's start plus its own `wait` (default 0). A `hold`
/// schedules the release later WITHOUT delaying the next step, so chords and
/// overlapping notes are just steps that share a start. `drag` and paced
/// `type` occupy time; the next relative step starts after them.
enum CDPInputScript {

    // MARK: - Model

    /// Where a mouse event lands. Selectors and screen points are resolved to
    /// viewport points in one round trip before the clock starts.
    enum Target: Hashable {
        case viewport(Double, Double)
        case screen(Double, Double)
        /// `fx`/`fy`: the point inside the element's box, as fractions (0.5 = centre).
        case selector(String, fx: Double, fy: Double)
        /// An element ref (`ref_12`) from `som` / `query-dom` / `find` on this page.
        case ref(String, fx: Double, fy: Double)
        /// The last mouse position (an `up` with no target).
        case last
        /// A point a fraction of the way from one target to another (drag moves).
        indirect case between(Target, Target, Double)
    }

    enum MouseButton: String {
        case left, right, middle
        var mask: Int { switch self { case .left: return 1; case .right: return 2; case .middle: return 4 } }
    }

    struct KeyDef: Equatable {
        let key: String
        let code: String
        let vk: Int
        /// The character the key types, nil for keys that type nothing.
        let text: String?
    }

    enum Prim {
        case mousePressed(Target, MouseButton, clickCount: Int, modifiers: Int)
        case mouseReleased(Target, MouseButton, clickCount: Int, modifiers: Int)
        case mouseMoved(Target, modifiers: Int)
        case wheel(Target, dx: Double, dy: Double, modifiers: Int)
        case keyDown(KeyDef, modifiers: Int, commands: [String])
        case keyUp(KeyDef, modifiers: Int)
        case insertText(String)
        /// Focus the element, select its content, insert `text` — a form field's
        /// value replaced through trusted input (the page sees `input` events).
        case fill(Target, String)
    }

    struct Timed {
        let atMs: Double
        let step: Int        // 1-based, for error reports
        let prim: Prim
    }

    struct ScriptError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static let maxEvents = 20_000
    static let maxDurationMs = 900_000.0     // 15 min

    // MARK: - Compile

    /// Steps → a timeline sorted by time (ties keep step order). Throws on the
    /// first bad step, before anything is sent.
    static func compile(_ steps: [[String: Any]]) throws -> [Timed] {
        var out: [Timed] = []
        var cursor = 0.0
        for (i, s) in steps.enumerated() {
            let n = i + 1
            func fail(_ m: String) -> ScriptError { ScriptError(message: "step \(n): \(m)") }
            func num(_ k: String) -> Double? { (s[k] as? NSNumber)?.doubleValue }
            let actions = actionKeys.filter { s[$0] != nil }
            if actions.count > 1 {
                throw fail("one action per step — got \(actions.joined(separator: " + "))")
            }
            if let t = num("t"), t < 0 { throw fail("t must be ≥ 0") }
            if let w = num("wait"), w < 0 { throw fail("wait must be ≥ 0") }
            let start = num("t") ?? (cursor + (num("wait") ?? 0))
            guard let action = actions.first else {
                guard s["wait"] != nil || s["t"] != nil else {
                    throw fail("no action — one of \(actionKeys.joined(separator: "/")), or a bare {\"wait\":ms}")
                }
                cursor = start
                continue
            }
            let hold = max(num("hold") ?? 0, 0)
            let mods = try modifierMask(s["modifiers"], fail)
            var busy = 0.0          // how long this step delays the next relative step
            func add(_ at: Double, _ p: Prim) { out.append(Timed(atMs: at, step: n, prim: p)) }

            switch action {
            case "click", "down", "up", "move":
                let target = try parseTarget(s[action], allowLast: action == "up", fail)
                let button = try parseButton(s["button"], fail)
                let count = min(max(Int(num("count") ?? 1), 1), 3)
                // A hand reaches the control before it presses: pages that react to
                // pointerenter / mouseover (menus, hover cards, some buttons) need
                // the move first. CDP's own example driver does the same.
                if action == "click" || action == "down" { add(start, .mouseMoved(target, modifiers: mods)) }
                switch action {
                case "click":
                    for c in 1...count {
                        add(start, .mousePressed(target, button, clickCount: c, modifiers: mods))
                        add(c == count ? start + hold : start, .mouseReleased(target, button, clickCount: c, modifiers: mods))
                    }
                case "down":
                    add(start, .mousePressed(target, button, clickCount: 1, modifiers: mods))
                    if hold > 0 { add(start + hold, .mouseReleased(target, button, clickCount: 1, modifiers: mods)) }
                case "up":
                    add(start, .mouseReleased(target, button, clickCount: 1, modifiers: mods))
                default:
                    add(start, .mouseMoved(target, modifiers: mods))
                }
            case "drag":
                guard let d = s["drag"] as? [String: Any], d["from"] != nil, d["to"] != nil else {
                    throw fail("drag needs {\"from\": target, \"to\": target}")
                }
                let from = try parseTarget(d["from"], allowLast: false, fail)
                let to = try parseTarget(d["to"], allowLast: false, fail)
                let button = try parseButton(s["button"] ?? d["button"], fail)
                let moves = min(max(Int((d["steps"] as? NSNumber)?.intValue ?? num("steps").map(Int.init) ?? 10), 1), 200)
                let duration = max((d["duration"] as? NSNumber)?.doubleValue ?? num("duration") ?? 200, 0)
                add(start, .mouseMoved(from, modifiers: mods))
                add(start, .mousePressed(from, button, clickCount: 1, modifiers: mods))
                for k in 1...moves {
                    let f = Double(k) / Double(moves)
                    add(start + duration * f, .mouseMoved(k == moves ? to : .between(from, to, f), modifiers: mods))
                }
                add(start + duration, .mouseReleased(to, button, clickCount: 1, modifiers: mods))
                busy = duration
            case "wheel":
                let target = try parseTarget(s["wheel"], allowLast: true, fail)
                let dx = num("dx") ?? 0, dy = num("dy") ?? 0
                guard dx != 0 || dy != 0 else { throw fail("wheel needs dx or dy (pixels; +dy scrolls down)") }
                add(start, .wheel(target, dx: dx, dy: dy, modifiers: mods))
            case "key", "keydown", "keyup":
                guard let spec = s[action] as? String, !spec.isEmpty else { throw fail("\(action) needs a key name") }
                // "cmd+a", "Tab Tab Enter", "Page_Up" — the same syntax as `floaty key`.
                let strokes: [KeySpec.Stroke]
                do { strokes = try KeySpec.parse(spec) } catch { throw fail(error.localizedDescription) }
                let repeatN = min(max(Int(num("repeat") ?? 1), 1), 100)
                if action != "key" || hold > 0, strokes.count > 1 || repeatN > 1 {
                    throw fail("\(action == "key" ? "hold" : action) takes ONE key or chord, not a sequence or repeat")
                }
                var defs: [(KeyDef, Int)] = []
                for st in strokes {
                    guard let (def, implied) = keyDef(st.key) else {
                        throw fail("unknown key \"\(st.key)\" — a character, or a name like Enter/Tab/Escape/Backspace/"
                            + "ArrowLeft/PageDown/F5/Space (floaty key names work too)")
                    }
                    let m = try modifierMask(st.modifiers, fail)
                    defs.append((def, mods | implied | m))
                }
                for _ in 0..<repeatN {
                    for (def, m) in defs {
                        if action != "keyup" { add(start, .keyDown(def, modifiers: m, commands: macCommands(def, m))) }
                        if action == "key" { add(start + hold, .keyUp(def, modifiers: m)) }
                        if action == "keyup" { add(start, .keyUp(def, modifiers: m)) }
                    }
                }
            case "type":
                guard let text = s["type"] as? String else { throw fail("type needs a string") }
                let gap = max(num("interval") ?? 0, 0)
                var t = start
                for ch in text {
                    let c = String(ch)
                    if let (def, implied) = keyDef(c == "\n" ? "Enter" : c) {
                        add(t, .keyDown(def, modifiers: mods | implied, commands: []))
                        add(t, .keyUp(def, modifiers: mods | implied))
                    } else {
                        add(t, .insertText(c))     // no key on a US layout (é, emoji): insert it
                    }
                    t += gap
                }
                busy = gap * Double(text.count)
            case "text":
                guard let text = s["text"] as? String else { throw fail("text needs a string") }
                add(start, .insertText(text))
            case "fill":
                let target = try parseTarget(s["fill"], allowLast: false, fail)
                switch target {
                case .selector, .ref: break
                default: throw fail("fill needs an element: a CSS selector or a ref, not a point")
                }
                guard let v = s["value"] else { throw fail("fill needs \"value\"") }
                let value = (v as? String) ?? (v as? NSNumber)?.stringValue ?? ""
                add(start, .fill(target, value))
            default:
                break
            }
            cursor = start + busy
            if out.count > maxEvents { throw fail("script too long (over \(maxEvents) events) — split it") }
        }
        // Stable: equal times keep the order they were written in.
        let sorted = out.enumerated().sorted { a, b in
            a.element.atMs != b.element.atMs ? a.element.atMs < b.element.atMs : a.offset < b.offset
        }.map(\.element)
        if let last = sorted.last, last.atMs > maxDurationMs {
            throw ScriptError(message: "script runs \(Int(last.atMs / 1000)) s — the cap is \(Int(maxDurationMs / 1000)) s; split it")
        }
        return sorted
    }

    static let actionKeys = ["click", "down", "up", "move", "drag", "wheel", "key", "keydown", "keyup", "type",
                             "text", "fill"]

    /// Every selector target in the timeline (resolved before the clock starts).
    static func selectors(in timeline: [Timed]) -> [Target] {
        var seen = Set<Target>(), out: [Target] = []
        func visit(_ t: Target) {
            switch t {
            case .selector, .screen, .ref:
                if seen.insert(t).inserted { out.append(t) }
            case .between(let a, let b, _):
                visit(a); visit(b)
            default: break
            }
        }
        for e in timeline {
            switch e.prim {
            case .mousePressed(let t, _, _, _), .mouseReleased(let t, _, _, _), .mouseMoved(let t, _), .wheel(let t, _, _, _),
                 .fill(let t, _):
                visit(t)
            default: break
            }
        }
        return out
    }

    // MARK: - Parsing helpers

    private static func parseTarget(_ v: Any?, allowLast: Bool, _ fail: (String) -> ScriptError) throws -> Target {
        if allowLast, v == nil || (v as? NSNumber)?.boolValue == true || v is NSNull { return .last }
        if let s = v as? String, !s.isEmpty {
            return isRef(s) ? .ref(s, fx: 0.5, fy: 0.5) : .selector(s, fx: 0.5, fy: 0.5)
        }
        if let a = v as? [Any], a.count == 2, let x = (a[0] as? NSNumber)?.doubleValue,
           let y = (a[1] as? NSNumber)?.doubleValue {
            return .viewport(x, y)
        }
        if let d = v as? [String: Any] {
            if let p = d["screen"] as? [Any], p.count == 2, let x = (p[0] as? NSNumber)?.doubleValue,
               let y = (p[1] as? NSNumber)?.doubleValue {
                return .screen(x, y)
            }
            if let sel = (d["selector"] as? String) ?? (d["sel"] as? String) ?? (d["ref"] as? String), !sel.isEmpty {
                var fx = 0.5, fy = 0.5
                if let p = d["pos"] as? [Any], p.count == 2 {
                    fx = (p[0] as? NSNumber)?.doubleValue ?? 0.5
                    fy = (p[1] as? NSNumber)?.doubleValue ?? 0.5
                }
                return isRef(sel) ? .ref(sel, fx: fx, fy: fy) : .selector(sel, fx: fx, fy: fy)
            }
            if let x = (d["x"] as? NSNumber)?.doubleValue, let y = (d["y"] as? NSNumber)?.doubleValue {
                return .viewport(x, y)
            }
        }
        throw fail("bad target — a CSS selector, a ref (ref_12), [x,y] in viewport px, {\"screen\":[x,y]}, "
            + "or {\"selector\":\"…\",\"pos\":[0.5,0.8]}")
    }

    /// `ref_12` — an element ref from som / query-dom / find. Never a sane CSS
    /// selector (it would be a tag named "ref_12").
    static func isRef(_ s: String) -> Bool {
        s.hasPrefix("ref_") && s.count > 4 && s.dropFirst(4).allSatisfy(\.isNumber)
    }

    private static func parseButton(_ v: Any?, _ fail: (String) -> ScriptError) throws -> MouseButton {
        guard let s = v as? String else { return .left }
        if s == "center" { return .middle }
        guard let b = MouseButton(rawValue: s.lowercased()) else { throw fail("button is left, right or middle") }
        return b
    }

    /// CDP modifier bits: Alt 1, Ctrl 2, Meta/Cmd 4, Shift 8.
    private static func modifierMask(_ v: Any?, _ fail: (String) -> ScriptError) throws -> Int {
        let names: [String]
        if let a = v as? [Any] { names = a.compactMap { $0 as? String } }
        else if let s = v as? String { names = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        else { return 0 }
        var m = 0
        for n in names where !n.isEmpty {
            switch n.lowercased() {
            case "alt", "opt", "option": m |= 1
            case "ctrl", "control": m |= 2
            case "cmd", "command", "meta": m |= 4
            case "shift": m |= 8
            default: throw fail("unknown modifier \"\(n)\" — cmd, shift, alt/opt, ctrl")
            }
        }
        return m
    }

    // MARK: - Keys (US layout, the same table Chrome's own input tests use)

    /// A key name or a character → its definition, plus the modifiers the
    /// character implies ("A" and "!" are Shift + a key).
    static func keyDef(_ name: String) -> (KeyDef, Int)? {
        if let d = named[name.lowercased()] { return (d, 0) }
        guard name.count == 1, let ch = name.first else { return nil }
        let c = String(ch)
        if ch.isLetter, ch.isASCII {
            let lower = c.lowercased()
            let vk = Int(lower.unicodeScalars.first!.value) - 32       // 'a' 97 → 65
            let shifted = ch.isUppercase
            return (KeyDef(key: shifted ? c : lower, code: "Key" + lower.uppercased(), vk: vk,
                           text: shifted ? c : lower), shifted ? 8 : 0)
        }
        if ch.isASCII, let d = ch.wholeNumberValue {
            return (KeyDef(key: c, code: "Digit\(d)", vk: 48 + d, text: c), 0)
        }
        for (base, shift, code, vk) in punct {
            if c == base { return (KeyDef(key: c, code: code, vk: vk, text: c), 0) }
            if c == shift { return (KeyDef(key: c, code: code, vk: vk, text: c), 8) }
        }
        for (i, s) in ")!@#$%^&*(".enumerated() where String(s) == c {
            return (KeyDef(key: c, code: "Digit\(i)", vk: 48 + i, text: c), 8)
        }
        return nil
    }

    private static let punct: [(String, String, String, Int)] = [
        (";", ":", "Semicolon", 186), ("=", "+", "Equal", 187), (",", "<", "Comma", 188),
        ("-", "_", "Minus", 189), (".", ">", "Period", 190), ("/", "?", "Slash", 191),
        ("`", "~", "Backquote", 192), ("[", "{", "BracketLeft", 219), ("\\", "|", "Backslash", 220),
        ("]", "}", "BracketRight", 221), ("'", "\"", "Quote", 222),
    ]

    private static let named: [String: KeyDef] = {
        var m: [String: KeyDef] = [:]
        func put(_ names: [String], _ d: KeyDef) { for n in names { m[n] = d } }
        put(["enter", "return"], KeyDef(key: "Enter", code: "Enter", vk: 13, text: "\r"))
        put(["tab"], KeyDef(key: "Tab", code: "Tab", vk: 9, text: nil))
        put(["space", " "], KeyDef(key: " ", code: "Space", vk: 32, text: " "))
        // floaty's own `key` names: "delete" is the Mac delete key (Backspace).
        put(["backspace", "delete"], KeyDef(key: "Backspace", code: "Backspace", vk: 8, text: nil))
        put(["forwarddelete", "fwddelete", "del"], KeyDef(key: "Delete", code: "Delete", vk: 46, text: nil))
        put(["escape", "esc"], KeyDef(key: "Escape", code: "Escape", vk: 27, text: nil))
        put(["arrowleft", "left"], KeyDef(key: "ArrowLeft", code: "ArrowLeft", vk: 37, text: nil))
        put(["arrowup", "up"], KeyDef(key: "ArrowUp", code: "ArrowUp", vk: 38, text: nil))
        put(["arrowright", "right"], KeyDef(key: "ArrowRight", code: "ArrowRight", vk: 39, text: nil))
        put(["arrowdown", "down"], KeyDef(key: "ArrowDown", code: "ArrowDown", vk: 40, text: nil))
        put(["home"], KeyDef(key: "Home", code: "Home", vk: 36, text: nil))
        put(["end"], KeyDef(key: "End", code: "End", vk: 35, text: nil))
        put(["pageup", "pgup"], KeyDef(key: "PageUp", code: "PageUp", vk: 33, text: nil))
        put(["pagedown", "pgdown"], KeyDef(key: "PageDown", code: "PageDown", vk: 34, text: nil))
        put(["insert"], KeyDef(key: "Insert", code: "Insert", vk: 45, text: nil))
        put(["shift"], KeyDef(key: "Shift", code: "ShiftLeft", vk: 16, text: nil))
        put(["control", "ctrl"], KeyDef(key: "Control", code: "ControlLeft", vk: 17, text: nil))
        put(["alt", "option", "opt"], KeyDef(key: "Alt", code: "AltLeft", vk: 18, text: nil))
        put(["meta", "cmd", "command"], KeyDef(key: "Meta", code: "MetaLeft", vk: 91, text: nil))
        put(["capslock"], KeyDef(key: "CapsLock", code: "CapsLock", vk: 20, text: nil))
        for i in 1...12 { put(["f\(i)"], KeyDef(key: "F\(i)", code: "F\(i)", vk: 111 + i, text: nil)) }
        let words: [(String, String)] = [
            ("minus", "-"), ("equal", "="), ("leftbracket", "["), ("rightbracket", "]"), ("backslash", "\\"),
            ("semicolon", ";"), ("quote", "'"), ("comma", ","), ("period", "."), ("slash", "/"),
            ("grave", "`"), ("backtick", "`"),
        ]
        for (w, c) in words {
            if let (code, vk) = punct.first(where: { $0.0 == c }).map({ ($0.2, $0.3) }) {
                m[w] = KeyDef(key: c, code: code, vk: vk, text: c)
            }
        }
        return m
    }()

    /// On macOS, Chrome runs editing shortcuts from the native menu, not from
    /// key events — so ⌘A sent over CDP selects nothing unless the command
    /// rides along (what Chrome's own tools do).
    private static func macCommands(_ d: KeyDef, _ mods: Int) -> [String] {
        guard mods & 4 != 0 else { return [] }
        let shift = mods & 8 != 0
        switch d.code {
        case "KeyA": return ["selectAll"]
        case "KeyC": return ["copy"]
        case "KeyX": return ["cut"]
        case "KeyV": return ["paste"]
        case "KeyZ": return [shift ? "redo" : "undo"]
        default: return []
        }
    }
}
