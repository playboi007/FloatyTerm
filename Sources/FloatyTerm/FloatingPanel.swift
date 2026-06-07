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

    /// Window-level key commands (tab shortcuts, new window, preferences…).
    /// Returns true if the event was handled. Checked before the command is
    /// forwarded to the terminal view, so ⌘C/⌘V/⌘Z still reach the terminal.
    var keyCommandHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyCommandHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    func setupFloatingBehavior() {
        // High window level so it floats above ordinary windows.
        level = .statusBar

        // The crucial part: appear on every Space and over fullscreen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

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

    // MARK: - Position persistence (shared "last used" frame)

    private static let keyX = "frameX", keyY = "frameY", keyW = "frameW", keyH = "frameH"

    /// Restores the last-used frame, or centers if there is none.
    func restoreSavedFrame() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.keyX) != nil {
            let f = NSRect(
                x: d.double(forKey: Self.keyX),
                y: d.double(forKey: Self.keyY),
                width: max(320, d.double(forKey: Self.keyW)),
                height: max(180, d.double(forKey: Self.keyH))
            )
            setFrame(f, display: false)
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
}
