import AppKit

/// In-process registry that maps a drag session UUID to the live objects being
/// dragged.  We never serialize a `TabContent` through the pasteboard — we just
/// carry a UUID string and look it up here on drop.
///
/// Entry lifecycle:
///  1. Created in `TabChip` just before `beginDraggingSession` is called.
///  2. Consumed (and removed) in the drop destination or in the drag-ended
///     callback (tear-off path).
final class TabDragRegistry {
    static let shared = TabDragRegistry()
    private init() {}

    /// The custom UTI written to and read from the pasteboard.
    static let uti = "vin.floatyterm.tab"

    struct Entry {
        weak var sourceController: TerminalWindowController?
        let tab: any TabContent
    }

    private var store: [String: Entry] = [:]

    func register(token: String, sourceController: TerminalWindowController, tab: any TabContent) {
        store[token] = Entry(sourceController: sourceController, tab: tab)
    }

    func entry(for token: String) -> Entry? {
        store[token]
    }

    func remove(token: String) {
        store.removeValue(forKey: token)
    }

    // MARK: - Hotkey merge (mid-drag)

    /// The modifier held during a drag to merge the dragged tab into the window
    /// under the cursor *immediately* — instead of releasing onto the sometimes
    /// flaky drop highlight. AppKit suppresses ordinary key events for the
    /// duration of a drag session, so only modifier state is observable; the
    /// "hotkey" is therefore a modifier chord, read live from
    /// `NSEvent.modifierFlags` inside a hovered destination's `draggingUpdated`.
    static let mergeModifier: NSEvent.ModifierFlags = .command

    /// Invoked from a drop destination's `draggingUpdated` while `token` hovers
    /// it. If `mergeModifier` is held and the drag is cross-window, moves the
    /// dragged tab into `destWC` right then and returns true so the caller can
    /// stop highlighting — the drag is spent. Removing the registry entry routes
    /// the eventual mouse-up through the existing token-consumed guards, so it
    /// neither double-merges nor tears off.
    func commitHotkeyMerge(token: String, into destWC: TerminalWindowController) -> Bool {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isSuperset(of: Self.mergeModifier) else { return false }
        guard let entry = store[token],
              let sourceWC = entry.sourceController,
              sourceWC !== destWC else { return false }
        store.removeValue(forKey: token)
        sourceWC.releaseTab(entry.tab)
        destWC.adoptTab(entry.tab)
        return true
    }
}
