import AppKit

extension Notification.Name {
    /// Posted when the `ruler` terminal helper (or any other path) wants the
    /// on-screen ruler summoned. AppDelegate observes it and toggles the panel.
    static let floatySummonRuler = Notification.Name("FloatyTermSummonRuler")
}

/// Installs and locates FloatyTerm's PATH-injected shell helpers. Each helper
/// is a tiny executable that just emits a private OSC sequence the terminal
/// parser intercepts (see `TerminalController.handleOSC`), so commands like
/// `ruler` work in any shell with zero setup and never print "command not
/// found". `TerminalController.startShell` prepends `binDirectory()` to PATH.
enum TerminalCommandTools {
    /// Private OSC code FloatyTerm reserves for its helper commands:
    /// `ESC ] 5152 ; <name> BEL`. 5152 is well outside the standard OSC range
    /// terminals assign meaning to, so it won't collide with real sequences.
    static let oscCode = "5152"

    /// `~/Library/Application Support/FloatyTerm/bin`, with helpers installed.
    /// Returns nil only if Application Support can't be located.
    static func binDirectory() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = appSupport.appendingPathComponent("FloatyTerm/bin", isDirectory: true)
        install(in: dir)
        return dir
    }

    /// Writes the helper scripts (idempotent; rewritten each launch so their
    /// payloads stay in sync with the app).
    private static func install(in dir: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        write(name: "ruler", in: dir)
    }

    private static func write(name: String, in dir: URL) {
        let script = "#!/bin/sh\nprintf '\\033]\(oscCode);\(name)\\007'\n"
        let url = dir.appendingPathComponent(name)
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

/// Owns the single free-floating ruler panel and toggles it on summon (from the
/// Utils menu or the `ruler` terminal command).
final class RulerController {
    private var panel: RulerPanel?

    /// Show the ruler if hidden, hide it if already visible — re-summoning is a
    /// toggle, which matches both a menu re-click and typing `ruler` again.
    func toggle() {
        if let p = panel, p.isVisible {
            p.orderOut(nil)
            return
        }
        let p = panel ?? RulerPanel()
        panel = p
        // Match the app-wide screen-capture privacy setting, like every other
        // FloatyTerm surface.
        p.sharingType = Settings.shared.hideFromScreenCapture ? .none : .readOnly
        if !p.hasBeenShown { p.placeForInitialShow() }
        p.orderFrontRegardless()
        p.makeKey()
    }
}

/// A free-floating, horizontally-resizable measuring ruler. Borrows the
/// floating-strip chassis from `TickerPanel` (status-bar level, all Spaces,
/// frosted) but drops the terminal feed — it measures screen points, not
/// output. Drag the body to move; drag the right edge to widen and reveal more
/// measurements. A pencil toggle expands it downward into an annotation strip.
final class RulerPanel: NSPanel {
    static let rulerHeight: CGFloat = 48
    static let stripHeight: CGFloat = 132
    static let defaultWidth: CGFloat = 680

    private(set) var hasBeenShown = false
    private let content: RulerContentView

    init() {
        let size = NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.rulerHeight)
        content = RulerContentView(frame: size)
        super.init(contentRect: size,
                   styleMask: [.nonactivatingPanel, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isFloatingPanel = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true     // needed for the shift-hover magnifier
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // Free horizontal resize; height is pinned to the current mode (ruler,
        // or ruler+strip) so dragging an edge only ever changes the width.
        contentMinSize = NSSize(width: 240, height: Self.rulerHeight)
        contentMaxSize = NSSize(width: .greatestFiniteMagnitude, height: Self.rulerHeight)

        content.panel = self
        contentView = content
    }

    override var canBecomeKey: Bool { true }   // so annotation fields can be typed in
    override var canBecomeMain: Bool { false }

    func placeForInitialShow() {
        hasBeenShown = true
        let vis = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: vis.midX - frame.width / 2, y: vis.maxY - frame.height - 80)
        setFrameOrigin(origin)
    }

    /// Pins/locks the height to `h` (so edge-drag stays horizontal) and grows
    /// the panel downward to match — used when the annotation strip toggles.
    func lockHeight(_ h: CGFloat) {
        contentMinSize.height = h
        contentMaxSize.height = h
        var f = frame
        let delta = h - f.height
        f.size.height = h
        f.origin.y -= delta            // grow toward the bottom of the screen
        setFrame(f, display: true, animate: true)
    }
}

/// Container: frosted backdrop + the drawing/interaction canvas + the pencil
/// toggle. Kept thin — all geometry lives in `RulerCanvas`.
final class RulerContentView: NSView {
    weak var panel: RulerPanel? {
        didSet { canvas.panel = panel }
    }

    private let blur = NSVisualEffectView()
    private let canvas = RulerCanvas()
    private let pencil = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        blur.autoresizingMask = [.width, .height]
        blur.frame = bounds
        addSubview(blur)

        canvas.autoresizingMask = [.width, .height]
        canvas.frame = bounds
        addSubview(canvas)            // above the blur so ticks composite on top

        // Pencil: toggles the annotation strip. Pinned to the bottom-left.
        pencil.bezelStyle = .regularSquare
        pencil.isBordered = false
        pencil.image = NSImage(systemSymbolName: "square.and.pencil",
                               accessibilityDescription: "Annotate")
        pencil.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        pencil.target = self
        pencil.action = #selector(togglePencil)
        pencil.toolTip = "Add reference notes along the ruler"
        pencil.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pencil)
        NSLayoutConstraint.activate([
            pencil.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            pencil.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            pencil.widthAnchor.constraint(equalToConstant: 22),
            pencil.heightAnchor.constraint(equalToConstant: 20)
        ])

        toolTip = "Drag to move · drag right edge to widen · hold ⇧ to magnify"
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func togglePencil() {
        canvas.setAnnotating(!canvas.annotating)
        pencil.contentTintColor = canvas.annotating
            ? NSColor.controlAccentColor
            : NSColor.white.withAlphaComponent(0.75)
    }
}

