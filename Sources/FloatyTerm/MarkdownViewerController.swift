import AppKit
import WebKit

/// A tab that views *and edits* a Markdown file, opened from a terminal
/// selection via the right-click "Open in Markdown Viewer" action.
///
/// Two modes, toggled from an expandable icon toolbar pinned top-left:
///   • **Preview** — rendered HTML in a `WKWebView` via vendored marked.js
///     (`MarkdownAssets.swift`); dark/transparent theme, GFM tables + code.
///     Loaded with the file's directory as `baseURL` so relative images resolve.
///   • **Edit** — the raw source in an editable `NSTextView`.
/// Save writes the editor's contents back to the file. Switching to preview
/// re-renders from the *current* editor text, so unsaved edits preview live.
///
/// Fully offline (the renderer JS is embedded, not an SPM resource). Ephemeral
/// across launches in v1 (`restorableRecord` = nil), but edits flush to disk on
/// close so nothing is lost.
final class MarkdownViewerController: NSObject, TabContent, NSTextViewDelegate {

    private enum Mode { case preview, edit }

    private let filePath: String
    private let fileName: String

    private let container = LayoutForwardingView()
    private let webView: WKWebView
    private let editorScroll = NSScrollView()
    private let textView = NSTextView()

    // Toolbar
    private let toolbar = NSVisualEffectView()
    private let toolStack = NSStackView()
    private var discloseButton = NSButton()
    private var modeButton = NSButton()
    private var saveButton = NSButton()
    private var revealButton = NSButton()

    private var mode: Mode = .preview
    private var isExpanded = true
    private var isDirty = false { didSet { if oldValue != isDirty { onTitleChanged?() } } }

