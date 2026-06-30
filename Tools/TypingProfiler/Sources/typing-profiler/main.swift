import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// TypingProfiler — a keystroke-dynamics recorder.
//
// WHY A GUI, NOT A CLI: dwell time (how long a key is held) needs the key-UP
// event. Terminals never report key-up — they only emit a byte on key-down — so
// dwell is unmeasurable from a CLI. An NSTextView is first responder and receives
// keyDown / keyUp / flagsChanged with hardware timestamps (NSEvent.timestamp,
// already monotonic seconds-since-boot), which is exactly what this needs.
//
// WHAT IT MEASURES (all in milliseconds):
//   • Dwell    — keyDown→keyUp of the same key, bucketed by key class.
//   • Flight   — keyUp(n-1)→keyDown(n), bucketed by digraph and by class-pair.
//   • Corrections — backspace runs: burst length, the cadence of held backspace,
//                   and the resume latency before typing continues.
//   • Macro-pauses — flights over 2 s are hesitations; kept separate, never mixed
//                    into the rhythm aggregates.
//
// Stats are right-skewed (log-normal-ish), so we keep percentiles (p10/p50/p90)
// plus mean/sd and a sample count per bucket — never assume a Gaussian. The raw
// per-bucket samples are persisted (capped via reservoir) so multiple sessions
// merge correctly: percentiles can't be re-derived from percentiles.
//
// Output: ~/Library/Application Support/FloatyTerm/typing-profile.json
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Key classification

enum KeyClass: String {
    case vowel, consonant, digit, space
    case returnKey = "return"
    case backspace, shift, modifier, punct, other
}

private let kBackspace: UInt16 = 51
private let kForwardDelete: UInt16 = 117
private let kReturn: UInt16 = 36
private let kEnter: UInt16 = 76
private let kLeftShift: UInt16 = 56
private let kRightShift: UInt16 = 60

func classify(_ chars: String?, _ keyCode: UInt16) -> KeyClass {
    if keyCode == kBackspace || keyCode == kForwardDelete { return .backspace }
    if keyCode == kReturn || keyCode == kEnter { return .returnKey }
    if keyCode == kLeftShift || keyCode == kRightShift { return .shift }
    guard let c = chars?.lowercased().first else { return .other }
    if "aeiou".contains(c) { return .vowel }
    if c.isLetter { return .consonant }
    if c.isNumber { return .digit }
    if c == " " { return .space }
    if c.isPunctuation || c.isSymbol { return .punct }
    return .other
}

// MARK: - Stats helpers

private func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    if sorted.count == 1 { return sorted[0] }
    let rank = p / 100 * Double(sorted.count - 1)
    let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
    let frac = rank - Double(lo)
    return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
}

private func stats(_ xs: [Double]) -> [String: Any] {
    guard !xs.isEmpty else { return ["n": 0] }
    let s = xs.sorted()
    let mean = xs.reduce(0, +) / Double(xs.count)
    let varc = xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)
    return [
        "n": xs.count,
        "mean_ms": round2(mean),
        "sd_ms": round2(varc.squareRoot()),
        "p10_ms": round2(percentile(s, 10)),
        "p50_ms": round2(percentile(s, 50)),
        "p90_ms": round2(percentile(s, 90)),
    ]
}

/// Reservoir-cap a sample array so the persisted profile stays small.
private func cap(_ xs: [Double], _ n: Int) -> [Double] {
    xs.count <= n ? xs : Array(xs.shuffled().prefix(n))
}

// MARK: - Profiler (Tiers 2–4: extract, normalize, aggregate)

final class Profiler {
    // Reservoirs of samples (ms) — the source of truth, persisted for merging.
    var dwell: [String: [Double]] = [:]            // keyClass -> dwell samples
    var flightGlobal: [Double] = []
    var flightPair: [String: [Double]] = [:]       // "consonant>vowel" -> flights
    var flightDigraph: [String: [Double]] = [:]     // "th" -> flights (letters only)
    var resume: [Double] = []                        // post-correction resume latency
    var burstLen: [Double] = []                      // chars deleted per backspace burst
    var bkspInterval: [Double] = []                  // gap between held-backspace repeats
    var macroPause: [Double] = []                    // flights over the threshold

    // Cumulative counters (carried across sessions via metadata).
    var totalEvents = 0          // this session
    var totalDown = 0            // this session, non-repeat key-downs
    var bursts = 0               // this session, correction bursts
    var priorEvents = 0
    var priorSessions = 0

    let macroThresholdMs = 2000.0
    private let reservoirCap = 4000