/// Does the real work: draws ticks/labels from its own width, hosts annotation
/// markers, and renders the shift-hover magnifier. Flipped so y grows downward
/// — the ruler band sits at the top (ticks hang down) and the annotation strip
/// below it.
final class RulerCanvas: NSView {
    weak var panel: RulerPanel?

    private(set) var annotating = false

    /// A reference note pinned to an exact point on the ruler.
    private struct Marker {
        let id = UUID()
        var point: CGFloat          // distance in points from the left edge (x = 0)
        let field: NSTextField
    }
    private var markers: [Marker] = []

    private var hover: NSPoint?
    private var shiftDown = false
    private var magnifying: Bool { shiftDown && hover != nil }

    private let minor: CGFloat = 10
    private let mid: CGFloat = 50
    private let major: CGFloat = 100

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Annotation mode

    func setAnnotating(_ on: Bool) {
        annotating = on
        markers.forEach { $0.field.isHidden = !on }
        panel?.lockHeight(on ? RulerPanel.rulerHeight + RulerPanel.stripHeight
                             : RulerPanel.rulerHeight)
        needsDisplay = true
    }

    private func addMarker(at x: CGFloat) {
        let field = NSTextField(frame: .zero)
        field.placeholderString = "note…"
        field.font = .systemFont(ofSize: 11)
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.drawsBackground = true
        field.delegate = self
        addSubview(field)
        markers.append(Marker(point: x, field: field))
        layoutMarkers()
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func removeMarker(for field: NSTextField) {
        field.removeFromSuperview()
        markers.removeAll { $0.field === field }
        needsDisplay = true
    }

    private func layoutMarkers() {
        let w: CGFloat = 132, h: CGFloat = 22
        let top = RulerPanel.rulerHeight + 10
        for (i, m) in markers.enumerated() {
            // Two staggered rows so neighbouring notes don't fully overlap.
            let row = CGFloat(i % 2)
            let x = min(max(m.point, 4), max(4, bounds.width - w - 4))
            m.field.frame = NSRect(x: x, y: top + row * 30, width: w, height: h)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutMarkers()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        drawTicks(in: ctx, width: bounds.width)
        if annotating { drawMarkerGuides(in: ctx) }
        if magnifying, let h = hover { drawCrosshair(in: ctx, at: h); drawLoupe(in: ctx, at: h) }
    }

    private func drawTicks(in ctx: CGContext, width w: CGFloat) {
        let tick = NSColor.white.withAlphaComponent(0.7)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        ctx.setStrokeColor(tick.cgColor)
        var x: CGFloat = 0
        while x <= w {
            let isMajor = x.truncatingRemainder(dividingBy: major) == 0
            let isMid = x.truncatingRemainder(dividingBy: mid) == 0
            let len: CGFloat = isMajor ? 16 : (isMid ? 11 : 6)
            ctx.setLineWidth(isMajor ? 1.0 : 0.75)
            ctx.move(to: CGPoint(x: x + 0.5, y: 0))
            ctx.addLine(to: CGPoint(x: x + 0.5, y: len))
            ctx.strokePath()
            if isMajor {
                let s = NSAttributedString(string: "\(Int(x))", attributes: labelAttrs)
                let lx = min(max(x + 2, 1), w - s.size().width - 1)
                s.draw(at: CGPoint(x: lx, y: 19))
            }
            x += minor
        }
    }

    private func drawMarkerGuides(in ctx: CGContext) {
        let accent = NSColor.controlAccentColor
        for m in markers {
            let x = m.point + 0.5
            ctx.setStrokeColor(accent.withAlphaComponent(0.5).cgColor)
            ctx.setLineWidth(1)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: m.field.frame.minY))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            // Solid dot at the measured point.
            accent.setFill()
            ctx.fillEllipse(in: CGRect(x: m.point - 2.5, y: 0, width: 5, height: 5))
        }
    }