    /// File extensions we treat as openable Markdown.
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]

    /// True when `path` is an existing regular file with a Markdown extension.
    static func isMarkdownFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard markdownExtensions.contains(ext) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && !isDir.boolValue
    }

    /// Fails when the path isn't a readable Markdown file.
    init?(path: String) {
        guard Self.isMarkdownFile(path),
              let source = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        self.filePath = path
        self.fileName = (path as NSString).lastPathComponent

        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()

        setUpPreview(source: source)
        setUpEditor(source: source)
        setUpToolbar()

        container.addSubview(editorScroll)
        container.addSubview(webView)
        container.addSubview(toolbar)
        container.onLayout = { [weak self] in self?.layoutContents() }

        applyMode()   // start in preview
    }

    // MARK: - Subview setup

    private func setUpPreview(source: String) {
        webView.setValue(false, forKey: "drawsBackground")
        webView.layer?.backgroundColor = CGColor.clear
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = .clear }
        render(source)
    }

    private func setUpEditor(source: String) {
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.drawsBackground = false               // blurred panel shows through
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.string = source
        textView.delegate = self

        editorScroll.drawsBackground = false
        editorScroll.hasVerticalScroller = true
        editorScroll.hasHorizontalScroller = false
        editorScroll.autohidesScrollers = true
        editorScroll.contentView.drawsBackground = false
        editorScroll.documentView = textView
    }

    private func setUpToolbar() {
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 8
        toolbar.layer?.masksToBounds = true

        discloseButton = iconButton("sidebar.leading", "Show / hide actions",
                                    #selector(toggleExpanded(_:)))
        modeButton = iconButton("pencil", "Edit", #selector(toggleMode(_:)))
        saveButton = iconButton("square.and.arrow.down", "Save", #selector(saveAction(_:)))
        revealButton = iconButton("folder", "Reveal in Finder", #selector(revealAction(_:)))
        saveButton.isEnabled = false

        toolStack.orientation = .horizontal
        toolStack.spacing = 2
        toolStack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        toolStack.translatesAutoresizingMaskIntoConstraints = false
        [discloseButton, modeButton, saveButton, revealButton].forEach { toolStack.addArrangedSubview($0) }

        toolbar.addSubview(toolStack)
        NSLayoutConstraint.activate([
            toolStack.topAnchor.constraint(equalTo: toolbar.topAnchor),
            toolStack.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor)
        ])
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton()
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        b.toolTip = tip
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 26),
            b.heightAnchor.constraint(equalToConstant: 24)
        ])
        return b
    }

    // MARK: - Layout

    private func layoutContents() {
        editorScroll.frame = container.bounds
        webView.frame = container.bounds
        toolbar.layoutSubtreeIfNeeded()
        let size = toolbar.fittingSize
        // Top-left with a small inset (container is non-flipped: top == max Y).
        toolbar.frame = NSRect(x: 12,
                               y: container.bounds.height - size.height - 12,
                               width: size.width, height: size.height)
        toolbar.autoresizingMask = [.minYMargin, .maxXMargin]   // stay pinned top-left
    }

    // MARK: - Mode + toolbar actions

    private func applyMode() {
        let preview = (mode == .preview)
        webView.isHidden = !preview
        editorScroll.isHidden = preview
        // Mode button shows the action you'd take next.
        modeButton.image = NSImage(systemSymbolName: preview ? "pencil" : "eye",
                                   accessibilityDescription: preview ? "Edit" : "Preview")
        modeButton.toolTip = preview ? "Edit" : "Preview"
        if let panel = container.window { focus(in: panel) }
    }

    @objc private func toggleMode(_ sender: Any?) {
        if mode == .preview {
            mode = .edit
        } else {
            render(textView.string)   // preview the live (possibly unsaved) text
            mode = .preview
        }
        applyMode()
    }

    @objc private func toggleExpanded(_ sender: Any?) {
        isExpanded.toggle()
        [modeButton, saveButton, revealButton].forEach { $0.isHidden = !isExpanded }
        discloseButton.image = NSImage(
            systemSymbolName: isExpanded ? "sidebar.leading" : "sidebar.trailing",
            accessibilityDescription: "Show / hide actions")
        container.needsLayout = true
    }

    @objc private func saveAction(_ sender: Any?) {
        writeToDisk()
    }

    @objc private func revealAction(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
    }

    private func writeToDisk() {
        guard isDirty else { return }
        do {
            try textView.string.write(toFile: filePath, atomically: true, encoding: .utf8)
            isDirty = false
            saveButton.isEnabled = false
        } catch {
            NSSound.beep()
        }
    }

    // MARK: - Editing

    func textDidChange(_ notification: Notification) {
        isDirty = true
        saveButton.isEnabled = true
    }

    // MARK: - Rendering

    private func render(_ markdown: String) {
        let baseURL = URL(fileURLWithPath: filePath).deletingLastPathComponent()
        webView.loadHTMLString(Self.htmlDocument(forMarkdown: markdown), baseURL: baseURL)
    }

    // MARK: - TabContent

    var view: NSView { container }

    var title: String { fileName }
    var customName: String?
    var displayName: String { (isDirty ? "● " : "") + (customName ?? fileName) }

    var hasUnseenOutput: Bool { false }
    var isCurrentlyViewed: Bool = false

    var onTitleChanged: (() -> Void)?
    var onTerminated: (() -> Void)?

    var restorableRecord: TabRecord? { nil }

    func focus(in panel: NSWindow) {
        panel.makeFirstResponder(mode == .edit ? textView : webView)
    }

    func cleanup() {
        writeToDisk()                 // flush unsaved edits so nothing is lost
        textView.delegate = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        editorScroll.documentView = nil
    }

    // MARK: - HTML assembly

    /// Builds a self-contained HTML document. The raw Markdown is passed to the
    /// page as base64 (sidesteps all HTML/JS escaping issues) and rendered by
    /// marked.js client-side.
    private static func htmlDocument(forMarkdown markdown: String) -> String {
        let b64 = Data(markdown.utf8).base64EncodedString()
        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(themeCSS)</style>
        </head>
        <body><article id="content" class="markdown-body"></article>
        <script>\(markedJS)</script>
        <script>
        (function () {
          const b64 = "\(b64)";
          const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0));
          const text = new TextDecoder("utf-8").decode(bytes);
          marked.setOptions({ gfm: true, breaks: false });
          document.getElementById("content").innerHTML = marked.parse(text);
        })();
        </script>
        </body></html>
        """
    }

    /// Dark, transparent GitHub-ish theme tuned for the app's blurred panel.
    private static let themeCSS = """
    :root { color-scheme: dark; }
    html, body { background: transparent; margin: 0; }
    body {
      font: 14px/1.65 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
      color: rgba(255,255,255,0.90);
      -webkit-font-smoothing: antialiased;
    }
    .markdown-body { max-width: 860px; margin: 0 auto; padding: 56px 36px 64px; }
    h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.25; margin: 1.4em 0 0.5em; }
    h1 { font-size: 1.9em; border-bottom: 1px solid rgba(255,255,255,0.12); padding-bottom: .3em; }
    h2 { font-size: 1.5em; border-bottom: 1px solid rgba(255,255,255,0.10); padding-bottom: .3em; }
    h3 { font-size: 1.25em; } h4 { font-size: 1.05em; }
    a { color: #6cb6ff; text-decoration: none; } a:hover { text-decoration: underline; }
    p, ul, ol, blockquote, table, pre { margin: 0 0 1em; }
    ul, ol { padding-left: 1.6em; }
    li { margin: .25em 0; }
    blockquote {
      margin-left: 0; padding: 0 1em; color: rgba(255,255,255,0.65);
      border-left: 3px solid rgba(255,255,255,0.18);
    }
    code {
      font: 12.5px/1.5 "SF Mono", ui-monospace, Menlo, monospace;
      background: rgba(255,255,255,0.10); padding: .15em .4em; border-radius: 5px;
    }
    pre {
      background: rgba(0,0,0,0.35); padding: 14px 16px; border-radius: 8px;
      overflow: auto; border: 1px solid rgba(255,255,255,0.08);
    }
    pre code { background: none; padding: 0; }
    table { border-collapse: collapse; width: 100%; display: block; overflow: auto; }
    th, td { border: 1px solid rgba(255,255,255,0.14); padding: 6px 12px; }
    th { background: rgba(255,255,255,0.06); font-weight: 600; }
    tr:nth-child(2n) td { background: rgba(255,255,255,0.03); }
    img { max-width: 100%; }
    hr { border: 0; border-top: 1px solid rgba(255,255,255,0.12); margin: 1.6em 0; }
    """
}

/// A bare container that forwards `layout()` to a closure, so the controller can
/// keep the editor / preview filling the bounds and the toolbar pinned top-left
/// without a separate Auto Layout graph.
private final class LayoutForwardingView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}
