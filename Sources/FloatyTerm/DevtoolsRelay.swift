import Foundation
import Network

/// A tiny loopback-only HTTP endpoint (127.0.0.1:7777) that gives agents
/// devtools awareness of pages running in EXTERNAL browsers — Chrome, an IDE
/// preview, Safari — not just FloatyTerm's own tabs.
///
/// The page includes one script tag (e.g. in a Flutter app's web/index.html
/// during development, or pasted into the browser console):
///
///     <script src="http://127.0.0.1:7777/floaty.js?mode=flutter&label=admin-app"></script>
///
/// The script wraps console/errors/fetch/XHR — the same capture FloatyTerm's
/// in-app browser tabs get — and batches events back here. They land in
/// `…/Application Support/FloatyTerm/Devtools/remote-<host>.log`, one stable
/// file per page origin, ready for an agent to `tail -f`. Loopback-only by
/// construction: page telemetry must never be reachable from the network.
///
/// Events are deduplicated and ranked by severity before writing, so the agent
/// sees signal instead of noise.
final class DevtoolsRelay {
    static let shared = DevtoolsRelay()
    static let port: UInt16 = 7777

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "floatyterm.devtools-relay")
    private let aggQueue = DispatchQueue(label: "floatyterm.aggregator")

    private var handles: [String: FileHandle] = [:]   // origin key → open log
    private var aggregators: [String: EventAggregator] = [:]  // origin key → deduplicator
    private var lastFileHandleCleanup: Date = Date()

    func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in
                guard let self else { conn.cancel(); return }
                conn.start(queue: self.queue)
                self.receive(conn, buffer: Data())
            }
            l.start(queue: queue)
            listener = l
        } catch {
            NSLog("DevtoolsRelay failed to start: \(error)")
        }
    }

    // MARK: - Minimal HTTP handling (one request per connection)

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, complete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil { conn.cancel(); return }
            if let response = self.handle(request: buf) {
                conn.send(content: response,
                          completion: .contentProcessed { _ in conn.cancel() })
            } else if complete || buf.count > 2 * 1024 * 1024 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    /// Full response once the request is completely buffered; nil = need more.
    private func handle(request buf: Data) -> Data? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buf[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.components(separatedBy: " ") ?? []
        guard parts.count >= 2 else { return response(400, "text/plain", "bad request") }
        let contentLength = lines.lazy
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count)
                .trimmingCharacters(in: .whitespaces)) } ?? 0
        let body = buf[headerEnd.upperBound...]
        if body.count < contentLength { return nil }

        // Route on the PATH only — the script tag carries ?mode=&label=
        // query params, and matching the full URL string would 404 exactly
        // the requests that matter.
        let path = parts[1].components(separatedBy: "?")[0]
        switch (parts[0], path) {
        case ("OPTIONS", _):
            return response(204, nil, "")
        case ("GET", "/floaty.js"):
            return response(200, "application/javascript", Self.remoteCaptureJS)
        case ("POST", "/log"):
            ingest(Data(body.prefix(contentLength)))
            return response(200, "text/plain", "ok")
        default:
            return response(404, "text/plain", "not found")
        }
    }

    private func response(_ status: Int, _ type: String?, _ body: String) -> Data {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request",
                      404: "Not Found"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: *\r\n"
        if let type { head += "Content-Type: \(type)\r\n" }
        let data = Data(body.utf8)
        head += "Content-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + data
    }

    // MARK: - Event ingestion → per-provenance NDJSON files with deduplication

    /// One JSON object per line — agents parse fields (`kind`, `status`,
    /// `ms`…) instead of regexing prose. Keys are whitelisted so a page
    /// can't smuggle arbitrary structure into the log.
    static let allowedEventKeys: Set<String> = [
        "kind", "level", "text", "message", "source", "line",
        "method", "url", "status", "ms", "error", "stack",
        "dedup_count", "first_seen",
        "constraints", "widget_chain", "user_frames", "hints",
        "viewport", "severity",
        // Rich network detail from the Dart-side Dio interceptor — the
        // request/response bodies, query and (redacted) headers the outside
        // XHR wrapper can't see. Bodies are strings (JSON-encoded), query and
        // headers one-level dicts; all run through the same caps below.
        "req_body", "res_body", "req_query", "req_headers", "res_headers"
    ]

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Subkeys allowed inside `triggered_by` — the user-action causal chain
    /// ("clicked Submit → POST → 500"). Never includes input VALUES.
    static let allowedActionKeys: Set<String> = ["type", "element", "id", "text", "ts"]

    /// Subkeys allowed inside `diagnosis` — the classifier's envelope.
    /// Generated server-side by FlutterDiagnosis, but encoded through the
    /// same whitelist gate as page data so a page sending its own
    /// "diagnosis" key can't smuggle structure past the sanitizer.
    static let allowedDiagnosisKeys: Set<String> = [
        "category", "what", "where", "evidence",
        "candidates", "candidates_complete", "protocol"
    ]

    /// Sanitizes a raw event dict into one NDJSON line with a server-side
    /// timestamp. Returns nil for events without a `kind` or unserializable.
    static func ndjsonLine(from raw: [String: Any]) -> String? {
        var event: [String: Any] = ["ts": isoFormatter.string(from: Date())]
        for (k, v) in raw where allowedEventKeys.contains(k) {
            if let s = v as? String { event[k] = String(s.prefix(16000)) }
            else if let n = v as? NSNumber { event[k] = n }
            else if let d = v as? Double { event[k] = d }
            else if let i = v as? Int { event[k] = i }
            // Arrays of strings (widget_chain, user_frames, hints):
            // each item capped, max 12 items, non-strings dropped.
            else if let arr = v as? [Any] {
                let items = arr.compactMap { $0 as? String }
                    .prefix(12).map { String($0.prefix(300)) }
                if !items.isEmpty { event[k] = Array(items) }
            }
            // One-level dicts of string/number values (viewport).
            else if let dict = v as? [String: Any] {
                var flat: [String: Any] = [:]
                for (dk, dv) in dict {
                    if let s = dv as? String { flat[dk] = String(s.prefix(300)) }
                    else if let n = dv as? NSNumber { flat[dk] = n }
                }
                if !flat.isEmpty { event[k] = flat }
            }
        }
        // The causal chain: which user action preceded this event. The page
        // attaches it per event within a 3s freshness window; here we
        // sanitize subkeys and drop anything implausibly old (batching adds
        // at most ~1s, so >10s means a stale or forged timestamp).
        if let action = raw["triggered_by"] as? [String: Any] {
            var t: [String: Any] = [:]
            for (k, v) in action where allowedActionKeys.contains(k) {
                if let s = v as? String { t[k] = String(s.prefix(120)) }
                else if let n = v as? NSNumber { t[k] = n }
            }
            let age = Date().timeIntervalSince1970 * 1000
                - ((t["ts"] as? NSNumber)?.doubleValue ?? 0)
            if !t.isEmpty, age >= 0, age < 10_000 {
                event["triggered_by"] = t
            }
        }
        // The diagnosis envelope: top-level strings (category/what/where/
        // protocol), a bool, a one-level `evidence` dict, and a `candidates`
        // array of one-level dicts (filled by the Dart-side collector;
        // banner-parsed events omit it).
        if let diag = raw["diagnosis"] as? [String: Any] {
            var d: [String: Any] = [:]
            for (k, v) in diag where allowedDiagnosisKeys.contains(k) {
                if let s = v as? String { d[k] = String(s.prefix(600)) }
                else if let arr = v as? [[String: Any]] {
                    let items: [[String: Any]] = arr.prefix(12).compactMap { c in
                        var flat: [String: Any] = [:]
                        for (ck, cv) in c {
                            if let s = cv as? String { flat[ck] = String(s.prefix(300)) }
                            else if let n = cv as? NSNumber { flat[ck] = n }
                        }
                        return flat.isEmpty ? nil : flat
                    }
                    if !items.isEmpty { d[k] = items }
                }
                else if let dict = v as? [String: Any] {
                    var flat: [String: Any] = [:]
                    for (dk, dv) in dict {
                        if let s = dv as? String { flat[dk] = String(s.prefix(300)) }
                        else if let n = dv as? NSNumber { flat[dk] = n }
                    }
                    if !flat.isEmpty { d[k] = flat }
                }
                else if let n = v as? NSNumber { d[k] = n }  // covers Bool
            }
            if d["category"] != nil { event["diagnosis"] = d }
        }
        guard event["kind"] != nil,
              let data = try? JSONSerialization.data(withJSONObject: event),
              let line = String(data: data, encoding: .utf8) else { return nil }
        return line
    }

    private func ingest(_ body: Data) {
        guard let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let host = payload["host"] as? String else { return }

        let mode = (payload["mode"] as? String) ?? "browser"
        let label = (payload["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // ONE canonical (sanitized) key for both the file handle and the
        // aggregator — a raw "localhost:5173" here vs the sanitized
        // "localhost_5173" in logHandle would orphan the aggregator and
        // silently drop every event.
        let key = Self.sanitize(label ?? host)

        aggQueue.async { [weak self] in
            guard let self else { return }
            // Created here (not in logHandle) so aggregator state is only
            // ever touched on aggQueue.
            var agg = self.aggregators[key] ?? EventAggregator()

            var out = ""

            // Page load marker (same for all modes). Carries the viewport
            // (w/h/dpr) so the agent can tell why a layout broke at that size.
            if let loaded = payload["loaded"] as? String {
                var marker: [String: Any] = ["kind": "loaded", "url": loaded]
                if let vp = payload["viewport"] as? [String: Any] {
                    marker["viewport"] = vp
                }
                if let line = Self.ndjsonLine(from: marker) {
                    out += line + "\n"
                }
            }

            // Route events through mode-specific parser
            let events = payload["events"] as? [[String: Any]] ?? []
            for e in events {
                // Let aggregator deduplicate + filter
                if let filtered = agg.ingest(e) {
                    // Format based on mode
                    let formatted: [String: Any]
                    switch mode {
                    case "flutter":
                        formatted = Self.formatFlutterEvent(filtered)
                    case "react-native":
                        formatted = Self.formatReactNativeEvent(filtered)
                    default:  // "browser"
                        formatted = filtered
                    }

                    if let line = Self.ndjsonLine(from: formatted) {
                        out += line + "\n"
                    }
                }
            }

            // Update aggregator state
            self.aggregators[key] = agg

            if !out.isEmpty, let data = out.data(using: .utf8) {
                self.queue.async {
                    // Resolve the handle AT WRITE TIME, on the relay queue.
                    // A handle captured back in ingest() can be closed before
                    // this block runs — closeIdleHandles() or the janitor's
                    // dropHandles() enqueue ahead of it — and a write to a
                    // closed FileHandle fails silently under `try?`, eating
                    // the events. logHandle reopens (and recreates) on demand.
                    try? self.logHandle(forKey: key)?.write(contentsOf: data)
                }
            }
        }

        // Periodically close idle handles
        if Date().timeIntervalSince(lastFileHandleCleanup) > 300 {
            closeIdleHandles()
            lastFileHandleCleanup = Date()
        }
    }

    /// One stable, appendable log per provenance key — survives reloads, so
    /// the agent tails a single path per dev server / label
    /// ("Devtools/remote/flutter-app.ndjson").
    private func logHandle(forKey rawKey: String) -> FileHandle? {
        let key = Self.sanitize(rawKey)
        if let h = handles[key] { return h }
        let url = Self.logDirectory(category: "remote").appendingPathComponent("\(key).ndjson")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? h.seekToEnd()
        handles[key] = h
        return h
    }

    /// Close idle file handles to avoid descriptor leak.
    private func closeIdleHandles() {
        dropHandles()
    }

    /// Closes and forgets every open log handle (on the relay's queue, where
    /// `handles` lives). StorageJanitor calls this after deleting Devtools
    /// files: an open handle would keep appending to the deleted inode —
    /// events vanishing silently into a file no path reaches. With the
    /// handles dropped, the next event re-opens (and recreates) its log.
    func dropHandles() {
        queue.async { [weak self] in
            self?.handles.forEach { _, h in
                try? h.close()
            }
            self?.handles.removeAll()
        }
    }

    /// Filesystem-safe provenance key ("localhost:5173" → "localhost_5173").
    static func sanitize(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
    }

    /// `…/FloatyTerm/Devtools/<category>/` — "remote" for external pages,
    /// "tabs" for FloatyTerm's own browser tabs. Created on demand.
    static func logDirectory(category: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("FloatyTerm/Devtools/\(category)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Every devtools log, newest first — drives the context menu's picker.
    static func allLogs() -> [(path: String, name: String, category: String, modified: Date)] {
        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("FloatyTerm/Devtools", isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return walker.compactMap { $0 as? URL }
            .filter { ["log", "ndjson"].contains($0.pathExtension) }
            .map { url in
                (path: url.path,
                 name: url.deletingPathExtension().lastPathComponent,
                 category: url.deletingLastPathComponent().lastPathComponent,
                 modified: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
    }

    /// The most recently written devtools log (any category) — what the
    /// terminal context menu's "Tail DevTools Log" stages for the agent.
    static func newestLogPath() -> String? {
        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("FloatyTerm/Devtools", isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        return walker.compactMap { $0 as? URL }
            .filter { ["log", "ndjson"].contains($0.pathExtension) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da < db
            }?
            .path
    }

    // MARK: - Event deduplication & ranking

    /// Detects duplicate events by hashing kind + message + source + line.
    /// Ranks by severity. Filters low-signal noise. Samples high-volume repeats.
    struct EventAggregator {
        private var seen: [String: EventRecord] = [:]
        private let window: TimeInterval = 300  // 5 minutes

        struct EventRecord {
            var first: Date
            var last: Date
            var count: Int
            var severity: Int
            var sample: [String: Any]
        }

        static func severity(_ event: [String: Any]) -> Int {
            let kind = event["kind"] as? String ?? ""
            switch kind {
            case "error", "unhandledrejection":
                return 1000
            case "network":
                let status = (event["status"] as? NSNumber)?.intValue ?? 200
                return status >= 500 ? 900 : (status >= 400 ? 500 : 0)
            case "console":
                let level = event["level"] as? String ?? ""
                switch level {
                case "error":
                    return 800
                case "warn":
                    return 200
                default:
                    return 0  // skip info/debug/log by default
                }
            default:
                return 10
            }
        }

        static func fingerprint(_ event: [String: Any]) -> String {
            let kind = event["kind"] as? String ?? "?"
            let msg = (event["message"] ?? event["text"] ?? "?") as? String ?? "?"
            let src = event["source"] as? String ?? ""
            let line = (event["line"] as? NSNumber)?.stringValue ?? ""
            return "\(kind):\(String(msg.prefix(100))):\(src):\(line)"
        }

        mutating func ingest(_ event: [String: Any]) -> [String: Any]? {
            let hash = Self.fingerprint(event)
            let now = Date()
            let sev = Self.severity(event)

            // Filter by severity (skip debug/info spam)
            if sev < 10 {
                return nil
            }

            if var rec = seen[hash] {
                // Seen before: increment count, update timestamp
                rec.last = now
                rec.count += 1
                seen[hash] = rec

                // Sample: log every Nth duplicate after the 3rd occurrence
                // This gives you visibility into repeating errors without log spam
                let shouldSample = rec.count == 3 || rec.count == 10 || rec.count % 50 == 0
                if shouldSample {
                    var out = event
                    out["dedup_count"] = rec.count
                    out["first_seen"] = rec.first.timeIntervalSince1970
                    out["severity"] = sev
                    return out
                }
                return nil  // drop duplicate
            } else {
                // First time seeing this error
                seen[hash] = EventRecord(
                    first: now, last: now, count: 1, severity: sev, sample: event
                )
                var out = event
                out["severity"] = sev
                return out
            }
        }

        mutating func expire() {
            let now = Date()
            let cutoff = now.addingTimeInterval(-window)
            seen = seen.filter { $0.value.last >= cutoff }
        }
    }

    // MARK: - Mode-specific formatters

    /// Flutter-specific event formatting. Extracts frame count from stack traces,
    /// enriches Dart-specific metadata.
    static func formatFlutterEvent(_ raw: [String: Any]) -> [String: Any] {
        var event = raw

        // Dart stack traces: count frames
        if let kind = event["kind"] as? String, kind == "error",
           let stack = event["stack"] as? String {
            let frameCount = stack.split(separator: "\n").count
            event["frame_count"] = frameCount
        }

        // Uniform diagnosis envelope (claim + evidence + audit protocol with
        // a stop condition) — replaces ad-hoc prose hints, which agents
        // satisfice on. The classifier table lives in FlutterDiagnosis.
        if let diagnosis = FlutterDiagnosis.classify(event) {
            var merged = diagnosis
            // A Dart-side hook (floaty_devtools.dart) can pre-attach the real
            // sibling-size table the banner can't see. Keep the server's
            // category/protocol (one source of truth), but let the client's
            // ground-truth candidates + completeness + extra evidence win.
            if let client = event["diagnosis"] as? [String: Any] {
                if let cand = client["candidates"] { merged["candidates"] = cand }
                if let cc = client["candidates_complete"] { merged["candidates_complete"] = cc }
                if let ce = client["evidence"] as? [String: Any] {
                    var ev = (merged["evidence"] as? [String: Any]) ?? [:]
                    for (k, v) in ce { ev[k] = v }
                    merged["evidence"] = ev
                }
            }
            event["diagnosis"] = merged
        }

        return event
    }

    /// React Native-specific event formatting. Extensible for RN-specific fields.
    static func formatReactNativeEvent(_ raw: [String: Any]) -> [String: Any] {
        let event = raw

        // React Native-specific enrichment could go here:
        // - Component name extraction
        // - Native module errors
        // - Redux action logging

        return event
    }

    // MARK: - The served script (remote twin of the in-tab capture)

    private static let remoteCaptureJS = #"""
    (function () {
        if (window.__floatyRemote) return; window.__floatyRemote = true;

        // Provenance label and mode from the script tag's URL:
        //   <script src="http://127.0.0.1:7777/floaty.js?mode=flutter&label=admin-app">
        var mode = 'browser';
        var label = '';
        try {
            var src = (document.currentScript && document.currentScript.src) || '';
            var modeMatch = src.match(/[?&]mode=([^&]+)/);
            if (modeMatch) mode = decodeURIComponent(modeMatch[1]);
            var labelMatch = src.match(/[?&]label=([^&]+)/);
            if (labelMatch) label = decodeURIComponent(labelMatch[1]);
        } catch (e) {}

        var queue = [];

        // ── User-action context (the causal chain) ──
        // Records the last interaction so each event can carry what the user
        // did right before it ("clicked Submit" → POST → 500). Capture phase
        // so stopPropagation can't hide actions. Input VALUES are never read.
        var lastAction = null;
        function recordAction(type, target) {
            try {
                var el = (target && target.closest)
                    ? (target.closest('button,a,[role="button"],input,select,textarea,form') || target)
                    : target;
                if (!el || !el.tagName) return;
                var text;
                if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
                    text = el.name || el.placeholder || el.type || '';
                } else {
                    text = (el.innerText || '').trim().slice(0, 40);
                }
                lastAction = { type: type, element: el.tagName,
                               id: el.id || '', text: text, ts: Date.now() };
            } catch (e) {}
        }
        document.addEventListener('click',   function (e) { recordAction('click', e.target);  }, true);
        document.addEventListener('input',   function (e) { recordAction('input', e.target);  }, true);
        document.addEventListener('submit',  function (e) { recordAction('submit', e.target); }, true);
        document.addEventListener('focusin', function (e) { recordAction('focus', e.target);  }, true);
        // Attached per event at post() time (NOT at batch-flush time, which
        // would mis-attribute) when the action is fresh enough to be causal.
        function withAction(p) {
            if (lastAction && Date.now() - lastAction.ts <= 3000) p.triggered_by = lastAction;
            return p;
        }
        function post(p) { queue.push(withAction(p)); if (queue.length > 200) queue.shift(); }
        function fmt(a) {
            if (typeof a === 'string') return a;
            try { return JSON.stringify(a); } catch (e) { return String(a); }
        }
        function flush(loaded) {
            if (!queue.length && !loaded) return;
            var payload = {
                host: location.host || 'file',
                mode: mode,
                label: label,
                events: queue.splice(0)
            };
            if (loaded) {
                payload.loaded = location.href;
                // Window size explains layout breakage at that size.
                try {
                    payload.viewport = { w: window.innerWidth,
                                         h: window.innerHeight,
                                         dpr: window.devicePixelRatio || 1 };
                } catch (e) {}
            }
            try {
                fetch('http://127.0.0.1:7777/log',
                      { method: 'POST', body: JSON.stringify(payload), keepalive: true })
                    .catch(function () {});
            } catch (e) {}
        }

        // ── Flutter exception banners ──
        // Flutter web prints framework errors ("EXCEPTION CAUGHT BY ...") as
        // dozens of console.log lines, which a severity filter rightly drops
        // as level-0 noise. Sift them: buffer the banner, emit ONE structured
        // kind:'error' event with the parsed message and offending widget.
        var fxBuf = '';
        function flutterSift(t) {
            if (!fxBuf) {
                var i = t.indexOf('\u2550\u2550\u2561 EXCEPTION CAUGHT BY');
                if (i === -1) {
                    var another = t.match(/^Another exception was thrown: (.+)$/m);
                    if (another) {
                        post({ kind: 'error', message: another[1].slice(0, 500) });
                        return true;
                    }
                    return false;
                }
                fxBuf = t.slice(i);
            } else {
                fxBuf += '\n' + t;
            }
            var done = /(^|\n)\u2550{40,}\s*$/.test(fxBuf) || fxBuf.length > 12000;
            if (!done) return true;
            var ctx = (fxBuf.match(/thrown ([^:\n]*):/) || [])[1] || '';
            var msg = (fxBuf.match(/thrown[^:\n]*:\s*\n(.+)/) || [])[1] || 'Flutter exception';
            var src = (fxBuf.match(/error-causing widget was:[\s\S]*?(file:\/\/\S+\.dart:\d+:\d+)/) || [])[1] || '';
            // The offending constraints, e.g.
            // "BoxConstraints(w=1317.0, h=-45.0; NOT NORMALIZED)".
            var constraints = (fxBuf.match(/BoxConstraints\([^)]*\)/) || [])[0] || '';
            // Parent chain from the RenderObject's
            // "creator: A ← B ← C ← ..." line, split on ← (U+2190).
            var widgetChain = [];
            var creator = (fxBuf.match(/creator: ([^\n]+)/) || [])[1] || '';
            if (creator) {
                widgetChain = creator.split('\u2190')
                    .map(function (s) { return s.trim(); })
                    .filter(function (s) { return s.length > 0; })
                    .slice(0, 12);
            }
            // Stack frames in the app's own dart files (not framework/SDK).
            var userFrames = [];
            var bufLines = fxBuf.split('\n');
            for (var li = 0; li < bufLines.length && userFrames.length < 5; li++) {
                var ln = bufLines[li];
                if (ln.indexOf('.dart') === -1) continue;
                if (ln.indexOf('package:flutter/') !== -1 ||
                    ln.indexOf('dart-sdk/') !== -1 ||
                    ln.indexOf('lib/_engine') !== -1) continue;
                var fm = ln.match(/([^\s(\/:]+\.dart)[: ](\d+)/);
                if (fm) {
                    var frame = fm[1] + ':' + fm[2];
                    if (userFrames.indexOf(frame) === -1) userFrames.push(frame);
                }
            }
            var ev = { kind: 'error',
                       message: (ctx ? ctx + ': ' : '') + msg.trim().slice(0, 500),
                       source: decodeURIComponent(src),
                       text: fxBuf.slice(0, 12000) };
            if (constraints) ev.constraints = constraints;
            if (widgetChain.length) ev.widget_chain = widgetChain;
            if (userFrames.length) ev.user_frames = userFrames;
            post(ev);
            fxBuf = '';
            return true;
        }
        ['log','info','warn','error','debug'].forEach(function (level) {
            var orig = console[level];
            console[level] = function () {
                var args = [].slice.call(arguments);
                var t = args.map(fmt).join(' ');
                if (!flutterSift(t)) {
                    post({ kind: 'console', level: level, text: t.slice(0, 2000) });
                }
                return orig.apply(this, args);
            };
        });

        window.addEventListener('error', function (e) {
            post({ kind: 'error', message: e.message || '?',
                   source: e.filename || '?', line: e.lineno || 0 });
        });

        window.addEventListener('unhandledrejection', function (e) {
            post({ kind: 'error',
                   message: 'Unhandled rejection: ' + fmt(e.reason).slice(0, 1000) });
        });

        var ofetch = window.fetch;
        window.fetch = function (input, init) {
            var url = (typeof input === 'string') ? input : ((input && input.url) || '');
            if (url.indexOf('127.0.0.1:7777') !== -1) return ofetch.apply(this, arguments);
            var method = ((init && init.method) || (input && input.method) || 'GET').toUpperCase();
            var t0 = Date.now();
            return ofetch.apply(this, arguments).then(function (r) {
                post({ kind: 'network', method: method, url: url,
                       status: r.status, ms: Date.now() - t0 });
                return r;
            }, function (err) {
                post({ kind: 'network', method: method, url: url,
                       error: String(err).slice(0, 300) });
                throw err;
            });
        };

        var oopen = XMLHttpRequest.prototype.open;
        var osend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function (m, u) {
            this.__floaty = { m: String(m).toUpperCase(), u: String(u) };
            return oopen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function () {
            var info = this.__floaty || { m: '?', u: '?' };
            var t0 = Date.now(), xhr = this;
            this.addEventListener('loadend', function () {
                post({ kind: 'network', method: info.m, url: info.u,
                       status: xhr.status, ms: Date.now() - t0 });
            });
            return osend.apply(this, arguments);
        };

        setInterval(flush, 700);
        flush(true);
        window.addEventListener('pagehide', function () { flush(); });
    })();
    """#
}