    private func drawCrosshair(in ctx: CGContext, at p: NSPoint) {
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: p.x + 0.5, y: 0))
        ctx.addLine(to: CGPoint(x: p.x + 0.5, y: RulerPanel.rulerHeight))
        ctx.strokePath()
    }

    /// A compact iOS-style lens: a rounded pill near the cursor showing the
    /// ticks around it horizontally magnified, plus the exact point value.
    private func drawLoupe(in ctx: CGContext, at p: NSPoint) {
        let lensW: CGFloat = 140
        let lensH: CGFloat = min(40, bounds.height)
        let zoom: CGFloat = 2.6
        let cx = min(max(p.x, lensW / 2 + 2), bounds.width - lensW / 2 - 2)
        let rect = CGRect(x: cx - lensW / 2, y: 3, width: lensW, height: lensH)
        let pill = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)

        NSColor(white: 0.06, alpha: 0.94).setFill()
        pill.fill()
        NSColor.white.withAlphaComponent(0.22).setStroke()
        pill.lineWidth = 1
        pill.stroke()

        ctx.saveGState()
        pill.addClip()
        // Magnify only horizontally around the cursor — spreads the ticks out
        // like a loupe while keeping their height readable.
        ctx.translateBy(x: p.x, y: rect.minY + 2)
        ctx.scaleBy(x: zoom, y: 1)
        ctx.translateBy(x: -p.x, y: 0)
        drawTicks(in: ctx, width: bounds.width)
        ctx.restoreGState()

        let value = NSAttributedString(string: "\(Int(p.x.rounded())) px", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white
        ])
        value.draw(at: CGPoint(x: cx - value.size().width / 2, y: rect.maxY - 15))
    }

    // MARK: Mouse / modifiers

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        hover = convert(event.locationInWindow, from: nil)
        shiftDown = event.modifierFlags.contains(.shift)
        if shiftDown { needsDisplay = true } else if hover != nil { needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        shiftDown = event.modifierFlags.contains(.shift)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // In annotate mode, a click on the ruler band drops a reference note.
        if annotating && p.y <= RulerPanel.rulerHeight {
            addMarker(at: p.x)
            return
        }
        window?.performDrag(with: event)   // otherwise drag the panel around
    }
}

extension RulerCanvas: NSTextFieldDelegate {
    /// An empty note that loses focus is discarded — clicking the ruler then
    /// typing nothing shouldn't leave a stray marker behind.
    func controlTextDidEndEditing(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        if field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
            removeMarker(for: field)
        }
    }
}
