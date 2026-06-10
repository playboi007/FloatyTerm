import AppKit
import WebKit

/// Owns one WKWebView browser session (i.e. one browser tab).
///
/// Shape mirrors `TerminalController`:
///  - conforms to `TabContent`
///  - ephemeral WKWebViewConfiguration (no persistence)
///  - transparency coaxing so the blur behind shows through
///  - KVO title observation → drives the tab chip label
///  - `load(_:)` smart URL / search-query router
///  - WKUIDelegate stubs so JS dialogs and target=_blank don't hang
final class BrowserController: NSObject, TabContent, WKNavigationDelegate, WKUIDelegate {

    // MARK: - TabContent

    let view: NSView   // the WKWebView itself, exposed as NSView for the protocol
    private(set) var title: String = "Browser"
    var onTitleChanged: (() -> Void)?
    var onTerminated: (() -> Void)?   // browsers never self-terminate; kept for protocol

    /// Fired when the URL or back/forward availability changes, so the URL bar
    /// stays in sync on navigations that don't change the page title.
    var onNavChanged: (() -> Void)?

    /// User-pinned name (right-click chip → Rename). Wins over the page title.
    var customName: String?

    var displayName: String {
        if let name = customName, !name.isEmpty { return name }
        return title
    }

    // MARK: - Unseen-change tracking (title changes while not in view)

    private(set) var hasUnseenOutput = false

    var isCurrentlyViewed = true {
        didSet { if isCurrentlyViewed { hasUnseenOutput = false } }
    }

    // MARK: - Browser state

    /// The underlying web view, typed for internal use.
    let webView: WKWebView

    var canGoBack:    Bool { webView.canGoBack    }
    var canGoForward: Bool { webView.canGoForward }

    // MARK: - KVO

    private var titleObservation: NSKeyValueObservation?
    private var navObservations: [NSKeyValueObservation] = []

    // MARK: - Init

    private let initialURL: String?

    /// - Parameter initialURL: first page to load; nil = the default homepage.
    ///   Used by session restore to bring a browser tab back to its last page.
    init(initialURL: String? = nil) {
        self.initialURL = initialURL
        // ── Ephemeral session ────────────────────────────────────────────────
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        // ── Transparency coaxing (optional, Settings.browserTransparency) ───
        // Aggressive: forces transparent page backgrounds on all sites so the
        // blurred panel shows through. Some dark-mode pages rely on their
        // background-color for readability, so this is a user setting now;
        // it's baked into the WKWebView config, so it applies to tabs created
        // after the toggle (existing tabs keep their look).
        let transparent = Settings.shared.browserTransparency
        if transparent {
            let css = "html, body { background-color: transparent !important; }"
            let script = WKUserScript(
                source: """
                (function() {
                    var style = document.createElement('style');
                    style.textContent = '\(css)';
                    document.documentElement.appendChild(style);
                })();
                """,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            config.userContentController.addUserScript(script)
        }

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false

        if transparent {
            // ── Transparency coaxing (native layer) ─────────────────────────
            // (a) KVC private API — suppresses the default opaque white
            //     backdrop. Confirmed working on macOS 13–15; no App Store
            //     concern here (this is a non-sandboxed macOS app).
            wv.setValue(false, forKey: "drawsBackground")
            // (b) Clear CALayer background — no compositor fill behind content.
            wv.wantsLayer = true
            wv.layer?.backgroundColor = CGColor.clear
            // (c) macOS 12+ official API for the "under page" gutter colour.
            if #available(macOS 12.0, *) {
                wv.underPageBackgroundColor = .clear
            }
        }

        webView = wv
        view    = wv
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate         = self

        // ── KVO: watch the web view's published `title` property ────────────
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, change in
            guard let self else { return }
            let newTitle = change.newValue??.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.title = newTitle.isEmpty ? "Browser" : newTitle
            if !self.isCurrentlyViewed { self.hasUnseenOutput = true }
            self.onTitleChanged?()
        }

        // ── KVO: URL + history state → keep the URL bar honest ──────────────
        navObservations = [
            webView.observe(\.url)          { [weak self] _, _ in self?.onNavChanged?() },
            webView.observe(\.canGoBack)    { [weak self] _, _ in self?.onNavChanged?() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.onNavChanged?() }
        ]

        // Load the restored page, or the default homepage.
        load(initialURL ?? "https://duckduckgo.com")
    }

    // MARK: - Page zoom (⌘+/⌘−/⌘0)

    func zoomIn()    { webView.pageZoom = min(3.0, webView.pageZoom + 0.1) }
    func zoomOut()   { webView.pageZoom = max(0.5, webView.pageZoom - 0.1) }
    func resetZoom() { webView.pageZoom = 1.0 }

    // MARK: - TabContent focus / cleanup

    func focus(in panel: NSWindow) {
        panel.makeFirstResponder(webView)
    }

    func cleanup() {
        titleObservation = nil
        navObservations = []
        webView.stopLoading()
    }

    // MARK: - Navigation API

    /// Loads a URL string or (if it isn't a valid URL) treats the input as a
    /// DuckDuckGo search query.
    func load(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let url: URL
        if let explicit = parseURL(trimmed) {
            url = explicit
        } else {
            // Treat as a search query.
            var comps = URLComponents(string: "https://duckduckgo.com/")!
            comps.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            url = comps.url!
        }
        webView.load(URLRequest(url: url))
    }

    func goBack()    { webView.goBack()    }
    func goForward() { webView.goForward() }
    func reload()    { webView.reload()    }

    // MARK: - URL parsing helper

    private func parseURL(_ text: String) -> URL? {
        // Anything with an explicit scheme (http, https, file, about…) parses
        // directly — don't second-guess it into a search.
        if text.contains("://") || text.lowercased().hasPrefix("about:") {
            return URL(string: text)
        }
        guard !text.contains(" ") else { return nil }
        // Dev-server style: localhost / 127.0.0.1, with or without a port.
        let host = text.split(separator: "/").first.map(String.init) ?? text
        let bareHost = host.split(separator: ":").first.map(String.init) ?? host
        if bareHost == "localhost" || bareHost == "127.0.0.1" {
            return URL(string: "http://\(text)")
        }
        // Looks like a hostname (contains a dot)?
        if text.contains(".") {
            return URL(string: "https://\(text)")
        }
        return nil
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Title is updated via KVO; no extra work needed here.
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        // Swallow navigation errors silently in Phase 1 — the web view shows
        // its own built-in error page.
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(.allow)
    }

    // MARK: - WKUIDelegate stubs

    /// target=_blank links: load in the same web view instead of opening a new
    /// window, so we don't spawn windows we can't manage.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    /// JS alert() — show a minimal NSAlert and dismiss immediately after.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)  // accessory app: surface the modal
        alert.runModal()
        completionHandler()
    }

    /// JS confirm() — show a two-button alert; return the user's choice.
    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    /// JS prompt() — show a text-input alert; return the typed value or nil if cancelled.
    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            completionHandler(field.stringValue)
        } else {
            completionHandler(nil)
        }
    }
}