    // Pairing / correction state (reset per passage; samples persist).
    private var downTimes: [UInt16: Double] = [:]
    private var lastUpTime: Double?
    private var lastChar: Character?
    private var lastClass: KeyClass?
    private var downMods: Set<UInt16> = []
    private var burst = 0
    private var lastDeleteDownT: Double?
    private var lastDeleteUpT: Double?

    func resetPairing() {
        downTimes.removeAll(); lastUpTime = nil; lastChar = nil; lastClass = nil
        downMods.removeAll(); burst = 0; lastDeleteDownT = nil; lastDeleteUpT = nil
    }

    // MARK: event ingestion

    func keyDown(_ e: NSEvent) {
        totalEvents += 1
        let t = e.timestamp * 1000.0
        let code = e.keyCode
        let chars = e.charactersIgnoringModifiers
        let cls = classify(chars, code)
        let isDelete = (cls == .backspace)

        if e.isARepeat {
            // Held key. Only backspace repeats carry rhythm we care about.
            if isDelete {
                if let p = lastDeleteDownT { bkspInterval.append(t - p) }
                lastDeleteDownT = t
                burst += 1
            }
            return
        }
        totalDown += 1

        // Flight: previous key-up → this key-down.
        if let up = lastUpTime {
            let ft = t - up
            if ft >= 0 {
                if ft > macroThresholdMs {
                    macroPause.append(ft)
                } else {
                    flightGlobal.append(ft)
                    if let lc = lastClass {
                        flightPair["\(lc.rawValue)>\(cls.rawValue)", default: []].append(ft)
                    }
                    if let a = lastChar, let b = chars?.lowercased().first, a.isLetter, b.isLetter {
                        flightDigraph["\(a)\(b)", default: []].append(ft)
                    }
                }
            }
        }

        // Correction detection.
        if isDelete {
            if burst > 0, let p = lastDeleteDownT { bkspInterval.append(t - p) }
            lastDeleteDownT = t
            burst += 1
        } else if burst > 0 {
            burstLen.append(Double(burst))
            bursts += 1
            if let du = lastDeleteUpT {
                let r = t - du
                if r >= 0 && r <= macroThresholdMs { resume.append(r) }
            }
            burst = 0
        }

        downTimes[code] = t
        lastChar = chars?.lowercased().first
        lastClass = cls
    }

    func keyUp(_ e: NSEvent) {
        totalEvents += 1
        let t = e.timestamp * 1000.0
        let code = e.keyCode
        let cls = classify(e.charactersIgnoringModifiers, code)
        if let dt = downTimes[code] {
            let d = t - dt
            if d >= 0 && d <= macroThresholdMs { dwell[cls.rawValue, default: []].append(d) }
            downTimes[code] = nil
        }
        if cls == .backspace { lastDeleteUpT = t }
        lastUpTime = t
    }

    func flagsChanged(_ e: NSEvent) {
        totalEvents += 1
        let t = e.timestamp * 1000.0
        let code = e.keyCode
        guard code != 0 else { return }
        let cls: KeyClass = (code == kLeftShift || code == kRightShift) ? .shift : .modifier
        if downMods.contains(code) {            // release
            if let dt = downTimes[code] {
                let d = t - dt
                if d >= 0 && d <= macroThresholdMs { dwell[cls.rawValue, default: []].append(d) }
                downTimes[code] = nil
            }
            downMods.remove(code)
            lastUpTime = t
        } else {                                 // press
            downMods.insert(code)
            downTimes[code] = t
        }
    }

    // MARK: persistence

    var liveSummary: String {
        let dwellN = dwell.values.reduce(0) { $0 + $1.count }
        let digN = flightDigraph.filter { $0.value.count >= 8 }.count
        return "events \(totalEvents)  ·  dwell \(dwellN)  ·  flight \(flightGlobal.count)  ·  digraphs ≥8 \(digN)  ·  bursts \(bursts)"
    }

