import AppKit

/// A "hero" morph between two on-screen frames. A transient borderless overlay
/// holds two layers — a snapshot of the terminal and a bubble/glyph view — and
/// cross-fades between them while animating the frame + corner radius.
///
/// - Collapse: snapshot (rect) fades out → glyph bubble (circle) fades in.
/// - Expand:   glyph bubble (circle) fades out → snapshot (rect) fades in.
///
/// We animate a *snapshot*, never the live views, so the SwiftTerm terminal is
/// never resized mid-animation (which would reflow cols/rows and look janky).
enum HeroTransition {

    static let duration: TimeInterval = 0.34

    /// - fadeToGlyph: true for collapse (snapshot→glyph), false for expand.
    static func morph(snapshot: NSImage,
                      from start: NSRect, to end: NSRect,
                      startRadius: CGFloat, endRadius: CGFloat,
                      fadeToGlyph: Bool,
                      completion: @escaping () -> Void) {

        let overlay = NSPanel(contentRect: start,
                              styleMask: [.nonactivatingPanel],
                              backing: .buffered, defer: false)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = true
        overlay.level = .statusBar
        overlay.ignoresMouseEvents = true
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        guard let content = overlay.contentView else { completion(); return }
        content.wantsLayer = true

        // Snapshot layer.
        let snapView = NSImageView(frame: content.bounds)
        snapView.image = snapshot
        snapView.imageScaling = .scaleAxesIndependently
        snapView.wantsLayer = true
        snapView.layer?.cornerRadius = startRadius
        snapView.layer?.masksToBounds = true
        snapView.autoresizingMask = [.width, .height]

        // Bubble/glyph layer.
        let bubble = makeBubble(frame: content.bounds, radius: startRadius)
        bubble.autoresizingMask = [.width, .height]

        snapView.alphaValue = fadeToGlyph ? 1 : 0
        bubble.alphaValue   = fadeToGlyph ? 0 : 1

        content.addSubview(snapView)
        content.addSubview(bubble)
        overlay.orderFrontRegardless()

        animateRadius(snapView.layer, from: startRadius, to: endRadius)
        animateRadius(bubble.layer,   from: startRadius, to: endRadius)

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            overlay.animator().setFrame(end, display: true)
            snapView.animator().alphaValue = fadeToGlyph ? 0 : 1
            bubble.animator().alphaValue   = fadeToGlyph ? 1 : 0
        }, completionHandler: {
            overlay.orderOut(nil)
            completion()
        })
    }

    /// Snapshots a view into an NSImage (the hero's traveling content).
    static func snapshot(of view: NSView) -> NSImage? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Private

    /// A view that visually matches the avatar bubble: dark translucent circle,
    /// accent ring, centered terminal glyph that scales with the frame.
    private static func makeBubble(frame: NSRect, radius: CGFloat) -> NSView {
        let v = NSView(frame: frame)
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.82).cgColor
        v.layer?.cornerRadius = radius
        v.layer?.borderWidth = 1.5
        v.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        v.layer?.masksToBounds = true

        let glyph = NSImageView(frame: frame.insetBy(dx: frame.width * 0.30,
                                                     dy: frame.height * 0.30))
        let cfg = NSImage.SymbolConfiguration(pointSize: 24, weight: .medium)
        glyph.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        glyph.contentTintColor = .white
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.autoresizingMask = [.width, .height, .minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        v.addSubview(glyph)
        return v
    }

    private static func animateRadius(_ layer: CALayer?, from: CGFloat, to: CGFloat) {
        guard let layer else { return }
        let a = CABasicAnimation(keyPath: "cornerRadius")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "cornerRadius")
        layer.cornerRadius = to
    }
}
