import Foundation

/// Key syntax shared by `key` (foreground and background) and `input`: what
/// models already write for computer use. Pure, so it is testable on its own.
///
///   "Enter"              one key
///   "cmd+s"              a chord: modifiers, then the key, joined by "+"
///   "Tab Tab Enter"      a sequence: strokes separated by spaces
///   "ctrl+shift+Page_Up" names are case-insensitive; "_" is ignored
///
/// A single character is always one key ("+", " " and "a" included).
enum KeySpec {

    struct Stroke: Equatable {
        var key: String
        /// Canonical names: cmd, shift, alt, ctrl.
        var modifiers: [String]
    }

    struct SpecError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A modifier word → its canonical name, nil when it isn't one.
    static func modifier(_ word: String) -> String? {
        switch word.lowercased().replacingOccurrences(of: "_", with: "") {
        case "cmd", "command", "meta", "super", "win", "windows": return "cmd"
        case "shift": return "shift"
        case "alt", "opt", "option": return "alt"
        case "ctrl", "control": return "ctrl"
        default: return nil
        }
    }

    /// Model-style key names → floaty's names. Lower-cased, "_" removed first.
    static func normalizedName(_ raw: String) -> String {
        guard raw.count > 1 else { return raw }
        let k = raw.lowercased().replacingOccurrences(of: "_", with: "")
        switch k {
        case "pageup", "prior": return "pgup"
        case "pagedown", "next": return "pgdown"
        case "arrowleft", "leftarrow": return "left"
        case "arrowright", "rightarrow": return "right"
        case "arrowup", "uparrow": return "up"
        case "arrowdown", "downarrow": return "down"
        case "esc": return "escape"
        case "enter", "kpenter": return "return"
        case "spacebar": return "space"
        default: return k
        }
    }

    /// Parse a key spec. `extra` modifiers (from --modifiers) apply to every
    /// stroke. Throws on an unknown modifier or an empty stroke; whether the
    /// KEY exists is the caller's table to decide.
    static func parse(_ spec: String, extra: [String] = []) throws -> [Stroke] {
        var extraCanon: [String] = []
        for m in extra where !m.isEmpty {
            guard let c = modifier(m) else {
                throw SpecError(message: "unknown modifier \"\(m)\" — cmd, shift, alt/opt, ctrl")
            }
            if !extraCanon.contains(c) { extraCanon.append(c) }
        }
        // One character is one key, whatever it is ("+", " ", "a").
        if spec.count == 1 { return [Stroke(key: spec, modifiers: extraCanon)] }
        let tokens = spec.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !tokens.isEmpty else { throw SpecError(message: "empty key") }
        return try tokens.map { token in
            var parts = token.components(separatedBy: "+")
            // "cmd++" → the "+" key with cmd: the split leaves two empty tails.
            if token.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }
            guard let key = parts.last, !key.isEmpty else {
                throw SpecError(message: "\"\(token)\" has no key after the modifiers")
            }
            var mods = extraCanon
            for word in parts.dropLast() {
                guard let c = modifier(word) else {
                    throw SpecError(message: "\"\(word)\" in \"\(token)\" is not a modifier — cmd, shift, alt/opt, ctrl")
                }
                if !mods.contains(c) { mods.append(c) }
            }
            return Stroke(key: normalizedName(key), modifiers: mods)
        }
    }
}