    /// Merge persisted samples from a prior session file into our reservoirs.
    func loadAndMerge(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let m = obj["profile_metadata"] as? [String: Any] {
            priorEvents = (m["total_events"] as? Int) ?? 0
            priorSessions = (m["sessions"] as? Int) ?? 0
        }
        guard let s = obj["_samples"] as? [String: Any] else { return }
        func arr(_ any: Any?) -> [Double] {
            if let a = any as? [Double] { return a }
            if let a = any as? [NSNumber] { return a.map { $0.doubleValue } }
            return []
        }
        func mergeDict(_ key: String, into target: inout [String: [Double]]) {
            guard let d = s[key] as? [String: Any] else { return }
            for (k, v) in d { target[k, default: []].insert(contentsOf: arr(v), at: 0) }
        }
        flightGlobal.insert(contentsOf: arr(s["flight_global"]), at: 0)
        resume.insert(contentsOf: arr(s["resume"]), at: 0)
        burstLen.insert(contentsOf: arr(s["burst_len"]), at: 0)
        bkspInterval.insert(contentsOf: arr(s["bksp_interval"]), at: 0)
        macroPause.insert(contentsOf: arr(s["macro_pause"]), at: 0)
        mergeDict("dwell", into: &dwell)
        mergeDict("flight_pair", into: &flightPair)
        mergeDict("flight_digraph", into: &flightDigraph)
    }

    /// Build the serializable profile: human-readable stats + raw `_samples`.
    func profileJSON() -> [String: Any] {
        // Capped sample reservoirs (the merge source of truth).
        func capDict(_ d: [String: [Double]]) -> [String: [Double]] {
            d.mapValues { cap($0, reservoirCap).map(round2) }
        }
        let samples: [String: Any] = [
            "dwell": capDict(dwell),
            "flight_global": cap(flightGlobal, reservoirCap).map(round2),
            "flight_pair": capDict(flightPair),
            "flight_digraph": capDict(flightDigraph),
            "resume": cap(resume, reservoirCap).map(round2),
            "burst_len": cap(burstLen, reservoirCap).map(round2),
            "bksp_interval": cap(bkspInterval, reservoirCap).map(round2),
            "macro_pause": cap(macroPause, reservoirCap).map(round2),
        ]

        // Readable stats, with sparse buckets filtered out (noise).
        let dwellStats = dwell.mapValues { stats($0) }
        let pairStats = flightPair.filter { $0.value.count >= 10 }.mapValues { stats($0) }
        let digraphStats = flightDigraph.filter { $0.value.count >= 8 }.mapValues { stats($0) }

        let burstRate = totalDown > 0 ? round2(Double(bursts) / Double(totalDown) * 100) : 0
        var burstLenStats = stats(burstLen)
        burstLenStats.removeValue(forKey: "mean_ms")  // chars, not ms
        if !burstLen.isEmpty {
            burstLenStats["mean_chars"] = round2(burstLen.reduce(0, +) / Double(burstLen.count))
        }

        return [
            "profile_metadata": [
                "schema": 1,
                "sessions": priorSessions + 1,
                "total_events": priorEvents + totalEvents,
                "macro_pause_threshold_ms": Int(macroThresholdMs),
                "covered_digraphs": digraphStats.count,
            ],
            "dwell": dwellStats,
            "flight": [
                "global": stats(flightGlobal),
                "by_class_pair": pairStats,
                "by_digraph": digraphStats,
            ],
            "corrections": [
                "burst_rate_per_100_keys": burstRate,
                "burst_len_chars": burstLenStats,
                "resume_latency_ms": stats(resume),
                "backspace_repeat_interval_ms": stats(bkspInterval),
            ],
            "pauses": [
                "threshold_ms": Int(macroThresholdMs),
                "count": macroPause.count,
                "duration_ms": stats(macroPause),
            ],
            "_samples": samples,
        ]
    }
}

// MARK: - Passages / collection modes
//
// Each mode targets a different gap in the profile. Easy was where we started:
// it nails baseline rhythm, dwell, and the common digraphs (th/he/in/er/an), but
// it under-samples the long digraph tail, digit↔punctuation transitions, and
// shift. The other modes feed exactly those thin buckets so the profile fills out
// evenly across sessions (the profile merges, so any mix of modes accumulates).

struct Mode {
    let name: String
    let feeds: String      // what data this mode is good for (shown in the UI)
    let passages: [String]
}

