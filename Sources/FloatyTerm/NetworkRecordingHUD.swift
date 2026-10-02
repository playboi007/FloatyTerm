import AppKit
import QuartzCore

// MARK: - Controller

/// Owns the on-screen REC pill for `floaty net` recordings.
///
/// Driven by `.networkRecordingChanged`, never by the CLI directly, so the pill
/// appears however a recording was started and stays honest however it was
/// stopped. Its Stop and Save go through `NetworkCapture` — the same path as
/// `floaty net stop` — so the collectors flush before the file closes.
@MainActor
final class NetworkRecordingController {

    static let shared = NetworkRecordingController()

    /// Told whenever "is anything recording" flips — the menu-bar dot.
    var onRecordingChanged: (Bool) -> Void = { _ in }

    private var hud: NetworkRecordingHUD?
    private var shownLabel: String?
    private var stopped: (file: URL, session: String)?
    private var stopRequestedHere = false
    private var ticker: Timer?
    private var autoHide: DispatchWorkItem?
    private var accessory: SaveFormatAccessory?
    private var installed = false

    private init() {}

    func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(forName: .networkRecordingChanged, object: nil,
                                               queue: .main) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.changed(info) }
        }
    }

    // MARK: Recorder events

    private func changed(_ info: [AnyHashable: Any]?) {
        let live = NetworkRecorder.shared.live()
        onRecordingChanged(!live.isEmpty)

        if let newest = live.last {
            let isNew = newest.label != shownLabel || hud?.mode != .recording
            shownLabel = newest.label
            stopped = nil
            cancelAutoHide()
            let h = hud ?? makeHUD()
            h.showRecording(newest, others: live.count - 1, animated: isNew)
            startTicker()
            return
        }

        stopTicker()
        guard let result = info?["result"] as? [String: Any],
              (info?["event"] as? String) == "stop",
              let path = result["file"] as? String else {
            hud?.dismiss(); hud = nil
            return
        }
        stopped = (URL(fileURLWithPath: path), result["session"] as? String ?? "recording")
        let events = result["events"] as? Int ?? 0
        let h = hud ?? makeHUD()
        h.showStopped(events: events, label: result["label"] as? String ?? "",
                      warning: result["warning"] as? String)
        // Stopped from the terminal: the user is already exporting there, so
        // offer Save briefly and get out of the way. Stopped from the pill: they
        // asked to stop, so wait for them.
        if !stopRequestedHere { scheduleAutoHide(after: 10) }
        stopRequestedHere = false
    }

    private func tick() {
        guard let label = shownLabel,
              let info = NetworkRecorder.shared.live().first(where: { $0.label == label }) else { return }
        hud?.showRecording(info, others: NetworkRecorder.shared.live().count - 1, animated: false)
    }

    // MARK: Actions (pill buttons and the menu bar)

    func stop() {
        guard let label = currentLiveLabel() else { return }
        stopRequestedHere = true
        hud?.showBusy("Stopping…")
        Task { @MainActor in
            let result = await NetworkCapture.stop(label: label)
            if let error = result["error"] as? String { self.hud?.showError(error) }
        }
    }

    /// Stop if still recording, then ask where to save.
    func save() {
        cancelAutoHide()
        if let label = currentLiveLabel() {
            stopRequestedHere = true
            hud?.showBusy("Stopping…")
            Task { @MainActor in
                let result = await NetworkCapture.stop(label: label)
                guard let path = result["file"] as? String else {
                    self.hud?.showError(result["error"] as? String ?? "stop failed")
                    return
                }
                self.presentSavePanel(record: URL(fileURLWithPath: path),
                                      session: result["session"] as? String ?? "recording")
            }
        } else if let stopped {
            presentSavePanel(record: stopped.file, session: stopped.session)
        }
    }

    private func currentLiveLabel() -> String? {
        if let label = shownLabel,
           NetworkRecorder.shared.isRecording(labelKey: DevtoolsRelay.sanitize(label)) { return label }
        return NetworkRecorder.shared.live().last?.label
    }

    private func presentSavePanel(record: URL, session: String) {
        cancelAutoHide()
        let panel = NSSavePanel()
        panel.title = "Save Network Recording"
        panel.message = "Unredacted — the file holds cookies and auth tokens."
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let acc = SaveFormatAccessory(panel: panel)
        accessory = acc
        panel.accessoryView = acc.view
        panel.nameFieldStringValue = "\(session).\(acc.ext)"

        // FloatyTerm has no Dock icon; without activating, the panel opens
        // behind whatever app the user was recording.
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                defer { self.accessory = nil }
                guard response == .OK, var url = panel.url else {
                    self.hud?.showStopped(events: nil, label: nil, warning: nil)
                    return
                }
                let ext = acc.ext
                if url.pathExtension.lowercased() != ext {
                    url = url.deletingPathExtension().appendingPathExtension(ext)
                }
                acc.rememberChoice()
                let result = NetworkExport.run(record: record, format: ext, out: url,
                                               urlContains: nil, failedOnly: false, fullBodies: false)
                if let error = result["error"] as? String {
                    self.hud?.showError(error)
                } else {
                    self.hud?.showSaved(url: url, requests: result["requests"] as? Int ?? 0)
                    self.scheduleAutoHide(after: 8)
                }
            }
        }
    }

    // MARK: Plumbing

    private func makeHUD() -> NetworkRecordingHUD {
        let h = NetworkRecordingHUD()
        h.onStop = { [weak self] in self?.stop() }
        h.onSave = { [weak self] in self?.save() }
        h.onReveal = { url in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        h.onClose = { [weak self] in
            self?.cancelAutoHide()
            self?.hud?.dismiss()
            self?.hud = nil
            self?.stopped = nil
            self?.shownLabel = nil
        }
        hud = h
        return h
    }

    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private func scheduleAutoHide(after seconds: TimeInterval) {
        cancelAutoHide()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hud?.isHovered != true else { return }
                self.hud?.dismiss(); self.hud = nil
                self.stopped = nil; self.shownLabel = nil
            }
        }
        autoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func cancelAutoHide() { autoHide?.cancel(); autoHide = nil }
}

