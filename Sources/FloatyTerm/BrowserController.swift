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

    // MARK: - Browser state

    /// The underlying web view, typed for internal use.
    let webView: WKWebView

    var canGoBack:    Bool { webView.canGoBack    }
    var canGoForward: Bool { webView.canGoForward }

    // MARK: - KVO

    private var titleObservation: NSKeyValueObservation?

    // MARK: - Init

    override init() {
        // ── Ephemeral session ────────────────────────────────────────────────
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()

        // ── Transparency coaxing CSS ─────────────────────────────────────────
        // Injected at document-start so it applies before page paint.
        // NOTE: This is aggressive — it forces transparent backgrounds on all
        //       sites. Most look fine over the blur, but some dark-mode pages
        //       use background-color for readability; they may look odd. The
        //       intent is to let the blurred floating panel show through.
        //       This is tunable in a future Phase 2 setting.
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

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false

        // ── Transparency coaxing (native layer) ──────────────────────────────
        // (a) KVC private API — suppresses the default opaque white backdrop.
        //     Accepted use: confirmed working on macOS 13–15; Apple's WKWebView
        //     team has acknowledged this key informally. No App Store concern
        //     here (this is a non-sandboxed macOS app).
        wv.setValue(false, forKey: "drawsBackground")
        // (b) Clear CALayer background — no compositor solid fill behind content.
        wv.wantsLayer = true
        wv.layer?.backgroundColor = CGColor.clear
        // (c) macOS 12+ official API for the "under page" gutter colour.
        if #available(macOS 12.0, *) {
            wv.underPageBackgroundColor = .clear
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
            self.onTitleChanged?()
        }

        // Load the default homepage.
        load("https://duckduckgo.com")
    }

    // MARK: - TabContent focus / cleanup

    func focus(in panel: NSWindow) {
        panel.makeFirstResponder(webView)
    }

    func cleanup() {
        titleObservation = nil
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
        // If it already has a scheme, parse it directly.
        if text.lowercased().hasPrefix("http://") || text.lowercased().hasPrefix("https://") {
            return URL(string: text)
        }
        // Looks like a hostname (contains a dot, no spaces)?
        if !text.contains(" "), text.contains(".") {
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
        if alert.runModal() == .alertFirstButtonReturn {
            completionHandler(field.stringValue)
        } else {
            completionHandler(nil)
        }
    }
}