let modes: [Mode] = [
    Mode(name: "Easy · Prose & pangrams",
         feeds: "baseline rhythm · dwell · common digraphs (th he in er an)",
         passages: [
            "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. Sphinx of black quartz, judge my vow.",
            "When the morning light breaks over the hills, the whole valley seems to wake at once. People move through the streets with that easy rhythm of another ordinary day, and for a moment nothing else really matters at all.",
            "It is a truth often forgotten that the smallest habits quietly shape the largest outcomes. We rarely notice the steady work of repetition until, looking back, we find a path worn smooth beneath our own feet.",
            "Writing by hand or by keyboard, we each leave a kind of signature in the timing of our keys: the brief press of a vowel, the small leap between letters our fingers know well, the stumble and quick backspace when a word comes out wrong. None of it is planned, yet all of it is ours.",
         ]),
    Mode(name: "Medium · Wide vocabulary",
         feeds: "broadens the digraph tail · rarer letters (j q x z k) · long words",
         passages: [
            "The jovial wizard quickly mixed a fizzy brew of quartz dust and zephyr oil, then puzzled over a vexing equation while a drowsy lynx dozed beside the hexagonal hearth.",
            "Awkward, anxious, and thoroughly bewildered, the juggler vowed to conquer every difficult rhythm, juxtaposing brisk jazz with the baroque flourishes nobody in the audience expected.",
            "Foxglove and ivy sprawled across the rugged bluff, where kestrels wheeled above the frothing surf and a salt wind carried the faint, acrid tang of kelp and diesel.",
            "Knowledge, like a labyrinth, rewards the curious wanderer who is willing to backtrack, requestion the obvious, and rethink each junction before choosing an elegant exit.",
            "Zigzagging through the bazaar, she haggled for saffron, apricots, and a quirky brass lamp, unfazed by the jostling crowd or the muezzin's distant, echoing call.",
         ]),
    Mode(name: "Hard · Code & symbols",
         feeds: "punctuation & brackets · shift dwell (CamelCase) · symbol flights",
         passages: [
            "let total = items.filter { $0.price > 0 }.reduce(0, +)   // running sum",
            "const url = \"https://api.example.com/v2/users?id=42&sort=desc#top\";",
            "git commit -m \"fix: handle nil in parse() (#1287)\" && git push origin main",
            "func merge(_ a: [String: Int], _ b: [String: Int]) -> [String: Int] { a.merging(b) { $1 } }",
            "{\"id\": 30482, \"ok\": true, \"tags\": [\"alpha\", \"beta\"], \"ratio\": 0.875, \"note\": null}",
            "Email mick@reduzer.tech by Friday — we ship v2.0 on 2026-07-15! Budget: $4,500 (approx). Ping #floaty-team.",
         ]),
    Mode(name: "Drill · Numbers",
         feeds: "thin digit buckets · digit↔punct transitions · number-row reach",
         passages: [
            "2026-07-15 09:42:18  invoice #30482  $4,500.00  +1 (415) 555-0137  ext. 226",
            "3.14159, 2.71828, 1.61803; 100% of 250 = 250; 7 * 8 = 56; 1024 / 16 = 64; 2^10 = 1024",
            "ZIP 94105-2207, order 1Z998AA7740, PIN 4821, lat 37.7749, lon -122.4194, alt 16m",
            "Q1 12,430   Q2 15,980   Q3 18,205   Q4 21,660   total 68,275   (up 19.4% YoY)",
            "Order 30482 shipped 12 units at 19.99 each; subtotal 239.88, tax 8.25%, total 259.67.",
         ]),
    Mode(name: "Drill · Digraphs",
         feeds: "evens out under-sampled letter pairs · comma+space cadence",
         passages: [
            "axle, oxen, vex, quay, jinx, zeal, gulf, wharf, blitz, cusp, dwarf, glyph, knob, lymph, mocha",
            "nymph, pixel, quirk, sphinx, vodka, yacht, zebra, fjord, gauze, hubcap, ivory, jackal, kiosk",
            "amber, bronze, candor, dazzle, effigy, fervor, gusto, hazel, ingot, jumble, kraken, locust, marquee",
            "obelisk, plywood, quiver, rhombus, syringe, tundra, upkeep, vortex, wedlock, xenon, yonder, zealous",
         ]),
]

// MARK: - Capture surface

final class CaptureTextView: NSTextView {
    let profiler: Profiler
    var onUpdate: (() -> Void)?

