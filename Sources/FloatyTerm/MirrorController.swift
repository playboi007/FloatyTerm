import AppKit
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Live-mirrors another app's window into a FloatyTerm tab via ScreenCaptureKit.
///
/// The point: while you're in one app's fullscreen Space, summon FloatyTerm over
/// it and glance at another app (e.g. Cursor) without leaving the Space — the
/// panel already floats over fullscreen via `FloatingPanel`; this tab supplies
/// the live picture.
///
/// Shape mirrors `BrowserController` / `DiffViewerController` — a non-terminal
/// `TabContent`:
///  - ephemeral (`restorableRecord = nil`): window IDs aren't stable across
///    launches and the source app may not even be running next time.
///  - never self-terminates (`onTerminated` kept only for protocol conformance);
///    a closed source window shows an in-tab message, it doesn't yank the tab.
///  - KVO-style title: the title is "<App> — <window title>", pushed via
///    `onTitleChanged?()` when a source is picked.
///
/// Capture is PAUSED whenever the tab isn't the visible active tab. The window
/// machinery already toggles `isCurrentlyViewed` on show/hide/tab-switch/collapse
/// (`TerminalWindowController.updateViewedFlags()`), so that flag IS the
/// pause/resume signal — no extra lifecycle hooks. Pausing stops the `SCStream`,
/// which frees its IOSurface pool (~tens of MB per Retina frame × queueDepth).
final class MirrorController: NSObject, TabContent, SCStreamOutput, SCStreamDelegate {

    // MARK: - TabContent

    let view: NSView                      // container; hosts picker / mirror / message
    private(set) var title: String = "Mirror"
    var onTitleChanged: (() -> Void)?
    var onTerminated: (() -> Void)?       // mirrors never self-terminate; kept for protocol

    var customName: String?
    var displayName: String {
        if let n = customName, !n.isEmpty { return n }
        return title
    }

    /// A mirror has no "unseen output" concept — it's a live view, not a log.
    let hasUnseenOutput = false

    /// Drives pause/resume. Defaults to `false` (unlike Browser) so capture only
    /// begins once the tab is actually the visible active tab AND laid out with a
    /// valid backing scale — `updateViewedFlags()` flips it true on first show.
    var isCurrentlyViewed = false {
        didSet {
            guard isCurrentlyViewed != oldValue else { return }
            if isCurrentlyViewed { startCaptureIfNeeded() } else { stopCapture() }
        }
    }

    /// Ephemeral: a live mirror carries nothing worth restoring next launch.
    var restorableRecord: TabRecord? { nil }

    // MARK: - Source + capture state

    private var selectedWindow: SCWindow?           // retained to rebuild the filter
    private var pickerWindows: [SCWindow] = []       // index = NSButton.tag in the picker

    private var stream: SCStream?
    private var isStarting = false                   // guards against overlapping starts
    private var lastConfiguredSize: CGSize = .zero
    private let frameQueue = DispatchQueue(label: "vin.floatyterm.mirror.frames")

    /// Keeps the on-screen frame's pixel buffer alive until the next frame
    /// replaces it. Without this the IOSurface handed to the layer can be
    /// recycled back into SCK's pool before CA reads it → blank/torn frames.
    private var displayedBuffer: CVPixelBuffer?
    private var loggedFirstFrame = false             // log only the first frame per (re)start
    private var lastLoggedStatus: SCFrameStatus?     // avoid status-log spam

    private let mirrorView = MirrorView()

    // MARK: - Resize debounce

    private var resizeWork: DispatchWorkItem?

    // MARK: - Init

    override init() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.view = container
        super.init()

        // Re-capture at the new resolution as the tab grows (sharper, not upscaled),
        // and kick off the first capture once the view finally has a size.
        mirrorView.onGeometryChanged = { [weak self] in self?.viewGeometryChanged() }

