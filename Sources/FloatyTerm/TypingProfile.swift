import Foundation

/// Loads the keystroke-dynamics profile recorded by Tools/TypingProfiler and
/// turns it into a sampler that `AgentInput.type` uses to reproduce the user's
/// real typing rhythm (dwell + flight + corrections) when `--human` is passed.
///
/// DESIGN NOTES (from analysing the recorded data):
///   • Intervals are right-skewed (mean ≫ median), so we sample EMPIRICALLY from
///     the raw `_samples` reservoirs — never from a Gaussian(mean,sd). Each draw
///     is a real measured value, so the synthesized distribution matches yours,
///     skew and all.
///   • Each bucket is trimmed to [p05, p95] on sampling, which kills the rare
///     intra-word multi-second stall that leaked under the 2 s capture threshold
///     without flattening the legitimate slow-downs at word/number/punct edges.
///   • The `other` key class (arrows, tab — navigation while editing) is never
///     queried: we only type forward, so those transitions don't apply.
///   • Bucket selection falls back digraph → class-pair → global, since the
///     digraph tail is sparser than the (huge) class-pair buckets.
final class TypingProfile {

    // MARK: sample bucket

    /// A pool of measured intervals (ms) with precomputed tail-trim bounds.
    struct Bucket {
        let samples: [Double]
        let p05: Double
        let p95: Double
        var count: Int { samples.count }

        init(_ xs: [Double]) {
            samples = xs
            guard !xs.isEmpty else { p05 = 0; p95 = 0; return }
            let s = xs.sorted()
            func pct(_ p: Double) -> Double {
                if s.count == 1 { return s[0] }
                let r = p / 100 * Double(s.count - 1)
                let lo = Int(r.rounded(.down)), hi = Int(r.rounded(.up))
                return s[lo] + (s[hi] - s[lo]) * (r - Double(lo))
            }
            p05 = pct(5); p95 = pct(95)
        }

        /// A random measured value, clamped to [p05, p95] to drop extreme tails.
        func sample() -> Double {
            guard let v = samples.randomElement() else { return 0 }
            return min(max(v, p05), p95)
        }
    }

    // MARK: data

    private var dwell: [String: Bucket] = [:]
    private var flightGlobal = Bucket([])
    private var flightPair: [String: Bucket] = [:]
    private var flightDigraph: [String: Bucket] = [:]
    private var resume = Bucket([])
    private var bkspInterval = Bucket([])
    private var burstLen: [Double] = []
    /// Probability of a backspace-and-retype correction PER typed character.
    private(set) var correctionRatePerKey: Double = 0
    let available: Bool

    // MARK: load (mtime-cached so a re-record is picked up without relaunch)

    static var profileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FloatyTerm/typing-profile.json")
    }

    private static var cached: TypingProfile?
    private static var cachedMTime: Date?

    /// The current profile, or nil if none has been recorded yet.
    static func current() -> TypingProfile? {
        let url = profileURL
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if let c = cached, cachedMTime == mtime { return c.available ? c : nil }
        let p = TypingProfile(url: url)
        cached = p; cachedMTime = mtime
        return p.available ? p : nil
    }

    init(url: URL) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let s = obj["_samples"] as? [String: Any]
        else { available = false; return }

        func arr(_ a: Any?) -> [Double] {
            if let n = a as? [NSNumber] { return n.map { $0.doubleValue } }
            if let d = a as? [Double] { return d }
            return []
        }
        func dict(_ a: Any?) -> [String: [Double]] {
            guard let d = a as? [String: Any] else { return [:] }
            var out: [String: [Double]] = [:]
            for (k, v) in d { out[k] = arr(v) }
            return out
        }

        flightGlobal = Bucket(arr(s["flight_global"]))
        for (k, v) in dict(s["dwell"]) { dwell[k] = Bucket(v) }
        for (k, v) in dict(s["flight_pair"]) { flightPair[k] = Bucket(v) }
        for (k, v) in dict(s["flight_digraph"]) { flightDigraph[k] = Bucket(v) }
        resume = Bucket(arr(s["resume"]))
        bkspInterval = Bucket(arr(s["bksp_interval"]))
        burstLen = arr(s["burst_len"])
        if let c = obj["corrections"] as? [String: Any],
           let r = c["burst_rate_per_100_keys"] as? NSNumber {
            correctionRatePerKey = r.doubleValue / 100.0
        }
        available = !flightGlobal.samples.isEmpty
    }

    // MARK: classification (mirrors the recorder)

    private func classOf(_ ch: Character) -> String {
        guard let c = ch.lowercased().first else { return "other" }
        if "aeiou".contains(c) { return "vowel" }
        if c.isLetter { return "consonant" }
        if c.isNumber { return "digit" }
        if c == " " { return "space" }
        if c.isPunctuation || c.isSymbol { return "punct" }
        return "other"
    }

    private func isLetterClass(_ c: String) -> Bool { c == "vowel" || c == "consonant" }
    private func floorMs(_ v: Double) -> Double { max(v, 15) }   // never machine-fast

    // MARK: sampling API (all return milliseconds)

    /// How long to hold `ch` down.
    func dwellMs(for ch: Character) -> Double {
        let b = dwell[classOf(ch)] ?? dwell["consonant"]
        return floorMs(b?.sample() ?? 95)
    }

    /// Gap between the previous key's release and pressing `cur`.
    func flightMs(prev: Character?, cur: Character) -> Double {
        guard let p = prev else { return 0 }
        let pc = classOf(p), cc = classOf(cur)
        if isLetterClass(pc), isLetterClass(cc),
           let lp = p.lowercased().first, let lc = cur.lowercased().first {
            if let b = flightDigraph["\(lp)\(lc)"], b.count >= 5 { return floorMs(b.sample()) }
        }
        if let b = flightPair["\(pc)>\(cc)"], b.count >= 10 { return floorMs(b.sample()) }
        return floorMs(flightGlobal.sample())
    }

    // MARK: corrections (backspace-and-retype — never enters wrong text)

    func shouldCorrect() -> Bool {
        correctionRatePerKey > 0 && Double.random(in: 0..<1) < correctionRatePerKey
    }

    func sampleBurstLen() -> Int {
        max(1, Int((burstLen.randomElement() ?? 1).rounded()))
    }

    /// The "notice the error" beat before the first backspace.
    func correctionEntryMs() -> Double {
        if let b = flightPair["consonant>backspace"], b.count >= 8 { return max(60, b.sample()) }
        if let b = flightPair["vowel>backspace"], b.count >= 8 { return max(60, b.sample()) }
        return max(60, resume.sample() * 0.7)
    }

    func backspaceDwellMs() -> Double { max(20, dwell["backspace"]?.sample() ?? 80) }
    func bkspIntervalMs() -> Double { max(40, bkspInterval.sample()) }
    /// The pause after correcting, before resuming forward typing.
    func resumeMs() -> Double { max(80, resume.sample()) }
}