    init(frame: NSRect, profiler: Profiler) {
        self.profiler = profiler
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(
            containerSize: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        super.init(frame: frame, textContainer: container)

        isEditable = true
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textContainerInset = NSSize(width: 8, height: 8)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        profiler.keyDown(event)
        super.keyDown(with: event)
        onUpdate?()
    }

    override func keyUp(with event: NSEvent) {
        profiler.keyUp(event)
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        profiler.flagsChanged(event)
        super.flagsChanged(with: event)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let profiler = Profiler()
    var window: NSWindow!
    var modePopup: NSPopUpButton!
    var feedsLabel: NSTextField!
    var passageLabel: NSTextField!
    var statusLabel: NSTextField!
    var textView: CaptureTextView!
    var scrollView: NSScrollView!
    var modeIndex = 0
    var index = 0

    var passages: [String] { modes[modeIndex].passages }

    var profileURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FloatyTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("typing-profile.json")
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 800, height: 620)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "TypingProfiler"
        window.center()
        let content = window.contentView!

        // Mode selector (difficulty / drill). Switching resets to its passage 1.
        modePopup = NSPopUpButton(frame: NSRect(x: 20, y: 580, width: 280, height: 26))
        modePopup.autoresizingMask = [.minYMargin]
        modePopup.addItems(withTitles: modes.map { $0.name })
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        content.addSubview(modePopup)

        // What the selected mode feeds.
        feedsLabel = NSTextField(labelWithString: "")
        feedsLabel.frame = NSRect(x: 312, y: 583, width: 468, height: 20)
        feedsLabel.autoresizingMask = [.width, .minYMargin]
        feedsLabel.font = NSFont.systemFont(ofSize: 11)
        feedsLabel.textColor = .tertiaryLabelColor
        content.addSubview(feedsLabel)

        // Passage to type (read-only, wrapping).
        passageLabel = NSTextField(wrappingLabelWithString: "")
        passageLabel.frame = NSRect(x: 20, y: 432, width: 760, height: 138)
        passageLabel.autoresizingMask = [.width, .minYMargin]
        passageLabel.font = NSFont.systemFont(ofSize: 15)
        passageLabel.textColor = .secondaryLabelColor
        passageLabel.isSelectable = false
        content.addSubview(passageLabel)

        // Typing surface.
        scrollView = NSScrollView(frame: NSRect(x: 20, y: 78, width: 760, height: 344))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        textView = CaptureTextView(
            frame: NSRect(x: 0, y: 0, width: 760, height: 344), profiler: profiler)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 344)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        scrollView.documentView = textView
        textView.onUpdate = { [weak self] in self?.refreshStatus() }
        content.addSubview(scrollView)

        // Status line.
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 20, y: 46, width: 760, height: 20)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        statusLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .tertiaryLabelColor
        content.addSubview(statusLabel)

        // Buttons.
        let prevBtn = NSButton(title: "Prev", target: self, action: #selector(prevPassage))
        prevBtn.frame = NSRect(x: 470, y: 12, width: 70, height: 30)
        prevBtn.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(prevBtn)

        let nextBtn = NSButton(title: "Next", target: self, action: #selector(nextPassage))
        nextBtn.frame = NSRect(x: 548, y: 12, width: 70, height: 30)
        nextBtn.autoresizingMask = [.minXMargin, .maxYMargin]
        content.addSubview(nextBtn)

        let saveBtn = NSButton(title: "Save Profile", target: self, action: #selector(saveProfile))
        saveBtn.frame = NSRect(x: 626, y: 12, width: 154, height: 30)
        saveBtn.autoresizingMask = [.minXMargin, .maxYMargin]
        saveBtn.keyEquivalent = "\r"
        content.addSubview(saveBtn)

        showPassage()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(textView)
        refreshStatus()
    }

    func showPassage() {
        let mode = modes[modeIndex]
        feedsLabel.stringValue = "feeds: \(mode.feeds)"
        passageLabel.stringValue = "Passage \(index + 1) of \(passages.count) — type it as naturally as you can (typos and backspaces welcome):\n\n\(passages[index])"
        textView.string = ""
        profiler.resetPairing()
        window.makeFirstResponder(textView)
    }

    func refreshStatus() {
        statusLabel.stringValue = profiler.liveSummary
    }

    @objc func modeChanged() {
        modeIndex = modePopup.indexOfSelectedItem
        index = 0
        showPassage()
    }

    @objc func nextPassage() {
        index = (index + 1) % passages.count
        showPassage()
    }

    @objc func prevPassage() {
        index = (index - 1 + passages.count) % passages.count
        showPassage()
    }

    @objc func saveProfile() {
        let url = profileURL
        profiler.loadAndMerge(from: url)            // accumulate across sessions
        let json = profiler.profileJSON()
        guard let data = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            statusLabel.stringValue = "save failed: could not serialize"
            return
        }
        do {
            try data.write(to: url)
            let meta = json["profile_metadata"] as? [String: Any]
            let events = meta?["total_events"] as? Int ?? 0
            let sessions = meta?["sessions"] as? Int ?? 0
            statusLabel.stringValue = "saved → \(url.path)  (\(events) events, \(sessions) sessions)"
        } catch {
            statusLabel.stringValue = "save failed: \(error.localizedDescription)"
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
