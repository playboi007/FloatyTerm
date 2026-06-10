import AppKit

/// One persisted tab: enough to recreate the session's CONTEXT (not its live
/// process — a terminal restarts as a fresh shell in its last directory, a
/// browser reloads its URL).
struct TabRecord: Codable {
    var kind: String           // "terminal" | "browser"
    var customName: String?
    var directory: String?     // terminal: last working directory
    var url: String?           // browser: last page
}

/// One persisted window: its frame, avatar personalization, and tabs.
/// Records are written as a JSON array (one entry per open window), so every
/// window remembers its own geometry — replacing the old single shared
/// "last used frame" slot that whichever window moved last would clobber.
/// `tabs`/`activeIndex` are optional so pre-session records still decode.
struct WindowRecord: Codable {
    var frame: String          // NSStringFromRect
    var avatarSymbol: String
    var avatarColor: String
    var tabs: [TabRecord]?
    var activeIndex: Int?
}

enum WindowStateStore {
    private static let key = "windowRecords"

    /// Returns the persisted windows, or [] on first run / legacy data.
    /// (With no records, AppDelegate creates one window via the legacy
    /// shared-frame restore path, which migrates old installs for free.)
    static func load() -> [WindowRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let records = try? JSONDecoder().decode([WindowRecord].self, from: data) else {
            return []
        }
        return records
    }

    static func save(_ records: [WindowRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
