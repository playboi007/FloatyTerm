import Foundation

/// Full-fidelity network recording — the capture half of `floaty net`.
///
/// This is deliberately NOT the devtools diagnosis path. That path exists to
/// surface failures: `EventAggregator` scores a 2xx network event at severity
/// 0 and drops it, dedupes repeats, and `ndjsonLine` squeezes what survives
/// through a key whitelist with 16 KB string caps and one-level dicts. Every
/// one of those is correct for "tell me what broke" and fatal for "give me
/// every call the app made, complete enough to replay".
///
/// So a recording session writes its OWN file, with its own encoder:
///
///   - no severity filter, no dedupe, no sampling — every request, in order
///   - no key whitelist — unknown keys pass through, so a newer Dart SDK
///     returning a field this code has never heard of still lands on disk
///   - no redaction — headers, cookies, auth tokens and bodies are kept
///     verbatim, because a recording you cannot replay is a changelog
///   - the collector's raw payload is preserved under `vm` / `raw` beside the
///     normalized fields, so nothing is lost to a mapping bug
///
/// That last point is the honesty bit. Normalization is a best effort over a
/// protocol that changes between Dart SDKs; the verbatim subtree is the
/// receipt. If `NetworkExport` ever disagrees with reality, the raw subtree
/// is what settles it.
///
/// Consequence, stated plainly: the file holds live credentials. Sessions
/// create it 0600 under `Devtools/records/`, never in the tailed diagnosis
/// log, and `StorageJanitor` sweeps it like any other devtools artifact.
final class NetworkRecorder {

    static let shared = NetworkRecorder()

    /// One live recording. `seq` orders events within the session — wall-clock
    /// timestamps from two collectors (VM service polling, the Dart hook
    /// posting) interleave badly, and the export needs a stable order.
    struct Session {
        let id: String
        let label: String
        let file: URL
        let startedAt: Date
        /// Per-body byte cap. A body over this is truncated, and the line says
        /// so (`req_body_truncated`) — silent truncation would make a replay
        /// fail for no visible reason.
        let maxBody: Int
        var seq: Int = 0
        var events: Int = 0
        /// 4xx/5xx responses plus transport errors — the number the REC pill
        /// turns orange for.
        var failed: Int = 0
        var sources: Set<String> = []
    }

    /// A read-only view of one live session, for the on-screen controls.
    struct Live {
        let label: String
        let session: String
        let file: URL
        let startedAt: Date
        let events: Int
        let failed: Int
        let sources: [String]
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]   // sanitized label → session

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Session lifecycle

