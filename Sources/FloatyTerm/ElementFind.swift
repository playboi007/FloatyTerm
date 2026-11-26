import CoreGraphics
import Foundation

/// `floaty find` — rank elements by a plain-words query ("add to cart button",
/// "email field"). Pure, so the same scorer serves the AX path and the DOM
/// path and is testable on its own.
///
/// Not a language model: words in the query are matched against each
/// element's name (and its description / placeholder), role words ("button",
/// "field", "link"…) against its role, and the whole phrase counts extra. It
/// is the cheap first look — "where is the thing called X" without reading
/// the whole tree.
enum ElementFind {

    struct Candidate {
        let role: String
        let name: String
        /// Description, placeholder, help, value — weaker evidence than the name.
        let extra: String
        let rect: CGRect
        let ref: String
        let interactive: Bool
    }

    struct Hit {
        let candidate: Candidate
        let score: Double
    }

    /// Query role words → substrings of a role (AX `AXButton`, DOM `button`).
    private static let roleWords: [String: [String]] = [
        "button": ["button"], "btn": ["button"],
        "link": ["link"],
        "field": ["textfield", "textarea", "textbox", "searchfield", "combobox", "input"],
        "textbox": ["textfield", "textarea", "textbox", "input"],
        "input": ["textfield", "textarea", "textbox", "input", "searchfield"],
        "box": ["textfield", "textbox", "combobox", "checkbox", "input"],
        "search": ["searchfield", "search"],
        "checkbox": ["checkbox"], "check": ["checkbox"],
        "radio": ["radio"],
        "tab": ["tab"],
        "menu": ["menu"],
        "dropdown": ["popupbutton", "combobox", "select", "listbox"],
        "select": ["popupbutton", "combobox", "select", "listbox"],
        "heading": ["heading", "h1", "h2", "h3", "h4"], "title": ["heading", "h1", "h2"],
        "image": ["image", "img"], "icon": ["image", "img", "button"],
        "slider": ["slider"], "switch": ["switch", "checkbox"], "toggle": ["switch", "checkbox"],
        "row": ["row", "cell", "li", "tr"], "item": ["menuitem", "row", "cell", "li", "option"],
    ]
    private static let stopWords: Set<String> = [
        "the", "a", "an", "to", "of", "for", "on", "in", "and", "or", "with", "my", "this", "that",
        "please", "click", "press", "tap", "find", "where", "is", "it", "at", "called", "named", "labeled",
    ]

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func rank(_ query: String, _ candidates: [Candidate], limit: Int = 20) -> [Hit] {
        let all = words(query).filter { !stopWords.contains($0) }
        let roleHints = all.compactMap { roleWords[$0] }.flatMap { $0 }
        // Content words: what the element is CALLED. A role word can be content
        // too ("Search" is a common button name), so it stays in when it is the
        // only word.
        let content = all.filter { roleWords[$0] == nil }
        let nameWords = content.isEmpty ? all : content
        let phrase = nameWords.joined(separator: " ")

        var hits: [Hit] = []
        for c in candidates {
            let name = c.name.lowercased()
            let extra = c.extra.lowercased()
            let nameTokens = Set(words(c.name))
            var score = 0.0
            var matched = 0
            for w in nameWords {
                if nameTokens.contains(w) { score += 2.5; matched += 1 }
                else if name.contains(w) { score += 1.5; matched += 1 }
                else if extra.contains(w) { score += 1; matched += 1 }
            }
            guard matched > 0 else { continue }
            if nameWords.count > 1, matched == nameWords.count { score += 1.5 }
            if !phrase.isEmpty, name.contains(phrase) { score += 2 }
            if name == phrase { score += 2 }
            let role = c.role.lowercased()
            if !roleHints.isEmpty {
                score += roleHints.contains(where: { role.contains($0) }) ? 2 : -1
            }
            if c.interactive { score += 0.3 }
            if c.name.count > 80 { score -= 0.5 }    // a paragraph that merely mentions the words
            hits.append(Hit(candidate: c, score: score))
        }
        hits.sort { (a: Hit, b: Hit) -> Bool in
            if a.score != b.score { return a.score > b.score }
            if a.candidate.rect.minY != b.candidate.rect.minY { return a.candidate.rect.minY < b.candidate.rect.minY }
            return a.candidate.rect.minX < b.candidate.rect.minX
        }
        return Array(hits.prefix(limit))
    }
}
