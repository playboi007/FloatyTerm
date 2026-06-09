import AppKit

/// A borderless-feeling floating panel that:
///  - stays above normal windows AND over other apps' fullscreen Spaces
///  - does NOT steal focus from the app below (non-activating)
///  - can be dragged anywhere
///
/// Lifecycle (delegate, close, move) is handled by `TerminalWindowController`,
/// which owns the panel.
final class FloatingPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
    }

    // Allow the panel to receive keyboard focus when the user clicks into it,
    // so they can actually type in the terminal.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// When true, this window is "linked"/pinned to a single Space: it drops
    /// `.canJoinAllSpaces` and becomes `.managed`, so macOS binds it to the
    /// Space it was pinned on. Swiping to another Space leaves it behind (its
    /// session keeps running); swiping back finds it intact. Runtime-only —
    /// Space identity isn't stable across launches, so this isn't persisted.
    private(set) var isPinned = false

    /// Window-level key commands (tab shortcuts, new window, preferences…).
    /// Returns true if the event was handled. Checked before the command is
    /// forwarded to the terminal view, so ⌘C/⌘V/⌘Z still reach the terminal.
    var keyCommandHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyCommandHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    func setupFloatingBehavior() {
        // Level + collection behavior live in reassert() because the window
        // server can silently drop them across screen sleep / Space changes;
        // re-applying on every show() keeps the overlay reliable.
        reassertFloatingBehavior()

        hidesOnDeactivate = false      // stay visible when another app is focused
        isFloatingPanel = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false

        // Make the title bar a thin transparent drag strip.
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // Transparent window so the NSVisualEffectView behind the terminal
        // provides the translucent / blurred "floaty" look.
        isOpaque = false
        backgroundColor = .clear
    }

    /// Re-applies the window level and the all-Spaces / fullscreen-overlay
    /// collection behavior. Safe to call repeatedly; called on every show()
    /// because macOS can quietly reset these after display sleep, screen dim,
    /// or transitions in/out of another app's fullscreen Space — which is what
    /// caused the panel to stop appearing over Chrome/Cursor after idle.
    func reassertFloatingBehavior() {
        // High window level so it floats above ordinary windows.
        level = .statusBar
        if isPinned {
            // Linked: bound to ONE Space (managed). Keep fullScreenAuxiliary so
            // it can live on another app's fullscreen Space. NO canJoinAllSpaces
            // — that's what stops it following the user across Spaces.
            collectionBehavior = [.managed, .fullScreenAuxiliary]
        } else {
            // Default: appear on every Space and over fullscreen apps.
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        }
    }

    /// Links/unlinks this window to the currently-active Space.
    /// When linking, the window commits to whatever Space is active right now;
    /// when unlinking, it returns to floating over all Spaces.
    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        reassertFloatingBehavior()
        // Re-order front so the new Space binding takes effect on the active Space.
        orderFrontRegardless()
    }

    /// Brings the panel to the front of WHATEVER Space is currently active —
    /// including another app's fullscreen Space — and gives it key focus so the
    /// user can type, WITHOUT activating FloatyTerm as the foreground app
    /// (which would fight the window server and yank the user out of the
    /// fullscreen Space). This is the reliable overlay show path.
    func presentOverlay() {
        reassertFloatingBehavior()
        orderFrontRegardless()
        makeKey()
    }

    // MARK: - Position persistence (single cross-launch "last used" frame)
    //
    // NOTE: this is intentionally ONE shared slot — it remembers where the
    // roaming window was so the next *launch* reopens in a familiar spot. It is
    // NOT per-window identity. To stop it clobbering things, callers must only
    // write it from unpinned windows, and new windows are placed relative to the
    // window on the current Space (see cascade/centerOnActiveScreen) rather than
    // blindly restoring this slot.

    private static let keyX = "frameX", keyY = "frameY", keyW = "frameW", keyH = "frameH"

    static var hasSavedFrame: Bool {
        UserDefaults.standard.object(forKey: keyX) != nil
    }

    /// Restores the last-used frame, or centers if there is none.
    func restoreSavedFrame() {
        let d = UserDefaults.standard
        if Self.hasSavedFrame {
            let f = NSRect(
                x: d.double(forKey: Self.keyX),
                y: d.double(forKey: Self.keyY),
                width: max(320, d.double(forKey: Self.keyW)),
                height: max(180, d.double(forKey: Self.keyH))
            )
            setFrame(clampToVisibleScreen(f), display: false)
        } else {
            center()
        }
    }

    func saveFrame() {
        let d = UserDefaults.standard
        d.set(frame.origin.x, forKey: Self.keyX)
        d.set(frame.origin.y, forKey: Self.keyY)
        d.set(frame.size.width, forKey: Self.keyW)
        d.set(frame.size.height, forKey: Self.keyH)
    }

    // MARK: - Per-window placement (no shared state)

    /// Places this window cascaded down-right from `reference` (another window's
    /// frame), clamped onto the screen that frame sits on. Used so a new window
    /// appears near the one the user is looking at — not at a stale global spot.
    func cascade(from reference: NSRect) {
        var f = frame
        f.size = NSSize(width: reference.width, height: reference.height)
        f.origin = NSPoint(x: reference.minX + 26, y: reference.minY - 26)
        setFrame(clampToVisibleScreen(f), display: false)
    }

    /// Centers this window on the screen the user is currently viewing, keeping
    /// its current size. Used when spawning onto a fresh Space with no reference.
    func centerOnActiveScreen() {
        guard let vis = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else {
            center(); return
        }
        var f = frame
        f.origin = NSPoint(x: vis.midX - f.width / 2, y: vis.midY - f.height / 2)
        setFrame(f, display: false)
    }

    /// Keeps a frame fully on the visible area of whichever screen it overlaps.
    func clampToVisibleScreen(_ f: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main
        guard let vis = screen?.visibleFrame else { return f }
        var r = f
        r.size.width  = min(r.width, vis.width)
        r.size.height = min(r.height, vis.height)
        r.origin.x = min(max(r.minX, vis.minX), vis.maxX - r.width)
        r.origin.y = min(max(r.minY, vis.minY), vis.maxY - r.height)
        return r
    }
}
