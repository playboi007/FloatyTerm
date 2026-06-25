import AppKit
import UniformTypeIdentifiers

/// Owns one markdown note (i.e. one note tab).
///
/// Shape mirrors `DiffViewerController` — a non-terminal `TabContent`:
///  - exposes a scrollable `NSTextView` instead of a PTY/WKWebView
///  - never self-terminates (`onTerminated` kept only for protocol conformance)
///
/// The note is plain-text markdown, backed by a real `.md` file on disk
/// (`NotesStore`). Edits autosave on a short debounce. Markdown *source* is
/// lightly syntax-highlighted (headings, bold, code, list markers) as a
/// display-only overlay — the saved file is always the raw characters, never
/// styled. "Save As…" relocates the note to a user-chosen folder.
final class NoteController: NSObject, TabContent, NSTextViewDelegate, NSTextStorageDelegate {

    // MARK: - TabContent

    let view: NSView
    private(set) var title: String = "Untitled Note"
    var onTitleChanged: (() -> Void)?
    var onTerminated: (() -> Void)?   // notes never self-terminate; kept for protocol

    var customName: String?

    var displayName: String {
        if let name = customName, !name.isEmpty { return name }
        return title
    }

    var restorableRecord: TabRecord? {
        // Notes are documents — restore reopens the backing file (autosaved).
        TabRecord(kind: "note", customName: customName, path: fileURL.path)
    }

    /// Notes are user-driven; "unseen output" doesn't apply (nothing changes a
    /// note but the user typing in it). Always false.
    let hasUnseenOutput = false
    var isCurrentlyViewed = true

    // MARK: - Backing file

    /// The file this note autosaves into. Reassigned by "Save As…".
    private(set) var fileURL: URL

    // MARK: - Editor

    private let scrollView: NSScrollView
    private let textView: NSTextView
    private let textStorage: NSTextStorage

    // Debounced autosave: the last edit wins, written ~0.6s after typing stops.
    private var pendingSave: DispatchWorkItem?
    private static let saveDelay: TimeInterval = 0.6

    // MARK: - Fonts (precomputed for the highlighter)

    private static let bodyFont    = NSFont.systemFont(ofSize: 14)
    private static let boldFont    = NSFont.boldSystemFont(ofSize: 14)
    private static let monoFont    = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private static let headingFont = NSFont.boldSystemFont(ofSize: 17)

    // MARK: - Init

    /// - Parameter fileURL: the `.md` file to edit. If it already has contents
    ///   they're loaded; otherwise the note starts empty.
    init(fileURL: URL) {
        self.fileURL = fileURL

        // Build a TextKit 1 stack explicitly so the NSTextStorage delegate
        // drives highlighting predictably (NSTextView defaults to TextKit 2 on
        // macOS 13).
        textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let tv = NSTextView(frame: .zero, textContainer: container)
        tv.isRichText = false                     // plain markdown; we style for display only
        tv.allowsUndo = true
        tv.font = Self.bodyFont
        tv.textColor = .labelColor
        tv.insertionPointColor = .controlAccentColor
        tv.drawsBackground = false                // let the blurred panel show through
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        // Explicit min/max: a text view built with a manual container otherwise
        // inherits a zero maxSize and won't grow (or scroll) past one frame.
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 8, height: 10)
        tv.isAutomaticQuoteSubstitutionEnabled = false   // straight quotes in markdown
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.usesFindBar = true                     // ⌘F find & replace, for free
        tv.isIncrementalSearchingEnabled = true
        textView = tv

        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.drawsBackground = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.contentView.drawsBackground = false
        sv.documentView = tv
        scrollView = sv
        view = sv

        super.init()