        // A frame-rate toggle in Settings should take effect on a live mirror
        // without reopening the tab.
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChange, object: nil)

        // Permission gate up front: skip the throw-and-recover dance if we already
        // know we're not authorized. Either way the user lands on a clear screen.
        if CGPreflightScreenCaptureAccess() {
            loadWindows()
        } else {
            showPermissionState()
        }
    }

    // MARK: - Window enumeration (picker)

    private func loadWindows() {
        showMessage(title: "Loading windows…", detail: nil, actions: [])
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // onScreenWindowsOnly:false is essential — the window you want may
                // be off-screen on another fullscreen Space.
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
                let ownBundle = Bundle.main.bundleIdentifier
                let windows = content.windows.filter { w in
                    w.windowLayer == 0                                   // normal windows only
                    && (w.title?.isEmpty == false)                       // skip chrome/helpers
                    && w.frame.width > 80 && w.frame.height > 80         // skip tiny status windows
                    && w.owningApplication != nil
                    && w.owningApplication?.bundleIdentifier != ownBundle // don't mirror ourselves
                }
                self.presentPicker(windows)
            } catch {
                // A throw here almost always means Screen Recording isn't granted.
                self.showPermissionState()
            }
        }
    }

    private func presentPicker(_ windows: [SCWindow]) {
        pickerWindows = windows

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let intro = NSTextField(labelWithString: "Pick a window to mirror")
        intro.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(intro)

        if windows.isEmpty {
            let empty = NSTextField(labelWithString:
                "No windows found. Open an app, then choose Refresh.")
            empty.textColor = .secondaryLabelColor
            empty.lineBreakMode = .byWordWrapping
            stack.addArrangedSubview(empty)
        }

        // Group by owning app, preserving first-seen order.
        var order: [String] = []
        var byApp: [String: [Int]] = [:]
        for (i, w) in windows.enumerated() {
            let app = w.owningApplication?.applicationName ?? "Unknown"
            if byApp[app] == nil { byApp[app] = []; order.append(app) }
            byApp[app]?.append(i)
        }
        for app in order {
            let header = NSTextField(labelWithString: app)
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .secondaryLabelColor
            stack.setCustomSpacing(10, after: stack.arrangedSubviews.last ?? header)
            stack.addArrangedSubview(header)
            for idx in byApp[app] ?? [] {
                let w = windows[idx]
                let title = (w.title?.isEmpty == false) ? w.title! : "(untitled window)"
                // Leading "· " gives a light indent under the app header without
                // adding a constraint that would fight NSStackView's own alignment.
                let btn = NSButton(title: "·  " + title, target: self,
                                   action: #selector(pickWindow(_:)))
                btn.tag = idx
                btn.isBordered = false
                btn.alignment = .left
                btn.contentTintColor = .labelColor
                btn.font = .systemFont(ofSize: 12)
                btn.focusRingType = .none
                btn.lineBreakMode = .byTruncatingTail
                stack.addArrangedSubview(btn)
            }
        }

        let refresh = NSButton(title: "Refresh list", target: self,
                               action: #selector(refreshTapped))
        refresh.bezelStyle = .rounded
        stack.setCustomSpacing(14, after: stack.arrangedSubviews.last ?? refresh)
        stack.addArrangedSubview(refresh)

        setContent(scrollWrapped(stack))
    }

    @objc private func pickWindow(_ sender: NSButton) {
        guard pickerWindows.indices.contains(sender.tag) else { return }
        selectWindow(pickerWindows[sender.tag])
    }

    @objc private func refreshTapped() { loadWindows() }

    private func selectWindow(_ w: SCWindow) {
        selectedWindow = w
        let app = w.owningApplication?.applicationName ?? "Window"
        let win = (w.title?.isEmpty == false) ? w.title! : ""
        title = win.isEmpty ? app : "\(app) — \(win)"
        onTitleChanged?()

        setContent(mirrorView)
        // Start now if already visible; otherwise the first layout / next show()
        // (via isCurrentlyViewed) will kick it off.
        startCaptureIfNeeded()
    }

    // MARK: - Capture configuration

    private func makeConfiguration(pixelSize: CGSize) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width  = max(2, Int(pixelSize.width.rounded()))
        c.height = max(2, Int(pixelSize.height.rounded()))
        // Frame-rate cap. SCK won't emit duplicate frames for a static source, so
        // a low cap is genuinely cheap when nothing's moving.
        let fps: Int32 = Settings.shared.mirrorSmoothCapture ? 30 : 12
        c.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth  = 5
        c.scalesToFit = true                     // fit the window into the buffer, keep aspect
        return c
    }

    /// The capture buffer size that matches the view at native (Retina) pixels,
    /// so growing the tab re-captures sharper instead of upscaling.
    private func currentPixelSize() -> CGSize {
        let scale = mirrorView.window?.backingScaleFactor
            ?? mirrorView.layer?.contentsScale ?? 2
        let b = mirrorView.bounds.size
        return CGSize(width: b.width * scale, height: b.height * scale)
    }

    // MARK: - Start / stop (driven by isCurrentlyViewed; called on main)

    private func startCaptureIfNeeded() {
        guard isCurrentlyViewed, stream == nil, !isStarting,
              let w = selectedWindow else { return }
        let size = currentPixelSize()
        guard size.width >= 2, size.height >= 2 else { return }  // not laid out yet
        isStarting = true
        loggedFirstFrame = false
        lastLoggedStatus = nil
        let config = makeConfiguration(pixelSize: size)
        NSLog("[Mirror] start attempt %dx%d for window '%@'",
              config.width, config.height, w.title ?? "?")

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let filter = SCContentFilter(desktopIndependentWindow: w)
                let s = SCStream(filter: filter, configuration: config, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.frameQueue)
                try await s.startCapture()
                self.isStarting = false
                // The user may have switched away while we were starting up.
                guard self.isCurrentlyViewed, self.selectedWindow === w else {
                    try? await s.stopCapture()
                    return
                }
                self.stream = s
                self.lastConfiguredSize = size
                NSLog("[Mirror] startCapture OK")
            } catch {
                self.isStarting = false
                NSLog("[Mirror] startCapture FAILED: %@", error.localizedDescription)
                self.handleFailure(error)
            }
        }
    }

    private func stopCapture() {
        guard let s = stream else { return }
        stream = nil                              // late frames drop (identity check below)
        Task { try? await s.stopCapture() }       // releases the IOSurface pool
        displayedBuffer = nil
        NSLog("[Mirror] stop")
        clearMirrorContents()
    }

    // MARK: - Resize → live reconfigure (no flicker; macOS 14+ updateConfiguration)

    private func viewGeometryChanged() {
        if stream == nil {
            startCaptureIfNeeded()                // first valid layout starts capture
        } else {
            scheduleResizeReconfigure()
        }
    }

    private func scheduleResizeReconfigure() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconfigureForResize() }
        resizeWork = work
        // Debounce: a live edge-drag fires many layout passes; reconfigure once it settles.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func reconfigureForResize() {
        guard let s = stream else { return }
        let size = currentPixelSize()
        guard size.width >= 2, size.height >= 2 else { return }
        // Skip sub-threshold churn (sub-pixel jitter, tiny nudges).
        guard abs(size.width - lastConfiguredSize.width) > 16
           || abs(size.height - lastConfiguredSize.height) > 16 else { return }
        lastConfiguredSize = size
        let config = makeConfiguration(pixelSize: size)
        Task { try? await s.updateConfiguration(config) }
    }

    @objc private func settingsChanged() {
        // Re-apply the frame-rate toggle to a running stream in place.
        guard let s = stream else { return }
        let config = makeConfiguration(pixelSize: lastConfiguredSize)
        Task { try? await s.updateConfiguration(config) }
    }

    // MARK: - Frame delivery (on frameQueue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Frame status tells us whether this carries new pixels. Only `.complete`
        // does; `.idle` means "unchanged, keep showing the last frame"; `.blank`/
        // `.suspended` mean the source isn't being rendered (e.g. a fullscreen app
        // sitting on another, non-visible Space — the macOS off-Space limitation).
        // Painting only `.complete` avoids blanking a good image with an idle one.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            if status != lastLoggedStatus {
                lastLoggedStatus = status
                NSLog("[Mirror] frame status=%d (not painting — source may be off-Space)", raw)
            }
            return
        }
        lastLoggedStatus = .complete

        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(px)?.takeUnretainedValue()
        else { return }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)

        DispatchQueue.main.async { [weak self] in
            // Drop frames from a stream we've already torn down (pause / resize).
            guard let self, self.stream === stream else { return }
            if !self.loggedFirstFrame {
                self.loggedFirstFrame = true
                NSLog("[Mirror] first frame painted %dx%d", w, h)
            }
            self.displayedBuffer = px                      // keep alive until next frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)          // no per-frame fade
            self.mirrorView.frameLayer.contents = surface  // zero-copy IOSurface
            CATransaction.commit()
        }
    }

    // MARK: - Stream delegate (internal queue → hop to main)

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.clearMirrorContents()
            self.showMessage(
                title: "Source window closed",
                detail: "The window you were mirroring is gone.",
                actions: [("Pick another window", { [weak self] in self?.loadWindows() })])
        }
    }

    // MARK: - States: permission / message overlays

    private func showPermissionState() {
        showMessage(
            title: "Screen Recording needed",
            detail: "FloatyTerm needs Screen Recording permission to mirror a window.",
            actions: [
                ("Enable Screen Recording", { [weak self] in
                    if ContextSnap.ensurePermission(
                        purpose: "Window mirroring shows another app's window live inside this tab."
                    ) { self?.loadWindows() }
                }),
            ])
    }

    private func handleFailure(_ error: Error) {
        stream = nil
        clearMirrorContents()
        // Most start failures are a revoked/again-needed permission.
        showMessage(
            title: "Couldn't start mirroring",
            detail: "It may need Screen Recording permission, or the window closed.",
            actions: [
                ("Enable Screen Recording", { [weak self] in
                    if ContextSnap.ensurePermission(
                        purpose: "Window mirroring shows another app's window live inside this tab."
                    ) { self?.loadWindows() }
                }),
                ("Pick another window", { [weak self] in self?.loadWindows() }),
            ])
    }

    /// Centered title + detail + zero or more action buttons.
    private func showMessage(title: String, detail: String?,
                             actions: [(String, () -> Void)]) {
        messageActions = actions.map { $0.1 }   // retained by tag → closure lookup

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: 14)
        titleLabel.alignment = .center
        stack.addArrangedSubview(titleLabel)

        if let detail {
            let d = NSTextField(wrappingLabelWithString: detail)
            d.alignment = .center
            d.textColor = .secondaryLabelColor
            d.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true
            stack.addArrangedSubview(d)
        }

        for (i, action) in actions.enumerated() {
            let btn = NSButton(title: action.0, target: self,
                               action: #selector(messageActionTapped(_:)))
            btn.bezelStyle = .rounded
            btn.tag = i
            stack.addArrangedSubview(btn)
        }

        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -16),
        ])
        setContent(host)
    }

    private var messageActions: [() -> Void] = []

    @objc private func messageActionTapped(_ sender: NSButton) {
        guard messageActions.indices.contains(sender.tag) else { return }
        messageActions[sender.tag]()
    }

    // MARK: - View helpers

    /// Replaces the container's content with `child`, pinned to all edges.
    private func setContent(_ child: NSView) {
        view.subviews.forEach { $0.removeFromSuperview() }
        child.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: view.topAnchor),
            child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// Wraps a stack in a top-anchored, vertically-scrolling container.
    private func scrollWrapped(_ content: NSView) -> NSScrollView {
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: doc.topAnchor),
            content.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: doc.bottomAnchor),
        ])

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        return scroll
    }

    private func clearMirrorContents() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mirrorView.frameLayer.contents = nil
        CATransaction.commit()
    }

    // MARK: - TabContent focus / cleanup

    func focus(in panel: NSWindow) {
        panel.makeFirstResponder(view)
    }

    func cleanup() {
        resizeWork?.cancel(); resizeWork = nil
        NotificationCenter.default.removeObserver(self)
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }   // releases the IOSurface pool
        displayedBuffer = nil
        clearMirrorContents()
        selectedWindow = nil
        pickerWindows = []
    }
}

// MARK: - Mirror surface view

/// Layer-backed host whose dedicated `frameLayer` shows the captured IOSurface.
/// Reports geometry changes (resize and Retina/non-Retina moves) so the
/// controller can re-capture at the matching pixel size.
private final class MirrorView: NSView {

    let frameLayer = CALayer()
    var onGeometryChanged: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear            // letterbox gutters show the panel blur
        frameLayer.contentsGravity = .resizeAspect // preserve the source's aspect ratio
        frameLayer.backgroundColor = .clear
        layer?.addSublayer(frameLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frameLayer.frame = bounds
        CATransaction.commit()
        onGeometryChanged?()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            layer?.contentsScale = scale
            frameLayer.contentsScale = scale
        }
        onGeometryChanged?()
    }
}

/// Flipped container so a stacked picker lays out top-down inside a scroll view.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
