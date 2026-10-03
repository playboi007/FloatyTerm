import Foundation

/// The zero-code collector: attaches to a running Dart VM over the VM Service
/// and pulls every `dart:io` HTTP request out of it.
///
/// This is the same source Dart DevTools' Network tab reads, reached the same
/// way — a JSON-RPC WebSocket to the URI `flutter run` prints. It needs NO code
/// in the target app, which is the whole point: any debug or profile build of
/// any Dart project can be recorded, including one you did not prepare and
/// packages whose HTTP client you never see.
///
/// The protocol, in three calls:
///
///   ext.dart.io.httpEnableTimelineLogging  {isolateId, enabled:true}
///   ext.dart.io.getHttpProfile             {isolateId, updatedSince} → refs
///   ext.dart.io.getHttpProfileRequest      {isolateId, id}           → bodies
///
/// `getHttpProfile` returns entries that MUTATE — a request appears while
/// in-flight and is updated when the response completes — so the poll uses the
/// service's own `timestamp` as an `updatedSince` cursor and only emits an
/// entry once both `requestInProgress` and `responseInProgress` are false.
/// Emitting on first sight would record half of every call.
///
/// Field names here have drifted between Dart SDKs (`enable` → `enabled`,
/// bodies moving under `request`/`response`), so every read is tolerant and
/// the ENTIRE profile object is attached verbatim as `vm`. A normalization
/// this code gets wrong costs a pretty field, never the data.
///
/// What it cannot see, stated so nobody trusts it too far: Flutter **web**
/// (no `dart:io` — use the injected JS wrapper), traffic made by native
/// platform code behind a method channel, and anything a package sends over a
/// raw socket it opened itself. For those, the Dart package's interceptors
/// are the answer.
final class DartVMNetwork {

    static let shared = DartVMNetwork()

    private var client: VMClient?
    private var pollTask: Task<Void, Never>?
    private let lock = NSLock()
    private var attachedURI: String?
    private var label: String = ""
    /// Profile ids already written, so a mutating entry is emitted once.
    private var emitted: Set<String> = []
    private var enabledIsolates: Set<String> = []
    private var requestCount = 0

    var isAttached: Bool { lock.lock(); defer { lock.unlock() }; return client != nil }

    // MARK: - Attach / detach

    /// Connects, turns on HTTP timeline logging for every isolate, and starts
    /// the poll loop. Returns once the VM answered — so a bad URI or a release
    /// build fails HERE, with a reason, instead of silently recording nothing.
    func attach(uri rawURI: String, label: String, poll: Double) async -> [String: Any] {
        if isAttached { return ["error": "already attached", "uri": attachedURI ?? ""] }
        // Collecting into a label with no session means every request this
        // poll finds is counted and then dropped — a collector that reports
        // healthy numbers while the recording stays empty. Refuse instead.
        guard NetworkRecorder.shared.isRecording(labelKey: DevtoolsRelay.sanitize(label)) else {
            return ["error": "nothing is recording for label '\(label)'",
                    "hint": "run `floaty net start --label \(label)` first",
                    "recording": NetworkRecorder.shared.liveLabels()]
        }
        guard let url = Self.normalize(rawURI) else {
            return ["error": "not a VM service URI: \(rawURI)",
                    "hint": "paste the line flutter run prints: 'A Dart VM Service ... is available at: http://127.0.0.1:PORT/TOKEN=/'"]
        }

        let client = VMClient(url: url)
        do {
            client.connect()
            let vm = try await client.call("getVM", [:])
            let isolates = (vm["isolates"] as? [[String: Any]]) ?? []
            guard !isolates.isEmpty else {
                client.close()
                return ["error": "VM has no isolates", "uri": url.absoluteString]
            }
            var enabled: [String] = []
            for iso in isolates {
                guard let id = iso["id"] as? String else { continue }
                if await Self.enableLogging(client, isolateId: id) { enabled.append(id) }
            }
            guard !enabled.isEmpty else {
                client.close()
                return ["error": "ext.dart.io.httpEnableTimelineLogging unavailable",
                        "hint": "dart:io HTTP profiling exists only in DEBUG/PROFILE builds — a release build cannot be recorded this way"]
            }

            lock.withLock {
                self.client = client
                self.attachedURI = url.absoluteString
                self.label = label
                self.emitted = []
                self.enabledIsolates = Set(enabled)
                self.requestCount = 0
            }

            let interval = max(0.2, min(poll, 10))
            pollTask = Task { [weak self] in await self?.loop(every: interval) }

            return ["attached": true, "uri": url.absoluteString,
                    "isolates": enabled.count, "poll": interval,
                    "vm": ["version": vm["version"] as? String ?? "",
                           "name": vm["name"] as? String ?? ""]]
        } catch {
            client.close()
            return ["error": "cannot reach the VM service: \(error.localizedDescription)",
                    "uri": url.absoluteString,
                    "hint": "is the app still running? the token in the URI changes on every launch"]
        }
    }