        // Load existing contents (Save-As reopen / future "open note").
        if let data = try? Data(contentsOf: fileURL),
           let text = String(data: data, encoding: .utf8), !text.isEmpty {
            textStorage.replaceCharacters(
                in: NSRange(location: 0, length: 0), with: text)
        }
        textView.delegate = self
        textStorage.delegate = self
        textView.typingAttributes = [
            .font: Self.bodyFont, .foregroundColor: NSColor.labelColor
        ]
        highlight(range: NSRange(location: 0, length: textStorage.length))
        updateTitle()
    }

    // MARK: - TabContent focus / cleanup

    func focus(in panel: NSWindow) {
        panel.makeFirstResponder(textView)
    }

    func cleanup() {
        // Flush any pending edit synchronously so nothing is lost on close.
        pendingSave?.cancel()
        pendingSave = nil
        writeToDisk()
        textView.delegate = nil
        textStorage.delegate = nil
        scrollView.documentView = nil
    }

    // MARK: - Editing → autosave + title

    func textDidChange(_ notification: Notification) {
        scheduleSave()
        updateTitle()
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeToDisk() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    private func writeToDisk() {
        let text = textStorage.string
        do {
            try text.data(using: .utf8)?.write(to: fileURL, options: .atomic)
        } catch {
            // Non-fatal: the note stays in the editor; a later edit retries.
            NSLog("FloatyTerm: note save failed for \(fileURL.path): \(error)")
        }
    }

    /// Title = first non-empty line (trimmed/clamped), else the filename stem,
    /// else "Untitled Note". Fires `onTitleChanged` only when it actually moves.
    private func updateTitle() {
        let firstLine = textStorage.string
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
        let derived: String
        if let line = firstLine, !line.isEmpty {
            // Drop leading markdown heading markers for a cleaner chip label.
            let stripped = line.drop(while: { $0 == "#" || $0 == " " })
            let base = stripped.isEmpty ? Substring(line) : stripped
            derived = String(base.prefix(40))
        } else {
            let stem = fileURL.deletingPathExtension().lastPathComponent
            derived = stem.isEmpty ? "Untitled Note" : stem
        }
        guard derived != title else { return }
        title = derived
        onTitleChanged?()
    }

    // MARK: - Save As…

    /// Relocates the note to a user-chosen file. The content is written there,
    /// the managed scratch file (if any) is removed, and further edits autosave
    /// to the new location — which is outside the janitor's managed directory.
    func presentSaveAs(in window: NSWindow) {
        let panel = NSSavePanel()
        panel.title = "Save Note"
        panel.nameFieldStringValue = fileURL.lastPathComponent
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        NSApp.activate(ignoringOtherApps: true)
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let dest = panel.url else { return }
            let oldURL = self.fileURL
            self.fileURL = dest
            self.writeToDisk()
            // Clean up the previous scratch file once content lives at `dest`.
            if oldURL != dest, NotesStore.isManaged(oldURL) {
                try? FileManager.default.removeItem(at: oldURL)
            }
            self.updateTitle()
        }
    }

    // MARK: - Markdown syntax highlighting (display-only)

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        // Re-highlight the full paragraph(s) the edit touched — cheap, and
        // enough to repaint a line whose markers just opened or closed.
        let para = (textStorage.string as NSString).paragraphRange(for: editedRange)
        // Defer to avoid mutating attributes mid-edit-processing.
        DispatchQueue.main.async { [weak self] in self?.highlight(range: para) }
    }

    private static let headingRE = try! NSRegularExpression(pattern: #"(?m)^(#{1,6})\s.*$"#)
    private static let boldRE    = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    private static let codeRE    = try! NSRegularExpression(pattern: #"`([^`\n]+)`"#)
    private static let bulletRE  = try! NSRegularExpression(pattern: #"(?m)^\s*([-*+]|\d+\.)\s"#)

    /// Paints markdown source styling over `range`. Only attributes change; the
    /// stored characters (and thus the saved file) are untouched.
    private func highlight(range rawRange: NSRange) {
        let full = NSRange(location: 0, length: textStorage.length)
        guard let range = rawRange.clamped(to: full), range.length > 0 else { return }
        let ns = textStorage.string as NSString

        textStorage.beginEditing()
        // Reset the paragraph to the base style, then overlay markers.
        textStorage.setAttributes(
            [.font: Self.bodyFont, .foregroundColor: NSColor.labelColor], range: range)

        Self.headingRE.enumerateMatches(in: ns as String, range: range) { m, _, _ in
            guard let r = m?.range else { return }
            textStorage.addAttributes(
                [.font: Self.headingFont, .foregroundColor: NSColor.labelColor], range: r)
        }
        Self.boldRE.enumerateMatches(in: ns as String, range: range) { m, _, _ in
            guard let r = m?.range else { return }
            textStorage.addAttribute(.font, value: Self.boldFont, range: r)
        }
        Self.codeRE.enumerateMatches(in: ns as String, range: range) { m, _, _ in
            guard let r = m?.range else { return }
            textStorage.addAttributes(
                [.font: Self.monoFont,
                 .foregroundColor: NSColor.systemTeal], range: r)
        }
        Self.bulletRE.enumerateMatches(in: ns as String, range: range) { m, _, _ in
            guard let r = m?.range(at: 1) else { return }
            textStorage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: r)
        }
        textStorage.endEditing()
    }
}

private extension NSRange {
    /// Intersection with `other`, or nil if disjoint. Guards the highlighter
    /// against a stale paragraph range after a deletion shrank the storage.
    func clamped(to other: NSRange) -> NSRange? {
        let lo = Swift.max(location, other.location)
        let hi = Swift.min(location + length, other.location + other.length)
        return lo < hi ? NSRange(location: lo, length: hi - lo) : nil
    }
}
