import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// Typing replay — a pausable playback engine plus overlaid transport controls
// for human-paced typing sessions (`floaty type --human`).
//
// WHY AN ENGINE, NOT A LOOP: the old typeProfiled ran usleep-between-keystrokes
// ON THE MAIN THREAD, so the whole app (and any overlay button) was frozen for
// the duration of the text. Splitting the work lets the controls stay live:
//
//   • TypingReplayScript  — pure generation: text + TypingProfile → a timed
//     keystroke schedule. Corrections (backspace-and-retype) are pre-rolled
//     here, so the step count — and therefore the progress bar — is exact.
//   • TypingReplaySession — plays a script on its own thread, posting CGEvents
//     (thread-safe) with pause / resume / stop / speed honored between
//     keystrokes. A key is never left down: dwell always completes.
//   • TypingReplayHUD     — the overlaid controls, a NON-ACTIVATING panel
//     pinned to the terminal window. Non-activating is load-bearing: tapping
//     Pause must not steal focus from the app being typed into, or Resume
//     would type into the wrong place. Unlike AgentGhostBadge this panel DOES
//     take mouse events — it sits over FloatyTerm's own window, not the target
//     app, and a typing session posts no synthetic clicks it could swallow.
//   • TypingReplayController — glue: one session at a time, HUD lifecycle,
//     and the async bridge AgentInput.type awaits.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Script generation

enum TypingReplayScript {

    struct Step {
        enum Kind {
            case unicode(String)      // a printable character (layout-independent)
            case keycode(CGKeyCode)   // return / backspace
        }
        let kind: Kind
        let delayMs: Double   // flight: gap before pressing this key
        let dwellMs: Double   // how long the key is held
        /// Characters of the ORIGINAL text completed once this step lands.
        /// Regresses during a correction burst (that's honest progress).
        let textIndex: Int
    }

    /// Total scheduled duration — what the session takes at 1× with no pauses.
    static func estimatedMs(_ steps: [Step]) -> Double {
        steps.reduce(0) { $0 + $1.delayMs + $1.dwellMs }
    }

    @MainActor
    static func make(text: String, profile: TypingProfile?) -> [Step] {
        guard let prof = profile else { return makeFlat(text) }

        let deleteCode = AgentInput.keycode(for: "delete") ?? 51
        let returnCode = AgentInput.keycode(for: "return") ?? 36
        var steps: [Step] = []
        var prev: Character? = nil
        var buffer: [Character] = []       // recently emitted printable chars
        let bufferCap = 16
        var idx = 0                         // original chars completed
        // 4 s ceiling, same safety clamp the blocking engine applied at sleep time.
        func clamp(_ ms: Double) -> Double { min(ms, 4000) }

        for c in text {
            if c == "\n" || c == "\r" {
                // A line break is a real Return; corrections never span lines.
                idx += 1
                steps.append(Step(kind: .keycode(returnCode),
                                  delayMs: clamp(prof.flightMs(prev: prev, cur: " ")),
                                  dwellMs: prof.dwellMs(for: " "),
                                  textIndex: idx))
                prev = nil
                buffer.removeAll()
                continue
            }

            idx += 1
            steps.append(Step(kind: .unicode(String(c)),
                              delayMs: clamp(prof.flightMs(prev: prev, cur: c)),
                              dwellMs: prof.dwellMs(for: c),
                              textIndex: idx))
            prev = c

            // Buffer must mirror the emitted tail EXACTLY (spaces included), or a
            // backspace-and-retype would delete real chars and restore different
            // ones — corrupting the text. Trigger guard stays on non-whitespace.
            buffer.append(c)
            if buffer.count > bufferCap { buffer.removeFirst() }

            // Backspace-and-retype correction (the "equivalent typo").
            if !c.isWhitespace, !buffer.isEmpty, prof.shouldCorrect() {
                let k = min(prof.sampleBurstLen(), buffer.count)
                let lastK = Array(buffer.suffix(k))
                var completed = idx
                for i in 0..<k {
                    completed -= 1
                    steps.append(Step(kind: .keycode(deleteCode),
                                      delayMs: clamp(i == 0 ? prof.correctionEntryMs()
                                                            : prof.bkspIntervalMs()),
                                      dwellMs: prof.backspaceDwellMs(),
                                      textIndex: max(0, completed)))
                }
                // Re-type the identical characters; buffer content is unchanged.
                prev = buffer.count > k ? buffer[buffer.count - k - 1] : nil
                for (j, ch) in lastK.enumerated() {
                    completed += 1
                    let flight = prof.flightMs(prev: prev, cur: ch)
                    steps.append(Step(kind: .unicode(String(ch)),
                                      delayMs: clamp(j == 0 ? prof.resumeMs() + flight : flight),
                                      dwellMs: prof.dwellMs(for: ch),
                                      textIndex: completed))
                    prev = ch
                }
            }
        }
        return steps
    }

