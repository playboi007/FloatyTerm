import AppKit

/// Perception economics, layer 2 — "what changed?" primitives.
///
/// A hybrid perception loop (AX tree + Set-of-Mark screenshots) resends the
/// whole world to the model on every step; after a click the actual delta is
/// usually "12 nodes appeared (a menu opened)". These two stores let the
/// perception verbs answer with the delta instead:
///
///   • Element snapshots — `query-ax --diff` / `som --diff` compare the
///     current element set against the last one seen for the same target and
///     return only added/removed rows (tens of tokens, not thousands).
///   • Screen hashes — `capture --if-changed` / `--wait-change` fingerprint a
///     window (or a --region slice) with a tiny perceptual hash, so "nothing
///     changed" costs one line and no image, and "wait until it changes" is a
///     single long-poll instead of an agent-side screenshot loop.
///
/// Both stores are runtime-only rings, like the capture/mark frames. Guarded
/// by a lock (not actor isolation) so the relay's handler closures — which are
/// not statically main-actor-isolated — can call in synchronously.
enum AgentPerception {

    private static let lock = NSLock()

    // MARK: - Element snapshots (query-ax --diff / som --diff)

    struct Element {
        let role: String
        let name: String
        let rect: CGRect

        /// Diff identity: role|name|rect quantized to 4pt, so subpixel jitter
        /// and rounding don't read as change. An element that MOVED shows up
        /// as removed+added (by design — its click point changed).
        var hash: String {
            let q: (CGFloat) -> Int = { Int(($0 / 4).rounded()) }
            return "\(role)|\(name)|\(q(rect.origin.x)),\(q(rect.origin.y)),\(q(rect.width)),\(q(rect.height))"
        }
    }

    struct Diff {
        let added: [Element]
        let removed: [Element]
        let unchangedCount: Int
        /// false = no prior snapshot under this key — the caller should return
        /// the full table (this call stored the baseline for next time).
        let hadBaseline: Bool
    }

    private static var snapshots: [String: [String: Element]] = [:]   // key → hash → element
    private static var snapshotOrder: [String] = []                   // LRU, bounded

    /// Store `current` as the latest snapshot for `key`. EVERY perception call
    /// does this (diff requested or not), so a later `--diff` always compares
    /// against the most recent observation of that target.
    static func store(key: String, current: [Element]) {
        lock.lock(); defer { lock.unlock() }
        storeLocked(key: key, current: current)
    }

    private static func storeLocked(key: String, current: [Element]) {
        snapshots[key] = Dictionary(current.map { ($0.hash, $0) }, uniquingKeysWith: { a, _ in a })
        snapshotOrder.removeAll { $0 == key }
        snapshotOrder.append(key)
        while snapshotOrder.count > 24 {
            snapshots.removeValue(forKey: snapshotOrder.removeFirst())
        }
    }

    /// Diff `current` against the last snapshot under `key`, then make
    /// `current` the new baseline.
    static func diffAndStore(key: String, current: [Element]) -> Diff {
        lock.lock(); defer { lock.unlock() }
        let prev = snapshots[key]
        storeLocked(key: key, current: current)
        guard let prev else {
            return Diff(added: current, removed: [], unchangedCount: 0, hadBaseline: false)
        }
        var added: [Element] = []
        var unchanged = 0
        var remaining = prev
        for el in current {
            if remaining.removeValue(forKey: el.hash) != nil { unchanged += 1 }
            else { added.append(el) }
        }
        return Diff(added: added, removed: Array(remaining.values),
                    unchangedCount: unchanged, hadBaseline: true)
    }

    // MARK: - Screen hashes (capture --if-changed / --wait-change)

    /// 64-bit average hash (aHash): downscale to 8×8 grayscale, threshold each
    /// cell against the mean. Any visible UI change flips several bits; noise
    /// (antialiasing, a blinking caret) flips at most a couple — see
    /// `isUnchanged`. Returned as 16 hex chars.
    static func screenHash(_ image: CGImage) -> String {
        let n = 8
        var pixels = [UInt8](repeating: 0, count: n * n)
        guard let ctx = CGContext(
            data: &pixels, width: n, height: n, bitsPerComponent: 8,
            bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return "" }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
        let mean = pixels.reduce(0) { $0 + Int($1) } / (n * n)
        var bits: UInt64 = 0
        for (i, p) in pixels.enumerated() where Int(p) > mean {
            bits |= (1 << UInt64(i))
        }
        return String(format: "%016llx", bits)
    }

    static func hamming(_ a: String, _ b: String) -> Int {
        guard let x = UInt64(a, radix: 16), let y = UInt64(b, radix: 16) else { return 64 }
        return (x ^ y).nonzeroBitCount
    }

    /// "Same screen": ≤3 of 64 bits differ. Tolerates a caret, a clock tick,
    /// subtle antialiasing; a dialog, menu, or content change flips far more.
    ///
    /// Pass `tolerance: 0` when hashing an explicit --watch/--region rect: the
    /// 8×8 grid then covers just that rect, so every bit is signal — a game
    /// sprite or a small meter moves 1–2 bits, which the whole-window
    /// tolerance would swallow (seen live: Jump King gameplay stayed within
    /// 3 bits of the full-window hash).
    static func isUnchanged(_ a: String, _ b: String, tolerance: Int = 3) -> Bool {
        !a.isEmpty && !b.isEmpty && hamming(a, b) <= tolerance
    }

    private static var lastHashes: [String: String] = [:]    // capture key → hash
    private static var hashOrder: [String] = []

    /// Remember `hash` as the latest for this capture target; returns the
    /// previous value (nil on first sight).
    @discardableResult
    static func rememberHash(key: String, hash: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        let prev = lastHashes[key]
        lastHashes[key] = hash
        hashOrder.removeAll { $0 == key }
        hashOrder.append(key)
        while hashOrder.count > 24 {
            lastHashes.removeValue(forKey: hashOrder.removeFirst())
        }
        return prev
    }
}