    /// Stops polling and turns timeline logging back off. Best effort: a VM
    /// that already exited cannot answer, and that is not a failure to report.
    @discardableResult
    func detach() async -> [String: Any] {
        pollTask?.cancel()
        pollTask = nil
        let (client, isolates, count, uri) = lock.withLock {
            let taken = (self.client, enabledIsolates, requestCount, attachedURI)
            self.client = nil
            self.attachedURI = nil
            self.enabledIsolates = []
            return taken
        }

        guard let client else { return ["attached": false] }
        for id in isolates {
            _ = try? await client.call("ext.dart.io.httpEnableTimelineLogging",
                                       ["isolateId": id, "enabled": false])
        }
        client.close()
        return ["attached": false, "uri": uri ?? "", "requests": count]
    }

    func status() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        guard let uri = attachedURI else { return ["attached": false] }
        return ["attached": true, "uri": uri, "label": label, "requests": requestCount]
    }

    // MARK: - Poll loop

    /// Polls the profile, emits whatever completed since the last cursor, and
    /// re-scans isolates periodically so a hot restart (which replaces the
    /// isolate, and with it the logging flag) keeps recording.
    private func loop(every interval: TimeInterval) async {
        var cursor = 0            // micros; 0 = everything the VM still holds
        var sinceRescan = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { return }
            let (client, isolates) = lock.withLock { (self.client, enabledIsolates) }
            guard let client else { return }

            for isolateId in isolates {
                guard let profile = try? await client.call(
                    "ext.dart.io.getHttpProfile",
                    ["isolateId": isolateId, "updatedSince": cursor]) else { continue }
                if let ts = (profile["timestamp"] as? NSNumber)?.intValue { cursor = ts }
                let requests = (profile["requests"] as? [[String: Any]]) ?? []
                for ref in requests {
                    await emitIfComplete(ref, isolateId: isolateId, client: client)
                }
            }

            sinceRescan += 1
            if sinceRescan >= 10 {            // ~10 polls between rescans
                sinceRescan = 0
                await rescanIsolates(client)
            }
        }
    }

    /// A hot restart spawns a fresh isolate with logging off. Without this the
    /// recording just stops mid-session and nothing says why.
    private func rescanIsolates(_ client: VMClient) async {
        guard let vm = try? await client.call("getVM", [:]),
              let isolates = vm["isolates"] as? [[String: Any]] else { return }
        let live = Set(isolates.compactMap { $0["id"] as? String })
        let known = lock.withLock { enabledIsolates }
        for id in live.subtracting(known) where await Self.enableLogging(client, isolateId: id) {
            lock.withLock { _ = enabledIsolates.insert(id) }
        }
        lock.withLock { enabledIsolates.formIntersection(live) }
    }

    /// Emits one profile entry, once, when both halves have finished. Fetches
    /// the full record (bodies included) rather than trusting the ref — the
    /// ref is a summary and carries no body.
    private func emitIfComplete(_ ref: [String: Any], isolateId: String, client: VMClient) async {
        guard let id = ref["id"] as? String else { return }
        // The Dart package POSTs its own captures to the relay, and at the
        // dart:io level those POSTs are just more HTTP — so a recording with
        // both collectors running would fill up with itself, each entry
        // containing the entry it was reporting.
        if let uri = (ref["uri"] ?? ref["url"]) as? String, Self.isRelay(uri) {
            lock.withLock { _ = emitted.insert(id) }
            return
        }
        let requestDone = (ref["requestInProgress"] as? NSNumber)?.boolValue != true
        let responseDone = (ref["responseInProgress"] as? NSNumber)?.boolValue != true
        // A request that ERRORED has no response half and never clears
        // responseInProgress on some SDKs; an error field means it is over.
        let errored = ref["request"].flatMap { ($0 as? [String: Any])?["error"] } != nil
        guard (requestDone && responseDone) || errored else { return }

        // nil: another poll already emitted it.
        let claimed: String? = lock.withLock {
            if emitted.contains(id) { return nil }
            emitted.insert(id)
            requestCount += 1
            return self.label
        }
        guard let label = claimed else { return }

        let full = (try? await client.call("ext.dart.io.getHttpProfileRequest",
                                           ["isolateId": isolateId, "id": id])) ?? ref
        NetworkRecorder.shared.record(Self.event(from: full, ref: ref),
                                      label: label, source: "vm-service")
    }

    // MARK: - Mapping

    /// Normalizes one profile record into the recorder's event shape and keeps
    /// the original under `vm`. Every field is optional on purpose: the export
    /// renders what is there, and the verbatim subtree carries the rest.
    static func event(from full: [String: Any], ref: [String: Any]) -> [String: Any] {
        let request = (full["request"] as? [String: Any]) ?? [:]
        let response = (full["response"] as? [String: Any]) ?? [:]

        var e: [String: Any] = ["kind": "network", "protocol": "http"]
        e["req_id"] = full["id"] ?? ref["id"] ?? ""
        e["method"] = (full["method"] ?? ref["method"]) as? String ?? ""
        e["url"] = (full["uri"] ?? ref["uri"]) as? String ?? ""

        let start = num(full["startTime"] ?? ref["startTime"])
        let end = num(full["endTime"] ?? ref["endTime"])
        if let start { e["started_us"] = start }
        if let start, let end, end >= start { e["ms"] = Double(end - start) / 1000.0 }

        if let status = num(response["statusCode"]) { e["status"] = status }
        if let reason = response["reasonPhrase"] as? String { e["status_text"] = reason }
        if let v = (response["httpVersion"] ?? request["httpVersion"]) as? String { e["http_version"] = v }
        if let compressed = response["isRedirect"] { e["is_redirect"] = compressed }
        if let redirects = response["redirects"] as? [[String: Any]], !redirects.isEmpty {
            e["redirects"] = redirects
        }
        if let addr = (response["connectionInfo"] as? [String: Any]) {
            e["remote_address"] = addr["remoteAddress"] ?? ""
            if let port = num(addr["remotePort"]) { e["remote_port"] = port }
        }
        if let cookies = response["cookies"] { e["res_cookies"] = cookies }
        if let err = request["error"] ?? response["error"] ?? full["error"] {
            e["error"] = "\(err)"
        }

        // Headers, verbatim. dart:io gives Map<String, List<String>>; the
        // export needs every value of a repeated header (Set-Cookie), so the
        // lists are kept as lists rather than joined.
        if let h = request["headers"] as? [String: Any] { e["req_headers"] = h }
        if let h = response["headers"] as? [String: Any] { e["res_headers"] = h }
        if let ct = request["contentLength"], num(ct) != nil { e["req_content_length"] = ct }
        if let ct = response["contentLength"], num(ct) != nil { e["res_content_length"] = ct }

        if let body = decodeBody(full["requestBody"] ?? request["body"]) {
            e["req_body"] = body.text
            if body.base64 { e["req_body_base64"] = true }
            e["req_body_bytes"] = body.bytes
        }
        if let body = decodeBody(full["responseBody"] ?? response["body"]) {
            e["res_body"] = body.text
            if body.base64 { e["res_body_base64"] = true }
            e["res_body_bytes"] = body.bytes
        }

        // The receipt: everything the VM said, unmapped and unfiltered.
        e["vm"] = full
        return e
    }

    /// dart:io hands bodies over as a JSON array of byte values. Valid UTF-8
    /// is stored as text (readable, and replayable as-is); anything else is
    /// base64 with a flag, because a lossy String(decoding:) would quietly
    /// corrupt an image or a protobuf and still look fine in the export.
    private static func decodeBody(_ raw: Any?) -> (text: String, bytes: Int, base64: Bool)? {
        var data: Data?
        if let bytes = raw as? [Any] {
            let octets = bytes.compactMap { ($0 as? NSNumber)?.uint8Value }
            guard octets.count == bytes.count else { return nil }
            data = Data(octets)
        } else if let s = raw as? String {
            return s.isEmpty ? nil : (s, s.utf8.count, false)
        }
        guard let data, !data.isEmpty else { return nil }
        if let text = String(data: data, encoding: .utf8) {
            return (text, data.count, false)
        }
        return (data.base64EncodedString(), data.count, true)
    }

    private static func num(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    /// True for FloatyTerm's own loopback relay.
    static func isRelay(_ uri: String) -> Bool {
        guard let c = URLComponents(string: uri) else { return false }
        return (c.host == "127.0.0.1" || c.host == "localhost") && c.port == 7777
    }

    /// Turns logging on, tolerating the SDK-dependent parameter name. Older
    /// Dart took `enable`, newer takes `enabled`; sending the wrong one is an
    /// RPC error, not a silent no-op, so trying both is safe.
    private static func enableLogging(_ client: VMClient, isolateId: String) async -> Bool {
        for key in ["enabled", "enable"] {
            if (try? await client.call("ext.dart.io.httpEnableTimelineLogging",
                                       ["isolateId": isolateId, key: true])) != nil {
                return true
            }
        }
        return false
    }

    /// Accepts whatever the user pastes: the `http://127.0.0.1:PORT/TOKEN=/`
    /// line from `flutter run`, the same with `/ws`, or a bare `ws://` URI.
    static func normalize(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // People paste the whole line ("The Dart VM service is listening on
        // http://…"), because that is what the tooling prints and what the
        // error message invites. Pull the URI out of whatever arrives rather
        // than rejecting a string that plainly contains the answer.
        if s.contains(" ") {
            let pattern = #"(?:wss?|https?)://[^\s]+"#
            if let range = s.range(of: pattern, options: .regularExpression) {
                s = String(s[range])
            }
        }
        if s.hasPrefix("http://")  { s = "ws://"  + s.dropFirst("http://".count) }
        if s.hasPrefix("https://") { s = "wss://" + s.dropFirst("https://".count) }
        guard s.hasPrefix("ws://") || s.hasPrefix("wss://") else { return nil }
        if !s.hasSuffix("/ws") { s = s.hasSuffix("/") ? s + "ws" : s + "/ws" }
        return URL(string: s)
    }
}