    /// No recorded profile → flat jitter (the old humanKeyDelay: ~60ms ± noise).
    private static func makeFlat(_ text: String) -> [Step] {
        var steps: [Step] = []
        var idx = 0
        for c in text {
            idx += 1
            let ms = (idx == 1) ? 0 : max(10, 60 + Double.random(in: -20...40))
            steps.append(Step(kind: .unicode(String(c)), delayMs: ms, dwellMs: 0, textIndex: idx))
        }
        return steps
    }
}

// MARK: - Playback session (background thread, pausable)

final class TypingReplaySession: @unchecked Sendable {
    private enum State { case playing, paused, stopped, finished }

    private let steps: [TypingReplayScript.Step]
    private let source: CGEventSource?
    private let cond = NSCondition()
    private var state: State = .playing
    private var speedFactor: Double = 1.0

    let totalTextChars: Int
    var stepCount: Int { steps.count }

    /// Both fire on the main queue. (stepsDone, textCharsCompleted).
    var onProgress: ((Int, Int) -> Void)?
    /// (ranToCompletion, textCharsCompleted) — fires exactly once.
    var onFinish: ((Bool, Int) -> Void)?

    init(steps: [TypingReplayScript.Step], source: CGEventSource?, totalTextChars: Int) {
        self.steps = steps
        self.source = source
        self.totalTextChars = totalTextChars
    }

    func start() {
        Thread.detachNewThread { [self] in run() }
    }

    // MARK: transport (called from the main thread / HUD)

    var isPaused: Bool { cond.lock(); defer { cond.unlock() }; return state == .paused }

    func pause()  { cond.lock(); if state == .playing { state = .paused };  cond.unlock() }
    func resume() { cond.lock(); if state == .paused  { state = .playing; cond.broadcast() }; cond.unlock() }
    func stop() {
        cond.lock()
        if state == .playing || state == .paused { state = .stopped; cond.broadcast() }
        cond.unlock()
    }

    /// Playback rate: sleeps are divided by this. Applies live, mid-delay.
    var speed: Double {
        get { cond.lock(); defer { cond.unlock() }; return speedFactor }
        set { cond.lock(); speedFactor = max(0.1, newValue); cond.unlock() }
    }

    // MARK: playback loop

    private func run() {
        var typed = 0
        var i = 0
        while i < steps.count {
            let step = steps[i]
            guard interruptibleDelay(ms: step.delayMs) else { break }
            post(step)
            typed = step.textIndex
            i += 1
            let done = i, chars = typed
            DispatchQueue.main.async { self.onProgress?(done, chars) }
        }
        let completed = (i == steps.count)
        cond.lock(); if state != .stopped { state = .finished }; cond.unlock()
        let chars = typed
        DispatchQueue.main.async { self.onFinish?(completed, chars) }
    }

