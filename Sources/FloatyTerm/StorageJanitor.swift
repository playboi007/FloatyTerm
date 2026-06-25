import Foundation

/// Keeps FloatyTerm's per-feature data directories from growing unbounded.
///
/// Managed roots (each enforced independently, governed by the two shared
/// knobs in Settings — `storageRetentionDays` and `storageCapMB`):
///
///   - Devtools  (App Support/FloatyTerm/Devtools, recursive: remote/ + tabs/)
///   - Browser Context  (App Support/FloatyTerm/BrowserContext)
///   - Snaps  (~/.floatyterm/snaps — Context Snap captures)
///
/// The size cap is apportioned per root: **Devtools gets the full cap;
/// Browser Context and Snaps each get a quarter of it** (Devtools is the
/// high-volume stream; the others are small markdown/png captures).
///
/// Transcripts (App Support/FloatyTerm/Transcripts) are *display-only* in
/// `usage()` — they have their own lifecycle (TranscriptDisk) and are never
/// swept or manually cleared from here.
///
/// Safety rule: a file modified within the last 10 minutes is NEVER deleted
/// by a sweep — DevtoolsRelay and BrowserController keep open FileHandles on
/// active logs, and deleting under a live handle loses data silently.
final class StorageJanitor {
    static let shared = StorageJanitor()

    /// Files younger than this are untouchable by `sweep()` (live-handle guard).
    private static let recentFileGrace: TimeInterval = 10 * 60

    /// Serializes sweeps and manual clears so they can't race each other.
    private let queue = DispatchQueue(label: "floatyterm.storage-janitor", qos: .utility)
    private var timer: Timer?

    // MARK: - Categories

    /// The directories the janitor knows about. Raw value doubles as the
    /// display name in the Preferences Storage section.
    enum Category: String, CaseIterable {
        case devtools = "Devtools"
        case browserContext = "Browser Context"
        case transcripts = "Transcripts"
        case snaps = "Snaps"
        case notes = "Notes"

        var url: URL {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            switch self {
            case .devtools:
                return appSupport.appendingPathComponent("FloatyTerm/Devtools", isDirectory: true)
            case .browserContext:
                return appSupport.appendingPathComponent("FloatyTerm/BrowserContext", isDirectory: true)
            case .transcripts:
                return TranscriptDisk.directory
            case .snaps:
                // Same path as ContextSnap.snapsDirectory, computed without
                // its create-on-access side effect.
                return URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent(".floatyterm/snaps", isDirectory: true)
            case .notes:
                return NotesStore.directory
            }
        }

        /// Devtools logs live in subdirectories (remote/, tabs/); the other
        /// roots are flat.
        var isRecursive: Bool { self == .devtools }

        /// Transcripts are display-only: TranscriptDisk owns their lifecycle.
        var isSwept: Bool { self != .transcripts }

        /// This root's share of the user's total cap. Devtools (the
        /// high-volume event stream) gets the full cap; Browser Context,
        /// Snaps, and Notes get a quarter each.
        func capBytes(totalMB: Int) -> Int64 {
            let full = Int64(totalMB) * 1_048_576
            switch self {
            case .devtools:                      return full
            case .browserContext, .snaps, .notes: return full / 4
            case .transcripts:                   return .max   // never trimmed here
            }
        }
    }

    // MARK: - Lifecycle

    /// Called once from `applicationDidFinishLaunching`: sweeps immediately,
    /// then hourly. Tolerance is generous — the exact moment doesn't matter.
    func start() {
        sweep()
        let t = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.sweep()
        }
        t.tolerance = 600
        timer = t
    }

    // MARK: - Sweep

    /// Per managed root: delete files older than `storageRetentionDays`
    /// (skipped when 0 = forever), then — if the root still exceeds its cap
    /// share — delete oldest-first until under. Files modified in the last
    /// 10 minutes are never touched (they may have an open FileHandle).
    func sweep() {
        queue.async { self.sweepNow() }
    }

    private func sweepNow() {
        let fm = FileManager.default
        let retentionDays = Settings.shared.storageRetentionDays
        let capMB = Settings.shared.storageCapMB
        let now = Date()
        let graceCutoff = now.addingTimeInterval(-Self.recentFileGrace)
        let retentionCutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)

        for category in Category.allCases where category.isSwept {
            var deletedAny = false
            // Oldest first — both passes want that order.
            let entries = Self.files(in: category).sorted { $0.modified < $1.modified }
            var total = entries.reduce(Int64(0)) { $0 + $1.size }
            var survivors: [FileInfo] = []

            // Pass 1: retention (0 = keep forever).
            for f in entries {
                if retentionDays > 0, f.modified < retentionCutoff, f.modified <= graceCutoff,
                   (try? fm.removeItem(at: f.url)) != nil {
                    total -= f.size
                    deletedAny = true
                } else {
                    survivors.append(f)
                }
            }

            // Pass 2: size cap, oldest first, same live-handle guard.
            let cap = category.capBytes(totalMB: capMB)
            for f in survivors {
                guard total > cap else { break }
                guard f.modified <= graceCutoff else { continue }
                if (try? fm.removeItem(at: f.url)) != nil {
                    total -= f.size
                    deletedAny = true
                }
            }

            // Both DevtoolsRelay (remote/) and BrowserController (tabs/) keep
            // open handles on these logs through the shared DevtoolsLog sink:
            // once files are gone, drop the handles so events can't keep
            // streaming into deleted inodes (invisible, unreachable data).
            if category == .devtools, deletedAny {
                DevtoolsLog.shared.dropHandles()
            }
        }
    }

    // MARK: - Usage (Preferences UI)

    /// Per-category disk usage for the Preferences Storage section.
    /// Transcripts are included for visibility but are display-only.
    func usage() -> [(name: String, path: String, bytes: Int64, files: Int)] {
        Category.allCases.map { category in
            let entries = Self.files(in: category)
            return (name: category.rawValue,
                    path: category.url.path,
                    bytes: entries.reduce(Int64(0)) { $0 + $1.size },
                    files: entries.count)
        }
    }

    // MARK: - Manual clear

    /// "Clear Now": deletes every file in the category's directory. No-op for
    /// Transcripts (their lifecycle belongs to TranscriptDisk). Synchronous —
    /// the prefs UI refreshes its numbers right after.
    func clear(category: Category) {
        guard category.isSwept else { return }
        queue.sync {
            let fm = FileManager.default
            var deletedAny = false
            for f in Self.files(in: category) {
                if (try? fm.removeItem(at: f.url)) != nil { deletedAny = true }
            }
            // Without this, the shared sink's open handles (relay + tabs)
            // would silently resurrect writes into the deleted files' inodes.
            if category == .devtools, deletedAny {
                DevtoolsLog.shared.dropHandles()
            }
        }
    }

    // MARK: - Helpers

    private struct FileInfo {
        let url: URL
        let modified: Date
        let size: Int64
    }

    /// Regular files in a category's root (recursing for Devtools), with
    /// modification date and size. Missing directory → empty.
    private static func files(in category: Category) -> [FileInfo] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls: [URL]
        if category.isRecursive {
            let walker = fm.enumerator(at: category.url, includingPropertiesForKeys: Array(keys))
            urls = walker?.compactMap { $0 as? URL } ?? []
        } else {
            urls = (try? fm.contentsOfDirectory(at: category.url,
                                                includingPropertiesForKeys: Array(keys))) ?? []
        }
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: keys),
                  v.isRegularFile == true else { return nil }
            return FileInfo(url: url,
                            modified: v.contentModificationDate ?? .distantPast,
                            size: Int64(v.fileSize ?? 0))
        }
    }
}