// MARK: - Minimal JSON-RPC 2.0 client over a WebSocket

/// Just enough of the VM Service transport for this collector: request/reply
/// by id, with events ignored. Kept private to this file — CDPBridge speaks a
/// different dialect over a connection it does not own, and sharing one client
/// between them would couple two protocols that only look alike.
// Unchecked: the mutable state (pending, nextId, closed) is read and written
// only under `lock`, and `task` is set once in connect() before any call.
private final class VMClient: @unchecked Sendable {

    private let url: URL
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?
    private let lock = NSLock()
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var closed = false

    init(url: URL) { self.url = url }

    func connect() {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive()
    }

    func close() {
        lock.lock()
        closed = true
        let waiting = pending
        pending = [:]
        lock.unlock()
        waiting.values.forEach { $0.resume(throwing: VMError.closed) }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    enum VMError: LocalizedError {
        case closed, timeout, rpc(String)
        var errorDescription: String? {
            switch self {
            case .closed:      return "connection closed"
            case .timeout:     return "no reply within 20s"
            case .rpc(let m):  return m
            }
        }
    }

    /// One RPC. Times out so a VM that accepted the socket and then stopped
    /// answering (a paused isolate, a suspended app) cannot wedge the poll
    /// loop forever.
    func call(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id: Int? = lock.withLock {
            if closed { return nil }
            nextId += 1
            return nextId
        }
        guard let id else { throw VMError.closed }

        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty { message["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: message)

        return try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    self.pending[id] = cont
                    self.lock.unlock()
                    self.task?.send(.string(String(decoding: data, as: UTF8.self))) { error in
                        guard let error else { return }
                        self.fail(id, error)
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                throw VMError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw VMError.closed }
            return first
        }
    }

    private func fail(_ id: Int, _ error: Error) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(throwing: error)
    }

    /// The read pump. Re-arms after every frame; a receive error fails every
    /// in-flight call so nothing waits on a dead socket.
    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.lock.lock()
                let waiting = self.pending
                self.pending = [:]
                self.closed = true
                self.lock.unlock()
                waiting.values.forEach { $0.resume(throwing: error) }
            case .success(let message):
                let text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d):   text = String(data: d, encoding: .utf8)
                @unknown default:    text = nil
                }
                if let text { self.dispatch(text) }
                self.receive()
            }
        }
    }

    private func dispatch(_ text: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let id = (obj["id"] as? NSNumber)?.intValue else { return }   // stream event
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        guard let cont else { return }
        if let error = obj["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "RPC error"
            let detail = ((error["data"] as? [String: Any])?["details"] as? String).map { ": \($0)" } ?? ""
            cont.resume(throwing: VMError.rpc(message + detail))
        } else {
            cont.resume(returning: (obj["result"] as? [String: Any]) ?? [:])
        }
    }
}