    /// Sleep `ms` (scaled by speed) in small slices so pause/stop react within
    /// ~25 ms. While paused the remaining delay is frozen, not consumed — and
    /// a pause at the boundary still holds BEFORE the next key is pressed.
    /// Returns false when the session was stopped.
    private func interruptibleDelay(ms: Double) -> Bool {
        var remaining = ms
        while true {
            cond.lock()
            while state == .paused { cond.wait() }
            let stopped = (state == .stopped)
            let sp = speedFactor
            cond.unlock()
            if stopped { return false }
            if remaining <= 0 { return true }
            let chunk = min(remaining, 25)
            usleep(useconds_t(chunk / sp * 1000))
            remaining -= chunk
        }
    }

    /// Dwell is a plain sleep, never interruptible: stopping mid-hold would
    /// leave the key down forever. Dwells are ≤ a few hundred ms anyway.
    private func post(_ step: TypingReplayScript.Step) {
        let dwellUs = useconds_t(min(step.dwellMs, 500) / speed * 1000)
        switch step.kind {
        case .unicode(let s):  AgentInput.postUnicode(s, source: source, dwellUs: dwellUs)
        case .keycode(let c):  AgentInput.postKeycode(c, source: source, dwellUs: dwellUs)
        }
    }
}

// MARK: - Overlaid transport controls

@MainActor
final class TypingReplayHUD {
    private let panel: NSPanel
    private let playPauseBtn = FirstMouseButton()
    private let stopBtn = FirstMouseButton()
    private let speedBtn = FirstMouseButton()
    private let bar = NSProgressIndicator()
    private let charsLabel = NSTextField(labelWithString: "")
    private var hostObservers: [NSObjectProtocol] = []
    private weak var hostWindow: NSWindow?

    var onPlayPause: () -> Void = {}
    var onStop: () -> Void = {}
    var onCycleSpeed: () -> Void = {}

    private static let size = NSSize(width: 336, height: 40)
    private static let topInset: CGFloat = 8

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Above the terminal panel (.statusBar), same tier as AgentGhostBadge.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        func symbol(_ btn: FirstMouseButton, _ name: String, _ desc: String, _ action: Selector) {
            btn.image = NSImage(systemSymbolName: name, accessibilityDescription: desc)
            btn.isBordered = false
            btn.bezelStyle = .regularSquare
            btn.imageScaling = .scaleProportionallyDown
            btn.target = self
            btn.action = action
            btn.setContentHuggingPriority(.required, for: .horizontal)
        }
        symbol(playPauseBtn, "pause.fill", "Pause replay", #selector(playPauseTapped))
        symbol(stopBtn, "stop.fill", "Stop replay", #selector(stopTapped))

        speedBtn.title = "1×"
        speedBtn.isBordered = false
        speedBtn.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        speedBtn.contentTintColor = .secondaryLabelColor
        speedBtn.target = self
        speedBtn.action = #selector(speedTapped)
        speedBtn.setContentHuggingPriority(.required, for: .horizontal)

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.controlSize = .small

        charsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        charsLabel.textColor = .secondaryLabelColor
        charsLabel.alignment = .right
        charsLabel.setContentHuggingPriority(.required, for: .horizontal)

        let title = NSTextField(labelWithString: "✦")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .systemPink
        title.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [title, playPauseBtn, stopBtn, bar, charsLabel, speedBtn])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
        ])
    }

    @objc private func playPauseTapped() { onPlayPause() }
    @objc private func stopTapped() { onStop() }
    @objc private func speedTapped() { onCycleSpeed() }

    /// Show pinned to the top-center of `host` (the front terminal window);
    /// with no terminal visible, fall back to the top-center of the screen.
    /// Follows the host while it moves or resizes.
    func show(over host: NSWindow?, totalSteps: Int) {
        bar.maxValue = Double(max(1, totalSteps))
        bar.doubleValue = 0
        hostWindow = host
        reposition()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        if let host {
            let center = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
                hostObservers.append(center.addObserver(forName: name, object: host, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor in self?.reposition() }
                })
            }
        }
    }

    private func reposition() {
        let anchor: NSRect
        if let f = hostWindow?.frame {
            anchor = f
        } else if let screen = NSScreen.main {
            anchor = screen.visibleFrame
        } else {
            return
        }
        panel.setFrameOrigin(NSPoint(x: anchor.midX - Self.size.width / 2,
                                     y: anchor.maxY - Self.size.height - Self.topInset))
        panel.orderFrontRegardless()
    }

    func setPaused(_ paused: Bool) {
        playPauseBtn.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                     accessibilityDescription: paused ? "Resume replay" : "Pause replay")
    }

    func setSpeed(_ speed: Double) {
        speedBtn.title = speed == rounded(speed) ? "\(Int(speed))×" : "\(speed)×"
    }
    private func rounded(_ v: Double) -> Double { v.rounded() }

    func setProgress(stepsDone: Int, chars: Int, totalChars: Int) {
        bar.doubleValue = Double(stepsDone)
        charsLabel.stringValue = "\(chars)/\(totalChars)"
    }

    /// Terminal state: brief verdict, then fade out and tear down.
    func finish(completed: Bool) {
        playPauseBtn.isEnabled = false
        stopBtn.isEnabled = false
        speedBtn.isEnabled = false
        charsLabel.stringValue = completed ? "done" : "stopped"
        if completed { bar.doubleValue = bar.maxValue }
        removeObservers()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [panel] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
        }
    }

    private func removeObservers() {
        hostObservers.forEach { NotificationCenter.default.removeObserver($0) }
        hostObservers.removeAll()
    }
}