    /// Starts recording for `label`. Recording is opt-in and explicit: until
    /// a session exists, `record` is a no-op, so the credential-bearing file
    /// only appears when someone asked for it.
    func start(label: String, maxBody: Int = 5_000_000) -> [String: Any] {
        let key = DevtoolsRelay.sanitize(label)
        lock.lock()
        if let live = sessions[key] {
            lock.unlock()
            return ["error": "already recording", "label": label,
                    "session": live.id, "file": live.file.path,
                    "hint": "floaty net stop --label \(label) first"]
        }
        let started = Date()
        let stamp = Self.fileStamp(started)
        let id = "\(key)-\(stamp)"
        let file = Self.recordsDirectory().appendingPathComponent("\(id).ndjson")
        sessions[key] = Session(id: id, label: label, file: file,
                                startedAt: started, maxBody: max(0, maxBody))
        lock.unlock()

        // Create the file ahead of the first write so the 0600 mode is set
        // BEFORE any credential lands in it. DevtoolsLog would otherwise
        // create it on demand with the process umask.
        FileManager.default.createFile(atPath: file.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        // The header line documents the session inside the artifact itself —
        // an exported file that outlives this app still says what it is.
        append(["kind": "record_start", "session": id, "label": label,
                "started_at": Self.iso.string(from: started),
                "max_body": maxBody,
                "note": "full fidelity, unredacted — contains credentials"],
               to: file)

        return ["recording": true, "session": id, "label": label,
                "file": file.path, "max_body": maxBody]
    }

    /// Stops one session (or the only one, when `label` is nil) and returns
    /// the counts plus the file to export.
    func stop(label: String?) -> [String: Any] {
        lock.lock()
        let key: String?
        if let label, !label.isEmpty {
            key = DevtoolsRelay.sanitize(label)
        } else if sessions.count == 1 {
            key = sessions.keys.first
        } else {
            key = nil
        }
        guard let key, let session = sessions.removeValue(forKey: key) else {
            let open = sessions.values.map { $0.label }.sorted()
            lock.unlock()
            return open.isEmpty
                ? ["error": "no recording session"]
                : ["error": "ambiguous label — pass --label", "sessions": open]
        }
        lock.unlock()

        let stopped = Date()
        append(["kind": "record_stop", "session": session.id,
                "stopped_at": Self.iso.string(from: stopped),
                "events": session.events,
                "duration_ms": Int(stopped.timeIntervalSince(session.startedAt) * 1000)],
               to: session.file)

        return ["recording": false, "session": session.id, "label": session.label,
                "file": session.file.path, "events": session.events,
                "sources": session.sources.sorted(),
                "duration_ms": Int(stopped.timeIntervalSince(session.startedAt) * 1000)]
    }

    /// Stops a session and deletes its file — for a start that has to be
    /// rolled back (the collector failed to attach). The alternative is an
    /// empty recording sitting in `net status` forever, which reads as a
    /// successful capture of nothing.
    @discardableResult
    func discard(label: String) -> [String: Any] {
        let result = stop(label: label)
        if let path = result["file"] as? String {
            try? FileManager.default.removeItem(atPath: path)
        }
        return ["discarded": true, "label": label]
    }

    /// Live sessions, plus every finished recording on disk — so `floaty net
    /// status` answers both "am I recording?" and "what can I export?".
    func status() -> [String: Any] {
        lock.lock()
        let live: [[String: Any]] = sessions.values
            .sorted { $0.startedAt < $1.startedAt }
            .map { s in
                ["session": s.id, "label": s.label, "file": s.file.path,
                 "events": s.events, "failed": s.failed, "sources": s.sources.sorted(),
                 "started_at": Self.iso.string(from: s.startedAt)]
            }
        lock.unlock()
        return ["recording": !live.isEmpty, "sessions": live, "records": Self.records()]
    }

    /// Live sessions, oldest first.
    func live() -> [Live] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.sorted { $0.startedAt < $1.startedAt }.map {
            Live(label: $0.label, session: $0.id, file: $0.file, startedAt: $0.startedAt,
                 events: $0.events, failed: $0.failed, sources: $0.sources.sorted())
        }
    }