// MARK: - The pill

@MainActor
final class NetworkRecordingHUD {

    enum Mode { case recording, busy, stopped, saved, error }
    private(set) var mode: Mode = .recording

    var onStop: () -> Void = {}
    var onSave: () -> Void = {}
    var onClose: () -> Void = {}
    var onReveal: (URL) -> Void = { _ in }

    var isHovered: Bool { content.isHovered }

    private let panel: NSPanel
    private let content: HoverView
    private let dot = RecordingDot(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let stopBtn = HUDButton()
    private let saveBtn = HUDButton()
    private let revealBtn = HUDButton()
    private let closeBtn = HUDButton()
    private var savedURL: URL?
    private var moveObserver: NSObjectProtocol?

    private static let size = NSSize(width: 400, height: 44)
    private static let originKey = "NetworkRecordingHUD.origin"

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        // Draggable: wherever the default spot lands, it will cover something
        // in someone's layout. The position is remembered.
        panel.isMovableByWindowBackground = true

        content = HoverView(frame: NSRect(origin: .zero, size: Self.size))
        content.material = .hudWindow
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.size.height / 2
        content.layer?.masksToBounds = true
        panel.contentView = content

        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.setContentHuggingPriority(.required, for: .horizontal)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stopBtn.configure(title: "Stop", symbol: "stop.fill", tint: .systemRed, target: self, action: #selector(stopTapped))
        saveBtn.configure(title: "Save…", symbol: "square.and.arrow.down", tint: nil, target: self, action: #selector(saveTapped))
        revealBtn.configure(title: "Show", symbol: "folder", tint: nil, target: self, action: #selector(revealTapped))
        closeBtn.configure(title: nil, symbol: "xmark", tint: .secondaryLabelColor, target: self, action: #selector(closeTapped))
        closeBtn.toolTip = "Dismiss"
        // An image-only button's accessible name defaults to its symbol name
        // ("xmark") — say what it does instead.
        closeBtn.setAccessibilityLabel("Dismiss")

        dot.setContentHuggingPriority(.required, for: .horizontal)
        dot.widthAnchor.constraint(equalToConstant: 22).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let stack = NSStackView(views: [dot, title, detail, stopBtn, saveBtn, revealBtn, closeBtn])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        let originKey = Self.originKey   // read here: the observer's closure is not main-actor isolated
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak panel] _ in
            guard let origin = panel?.frame.origin else { return }
            UserDefaults.standard.set(NSStringFromPoint(origin), forKey: originKey)
        }
    }

    // MARK: States

    func showRecording(_ info: NetworkRecorder.Live, others: Int, animated: Bool) {
        let entering = mode != .recording || !panel.isVisible
        mode = .recording
        let t = NSMutableAttributedString(string: "REC", attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.systemFont(ofSize: 12, weight: .heavy)])
        t.append(NSAttributedString(string: "  \(info.label)", attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)]))
        title.attributedStringValue = t

