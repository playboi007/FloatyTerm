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
/// `{id, result}` — the exact JSON-RPC shape `AgentDOM` already speaks. So this
/// is a transport swap, not new protocol work.
///
/// Loopback-only by construction (the relay binds 127.0.0.1). This grants any
/// local process that reaches the bridge full CDP over the user's authenticated
/// tabs, so an optional shared-token gate is supported (see `expectedToken`).
///
/// RFC6455 framing is implemented inline rather than via NWProtocolWebSocket
/// because the relay is a plain HTTP server and the WebSocket upgrade happens on
/// exactly one adopted connection — mixing a listener-wide WS option in would be
/// heavier than framing the one socket we care about.
actor CDPBridge {
    static let shared = CDPBridge()

    /// The single live extension connection (latest wins — reconnect replaces).
    private var conn: NWConnection?
    private var nextID = 1
    /// Replies carry the tabId the extension resolved, so a multi-call session
    /// (som: collect → screenshot → cleanup) can pin every follow-up command to
    /// the SAME tab instead of re-resolving — no mid-session tab drift.
    private var pending: [Int: CheckedContinuation<(result: [String: Any], tabId: Int?), Error>] = [:]
    /// Incoming byte buffer for WebSocket frame reassembly.
    private var rxBuffer = Data()
    /// Continuation-fragment reassembly (opcode 0x0 continuation frames).
    private var fragOpcode: UInt8 = 0
    private var fragPayload = Data()

    enum BridgeError: LocalizedError {
        case notConnected
        case disconnected
        case remote(String)
        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "No CDP extension connected. Load the FloatyTerm CDP extension in Chrome (chrome://extensions → Load unpacked → extension/), then retry."
            case .disconnected: return "The CDP extension disconnected mid-request."
            case .remote(let s): return "CDP extension error: \(s)"
            }
        }
    }

    /// Optional shared secret. When non-nil, the extension's first frame must be
    /// `{"hello":"floaty-cdp","token":"<this>"}` or the connection is dropped.
    /// Read once at adopt-time from the token file (see `loadToken`).
    private let expectedToken: String? = CDPBridge.loadToken()

    var isConnected: Bool { conn != nil }

    // MARK: - Public API (mirrors AgentDOM's CDP `call`)

    /// Send one CDP command through the extension and await its reply. `match` is
    /// a url/title substring selecting which of the user's tabs to drive (nil =
    /// the active tab of the last-focused window, resolved extension-side).
    /// `pinnedTab` forces a specific tabId (from a prior reply in the same
    /// session); the returned tabId is what the extension actually drove.
    func call(method: String, params: [String: Any], match: String?,
              pinnedTab: Int? = nil) async throws -> (result: [String: Any], tabId: Int?) {
        guard conn != nil else { throw BridgeError.notConnected }
        let id = nextID; nextID += 1
        var frame: [String: Any] = ["id": id, "method": method, "params": params]
        if let match, !match.isEmpty { frame["match"] = match }
        if let pinnedTab { frame["tabId"] = pinnedTab }
        let data = (try? JSONSerialization.data(withJSONObject: frame)) ?? Data("{}".utf8)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                pending[id] = cont
                sendFrame(opcode: 0x1, payload: data)   // text frame
            }
        } onCancel: {
            // The caller (AgentDOM.withTimeout) bailed. The continuation MUST be
            // resumed, not just dropped: a leaked continuation would keep the
            // caller's task alive forever, and withTimeout's task group waits for
            // ALL children — so a silent drop turns "timed out" into "relay
            // handler hangs forever".
            Task { await self.cancelPending(id) }
        }
    }

    private func cancelPending(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    // MARK: - Connection adoption (called by DevtoolsRelay on the upgrade route)

    /// Adopt a raw connection that sent `GET /cdp-bridge` with the WebSocket
    /// upgrade headers. Completes the RFC6455 handshake, replaces any prior
    /// extension connection, and starts the frame-read loop. `leftover` is any
    /// bytes the relay already read past the request headers.
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
        // A fresh extension connection supersedes any previous one. The old
        // socket must be CANCELLED, not just forgotten: its receive loop would
        // otherwise keep feeding bytes into the shared rxBuffer, interleaving two
        // streams into one frame parser.
        if let old = conn {
            old.cancel()
            failAll(BridgeError.disconnected)
        }
        conn = connection
        rxBuffer = Data()
        fragOpcode = 0; fragPayload = Data()
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
        // Bytes from a superseded connection must never reach the shared buffer.
        guard conn === connection else { return }
        rxBuffer.append(data)
        drainFrames()
    }

    private func handleClose(_ connection: NWConnection) {
        // Only tear down if this is still the current connection (a reconnect may
        // have already replaced it).
        if conn === connection {
            conn = nil
            failAll(BridgeError.disconnected)
        }
        connection.cancel()
    }

    private func failAll(_ error: Error) {
        let conts = pending.values
        pending.removeAll()
        for c in conts { c.resume(throwing: error) }
    }

    // MARK: - RFC6455 frame parsing (client → server frames are masked)

    /// Largest single message we'll accept (a full-page Retina screenshot is a
    /// few MB of base64; 64 MiB is generous). A declared length beyond this is a
    /// protocol violation (or an Int-overflow attempt) → drop the connection.
    private static let maxMessageBytes = 64 * 1024 * 1024
    private enum FrameError: Error { case oversize }

    private func drainFrames() {
        while true {
            let parsed: (opcode: UInt8, payload: Data, consumed: Int, isFinal: Bool)?
            do { parsed = try Self.parseFrame(rxBuffer) } catch {
                if let c = conn { handleClose(c) }
                return
            }
            guard let (opcode, payload, consumed, isFinal) = parsed else { return }
            rxBuffer.removeFirst(consumed)
            if fragPayload.count + payload.count > Self.maxMessageBytes {
                if let c = conn { handleClose(c) }
                return
            }

            switch opcode {
            case 0x8:  // close
                if let c = conn { handleClose(c) }
                return
            case 0x9:  // ping → pong
                sendFrame(opcode: 0xA, payload: payload)
            case 0xA:  // pong — ignore
                break
            case 0x0:  // continuation
                fragPayload.append(payload)
                if isFinal { deliver(opcode: fragOpcode, payload: fragPayload); fragPayload = Data(); fragOpcode = 0 }
            case 0x1, 0x2:  // text / binary
                if isFinal {
                    deliver(opcode: opcode, payload: payload)
                } else {
                    fragOpcode = opcode; fragPayload = payload
                }
            default:
                break
            }
        }
    }

    /// One complete application message from the extension.
    private func deliver(opcode: UInt8, payload: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return }

        // Handshake frame: enforce the optional token before honoring anything.
        if obj["hello"] as? String == "floaty-cdp" {
            if let expected = expectedToken, (obj["token"] as? String) != expected {
                if let c = conn { c.cancel(); handleClose(c) }
            }
            return
        }

        guard let id = (obj["id"] as? NSNumber)?.intValue,
              let cont = pending.removeValue(forKey: id) else { return }
        if let err = obj["error"] {
            let msg = (err as? String) ?? ((err as? [String: Any])?["message"] as? String) ?? "unknown"
            cont.resume(throwing: BridgeError.remote(msg))
        } else {
            cont.resume(returning: ((obj["result"] as? [String: Any]) ?? [:],
                                    (obj["tabId"] as? NSNumber)?.intValue))
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
    private func sendFrame(opcode: UInt8, payload: Data) {
        guard let connection = conn else { return }
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
        connection.send(content: frame, completion: .contentProcessed { _ in })
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
