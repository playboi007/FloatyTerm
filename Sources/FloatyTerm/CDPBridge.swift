import Foundation
import Network
import CryptoKit

/// The extension-side CDP transport.
///
/// The insight (from the "CDP from extensions" approach): a Chrome extension
/// holding the `debugger` permission gets **full Chrome DevTools Protocol on the
/// user's LIVE tabs** — their real, logged-in Chrome — with no
/// `--remote-debugging-port`, no quit-and-relaunch, and no lost session. The one
/// thing the extension can't be is a server, so its MV3 background service worker
/// opens a WebSocket *to us* (`ws://127.0.0.1:7777/cdp-bridge`) and becomes a
/// long-lived CDP executor: we send it `{id, method, params, match}` frames, it
/// resolves `match` → a tabId, `chrome.debugger.sendCommand`s, and replies
/// `{id, result}` — the exact JSON-RPC shape `AgentDOM` already speaks.
///
/// **One connection per Chrome profile.** Every profile that loads the
/// extension runs its own service worker, and each one dials in. This used to be
/// "latest connection wins", which is right for ONE worker reconnecting after a
/// restart and disastrous for two profiles: each new connection closed the
/// other, the loser redialled 2s later, and they took turns forever — every
/// request in flight at a swap died with "disconnected mid-request". Now each
/// worker identifies itself in its hello frame (`instance`, a per-profile id it
/// keeps in `chrome.storage.local`), a reconnect replaces only its OWN earlier
/// socket, and different profiles stay connected side by side. Commands are
/// routed to the profile that has the tab (see `route`). An older extension
/// build sends no instance id; those still replace each other, and if they
/// keep doing so the error says what is going on and how to fix it.
///
/// Loopback-only by construction (the relay binds 127.0.0.1). This grants any
/// local process that reaches the bridge full CDP over the user's authenticated
/// tabs, so an optional shared-token gate is supported (see `expectedToken`).
///
/// RFC6455 framing is implemented inline rather than via NWProtocolWebSocket
/// because the relay is a plain HTTP server and the WebSocket upgrade happens on
/// exactly one adopted connection per worker — a listener-wide WS option would
/// be heavier than framing the sockets we care about.
actor CDPBridge {
    static let shared = CDPBridge()

    /// One connected copy of the extension — one per Chrome profile.
    private final class Peer {
        static let legacy = "legacy"

        let conn: NWConnection
        /// Arrival order: the last tie-break when choosing between profiles.
        let serial: Int
        /// From the hello frame. `legacy` for an extension build without one;
        /// nil only until the hello arrives.
        var instance: String?
        var label: String?
        var lastUsed = Date.distantPast
        /// Per-connection frame reassembly — two profiles must never share a
        /// parser, or their byte streams interleave into garbage frames.
        var rxBuffer = Data()
        var fragOpcode: UInt8 = 0
        var fragPayload = Data()

        init(conn: NWConnection, serial: Int) { self.conn = conn; self.serial = serial }

        var name: String {
            if let label { return label }
            guard let instance else { return "profile-#\(serial)" }
            return instance == Self.legacy ? "profile (old extension build)" : "profile-\(instance.prefix(4))"
        }
    }
    private typealias PeerID = ObjectIdentifier

    private struct TabInfo: Sendable {
        let id: Int, title: String, url: String, active: Bool, focused: Bool
    }

    private var peers: [PeerID: Peer] = [:]
    private var nextSerial = 1
    private var nextID = 1
    private var pending: [Int: (peer: PeerID, cont: CheckedContinuation<(result: [String: Any], tabId: Int?), Error>)] = [:]
    /// Chrome tab ids are unique across every profile in one browser, so each
    /// id names exactly one owner. Learned from replies and tab listings; lets a
    /// pinned multi-call session (som, net stop) go straight to its profile.
    private var tabOwner: [Int: PeerID] = [:]
    /// When old-build copies replaced each other — the fingerprint of the
    /// multi-profile fight, used to explain it instead of just failing.
    private var legacySwaps: [Date] = []

    enum BridgeError: LocalizedError {
        case notConnected
        case disconnected
        case replaced(String)
        case remote(String)
        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "No CDP extension connected. Load the FloatyTerm CDP extension in Chrome (chrome://extensions → Load unpacked → extension/), then retry."
            case .disconnected: return "The CDP extension disconnected mid-request."
            case .replaced(let why): return "The CDP extension connection was replaced mid-request: \(why)"
            case .remote(let s): return "CDP extension error: \(s)"
            }
        }
    }

    /// Optional shared secret. When non-nil, a worker's hello frame must carry
    /// `"token":"<this>"` or its connection is dropped.
    private let expectedToken: String? = CDPBridge.loadToken()

    var isConnected: Bool { !peers.isEmpty }

    // MARK: - Public API (mirrors AgentDOM's CDP `call`)

    /// Send one CDP command through the extension and await its reply. `match` is
    /// a url/title substring selecting which of the user's tabs to drive (nil =
    /// the active tab of the focused window). `pinnedTab` forces a specific
    /// tabId (from a prior reply in the same session); the returned tabId is what
    /// the extension actually drove.
    func call(method: String, params: [String: Any], match: String?,
              pinnedTab: Int? = nil) async throws -> (result: [String: Any], tabId: Int?) {
        guard !peers.isEmpty else { throw BridgeError.notConnected }
        if method == "Floaty.listTabs", peers.count > 1 {
            return (await mergedTabs(), nil)
        }
        let target = try await route(match: match, pinnedTab: pinnedTab)
        var reply = try await send(to: target, method: method, params: params,
                                   match: match, pinnedTab: pinnedTab)
        if method == "Floaty.listTabs", let warning = fightWarning() { reply.result["warning"] = warning }
        return reply
    }

    private func send(to id: PeerID, method: String, params: [String: Any], match: String?,
                      pinnedTab: Int?) async throws -> (result: [String: Any], tabId: Int?) {
        guard let peer = peers[id] else { throw BridgeError.disconnected }
        let rid = nextID; nextID += 1
        var frame: [String: Any] = ["id": rid, "method": method, "params": params]
        if let match, !match.isEmpty { frame["match"] = match }
        if let pinnedTab { frame["tabId"] = pinnedTab }
        let data = (try? JSONSerialization.data(withJSONObject: frame)) ?? Data("{}".utf8)
        peer.lastUsed = Date()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                pending[rid] = (id, cont)
                sendFrame(to: peer, opcode: 0x1, payload: data)   // text frame
            }
        } onCancel: {
            // The caller (AgentDOM.withTimeout) bailed. The continuation MUST be
            // resumed, not just dropped: a leaked continuation would keep the
            // caller's task alive forever, and withTimeout's task group waits for
            // ALL children — so a silent drop turns "timed out" into "relay
            // handler hangs forever".
            Task { await self.cancelPending(rid) }
        }
    }

    private func cancelPending(_ id: Int) {
        pending.removeValue(forKey: id)?.cont.resume(throwing: CancellationError())
    }

    // MARK: - Routing between profiles

    /// Picks the profile a command goes to. One profile connected (the common
    /// case): no questions asked, no extra round trip. Several: a pinned tab goes
    /// to its owner; otherwise every profile lists its tabs and the one holding
    /// the target wins — preferring the focused window's active tab, then any
    /// active tab, then the profile used most recently, then the newest.
    private func route(match: String?, pinnedTab: Int?) async throws -> PeerID {
        if peers.count == 1, let only = peers.keys.first { return only }
        if let pinnedTab, let owner = tabOwner[pinnedTab], peers[owner] != nil { return owner }

        let listings = await listings()
        if let pinnedTab {
            if let hit = listings.first(where: { $0.tabs.contains { $0.id == pinnedTab } }) { return hit.peer }
            throw BridgeError.remote("tab \(pinnedTab) is not open in any connected Chrome profile")
        }

        var candidates = listings
        if let match, !match.isEmpty {
            let m = match.lowercased()
            candidates = listings.compactMap { l in
                let hits = l.tabs.filter { $0.url.lowercased().contains(m) || $0.title.lowercased().contains(m) }
                return hits.isEmpty ? nil : (l.peer, hits)
            }
            guard !candidates.isEmpty else {
                throw BridgeError.remote("no tab matches \"\(match)\" in any of the \(listings.count) connected Chrome profiles")
            }
        }
        func rank(_ c: (peer: PeerID, tabs: [TabInfo])) -> (Int, Date, Int) {
            let focus = c.tabs.contains { $0.active && $0.focused } ? 2 : (c.tabs.contains { $0.active } ? 1 : 0)
            let p = peers[c.peer]
            return (focus, p?.lastUsed ?? .distantPast, p?.serial ?? 0)
        }
        if let best = candidates.max(by: { rank($0) < rank($1) }), peers[best.peer] != nil {
            return best.peer
        }
        // Every listing failed (a profile mid-reconnect): newest connection.
        guard let newest = peers.max(by: { $0.value.serial < $1.value.serial })?.key else {
            throw BridgeError.notConnected
        }
        return newest
    }

    private enum Listing: Sendable { case tabs(PeerID, [TabInfo]), failed, deadline }

    /// Every profile's tabs, asked in parallel. A profile that does not answer
    /// within 3s is left out rather than stalling the command.
    private func listings() async -> [(peer: PeerID, tabs: [TabInfo])] {
        let ids = Array(peers.keys)
        let collected: [(PeerID, [TabInfo])] = await withTaskGroup(of: Listing.self) { group in
            for id in ids {
                group.addTask {
                    guard let r = try? await self.send(to: id, method: "Floaty.listTabs", params: [:],
                                                       match: nil, pinnedTab: nil) else { return .failed }
                    return .tabs(id, Self.parseTabs(r.result))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return .deadline
            }
            var out: [(PeerID, [TabInfo])] = []
            var answered = 0
            while answered < ids.count, let next = await group.next() {
                switch next {
                case .tabs(let id, let tabs): out.append((id, tabs)); answered += 1
                case .failed: answered += 1
                case .deadline: answered = ids.count
                }
            }
            group.cancelAll()
            return out
        }
        for (id, tabs) in collected { for t in tabs { tabOwner[t.id] = id } }
        return collected.map { (peer: $0.0, tabs: $0.1) }
    }

    /// `Floaty.listTabs` across every profile, each tab labelled with its profile.
    private func mergedTabs() async -> [String: Any] {
        let listings = await listings().sorted {
            (peers[$0.peer]?.serial ?? 0) < (peers[$1.peer]?.serial ?? 0)
        }
        var tabs: [[String: Any]] = []
        for l in listings {
            let name = peers[l.peer]?.name ?? "?"
            for t in l.tabs {
                tabs.append(["id": String(t.id), "title": t.title, "url": t.url, "profile": name])
            }
        }
        var out: [String: Any] = ["tabs": tabs, "profiles": listings.count]
        if let warning = fightWarning() { out["warning"] = warning }
        return out
    }

    private static func parseTabs(_ result: [String: Any]) -> [TabInfo] {
        ((result["tabs"] as? [[String: Any]]) ?? []).compactMap { t in
            let id: Int?
            if let s = t["id"] as? String { id = Int(s) } else { id = (t["id"] as? NSNumber)?.intValue }
            guard let id else { return nil }
            return TabInfo(id: id, title: t["title"] as? String ?? "", url: t["url"] as? String ?? "",
                           active: (t["active"] as? NSNumber)?.boolValue ?? false,
                           focused: (t["windowFocused"] as? NSNumber)?.boolValue ?? false)
        }
    }

    /// Old-build copies replacing each other 3+ times in 30s is not a flaky
    /// network — it is the extension loaded in several profiles, fighting.
    private func fightWarning() -> String? {
        let cutoff = Date().addingTimeInterval(-30)
        legacySwaps.removeAll { $0 < cutoff }
        guard legacySwaps.count >= 3 else { return nil }
        return "an older build of the FloatyTerm CDP extension is loaded in more than one Chrome profile, and the copies keep replacing each other (\(legacySwaps.count)× in 30s). Reload the extension in chrome://extensions in EVERY profile — the current build lets profiles share the bridge."
    }

    // MARK: - Connection adoption (called by DevtoolsRelay on the upgrade route)

    /// Adopt a raw connection that sent `GET /cdp-bridge` with the WebSocket
    /// upgrade headers. Completes the RFC6455 handshake and starts the frame-read
    /// loop. Which earlier connection (if any) it replaces is decided by its
    /// hello frame, not here. `leftover` is any bytes the relay already read past
    /// the request headers.
    nonisolated func adopt(_ connection: NWConnection, secWebSocketKey key: String, leftover: Data) {
        let accept = Self.acceptValue(for: key)
        var head = "HTTP/1.1 101 Switching Protocols\r\n"
        head += "Upgrade: websocket\r\n"
        head += "Connection: Upgrade\r\n"
        head += "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak connection] err in
            guard err == nil, let connection else { return }
            Task { await CDPBridge.shared.install(connection, leftover: leftover) }
        })
    }

    private func install(_ connection: NWConnection, leftover: Data) {
        let peer = Peer(conn: connection, serial: nextSerial)
        nextSerial += 1
        peers[PeerID(connection)] = peer
        if !leftover.isEmpty { feed(leftover, from: connection) }
        receiveLoop(connection)
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task {
                if let data, !data.isEmpty { await self.feed(data, from: connection) }
                if error != nil || isComplete {
                    await self.handleClose(connection)
                } else {
                    await self.receiveLoop(connection)
                }
            }
        }
    }

    private func feed(_ data: Data, from connection: NWConnection) {
        // Bytes from a dropped connection must never reach a parser.
        guard let peer = peers[PeerID(connection)] else { return }
        peer.rxBuffer.append(data)
        drainFrames(peer)
    }

    private func handleClose(_ connection: NWConnection) {
        drop(PeerID(connection), error: .disconnected)
        connection.cancel()
    }

    /// Removes one profile's connection and fails only ITS requests — the other
    /// profiles' commands carry on.
    private func drop(_ id: PeerID, error: BridgeError) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.conn.cancel()
        for (rid, entry) in pending where entry.peer == id {
            pending.removeValue(forKey: rid)
            entry.cont.resume(throwing: error)
        }
        tabOwner = tabOwner.filter { $0.value != id }
    }

    // MARK: - RFC6455 frame parsing (client → server frames are masked)

    /// Largest single message we'll accept (a full-page Retina screenshot is a
    /// few MB of base64; 64 MiB is generous). A declared length beyond this is a
    /// protocol violation (or an Int-overflow attempt) → drop the connection.
    private static let maxMessageBytes = 64 * 1024 * 1024
    private enum FrameError: Error { case oversize }

    private func drainFrames(_ peer: Peer) {
        let id = PeerID(peer.conn)
        while peers[id] != nil {
            let parsed: (opcode: UInt8, payload: Data, consumed: Int, isFinal: Bool)?
            do { parsed = try Self.parseFrame(peer.rxBuffer) } catch {
                drop(id, error: .disconnected)
                return
            }
            guard let (opcode, payload, consumed, isFinal) = parsed else { return }
            peer.rxBuffer.removeFirst(consumed)
            if peer.fragPayload.count + payload.count > Self.maxMessageBytes {
                drop(id, error: .disconnected)
                return
            }

            switch opcode {
            case 0x8:  // close
                drop(id, error: .disconnected)
                return
            case 0x9:  // ping → pong
                sendFrame(to: peer, opcode: 0xA, payload: payload)
            case 0xA:  // pong — ignore
                break
            case 0x0:  // continuation
                peer.fragPayload.append(payload)
                if isFinal {
                    deliver(peer, opcode: peer.fragOpcode, payload: peer.fragPayload)
                    peer.fragPayload = Data(); peer.fragOpcode = 0
                }
            case 0x1, 0x2:  // text / binary
                if isFinal {
                    deliver(peer, opcode: opcode, payload: payload)
                } else {
                    peer.fragOpcode = opcode; peer.fragPayload = payload
                }
            default:
                break
            }
        }
    }

    /// One complete application message from one profile's worker.
    private func deliver(_ peer: Peer, opcode: UInt8, payload: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }
        let id = PeerID(peer.conn)

        // Handshake frame: enforce the optional token, then decide what this
        // connection replaces.
        if obj["hello"] as? String == "floaty-cdp" {
            if let expected = expectedToken, (obj["token"] as? String) != expected {
                drop(id, error: .disconnected)
                return
            }
            let instance = (obj["instance"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Peer.legacy
            peer.instance = instance
            peer.label = (obj["profile"] as? String).flatMap { $0.isEmpty ? nil : $0 }

            // A reconnect of the SAME worker (it restarted) replaces its own
            // earlier socket, which may be half-dead. Other profiles are left
            // alone — that is the whole fix.
            let stale = peers.filter { $0.key != id && $0.value.instance == instance }.map(\.key)
            for old in stale {
                if instance == Peer.legacy {
                    legacySwaps.append(Date())
                    drop(old, error: fightWarning().map { .replaced($0) } ?? .disconnected)
                } else {
                    drop(old, error: .replaced("the same extension reconnected (its service worker restarted) — retry"))
                }
            }
            return
        }

        guard let rid = (obj["id"] as? NSNumber)?.intValue,
              let entry = pending.removeValue(forKey: rid) else { return }
        let tabId = (obj["tabId"] as? NSNumber)?.intValue
        if let tabId { tabOwner[tabId] = entry.peer }
        if let err = obj["error"] {
            let msg = (err as? String) ?? ((err as? [String: Any])?["message"] as? String) ?? "unknown"
            entry.cont.resume(throwing: BridgeError.remote(msg))
        } else {
            entry.cont.resume(returning: ((obj["result"] as? [String: Any]) ?? [:], tabId))
        }
    }

    /// Parse one frame from the front of `buf`. Returns nil if a full frame isn't
    /// buffered yet; throws on a declared length past the cap (protocol violation
    /// — and building an unchecked 64-bit length into Int would trap). Client
    /// frames are always masked (browser requirement); we unmask into the
    /// returned payload.
    private static func parseFrame(_ buf: Data) throws -> (opcode: UInt8, payload: Data, consumed: Int, isFinal: Bool)? {
        guard buf.count >= 2 else { return nil }
        let b = [UInt8](buf.prefix(14))   // header is at most 2 + 8 + 4 bytes
        let isFinal = (b[0] & 0x80) != 0
        let opcode = b[0] & 0x0F
        let masked = (b[1] & 0x80) != 0
        var len = Int(b[1] & 0x7F)
        var offset = 2
        if len == 126 {
            guard buf.count >= 4 else { return nil }
            len = (Int(b[2]) << 8) | Int(b[3]); offset = 4
        } else if len == 127 {
            guard buf.count >= 10 else { return nil }
            var wide: UInt64 = 0
            for i in 2..<10 { wide = (wide << 8) | UInt64(b[i]) }
            guard wide <= UInt64(maxMessageBytes) else { throw FrameError.oversize }
            len = Int(wide)
            offset = 10
        }
        guard len <= maxMessageBytes else { throw FrameError.oversize }
        var maskKey: [UInt8] = [0, 0, 0, 0]
        if masked {
            guard buf.count >= offset + 4 else { return nil }
            let mb = [UInt8](buf[buf.startIndex.advanced(by: offset)..<buf.startIndex.advanced(by: offset + 4)])
            maskKey = mb
            offset += 4
        }
        let total = offset + len
        guard buf.count >= total else { return nil }
        var payload = [UInt8](buf[buf.startIndex.advanced(by: offset)..<buf.startIndex.advanced(by: total)])
        if masked {
            for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] }
        }
        return (opcode, Data(payload), total, isFinal)
    }

    /// Send a server→client frame (unmasked, single frame — no fragmentation on
    /// our side; our command JSON is small).
    private func sendFrame(to peer: Peer, opcode: UInt8, payload: Data) {
        var frame = Data()
        frame.append(0x80 | opcode)   // FIN + opcode
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xFF))
            }
        }
        frame.append(payload)
        peer.conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    // MARK: - Handshake helpers

    /// Sec-WebSocket-Accept = base64(SHA1(key + RFC6455 magic GUID)).
    private static func acceptValue(for key: String) -> String {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + magic).utf8))
        return Data(digest).base64EncodedString()
    }

    /// Optional token: if `…/FloatyTerm/cdp-bridge-token.txt` exists, its trimmed
    /// contents are the required shared secret. Absent → open (matches the
    /// existing loopback trust model for `/agent/*`).
    private static func loadToken() -> String? {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloatyTerm/cdp-bridge-token.txt")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