/// Buttons in a non-activating, never-key panel only get their first click if
/// they accept first mouse — NSButton doesn't by default.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Controller (one session at a time)

@MainActor
final class TypingReplayController {
    static let shared = TypingReplayController()
    private var session: TypingReplaySession?
    private var hud: TypingReplayHUD?
    private init() {}

    /// Run `text` as a replay session and await its outcome. `completed` is
    /// false when the user hit Stop; `typed` is how many characters of `text`
    /// had landed by then.
    func run(text: String, profile: TypingProfile?, source: CGEventSource?,
             showControls: Bool) async -> (completed: Bool, typed: Int) {
        // The relay serializes agent commands, so overlap shouldn't happen —
        // but if it ever does, the older session must not keep typing.
        session?.stop()

        let steps = TypingReplayScript.make(text: text, profile: profile)
        guard !steps.isEmpty else { return (true, 0) }

        let s = TypingReplaySession(steps: steps, source: source, totalTextChars: text.count)
        session = s

        if showControls {
            let h = TypingReplayHUD()
            let speeds: [Double] = [1, 2, 4, 0.5]
            h.onPlayPause = { [weak s, weak h] in
                guard let s else { return }
                if s.isPaused { s.resume() } else { s.pause() }
                h?.setPaused(s.isPaused)
            }
            h.onStop = { [weak s] in s?.stop() }
            h.onCycleSpeed = { [weak s, weak h] in
                guard let s else { return }
                let next = speeds[((speeds.firstIndex(of: s.speed) ?? 0) + 1) % speeds.count]
                s.speed = next
                h?.setSpeed(next)
            }
            h.show(over: Self.frontTerminalWindow(), totalSteps: steps.count)
            hud = h
        }

        return await withCheckedContinuation { cont in
            s.onProgress = { [weak self] done, chars in
                self?.hud?.setProgress(stepsDone: done, chars: chars, totalChars: text.count)
            }
            s.onFinish = { [weak self] completed, chars in
                self?.hud?.finish(completed: completed)
                self?.hud = nil
                self?.session = nil
                cont.resume(returning: (completed, chars))
            }
            s.start()
        }
    }

    /// The frontmost visible terminal panel — the HUD's anchor.
    private static func frontTerminalWindow() -> NSWindow? {
        NSApp.orderedWindows.first {
            $0 is FloatingPanel && $0.isVisible && $0.isOnActiveSpace
        }
    }
}
