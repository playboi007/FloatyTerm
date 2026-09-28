import Foundation

/// Turns a recording into something a person or an agent can act on:
/// structured JSON, a HAR file, or Markdown.
///
/// Three formats because they answer three different questions:
///
///   - **json** — the whole session, unflattened, plus a `replay.curl` string
///     per request. This is the agent's format: one array, every field, no
///     prose to parse.
///   - **har**  — HAR 1.2, which Chrome DevTools, Proxyman and Charles all
///     import. Costs nothing to emit and hands the user a real viewer with
///     timing waterfalls for free.
///   - **md**   — a summary table over a detail section per request, each with
///     a runnable `curl`. This is the format to paste into an issue.
///
/// Every format carries the unredacted headers and bodies the recorder
/// captured. The `curl` line is the test of that: if it does not reproduce the
/// request, the recording was not complete enough, and the point of this
/// feature was to be complete enough.
enum NetworkExport {

    // MARK: - Entry point

    /// Reads `record`, applies the filters, and writes `format` to `out`.
    /// Returns the summary the CLI prints.
    static func run(record: URL, format: String, out: URL,
                    urlContains: String?, failedOnly: Bool, fullBodies: Bool) -> [String: Any] {
        guard let text = try? String(contentsOf: record, encoding: .utf8) else {
            return ["error": "cannot read recording: \(record.path)"]
        }

        var meta: [String: Any] = [:]
        var stop: [String: Any] = [:]
        var events: [[String: Any]] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            switch obj["kind"] as? String {
            case "record_start": meta = obj
            case "record_stop":  stop = obj
            default:             events.append(obj)
            }
        }

        let filtered = events.filter { e in
            if failedOnly {
                let status = (e["status"] as? NSNumber)?.intValue ?? 0
                if e["error"] == nil && status < 400 { return false }
            }
            if let needle = urlContains, !needle.isEmpty {
                let url = (e["url"] as? String) ?? ""
                if !url.localizedCaseInsensitiveContains(needle) { return false }
            }
            return true
        }
        // Recorder sequence, not wall clock: two collectors stamping the same
        // request a millisecond apart must not reorder the session.
        .sorted { ($0["seq"] as? NSNumber)?.intValue ?? 0 < ($1["seq"] as? NSNumber)?.intValue ?? 0 }

        let body: String
        switch format.lowercased() {
        case "har":       body = har(filtered, meta: meta)
        case "md",
             "markdown":  body = markdown(filtered, meta: meta, stop: stop,
                                          source: record, fullBodies: fullBodies)
        case "json":      body = json(filtered, meta: meta, stop: stop)
        default:
            return ["error": "unknown format: \(format)", "formats": ["json", "har", "md"]]
        }

        do {
            try body.write(to: out, atomically: true, encoding: .utf8)
            // The export inherits the recording's secrets, so it inherits its
            // mode too — an unredacted HAR in a world-readable file is how a
            // token ends up in someone else's backup.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: out.path)
        } catch {
            return ["error": "cannot write \(out.path): \(error.localizedDescription)"]
        }

