import AppKit

/// Abstraction over a single tab — either a terminal or a browser.
///
/// Both `TerminalController` and `BrowserController` conform to this protocol.
/// `TerminalWindowController` operates exclusively on `[any TabContent]` so the
/// window machinery is type-agnostic. Terminal-specific behaviour (font updates,
/// find-bar, foreground-job check, recent-commands palette) is reached via
/// conditional downcasts to `TerminalController`.
/// Passive attention state of a session, surfaced as a colored dot on tab
/// chips, avatar bubbles, and switcher rows. Priority: unseenOutput > running.
enum SessionStatus {
    case idle           // nothing notable
    case running        // a foreground job is executing
    case unseenOutput   // produced output/changes since the user last viewed it

    /// Dot color for this status (idle is a faint neutral placeholder).
    var color: NSColor {
        switch self {
        case .idle:         return NSColor.white.withAlphaComponent(0.18)
        case .running:      return .systemGreen
        case .unseenOutput: return .controlAccentColor
        }
    }
}

protocol TabContent: AnyObject {
    /// The view to embed in the window's content area.
    var view: NSView { get }

    /// The display string for this tab's chip.
    var title: String { get }

    /// User-pinned name override (right-click a chip → Rename). nil = automatic.
    var customName: String? { get set }

    /// What chips and the session switcher show: the custom name when set,
    /// otherwise an automatic label (live process · directory for terminals,
    /// page title for browsers).
    var displayName: String { get }

    /// True when the session changed since the user last had it in view.
    var hasUnseenOutput: Bool { get }

    /// Set by the window controller: true while this tab is the active tab of
    /// a visible window. While true, new output doesn't count as "unseen";
    /// setting it true clears any pending unseen flag.
    var isCurrentlyViewed: Bool { get set }

    /// Called by the tab whenever its title changes so the tab strip can refresh.
    var onTitleChanged: (() -> Void)? { get set }

    /// Called by the tab when it wants to be closed (e.g. shell exited).
    /// Not all tab types need to fire this; browser tabs never auto-close.
    var onTerminated: (() -> Void)? { get set }

    /// Give focus to this tab's primary interactive view.
    func focus(in panel: NSWindow)

    /// Release resources when the tab is removed.
    func cleanup()
}
