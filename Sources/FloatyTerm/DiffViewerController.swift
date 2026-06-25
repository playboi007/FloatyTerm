import AppKit

/// Owns one side-by-side file diff (i.e. one diff tab).
///
/// Shape mirrors `BrowserController` — a non-terminal `TabContent`:
///  - exposes a static `NSView` (a scrollable diff canvas) instead of a PTY/WKWebView
///  - never self-terminates (`onTerminated` kept only for protocol conformance)
///  - keystrokes don't drive a process; the canvas just scrolls
///
/// The line diff is computed in-process with `CollectionDifference` (no shelling
/// out to `/usr/bin/diff`) and rendered as two aligned columns with red/green
/// row tints, so the look matches FloatyTerm's frosted aesthetic. Diff tabs are
/// intentionally NOT persisted across launches (see `TerminalWindowController`).
final class DiffViewerController: NSObject, TabContent {

    // MARK: - TabContent

    let view: NSView
    private(set) var title: String
    var onTitleChanged: (() -> Void)?
    var onTerminated: (() -> Void)?   // diffs never self-terminate; kept for protocol

    var customName: String?

    var displayName: String {
        if let name = customName, !name.isEmpty { return name }
        return title
    }

    /// Ephemeral: a diff references two files and carries no live session, so
    /// there's nothing worth restoring on next launch.
    var restorableRecord: TabRecord? { nil }

    /// A diff is static — its content never changes after load, so it can never
    /// produce "unseen output". Always false.
    let hasUnseenOutput = false
    var isCurrentlyViewed = true

    // MARK: - Inputs

    let leftURL: URL
    let rightURL: URL

    private let scrollView: NSScrollView
    private let canvas: DiffCanvasView

    // MARK: - Init

