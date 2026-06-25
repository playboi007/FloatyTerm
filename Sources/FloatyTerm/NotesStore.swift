import AppKit

/// On-disk home for scratch notes. Each note tab is backed by a real `.md`
/// file so the content survives a crash, is git-friendly, and — true to
/// FloatyTerm's theme — can be `cat`'d by an agent in a sibling terminal.
///
/// New notes land in the managed directory and fall under `StorageJanitor`'s
/// retention + cap policy (see `StorageJanitor.Category.notes`, which points
/// here). "Save As…" relocates a note to a user-chosen folder, taking it out
/// of the managed directory and out of the janitor's reach.
enum NotesStore {

    /// ~/Library/Application Support/FloatyTerm/Notes — created on demand.
    /// Single source of truth for the location; `StorageJanitor` references it.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("FloatyTerm/Notes", isDirectory: true)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    /// Creates a fresh, empty scratch note file and returns its URL. The
    /// timestamped name keeps notes created in the same session distinct and
    /// sorts them chronologically in Finder.
    static func newScratchNote() -> URL {
        let dir = directory
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let name = "Note-\(stampFormatter.string(from: Date())).md"
        let url = dir.appendingPathComponent(name)
        // Touch the file so it exists immediately (the tab's first autosave
        // overwrites it). createFile is a no-op if it somehow already exists.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    /// True when `url` lives inside the managed directory — i.e. it's a scratch
    /// note the janitor may clean, not a user-chosen "Save As…" location.
    static func isManaged(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
    }
}
