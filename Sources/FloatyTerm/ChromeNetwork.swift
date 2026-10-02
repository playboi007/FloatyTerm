import Foundation

/// The Chrome collector: records a tab in the user's LIVE Chrome — their real
/// profile, logged in — through the FloatyTerm CDP extension. No debug port,
/// no relaunch, session intact.
///
/// The work happens in the extension, not here. One request is five-plus
/// Network events arriving out of order, and its body is only fetchable while
/// Chrome still holds it, so `extension/netrecord.js` assembles complete
/// records next to the one API that can fetch bodies in time, and POSTs them to
/// the relay's `/net` ingress like every other collector. This class only
/// starts and stops that, over the bridge's synthetic `Floaty.net*` methods.
///
/// Stop is the part that has to be right: the extension replies to
/// `Floaty.netStop` only AFTER its final batch has landed, so the caller can
/// close the recording file without cutting off the last requests.
final class ChromeNetwork {

    static let shared = ChromeNetwork()

    /// Where the extension posts. Fixed: the relay binds only this address.
    static let relayIngress = "http://127.0.0.1:7777/net"

    private struct Tab { let tabId: Int; let label: String; let url: String; let title: String }

    private let lock = NSLock()
    private var tabs: [String: Tab] = [:]   // sanitized label → the tab recording into it

    // MARK: - Start / stop

    /// Starts recording one tab into `label`'s live session. `match` picks the
    /// tab by url/title substring; nil means the active tab.
    func start(label: String, match: String?, maxBody: Int) async -> [String: Any] {
        let key = DevtoolsRelay.sanitize(label)
        guard NetworkRecorder.shared.isRecording(labelKey: key) else {
            return ["error": "nothing is recording for label '\(label)'",
                    "hint": "run `floaty net start --label \(label)` first"]
        }
        let existing = lock.withLock { tabs[key] }
        if let existing {
            return ["error": "Chrome is already recording for '\(label)'",
                    "tabId": existing.tabId, "url": existing.url]
        }

        do {
            let (result, tabId) = try await Self.bridge(
                "Floaty.netStart",
                ["label": label, "relay": Self.relayIngress, "maxBody": maxBody],
                match: match, pinned: nil, timeout: 15)
            guard let tabId else { return ["error": "the extension did not report which tab it attached"] }
            let tab = Tab(tabId: tabId, label: label,
                          url: result["url"] as? String ?? "",
                          title: result["title"] as? String ?? "")
            lock.withLock { tabs[key] = tab }
            return ["attached": true, "tabId": tabId, "url": tab.url, "title": tab.title,
                    "note": "Chrome shows an \"is debugging this browser\" banner while recording. Dismissing it ends the recording."]
        } catch {
            return Self.failure(error)
        }
    }

    /// Stops the tab recording into `label`, after the extension has flushed
    /// everything. Returns nil when Chrome was never part of this session.
    func stop(label: String) async -> [String: Any]? {
        let key = DevtoolsRelay.sanitize(label)
        let tab = lock.withLock { tabs.removeValue(forKey: key) }
        guard let tab else { return nil }

        do {
            // Generous timeout: the reply waits for every body fetch and the
            // final POST, which on a heavy page is seconds, not milliseconds.
            var (result, _) = try await Self.bridge("Floaty.netStop", [:], match: nil,
                                                    pinned: tab.tabId, timeout: 60)
            result["tabId"] = tab.tabId
            result["url"] = tab.url
            return result
        } catch {
            var failed = Self.failure(error)
            failed["tabId"] = tab.tabId
            failed["note"] = "batches already sent are in the recording; the final batch may be missing"
            return failed
        }
    }

    func status() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return tabs.values.map { ["label": $0.label, "tabId": $0.tabId, "url": $0.url, "title": $0.title] }
    }

    // MARK: - Bridge

    private struct Timeout: LocalizedError {
        let seconds: Double
        var errorDescription: String? { "the CDP extension did not answer within \(Int(seconds))s" }
    }

    /// One bridge call with a deadline. `CDPBridge.call` waits forever on its
    /// own, and a relay handler that waits forever wedges `floaty net stop`.
    private static func bridge(_ method: String, _ params: [String: Any], match: String?,
                               pinned: Int?, timeout: Double) async throws -> ([String: Any], Int?) {
        try await withThrowingTaskGroup(of: ([String: Any], Int?).self) { group in
            group.addTask {
                let r = try await CDPBridge.shared.call(method: method, params: params,
                                                        match: match, pinnedTab: pinned)
                return (r.result, r.tabId)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw Timeout(seconds: timeout)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw Timeout(seconds: timeout) }
            return first
        }
    }

    /// Turns a bridge error into an answer with a next step. The first one a
    /// user meets is an extension loaded before this feature existed: it
    /// forwards `Floaty.netStart` to Chrome as if it were a CDP method, and
    /// Chrome says the method "wasn't found".
    private static func failure(_ error: Error) -> [String: Any] {
        let message = error.localizedDescription
        var out: [String: Any] = ["error": message]
        if message.contains("wasn't found") || message.contains("Floaty.net") {
            out["hint"] = "the loaded extension predates network recording — open chrome://extensions and click reload on \"FloatyTerm CDP Bridge\""
        } else if message.contains("No CDP extension connected") {
            out["hint"] = "load extension/ in Chrome (chrome://extensions → Developer mode → Load unpacked); it reconnects within 30s of a FloatyTerm relaunch"
        } else if message.contains("no tab matches") {
            out["hint"] = "list tabs with `floaty tabs --via-extension`; --chrome takes a url or title substring"
        }
        return out
    }
}