    /// Labels with a live session. `attach` uses this to bind a collector to
    /// the recording that is actually running, instead of writing into a label
    /// nobody is listening on.
    func liveLabels() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.sorted { $0.startedAt < $1.startedAt }.map { $0.label }
    }

    /// The file a session is writing to, if it is recording.
    func file(forLabel label: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return sessions[DevtoolsRelay.sanitize(label)]?.file
    }

    func isRecording(labelKey: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[labelKey] != nil
    }

    // MARK: - Capture

    /// Records one network event verbatim. `source` names the collector
    /// ("vm-service", "dart-hook", "js") so the export can say where a field
    /// came from — the VM profiler and the in-app interceptor see overlapping
    /// but different truths about the same request.
    ///
    /// Returns false when nothing is recording for that label, which is the
    /// normal case and not an error.
    @discardableResult
    func record(_ event: [String: Any], label: String, source: String) -> Bool {
        let key = DevtoolsRelay.sanitize(label)
        lock.lock()
        guard var session = sessions[key] else { lock.unlock(); return false }
        session.seq += 1
        session.events += 1
        session.sources.insert(source)
        if ((event["status"] as? NSNumber)?.intValue ?? 0) >= 400 || event["error"] != nil {
            session.failed += 1
        }
        sessions[key] = session
        let seq = session.seq
        let file = session.file
        let maxBody = session.maxBody
        lock.unlock()

        var line = capBodies(event, limit: maxBody)
        line["seq"] = seq
        line["source"] = source
        line["ts"] = Self.iso.string(from: Date())
        if line["kind"] == nil { line["kind"] = "network" }
        append(line, to: file)
        return true
    }

    // MARK: - Encoding

    /// Truncates only the two fields that can be arbitrarily large, and marks
    /// what it did. Everything else passes through untouched — capping headers
    /// or query strings would break exactly the replay this feature exists for.
    private func capBodies(_ event: [String: Any], limit: Int) -> [String: Any] {
        guard limit > 0 else { return event }
        var out = event
        for key in ["req_body", "res_body"] {
            guard let body = out[key] as? String, body.utf8.count > limit else { continue }
            out[key] = String(decoding: Array(body.utf8.prefix(limit)), as: UTF8.self)
            out["\(key)_truncated"] = true
            out["\(key)_full_bytes"] = body.utf8.count
        }
        return out
    }

    /// Serializes and appends one NDJSON line. Non-encodable values (a stray
    /// Date, a non-finite Double from a malformed profile entry) would make
    /// JSONSerialization throw and lose the whole event, so the fallback keeps
    /// the event with its unencodable parts described rather than dropping it.
    private func append(_ obj: [String: Any], to file: URL) {
        let payload: Data
        if JSONSerialization.isValidJSONObject(obj),
           let data = try? JSONSerialization.data(withJSONObject: obj) {
            payload = data
        } else {
            let salvaged = obj.mapValues { v -> Any in
                JSONSerialization.isValidJSONObject([v]) ? v : String(describing: v)
            }
            payload = (try? JSONSerialization.data(withJSONObject: salvaged))
                ?? Data(#"{"kind":"record_error","error":"unencodable event"}"#.utf8)
        }
        DevtoolsLog.shared.append(String(decoding: payload, as: UTF8.self) + "\n", to: file)
    }

    // MARK: - Files

    /// `…/FloatyTerm/Devtools/records/` — a sibling of `remote/` and `tabs/`,
    /// so StorageJanitor's existing Devtools sweep already covers it.
    static func recordsDirectory() -> URL {
        DevtoolsRelay.logDirectory(category: "records")
    }

    /// Finished recordings on disk, newest first.
    static func records() -> [[String: Any]] {
        let dir = recordsDirectory()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys)) ?? []
        return files
            .filter { $0.pathExtension == "ndjson" }
            .map { url -> (URL, Date, Int) in
                let v = try? url.resourceValues(forKeys: Set(keys))
                return (url, v?.contentModificationDate ?? .distantPast, v?.fileSize ?? 0)
            }
            .sorted { $0.1 > $1.1 }
            .map { ["session": $0.0.deletingPathExtension().lastPathComponent,
                    "file": $0.0.path,
                    "bytes": $0.2,
                    "modified": iso.string(from: $0.1)] }
    }

    /// Resolves an export target: an absolute path, a session id, or nil for
    /// "the newest recording". Returns nil when nothing matches.
    static func resolveRecord(_ hint: String?) -> URL? {
        if let hint, hint.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: hint) ? URL(fileURLWithPath: hint) : nil
        }
        let all = records()
        guard !all.isEmpty else { return nil }
        guard let hint, !hint.isEmpty else {
            return (all[0]["file"] as? String).map { URL(fileURLWithPath: $0) }
        }
        // Session id, or any unique prefix/substring of one (a label is a
        // substring of every session id it produced — newest wins).
        let match = all.first { ($0["session"] as? String)?.contains(hint) == true }
        return (match?["file"] as? String).map { URL(fileURLWithPath: $0) }
    }

    private static func fileStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }
}