        return ["exported": true, "file": out.path, "format": format.lowercased(),
                "requests": filtered.count, "of": events.count,
                "source": record.path,
                "note": "unredacted — contains credentials"]
    }

    // MARK: - JSON

    private static func json(_ events: [[String: Any]],
                             meta: [String: Any], stop: [String: Any]) -> String {
        let requests = events.map { e -> [String: Any] in
            var out = e
            if isHTTP(e) { out["replay"] = ["curl": curl(e)] }
            return out
        }
        let doc: [String: Any] = [
            "session": meta["session"] ?? "",
            "label": meta["label"] ?? "",
            "started_at": meta["started_at"] ?? "",
            "stopped_at": stop["stopped_at"] ?? "",
            "duration_ms": stop["duration_ms"] ?? 0,
            "count": requests.count,
            "redacted": false,
            "requests": requests
        ]
        let data = (try? JSONSerialization.data(withJSONObject: doc,
                                                options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - HAR 1.2

    private static func har(_ events: [[String: Any]], meta: [String: Any]) -> String {
        let entries = events.map { e -> [String: Any] in
            let ms = (e["ms"] as? NSNumber)?.doubleValue ?? -1
            let reqHeaders = harHeaders(e["req_headers"])
            let resHeaders = harHeaders(e["res_headers"])
            let url = (e["url"] as? String) ?? ""

            var postData: [String: Any]? = nil
            if let body = e["req_body"] as? String, !body.isEmpty {
                postData = ["mimeType": headerValue(e["req_headers"], "content-type") ?? "application/octet-stream",
                            "text": body, "params": []]
            }
            let status = (e["status"] as? NSNumber)?.intValue ?? 0
            var content: [String: Any] = [
                "size": (e["res_body_bytes"] as? NSNumber)?.intValue ?? 0,
                "mimeType": headerValue(e["res_headers"], "content-type") ?? ""
            ]
            if let body = e["res_body"] as? String {
                content["text"] = body
                if (e["res_body_base64"] as? NSNumber)?.boolValue == true {
                    content["encoding"] = "base64"
                }
            }

            var entry: [String: Any] = [
                "startedDateTime": (e["ts"] as? String) ?? "",
                "time": ms,
                "request": [
                    "method": (e["method"] as? String) ?? "",
                    "url": url,
                    "httpVersion": (e["http_version"] as? String) ?? "HTTP/1.1",
                    "cookies": [],
                    "headers": reqHeaders,
                    "queryString": queryString(url),
                    "headersSize": -1,
                    "bodySize": (e["req_body_bytes"] as? NSNumber)?.intValue ?? -1
                ].merging(postData.map { ["postData": $0] } ?? [:]) { a, _ in a },
                "response": [
                    "status": status,
                    "statusText": (e["status_text"] as? String) ?? "",
                    "httpVersion": (e["http_version"] as? String) ?? "HTTP/1.1",
                    "cookies": [],
                    "headers": resHeaders,
                    "content": content,
                    "redirectURL": headerValue(e["res_headers"], "location") ?? "",
                    "headersSize": -1,
                    "bodySize": (e["res_body_bytes"] as? NSNumber)?.intValue ?? -1
                ],
                "cache": [:],
                // HAR requires every phase; only total time is known, so the
                // rest are -1 ("not available") rather than invented zeros.
                "timings": ["send": -1, "wait": ms, "receive": -1,
                            "blocked": -1, "dns": -1, "connect": -1, "ssl": -1]
            ]
            if let error = e["error"] as? String { entry["comment"] = "error: \(error)" }
            if let source = e["source"] as? String {
                entry["_source"] = source        // HAR allows _-prefixed extras
            }
            return entry
        }

        let doc: [String: Any] = ["log": [
            "version": "1.2",
            "creator": ["name": "FloatyTerm", "version": "1"],
            "comment": "session \(meta["session"] ?? "") — unredacted",
            "entries": entries,
            "pages": []
        ]]
        let data = (try? JSONSerialization.data(withJSONObject: doc,
                                                options: [.prettyPrinted])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func harHeaders(_ raw: Any?) -> [[String: String]] {
        headerPairs(raw).map { ["name": $0.0, "value": $0.1] }
    }

    private static func queryString(_ url: String) -> [[String: String]] {
        guard let items = URLComponents(string: url)?.queryItems else { return [] }
        return items.map { ["name": $0.name, "value": $0.value ?? ""] }
    }

    // MARK: - Markdown

    private static func markdown(_ events: [[String: Any]], meta: [String: Any],
                                 stop: [String: Any], source: URL, fullBodies: Bool) -> String {
        var md = "# Network recording — \(meta["label"] ?? "session")\n\n"
        md += "| | |\n|---|---|\n"
        md += "| Session | `\(meta["session"] ?? "")` |\n"
        md += "| Started | \(meta["started_at"] ?? "") |\n"
        if let stopped = stop["stopped_at"] { md += "| Stopped | \(stopped) |\n" }
        md += "| Requests | \(events.count) |\n"
        md += "| Source | `\(source.lastPathComponent)` |\n\n"
        md += "> Unredacted. Headers, cookies and bodies are verbatim, so this file "
        md += "carries live credentials. Do not paste it anywhere public.\n\n"

        let failed = events.filter {
            $0["error"] != nil || (($0["status"] as? NSNumber)?.intValue ?? 0) >= 400
        }
        if !failed.isEmpty {
            md += "**\(failed.count) of \(events.count) failed.**\n\n"
        }

        md += "## Summary\n\n"
        md += "| # | Method | Status | ms | Size | URL |\n|---:|---|---:|---:|---:|---|\n"
        for (i, e) in events.enumerated() {
            let status = (e["status"] as? NSNumber)?.intValue
            let shown = e["error"] != nil ? "ERR" : (status.map(String.init) ?? "—")
            let ms = (e["ms"] as? NSNumber)?.doubleValue
            let bytes = (e["res_body_bytes"] as? NSNumber)?.intValue
            md += "| \(i + 1) "
            md += "| \((e["method"] as? String) ?? "") "
            md += "| \(shown) "
            md += "| \(ms.map { String(format: "%.0f", $0) } ?? "—") "
            md += "| \(bytes.map(byteSize) ?? "—") "
            md += "| `\(shortURL((e["url"] as? String) ?? ""))` |\n"
        }
        md += "\n## Requests\n\n"

        for (i, e) in events.enumerated() {
            let method = (e["method"] as? String) ?? ""
            let url = (e["url"] as? String) ?? ""
            let status = (e["status"] as? NSNumber)?.intValue
            let mark = e["error"] != nil ? "ERR" : (status.map(String.init) ?? "—")
            md += "### \(i + 1). `\(method)` \(shortURL(url)) — \(mark)\n\n"
            md += "`\(url)`\n\n"

            var facts: [String] = []
            if let ms = (e["ms"] as? NSNumber)?.doubleValue { facts.append(String(format: "%.0f ms", ms)) }
            if let v = e["http_version"] as? String { facts.append(v) }
            if let addr = e["remote_address"] as? String, !addr.isEmpty { facts.append(addr) }
            if let src = e["source"] as? String { facts.append("via \(src)") }
            if let type = e["resource_type"] as? String { facts.append(type) }
            if let cache = e["from_cache"] as? String { facts.append("from \(cache) cache") }
            if let ini = e["initiator"] as? [String: Any],
               let from = (ini["frame"] ?? ini["url"] ?? ini["type"]) as? String {
                facts.append("initiator: \(from)")
            }
            // The Dart package's tags: what the user was doing when this call
            // went out. No collector can infer it, so it leads the detail.
            if let ctx = e["context"] as? [String: Any], !ctx.isEmpty {
                facts.insert(ctx.keys.sorted().map { "\($0): \(ctx[$0] ?? "")" }
                    .joined(separator: ", "), at: 0)
            }
            if !facts.isEmpty { md += facts.joined(separator: " · ") + "\n\n" }
            if let error = e["error"] as? String { md += "**Error:** \(error)\n\n" }
            if let why = e["res_body_error"] as? String {
                md += "**Response body not captured:** \(why)\n\n"
            }

            md += headerBlock("Request headers", e["req_headers"])
            md += bodyBlock("Request body", e["req_body"], e, key: "req_body", full: fullBodies)
            md += headerBlock("Response headers", e["res_headers"])
            md += bodyBlock("Response body", e["res_body"], e, key: "res_body", full: fullBodies)

            if isHTTP(e) {
                md += "<details><summary>Replay</summary>\n\n```bash\n\(curl(e))\n```\n\n</details>\n\n"
            }
            md += "---\n\n"
        }
        return md
    }

    private static func headerBlock(_ title: String, _ raw: Any?) -> String {
        let pairs = headerPairs(raw)
        guard !pairs.isEmpty else { return "" }
        var s = "<details><summary>\(title) (\(pairs.count))</summary>\n\n```http\n"
        for (k, v) in pairs { s += "\(k): \(v)\n" }
        return s + "```\n\n</details>\n\n"
    }

    private static func bodyBlock(_ title: String, _ body: Any?,
                                  _ event: [String: Any], key: String, full: Bool) -> String {
        guard let body = body as? String, !body.isEmpty else { return "" }
        let isBase64 = (event["\(key)_base64"] as? NSNumber)?.boolValue == true
        let bytes = (event["\(key)_bytes"] as? NSNumber)?.intValue
        var note = bytes.map { " — \(byteSize($0))" } ?? ""
        if isBase64 { note += " — binary, base64" }
        if (event["\(key)_truncated"] as? NSNumber)?.boolValue == true {
            note += " — TRUNCATED by max-body"
        }

        // Markdown is the reading format; the JSON/HAR export keeps the whole
        // body. --full overrides when the body IS the thing being reviewed.
        let limit = 4000
        var shown = body
        if !full, body.count > limit {
            shown = String(body.prefix(limit))
            note += " — showing first \(limit) chars (export json for all)"
        }
        let fence = isBase64 ? "" : language(body)
        return "<details><summary>\(title)\(note)</summary>\n\n```\(fence)\n\(shown)\n```\n\n</details>\n\n"
    }

    // MARK: - curl

    /// Rebuilds the request as a runnable command. Host and content-length are
    /// dropped (curl sets them, and a stale content-length breaks the send);
    /// everything else — cookies, bearer tokens, custom headers — is kept,
    /// because the request will not reproduce without them.
    static func curl(_ e: [String: Any]) -> String {
        let method = ((e["method"] as? String) ?? "GET").uppercased()
        let url = (e["url"] as? String) ?? ""
        var parts = ["curl -i -X \(method) '\(shellQuote(url))'"]

        // Framing headers belong to curl, not to the recording: replaying a
        // captured `transfer-encoding: chunked` or a stale `content-length`
        // makes curl and the server disagree about where the body ends.
        let dropped: Set<String> = ["host", "content-length", "transfer-encoding", "connection"]
        let headers = headerPairs(e["req_headers"])
        // Chrome's raw headers carry the HTTP/2 pseudo-headers (:authority,
        // :method, :path, :scheme). They are framing, not headers — curl
        // rejects them — and the URL and -X already say the same thing.
        for (k, v) in headers where !dropped.contains(k.lowercased()) && !k.hasPrefix(":") {
            parts.append("-H '\(shellQuote("\(k): \(v)"))'")
        }
        // The recorded Accept-Encoding stays (fidelity), but a real site will
        // then answer gzip or br, and curl prints that as binary unless told to
        // decode it.
        if headers.contains(where: { $0.0.lowercased() == "accept-encoding" }) {
            parts.insert("--compressed", at: 1)
        }
        if let body = e["req_body"] as? String, !body.isEmpty {
            if (e["req_body_base64"] as? NSNumber)?.boolValue == true {
                parts.append("--data-binary @<(echo '\(shellQuote(body))' | base64 -d)")
            } else {
                parts.append("--data-raw '\(shellQuote(body))'")
            }
        }
        return parts.joined(separator: " \\\n  ")
    }

    /// POSIX single-quote escaping: end the quote, emit a literal quote, start
    /// again. The caller supplies the surrounding quotes.
    private static func shellQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    // MARK: - Shared helpers

    /// WebSocket frames and SSE messages are recorded too, but a `curl` line
    /// for one would be a lie.
    private static func isHTTP(_ e: [String: Any]) -> Bool {
        ((e["protocol"] as? String) ?? "http") == "http"
    }

    /// dart:io headers are `Map<String, List<String>>`; the JS path sends flat
    /// strings. Both flatten to ordered pairs, with a repeated header (like
    /// Set-Cookie) kept as several pairs rather than joined into one.
    static func headerPairs(_ raw: Any?) -> [(String, String)] {
        guard let dict = raw as? [String: Any] else { return [] }
        var pairs: [(String, String)] = []
        for key in dict.keys.sorted() {
            let value = dict[key]
            if let list = value as? [Any] {
                for item in list { pairs.append((key, "\(item)")) }
            } else if let s = value as? String {
                pairs.append((key, s))
            } else if let v = value {
                pairs.append((key, "\(v)"))
            }
        }
        return pairs
    }

    private static func headerValue(_ raw: Any?, _ name: String) -> String? {
        headerPairs(raw).first { $0.0.lowercased() == name }?.1
    }

    private static func language(_ body: String) -> String {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{") || t.hasPrefix("[") { return "json" }
        if t.hasPrefix("<") { return "xml" }
        return ""
    }

    private static func byteSize(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return String(format: "%.1f KB", Double(n) / 1024) }
        return String(format: "%.1f MB", Double(n) / 1_048_576)
    }

    /// Path + a hint of the query — the summary table has to stay readable
    /// when every row shares a 60-character base URL.
    private static func shortURL(_ url: String) -> String {
        guard let c = URLComponents(string: url) else { return url }
        var s = c.path.isEmpty ? "/" : c.path
        if let q = c.query, !q.isEmpty { s += "?" + (q.count > 40 ? String(q.prefix(40)) + "…" : q) }
        return s
    }
}
