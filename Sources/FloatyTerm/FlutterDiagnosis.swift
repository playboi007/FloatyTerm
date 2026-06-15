import Foundation

/// Classifies Flutter error events into a uniform `diagnosis` envelope so the
/// reading agent gets a claim, the load-bearing numbers, and an audit protocol
/// with an explicit stop condition — instead of a prose hint it can satisfice
/// on (stop at the first plausible match and miss the second offender).
///
/// The envelope is the same for every category:
///
///     "diagnosis": {
///       "category": "layout/overflow",
///       "what":     "<one-line claim>",
///       "where":    "<best user frame>",
///       "evidence": { "overflow_px": 1043, ... },
///       "candidates_complete": false,
///       "protocol": "<2-3 sentence audit with a stop condition>"
///     }
///
/// `candidates_complete` is the honesty bit: banner parsing can never
/// enumerate the full suspect set (sibling sizes live only in the render
/// tree), so it stays false here and each protocol says how to complete the
/// enumeration. A future Dart-side collector fills `candidates` and flips it.
///
/// Design: ONE ordered table of rules, not code paths. A new failure mode met
/// in the wild = one new row. First match wins, so put specific patterns
/// (Null subtype) above general ones (any subtype mismatch).
enum FlutterDiagnosis {

    private struct Rule {
        let category: String
        let pattern: NSRegularExpression
        let protocolText: String
        /// Pulls category-specific numbers/names out of the matched text.
        let evidence: (String, NSTextCheckingResult) -> [String: Any]
    }

