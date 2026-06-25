import Foundation

/// The single owner of every open `FileHandle` on a devtools NDJSON log —
/// both DevtoolsRelay's per-origin remote logs (`Devtools/remote/*.ndjson`)
/// and BrowserController's per-tab logs (`Devtools/tabs/*.ndjson`).
///
/// Why this exists: StorageJanitor deletes files under `Devtools/` and must
/// then release any handle still pointing at them. An open handle on a
/// deleted (unlinked) file keeps accepting writes that land in an inode no
/// path reaches — silent data loss. Before this sink, only the relay's
/// handles were tracked centrally; BrowserController held its own ungoverned
/// handle, so swept tab logs leaked events forever. Routing every writer
/// through here gives the janitor ONE `dropHandles()` that covers all of them.
///
/// Handles are keyed by file path and resolved at write time (mirroring
/// TranscriptDisk): if a sweep deleted the file and dropped the handle, the
/// next `append` recreates the file and reopens — writers never need to know
/// a sweep happened. All access is serialized on `queue`, so a write enqueued
/// before a drop runs first, and a write enqueued after a drop reopens.
final class DevtoolsLog {
    static let shared = DevtoolsLog()

    private let queue = DispatchQueue(label: "floatyterm.devtools-log", qos: .utility)
    private var handles: [String: FileHandle] = [:]   // file path → open log

    /// Appends `text` VERBATIM to the log at `url` (callers include their own
    /// trailing newline — the relay batches several lines per write). Creates
    /// the parent directory and file on first use, or after a sweep removed
    /// them. A write to a momentarily-closed handle is impossible: the handle
    /// is resolved on `queue`, the same queue `drop`/`dropHandles` run on.
    func append(_ text: String, to url: URL) {
        guard let data = text.data(using: .utf8) else { return }
        queue.async { [weak self] in
            try? self?.handle(for: url)?.write(contentsOf: data)
        }
    }

    /// Releases the handle for a single log (a browser tab closing). The file
    /// itself is the caller's to delete.
    func drop(_ url: URL) {
        queue.async { [weak self] in
            if let h = self?.handles.removeValue(forKey: url.path) {
                try? h.close()
            }
        }
    }

    /// Closes and forgets every open log handle. StorageJanitor calls this
    /// after deleting Devtools files; the relay also calls it periodically to
    /// avoid leaking descriptors on origins that have gone quiet. Either way
    /// the next `append` reopens (and recreates) on demand.
    func dropHandles() {
        queue.async { [weak self] in
            self?.handles.values.forEach { try? $0.close() }
            self?.handles.removeAll()
        }
    }

    /// Resolves (reopening on demand) the appendable handle for `url`. MUST be
    /// called on `queue`.
    private func handle(for url: URL) -> FileHandle? {
        if let h = handles[url.path] { return h }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? h.seekToEnd()
        handles[url.path] = h
        return h
    }
}
