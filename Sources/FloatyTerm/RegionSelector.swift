import AppKit

/// A ⇧⌘4-style region picker: a full-screen crosshair overlay on the target
/// screen. Drag a rectangle to select it (dim outside, clear inside), click
/// without dragging for "everything behind", Esc to cancel.
///
/// The overlay floats above everything (screenSaver level, joins all Spaces),
/// and because capture excludes windows above the floating terminal, the
/// overlay's dimming never appears in the snap.
final class RegionSelector {
    private static var current: RegionSelector?

    private let panel: NSPanel
    /// nil = cancelled; .zero = plain click (full screen); else the selected
    /// rect in AppKit GLOBAL screen coordinates.
    private let completion: (NSRect?) -> Void

    static func begin(on screen: NSScreen?, completion: @escaping (NSRect?) -> Void) {
        guard current == nil else { completion(nil); return }
        guard let screen = screen ?? NSScreen.main else { completion(nil); return }
        current = RegionSelector(screen: screen, completion: completion)
    }

    private init(screen: NSScreen, completion: @escaping (NSRect?) -> Void) {
        self.completion = completion

        let p = OverlayPanel(contentRect: screen.frame,
                             styleMask: [.nonactivatingPanel, .borderless],
                             backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        panel = p

        let view = RegionSelectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onDone = { [weak self] rectInWindow in
            guard let self else { return }
            let result: NSRect?
            if let r = rectInWindow {
                result = r.isEmpty ? .zero : self.panel.convertToScreen(r)
            } else {
                result = nil
            }
            self.finish(result)
        }
        p.contentView = view
        p.orderFrontRegardless()
        p.makeKey()
        p.makeFirstResponder(view)
    }

    private func finish(_ rect: NSRect?) {
        panel.orderOut(nil)
        Self.current = nil
        completion(rect)
    }
}

/// Borderless panels refuse key status by default; Esc handling needs it.
private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class RegionSelectView: NSView {
    /// Rect in WINDOW coordinates; .zero for a plain click; nil for Esc.
    var onDone: ((NSRect?) -> Void)?

    private var startPoint: NSPoint?
    private var selectionRect: NSRect = .zero
    private var dragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let hint = NSTextField(labelWithString:
            "Drag to select an area  ·  click for everything behind  ·  esc to cancel")
        hint.font = .systemFont(ofSize: 13, weight: .medium)
        hint.textColor = .white
        hint.backgroundColor = NSColor(white: 0, alpha: 0.55)
        hint.drawsBackground = true
        hint.alignment = .center
        hint.wantsLayer = true
        hint.layer?.cornerRadius = 6
        hint.layer?.masksToBounds = true
        hint.sizeToFit()
        let pad: CGFloat = 14
        hint.frame = NSRect(x: (frameRect.width - hint.frame.width - pad * 2) / 2,
                            y: frameRect.height - 70,
                            width: hint.frame.width + pad * 2,
                            height: hint.frame.height + 10)
        hint.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0, alpha: 0.25).setFill()
        bounds.fill()
        guard dragging, !selectionRect.isEmpty else { return }
        // Punch the selection clear so the underlying screen shows undimmed.
        NSColor.clear.setFill()
        selectionRect.fill(using: .copy)
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1.5
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        dragging = false
        selectionRect = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !dragging, hypot(p.x - start.x, p.y - start.y) < 4 { return }
        dragging = true
        selectionRect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y),
                               width: abs(p.x - start.x), height: abs(p.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { startPoint = nil; dragging = false }
        if dragging, selectionRect.width > 4, selectionRect.height > 4 {
            onDone?(convert(selectionRect, to: nil))   // → window coords
        } else {
            onDone?(.zero)   // plain click = full screen behind
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // Esc
            onDone?(nil)
        }
    }
}