    private static func rx(_ pattern: String) -> NSRegularExpression {
        // The table is static and developer-authored; a bad pattern should
        // crash loudly at first classify, not silently skip a rule.
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Captured group `n` of `m` in `text`, or nil when the group didn't take.
    private static func group(_ n: Int, _ m: NSTextCheckingResult, _ text: String) -> String? {
        guard n < m.numberOfRanges, let r = Range(m.range(at: n), in: text) else { return nil }
        return String(text[r])
    }

    /// First capture group of `pattern` anywhere in `text` — for evidence
    /// extractors that need a value living on a different line than the line
    /// the rule matched on (a Dio status code sits below its exception line).
    private static func firstGroup(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// Pulls a 3-digit HTTP status from anywhere in the text. Tries Dio's
    /// phrasing first, then generic "status: NNN" / "HTTP NNN" forms so the
    /// http/http2/chopper clients are covered too.
    private static func extractStatus(_ text: String) -> Int? {
        for p in [#"status code of (\d{3})"#, #"status[:= ]+(\d{3})"#, #"\bHTTP[/ ]?[\d.]*\s+(\d{3})"#] {
            if let s = firstGroup(p, text), let n = Int(s), (100...599).contains(n) { return n }
        }
        return nil
    }

    /// Concise, code-specific reading of an HTTP status: what it means and the
    /// one thing to check. Known codes get a precise line; unknown codes fall
    /// back to their class so EVERY status — not just the common handful —
    /// gets an actionable interpretation in `evidence.status_meaning`.
    static func httpStatusMeaning(_ code: Int) -> String {
        switch code {
        // 4xx — the request is wrong; fix it before touching the server.
        case 400: return "Bad Request — malformed syntax, params or body; validate what the client sent"
        case 401: return "Unauthorized — missing/expired/invalid credentials; check the auth token and refresh flow"
        case 402: return "Payment Required — billing/quota gate on the API"
        case 403: return "Forbidden — authenticated but not permitted; check roles, scopes, or resource ownership (not the token itself)"
        case 404: return "Not Found — wrong route/URL or a resource id that doesn't exist; verify the endpoint path and id"
        case 405: return "Method Not Allowed — wrong HTTP verb for this route; check GET vs POST/PUT/PATCH"
        case 406: return "Not Acceptable — server can't produce a format matching the request's Accept header; fix the Accept header (or request JSON)"
        case 407: return "Proxy Authentication Required — the proxy, not the API, wants credentials"
        case 408: return "Request Timeout — server gave up waiting for the request; retry or send a smaller/faster request"
        case 409: return "Conflict — state clash: a duplicate, a version mismatch, or concurrent edit; reconcile then retry"
        case 410: return "Gone — the resource was permanently removed; stop requesting it"
        case 411: return "Length Required — add a Content-Length header"
        case 412: return "Precondition Failed — an If-Match/If-Unmodified-Since precondition didn't hold"
        case 413: return "Payload Too Large — shrink the request body or stream/paginate it"
        case 414: return "URI Too Long — too many/too large query params; move them to the body"
        case 415: return "Unsupported Media Type — fix the Content-Type or the body encoding (e.g. send JSON, not form data)"
        case 416: return "Range Not Satisfiable — the requested byte range is outside the resource"
        case 417: return "Expectation Failed — the Expect header can't be met"
        case 418: return "I'm a teapot — a deliberate/easter-egg reject; the route likely isn't a real API endpoint"
        case 422: return "Unprocessable Entity — body is well-formed but fails validation; check field-level rules and required fields"
        case 423: return "Locked — the resource is locked; wait or release the lock"
        case 424: return "Failed Dependency — a prior request this one depended on failed"
        case 425: return "Too Early — replay risk; retry once the connection is established"
        case 426: return "Upgrade Required — the server demands a different protocol/TLS version"
        case 428: return "Precondition Required — add a conditional header (If-Match) the server mandates"
        case 429: return "Too Many Requests — rate limited; back off and honor the Retry-After header"
        case 431: return "Request Header Fields Too Large — trim oversized headers/cookies"
        case 451: return "Unavailable For Legal Reasons — blocked by policy/jurisdiction"
        // 5xx — the server failed; this is NOT the client's fault. Fix the server.
        case 500: return "Internal Server Error — an unhandled server-side bug; read the SERVER logs, not the Dart code"
        case 501: return "Not Implemented — the server doesn't support this method/endpoint yet"
        case 502: return "Bad Gateway — the API gateway/proxy got an invalid response from the backend; check the upstream service"
        case 503: return "Service Unavailable — server down, overloaded, or mid-deploy; retry with backoff (check Retry-After)"
        case 504: return "Gateway Timeout — an upstream service timed out; check the slow backend, not the client timeout"
        case 505: return "HTTP Version Not Supported"
        case 507: return "Insufficient Storage — the server is out of space"
        case 508: return "Loop Detected — the server hit an infinite loop resolving the request"
        case 511: return "Network Authentication Required — a captive portal/proxy needs sign-in (not the API's own auth)"
        // 3xx — Dio usually follows redirects, so seeing one thrown is unusual.
        case 301, 308: return "Permanent Redirect — update the client's base URL to the new location"
        case 302, 303, 307: return "Temporary Redirect — follow Location; ensure the client isn't configured to reject redirects"
        case 304: return "Not Modified — the cached copy is current; this is usually expected, not an error"
        default:
            switch code {
            case 300...399: return "Redirect (\(code)) — follow the Location header; check the client's redirect policy"
            case 400...499: return "Client error (\(code)) — the request is wrong; fix the request before the server"
            case 500...599: return "Server error (\(code)) — the server failed; fix the server, not the request"
            default:         return "Unexpected status \(code)"
            }
        }
    }

    private static let rules: [Rule] = [

        // ── Layout ──

        Rule(category: "layout/overflow",
             pattern: rx(#"Render\w*Flex overflowed by ([0-9.]+) pixels on the (top|right|bottom|left)"#),
             protocolText: "Enumerate EVERY child of the flex parent and classify each as "
                + "fixed-size or flex BEFORE proposing a fix — multiple oversized children "
                + "are common, do not stop at the first one found. The fixed children's "
                + "sizes must account for the full overflow_px.",
             evidence: { text, m in
                 var ev: [String: Any] = [:]
                 if let s = group(1, m, text), let px = Double(s) { ev["overflow_px"] = px }
                 if let edge = group(2, m, text) { ev["edge"] = edge }
                 return ev
             }),

        Rule(category: "layout/negative-constraints",
             pattern: rx(#"negative minimum (height|width)"#),
             protocolText: "A fixed-size sibling already exceeds the parent's budget, leaving "
                + "negative space for the flex children. Enumerate EVERY sibling in the flex "
                + "parent with its size on that axis — do not stop at the first fixed-size "
                + "widget found; the anomalous one is often not the first.",
             evidence: { text, m in
                 group(1, m, text).map { ["axis": $0] } ?? [:]
             }),

        Rule(category: "layout/unbounded",
             pattern: rx(#"unbounded (height|width)|forces an infinite (height|width)|RenderBox was not laid out|!?hasSize"#),
             protocolText: "The failure is in the PARENT chain, not the named widget: walk "
                + "widget_chain upward to the first widget that gives no bound on that axis "
                + "(a scrollable or Column/Row around this child, or an Intrinsic widget). "
                + "Fix by bounding there — Expanded, SizedBox, shrinkWrap — not by resizing the child.",
             evidence: { text, m in
                 (group(1, m, text) ?? group(2, m, text)).map { ["axis": $0] } ?? [:]
             }),

        Rule(category: "layout/parentdata",
             pattern: rx(#"Incorrect use of ParentDataWidget"#),
             protocolText: "This is a parent-type mismatch, not a sizing bug: Expanded/Flexible "
                + "are valid only DIRECTLY inside Row/Column/Flex, Positioned only inside Stack. "
                + "Check the offending widget's direct parent in widget_chain — some wrapper "
                + "(Padding, Container, Align…) is sitting between them.",
             evidence: { _, _ in [:] }),

        // ── Lifecycle ──

        Rule(category: "lifecycle/setstate-after-dispose",
             pattern: rx(#"setState\(\) called after dispose"#),
             protocolText: "Enumerate EVERY async path in this State — awaits, stream/listener "
                + "subscriptions, timers — and guard each with `mounted` or cancel it in "
                + "dispose(). Fixing only the path in the stack usually leaves siblings that "
                + "fail the same way.",
             evidence: { _, _ in [:] }),

        Rule(category: "lifecycle/build-phase",
             pattern: rx(#"(setState\(\) or markNeedsBuild\(\)|setState\(\)) called during build"#),
             protocolText: "Something mutates state synchronously during build — notifyListeners "
                + "or setState reached from build/initState/didChangeDependencies. Find the "
                + "mutation site in user_frames and defer it (addPostFrameCallback) or lift it "
                + "out of the build phase.",
             evidence: { _, _ in [:] }),

        Rule(category: "lifecycle/deactivated-context",
             pattern: rx(#"deactivated widget's ancestor"#),
             protocolText: "A BuildContext is used after its widget left the tree — typically "
                + "after an await or inside a dialog/navigation callback. Read the dependency "
                + "(Provider.of, Theme.of…) BEFORE the async gap, or re-check `mounted` after it.",
             evidence: { _, _ in [:] }),

        Rule(category: "lifecycle/duplicate-globalkey",
             pattern: rx(#"(Duplicate GlobalKey|Multiple widgets used the same GlobalKey)"#),
             protocolText: "Enumerate EVERY site that puts this key in the tree — a key declared "
                + "once in code can appear twice at runtime (e.g. built per list row, or a "
                + "widget kept alive across navigation). Each live widget needs its own key instance.",
             evidence: { _, _ in [:] }),

        // ── Types / null safety ── (Null subtype BEFORE the general cast rule)

        Rule(category: "type/null",
             pattern: rx(#"type 'Null' is not a subtype of type '([^']+)'|Null check operator used on a null value|Unexpected null value"#),
             protocolText: "Trace the value's PROVENANCE, not the crash site: enumerate every "
                + "site that assigns this field (API decode, cache read, constructor default) "
                + "and find which one produced null. Adding `!` or `?` at the crash site hides "
                + "the bug instead of fixing it.",
             evidence: { text, m in
                 group(1, m, text).map { ["expected_type": $0] } ?? [:]
             }),

        Rule(category: "type/cast",
             pattern: rx(#"type '([^']+)' is not a subtype of type '([^']+)'"#),
             protocolText: "The runtime value's shape disagrees with the model: check the JSON "
                + "decode / map cast feeding this expression against the actual payload. "
                + "Enumerate the construction sites of the expected type before changing the cast.",
             evidence: { text, m in
                 var ev: [String: Any] = [:]
                 if let a = group(1, m, text) { ev["actual_type"] = a }
                 if let e = group(2, m, text) { ev["expected_type"] = e }
                 return ev
             }),

        Rule(category: "type/method-or-range",
             pattern: rx(#"NoSuchMethodError|RangeError"#),
             protocolText: "The receiver is not what the call site assumes — often null, or a "
                + "collection emptier/shorter than expected. Trace where the receiver was "
                + "produced and enumerate its assignment sites before patching the call.",
             evidence: { _, _ in [:] }),

        // ── Network / data ── (timeout BEFORE bad-response: both are DioException)

        Rule(category: "network/timeout",
             pattern: rx(#"DioException \[(connection timeout|receive timeout|send timeout|connection error)\]|SocketException|Connection refused|Failed host lookup|XMLHttpRequest error"#),
             protocolText: "The request never got a response — connectivity, wrong base URL, "
                + "a dev server that isn't running, or CORS — NOT a logic bug at the Dart "
                + "stack frames. There is no status code here; confirm the host/port is "
                + "reachable and the API is up before touching app code.",
             evidence: { text, _ in
                 firstGroup(#"DioException \[([^\]]+)\]"#, text).map { ["dio_type": $0] } ?? [:]
             }),

        Rule(category: "network/http-response",
             pattern: rx(#"DioException|status code of \d+|HttpException|ClientException"#),
             protocolText: "The request REACHED the server and came back with an error status — "
                + "this is not a Dart bug at the crash site, so ignore the dart-sdk async "
                + "frames. Read `evidence.status_meaning` for what this specific code means and "
                + "what to check, then correlate with the kind:'network' event for the same URL "
                + "in this log (it has method/url/status). Change the request or the server per "
                + "the meaning — never just widen validateStatus to swallow it.",
             evidence: { text, _ in
                 var ev: [String: Any] = [:]
                 if let n = extractStatus(text) {
                     ev["status"] = n
                     ev["status_meaning"] = httpStatusMeaning(n)
                 }
                 if let t = firstGroup(#"DioException \[([^\]]+)\]"#, text) {
                     ev["dio_type"] = t
                 }
                 return ev
             }),

        Rule(category: "data/parse",
             pattern: rx(#"FormatException|Unexpected character|Unexpected end of input|Could not parse"#),
             protocolText: "The payload's shape disagrees with what the parser expects — usually "
                + "the response body isn't the JSON the model assumes (an HTML error page, an "
                + "empty body, or a field that changed type). Inspect the raw response in the "
                + "correlated kind:'network' event before adjusting the fromJson / model.",
             evidence: { _, _ in [:] }),

        // ── Async ──

        Rule(category: "async/unhandled",
             pattern: rx(#"Unhandled (rejection|exception)"#),
             protocolText: "Find the Future or Stream whose error escapes: an un-awaited call "
                + "without catchError, or a listen() without onError. user_frames shows where "
                + "it was created, which is usually not where it failed.",
             evidence: { _, _ in [:] }),
    ]

    /// The uniform envelope for a flutter-mode error event, or nil for
    /// non-error events. Errors no rule recognizes still get a `generic`
    /// envelope so the contract holds for every error in the log.
    static func classify(_ event: [String: Any]) -> [String: Any]? {
        // Errors arrive two ways: as kind:"error" (banners, window.onerror)
        // and as kind:"console" level:"error" — where Dart runtime dumps like
        // an uncaught DioException land, since flutterSift only assembles the
        // framed "EXCEPTION CAUGHT BY" banners. Classify both.
        let kind = event["kind"] as? String
        let isError = kind == "error"
            || (kind == "console" && (event["level"] as? String) == "error")
        guard isError else { return nil }
        // Console events carry their content in `text`, not `message`; fall
        // back so `what` and the haystack are never empty for them.
        let text = event["text"] as? String ?? ""
        let message = (event["message"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? text
        // The assembled banner carries detail the one-line message lacks
        // (constraints lines, viewport hints); match against both, capped so
        // a pathological banner can't make regex matching expensive.
        let haystack = message + "\n" + String(text.prefix(4000))
        let range = NSRange(haystack.startIndex..., in: haystack)

        var diagnosis: [String: Any] = [
            "what": String(message.prefix(200)),
            // Banner parsing can never see sibling sizes — only the Dart-side
            // collector can enumerate the real suspect set.
            "candidates_complete": false
        ]
        if let frames = event["user_frames"] as? [String], let first = frames.first {
            diagnosis["where"] = first
        } else if let src = event["source"] as? String, !src.isEmpty {
            diagnosis["where"] = src
        }

        for rule in rules {
            guard let m = rule.pattern.firstMatch(in: haystack, range: range) else { continue }
            diagnosis["category"] = rule.category
            diagnosis["protocol"] = rule.protocolText
            var ev = rule.evidence(haystack, m)
            if let c = event["constraints"] as? String { ev["constraints"] = c }
            if !ev.isEmpty { diagnosis["evidence"] = ev }
            return diagnosis
        }

        diagnosis["category"] = "generic"
        diagnosis["protocol"] = "Uncategorized error — read the full `text` field before acting; "
            + "start from user_frames, and treat the first plausible cause as a hypothesis to "
            + "verify, not a conclusion."
        return diagnosis
    }
}