        var parts = [Self.clock(Date().timeIntervalSince(info.startedAt)),
                     "\(info.events) req"]
        if info.failed > 0 { parts.append("\(info.failed) failed") }
        if others > 0 { parts.append("+\(others) more") }
        detail.stringValue = parts.joined(separator: " · ")
        detail.textColor = info.failed > 0 ? .systemOrange : .secondaryLabelColor

        if entering { dot.set(color: .systemRed, pulsing: true) }
        buttons(stop: true, save: true, reveal: false, close: false)
        present(animated: animated && entering)
    }

    func showBusy(_ text: String) {
        mode = .busy
        dot.set(color: .systemGray, pulsing: false)
        detail.stringValue = text
        detail.textColor = .secondaryLabelColor
        buttons(stop: false, save: false, reveal: false, close: false)
    }

    /// nil events/label keep what the pill already says (a cancelled save).
    func showStopped(events: Int?, label: String?, warning: String?) {
        mode = .stopped
        dot.set(color: .systemGray, pulsing: false)
        if let label {
            title.attributedStringValue = NSAttributedString(string: "Stopped", attributes: [
                .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
            let count = events.map { "\($0) request\($0 == 1 ? "" : "s")" } ?? ""
            detail.stringValue = [count, label].filter { !$0.isEmpty }.joined(separator: " · ")
            detail.textColor = .secondaryLabelColor
        }
        if let warning, events == 0 {
            detail.stringValue = "nothing captured"
            detail.textColor = .systemOrange
            detail.toolTip = warning
        }
        buttons(stop: false, save: true, reveal: false, close: true)
        present(animated: false)
    }

    func showSaved(url: URL, requests: Int) {
        mode = .saved
        savedURL = url
        dot.set(color: .systemGreen, pulsing: false)
        title.attributedStringValue = NSAttributedString(string: "Saved", attributes: [
            .foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        detail.stringValue = "\(url.lastPathComponent) · \(requests) req"
        detail.textColor = .secondaryLabelColor
        detail.toolTip = url.path
        buttons(stop: false, save: false, reveal: true, close: true)
        present(animated: false)
    }

    func showError(_ message: String) {
        mode = .error
        dot.set(color: .systemOrange, pulsing: false)
        detail.stringValue = message
        detail.textColor = .systemOrange
        detail.toolTip = message
        buttons(stop: false, save: true, reveal: false, close: true)
        present(animated: false)
    }

    func dismiss() {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        moveObserver = nil
        let panel = self.panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
    }

    // MARK: Layout

    private func buttons(stop: Bool, save: Bool, reveal: Bool, close: Bool) {
        stopBtn.isHidden = !stop
        saveBtn.isHidden = !save
        revealBtn.isHidden = !reveal
        closeBtn.isHidden = !close
    }

    /// The entrance is the "recording has started" signal: the pill rises and
    /// fades in while the dot starts its ripple. Later updates change text only.
    private func present(animated: Bool) {
        let target = NSRect(origin: restingOrigin(), size: Self.size)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            if !panel.isVisible { panel.setFrame(target, display: true) }
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        panel.setFrame(target.offsetBy(dx: 0, dy: -14), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    /// Where the user last dragged it, if that spot is still on a screen;
    /// otherwise bottom-centre, clear of Chrome's tab strip and address bar.
    private func restingOrigin() -> NSPoint {
        if panel.isVisible { return panel.frame.origin }
        if let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let p = NSPointFromString(saved)
            let rect = NSRect(origin: p, size: Self.size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { return p }
        }
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSPoint(x: screen.midX - Self.size.width / 2, y: screen.minY + 28)
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    @objc private func stopTapped() { onStop() }
    @objc private func saveTapped() { onSave() }
    @objc private func closeTapped() { onClose() }
    @objc private func revealTapped() { if let savedURL { onReveal(savedURL) } }
}

// MARK: - Pieces

/// The recording light: a solid core that breathes, plus a ring that ripples
/// outward — readable from the corner of an eye while working in another app.
/// Honors Reduce Motion (breathing only, no ripple).
private final class RecordingDot: NSView {
    private let core = CALayer()
    private let ring = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        ring.borderWidth = 1.5
        ring.opacity = 0
        layer?.addSublayer(ring)
        layer?.addSublayer(core)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        for l in [core, ring] {
            l.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
            l.cornerRadius = 5
            l.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    func set(color: NSColor, pulsing: Bool) {
        core.backgroundColor = color.cgColor
        ring.borderColor = color.cgColor
        core.removeAllAnimations()
        ring.removeAllAnimations()
        ring.opacity = 0
        guard pulsing else { return }

        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.35
        breathe.duration = 0.9
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        core.add(breathe, forKey: "breathe")

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8
        fade.toValue = 0
        let ripple = CAAnimationGroup()
        ripple.animations = [grow, fade]
        ripple.duration = 1.6
        ripple.repeatCount = .infinity
        ripple.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.add(ripple, forKey: "ripple")
    }
}

/// Buttons in a non-activating, never-key panel only get their first click if
/// they accept first mouse — NSButton does not by default.
private final class HUDButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(title: String?, symbol: String, tint: NSColor?, target: AnyObject, action: Selector) {
        self.title = title ?? ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title ?? symbol)
        imagePosition = title == nil ? .imageOnly : .imageLeading
        bezelStyle = .inline
        controlSize = .small
        font = .systemFont(ofSize: 11, weight: .medium)
        contentTintColor = tint
        self.target = target
        self.action = action
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
}

/// Tracks the pointer so an auto-hide never yanks the pill from under a
/// user who is about to click it.
private final class HoverView: NSVisualEffectView {
    private(set) var isHovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// The format picker in the save panel. Switching format rewrites the file
/// extension in the name field, and the choice is remembered for next time.
private final class SaveFormatAccessory: NSObject {
    static let formats: [(title: String, ext: String)] = [("Markdown", "md"), ("JSON", "json"), ("HAR (Chrome DevTools)", "har")]
    private static let key = "NetworkRecordingHUD.format"

    let view: NSView
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var panel: NSSavePanel?

    var ext: String { Self.formats[max(0, popup.indexOfSelectedItem)].ext }

    init(panel: NSSavePanel) {
        self.panel = panel
        let label = NSTextField(labelWithString: "Format:")
        popup.addItems(withTitles: Self.formats.map(\.title))
        let saved = UserDefaults.standard.string(forKey: Self.key)
        popup.selectItem(at: Self.formats.firstIndex { $0.ext == saved } ?? 0)
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view = row
        super.init()
        popup.target = self
        popup.action = #selector(changed)
    }

    @objc private func changed() {
        guard let panel else { return }
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base).\(ext)"
    }

    func rememberChoice() { UserDefaults.standard.set(ext, forKey: Self.key) }
}
