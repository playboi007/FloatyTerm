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
    static let uti = "tech.reduzer.floatyterm.tab"

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
}