    init(left: URL, right: URL) {
        self.leftURL  = left
        self.rightURL = right
        self.title    = "\(left.lastPathComponent) ↔ \(right.lastPathComponent)"

        let rows = DiffViewerController.computeRows(left: left, right: right)
        canvas = DiffCanvasView(rows: rows)

        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.drawsBackground = false               // let the blurred panel show through
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.contentView.drawsBackground = false
        sv.documentView = canvas
        scrollView = sv
        view = sv

        super.init()

        // NSClipView doesn't auto-size its document view, so drive the canvas
        // width from clip-view frame changes: the two columns stay responsive
        // while the document height stays pinned to the row count.
        sv.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewResized),
            name: NSView.frameDidChangeNotification, object: sv.contentView)
        canvas.layoutToWidth(sv.contentView.bounds.width)
    }

    @objc private func clipViewResized() {
        canvas.layoutToWidth(scrollView.contentView.bounds.width)
    }

    // MARK: - TabContent focus / cleanup

    func focus(in panel: NSWindow) {
        panel.makeFirstResponder(canvas)
    }

    func cleanup() {
        NotificationCenter.default.removeObserver(self)
        scrollView.documentView = nil
    }

    // MARK: - Diff computation

    /// Reads both files and aligns their lines into renderable rows.
    private static func computeRows(left: URL, right: URL) -> [DiffRow] {
        let leftLines  = readLines(left)
        let rightLines = readLines(right)

        guard let l = leftLines, let r = rightLines else {
            let which = leftLines == nil ? left.lastPathComponent : right.lastPathComponent
            return [DiffRow(left: "could not read \(which)", right: nil, kind: .removed)]
        }

        // `CollectionDifference` tells us which left offsets were removed and
        // which right offsets were inserted; everything else is a common line.
        // Walking both sequences with those two sets reconstructs the classic
        // aligned side-by-side layout (with filler on insert/delete, and a
        // paired "changed" row when a removal and insertion line up).
        let diff = r.difference(from: l)
        var removed  = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var rows: [DiffRow] = []
        var i = 0, j = 0
        while i < l.count || j < r.count {
            let leftChanged  = i < l.count && removed.contains(i)
            let rightChanged = j < r.count && inserted.contains(j)
            if leftChanged && rightChanged {
                rows.append(DiffRow(left: l[i], right: r[j], kind: .changed)); i += 1; j += 1
            } else if leftChanged {
                rows.append(DiffRow(left: l[i], right: nil, kind: .removed)); i += 1
            } else if rightChanged {
                rows.append(DiffRow(left: nil, right: r[j], kind: .added));   j += 1
            } else {
                // Neither side changed here ⇒ a common line; advance both.
                rows.append(DiffRow(left: l[i], right: r[j], kind: .equal));  i += 1; j += 1
            }
        }
        return rows
    }

    /// Reads a file as UTF-8 (lossy fallback) and splits into lines. Returns nil
    /// if the file can't be read.
    private static func readLines(_ url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        // Normalize CRLF, then split. A trailing newline yields a final empty
        // line, which we drop so files don't show a spurious blank last row.
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

// MARK: - Row model

private enum DiffKind {
    case equal, added, removed, changed
}

private struct DiffRow {
    let left: String?
    let right: String?
    let kind: DiffKind
}

// MARK: - Canvas

/// A flipped, scrollable view that draws the aligned diff rows. Only the rows
/// intersecting the dirty rect are rendered, so large files stay cheap.
private final class DiffCanvasView: NSView {

    private let rows: [DiffRow]
    private let leftNos:  [Int?]   // 1-based line number per row (nil = filler)
    private let rightNos: [Int?]
    private let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private let rowHeight: CGFloat
    private let gutterWidth: CGFloat
    private let padding: CGFloat = 6

    // Row-tint colors, low alpha so the blur behind reads through.
    private let removedTint = NSColor.systemRed.withAlphaComponent(0.16)
    private let addedTint   = NSColor.systemGreen.withAlphaComponent(0.16)
    private let gutterColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
    private let dividerColor = NSColor.white.withAlphaComponent(0.12)
    private let textColor   = NSColor.labelColor

    init(rows: [DiffRow]) {
        self.rows = rows
        // Precompute 1-based line numbers per side once (O(n)), so drawing a
        // scrolled-to row stays O(1) instead of re-counting from the top.
        var lNos = [Int?](repeating: nil, count: rows.count)
        var rNos = [Int?](repeating: nil, count: rows.count)
        var lCount = 0, rCount = 0
        for (k, row) in rows.enumerated() {
            if row.left  != nil { lCount += 1; lNos[k] = lCount }
            if row.right != nil { rCount += 1; rNos[k] = rCount }
        }
        self.leftNos  = lNos
        self.rightNos = rNos
        let lineH = ceil(font.ascender - font.descender + font.leading)
        self.rowHeight = max(16, lineH)
        // Gutter wide enough for the largest line number on either side.
        let maxNo = rows.count
        let digits = max(2, String(maxNo).count)
        let digitW = ("0" as NSString)
            .size(withAttributes: [.font: font]).width
        self.gutterWidth = ceil(CGFloat(digits) * digitW) + 10
        super.init(frame: NSRect(x: 0, y: 0, width: 600,
                                 height: max(1, CGFloat(rows.count) * rowHeight)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    /// Pin the document height to the row count; width follows the clip view via
    /// the autoresizing mask set by the controller.
    func layoutToWidth(_ width: CGFloat) {
        setFrameSize(NSSize(width: max(width, 200),
                            height: max(1, CGFloat(rows.count) * rowHeight)))
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true   // column widths are derived from our width
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty else { return }

        let columnX = bounds.width / 2          // divider position
        let leftColX = padding
        let leftTextX = leftColX + gutterWidth
        let rightColX = columnX + padding
        let rightTextX = rightColX + gutterWidth
        let leftTextW  = columnX - leftTextX - padding
        let rightTextW = bounds.width - rightTextX - padding

        // Only draw rows touching the dirty rect.
        let first = max(0, Int(dirtyRect.minY / rowHeight))
        let last  = min(rows.count - 1, Int(dirtyRect.maxY / rowHeight))
        guard first <= last else { return }

        for index in first...last {
            let row = rows[index]
            let y = CGFloat(index) * rowHeight

            // Per-column background tints.
            switch row.kind {
            case .equal:
                break
            case .removed:
                fill(NSRect(x: 0, y: y, width: columnX, height: rowHeight), removedTint)
            case .added:
                fill(NSRect(x: columnX, y: y, width: bounds.width - columnX,
                            height: rowHeight), addedTint)
            case .changed:
                fill(NSRect(x: 0, y: y, width: columnX, height: rowHeight), removedTint)
                fill(NSRect(x: columnX, y: y, width: bounds.width - columnX,
                            height: rowHeight), addedTint)
            }

            // Left side: line number + text.
            if let lt = row.left {
                drawLineNumber(leftNos[index],
                               x: leftColX, y: y, width: gutterWidth - 6)
                drawText(lt, x: leftTextX, y: y, width: leftTextW)
            }
            // Right side: line number + text.
            if let rt = row.right {
                drawLineNumber(rightNos[index],
                               x: rightColX, y: y, width: gutterWidth - 6)
                drawText(rt, x: rightTextX, y: y, width: rightTextW)
            }
        }

        // Center divider, drawn once over the visible span.
        dividerColor.setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: columnX, y: dirtyRect.minY))
        divider.line(to: NSPoint(x: columnX, y: dirtyRect.maxY))
        divider.lineWidth = 1
        divider.stroke()
    }

    // MARK: drawing helpers

    private func fill(_ rect: NSRect, _ color: NSColor) {
        color.setFill()
        rect.fill()
    }

    private func drawText(_ s: String, x: CGFloat, y: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: textColor, .paragraphStyle: para
        ]
        (s as NSString).draw(in: NSRect(x: x, y: y, width: width, height: rowHeight),
                             withAttributes: attrs)
    }

    private func drawLineNumber(_ n: Int?, x: CGFloat, y: CGFloat, width: CGFloat) {
        guard let n else { return }
        let para = NSMutableParagraphStyle()
        para.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: gutterColor, .paragraphStyle: para
        ]
        (String(n) as NSString).draw(in: NSRect(x: x, y: y, width: width, height: rowHeight),
                                     withAttributes: attrs)
    }
}
