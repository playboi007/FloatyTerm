import AppKit

/// Abstraction over a single tab — either a terminal or a browser.
///
/// Both `TerminalController` and `BrowserController` conform to this protocol.
/// `TerminalWindowController` operates exclusively on `[any TabContent]` so the
/// window machinery is type-agnostic. Terminal-specific behaviour (font updates,
/// find-bar, foreground-job check, recent-commands palette) is reached via
/// conditional downcasts to `TerminalController`.
protocol TabContent: AnyObject {
    /// The view to embed in the window's content area.
    var view: NSView { get }

    /// The display string for this tab's chip.
    var title: String { get }

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
