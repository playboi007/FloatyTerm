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
/// One captured browser selection: what the user highlighted, the text of its
/// enclosing block (the "surrounding paragraph" sweet spot), page identity,
/// and where on the web view it sits (AppKit view coords, for chip placement).
struct BrowserSelection {
    let text: String
    let context: String
    let pageTitle: String
    let urlString: String
    let viewPoint: NSPoint
}

final class BrowserController: NSObject, TabContent, WKNavigationDelegate, WKUIDelegate,
                               WKScriptMessageHandler {

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

    var restorableRecord: TabRecord? {
        TabRecord(kind: "browser", customName: customName,
                  url: webView.url?.absoluteString)
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

    // MARK: - Intrusion blocking (popups / unsolicited redirects)

    /// How many popups / redirects this tab has dropped. Drives the URL-bar
    /// shield's count. Resets when the page navigates (per-page tally).
    private(set) var blockedCount = 0

    /// Fired when `blockedCount` changes, so the host can refresh the shield.
    var onBlockedCountChanged: (() -> Void)?

    /// Per-tab escape hatch: when true, this tab honours popups and redirects
    /// regardless of the global settings (the shield's "allow on this site").
    var protectionDisabled = false {
        didSet { applyPopupPolicy(); onBlockedCountChanged?() }
    }

    /// Observes `Settings.didChange` so the popup-faker flag tracks the live
    /// blockPopups setting. Removed in `cleanup`.
    private var settingsObserver: NSObjectProtocol?

    /// Pushes the current effective popup policy into the page: when blocking
    /// is on for this site, the faker returns a stub window; when off, it
    /// defers to the real `window.open`.
    private func applyPopupPolicy() {
        let allow = protectionDisabled || !Settings.shared.blockPopups
        webView.evaluateJavaScript("window.__floatyAllowPopups = \(allow);",
                                   completionHandler: nil)
    }

    /// Timestamp of the last real user interaction (pointer/key), reported by
    /// the gesture beacon. Used to tell a user-driven redirect from an
    /// unsolicited one.
    private var lastGestureAt = Date.distantPast

    private func noteBlocked() {
        blockedCount += 1
        onBlockedCountChanged?()
    }

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

        // ── Selection bridge ─────────────────────────────────────────────────
        // Captures text selections (plus the enclosing block as context) so
        // the user can hand "what I'm looking at" to an agent in a sibling
        // terminal tab. Data-only: nothing from the page can execute anything.
        config.userContentController.addUserScript(WKUserScript(
            source: Self.selectionCaptureJS,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        // ── Devtools capture ─────────────────────────────────────────────────
        // Wraps console.*, error events, fetch and XHR — every event streams
        // into a per-tab log file an agent in a sibling terminal can tail.
        // Must run at documentStart so the wrapping is in place before any
        // page code executes.
        config.userContentController.addUserScript(WKUserScript(
            source: Self.devtoolsCaptureJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        // ── User-gesture beacon ──────────────────────────────────────────────
        // Records the timestamp of the last genuine pointer/key interaction so
        // the navigation policy can tell a user-driven redirect from an
        // unsolicited (timer-driven) ad redirect. Capture phase + all frames so
        // a click in the video-player iframe still counts. Cheap; the native
        // side only consults it when redirect blocking is enabled.
        config.userContentController.addUserScript(WKUserScript(
            source: Self.gestureBeaconJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        // ── Popup faker (anti-adblock gate bypass) ───────────────────────────
        // Many streaming sites gate their content behind `var w =
        // window.open(ad); if (w) unlock();` — a hard native block returns null,
        // the page sees it was blocked, and refuses to play. Instead we replace
        // window.open with a stub that returns a believable no-op window so the
        // gate passes while nothing actually opens. Live-gated by the
        // `__floatyAllowPopups` flag (set from `applyPopupPolicy`) so the per-
        // site shield can still let real popups through. documentStart + all
        // frames so it's in place before any page or ad-iframe code runs.
        config.userContentController.addUserScript(WKUserScript(
            source: Self.popupFakerJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

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

        // The handlers must be registered through a weak proxy:
        // userContentController retains its handler, and a direct `self`
        // would leak every closed browser tab.
        let proxy = WeakScriptMessageHandler(self)
        config.userContentController.add(proxy, name: "floatySelection")
        config.userContentController.add(proxy, name: "floatyDevtools")
        config.userContentController.add(proxy, name: "floatyGesture")
        config.userContentController.add(proxy, name: "floatyPopup")

        // Keep the in-page popup-faker flag in step with the live settings /
        // per-site override, without needing a navigation to take effect.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.applyPopupPolicy() }

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
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "floatySelection")
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "floatyDevtools")
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "floatyGesture")
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "floatyPopup")
        if let observer = settingsObserver {
            NotificationCenter.default.removeObserver(observer)
            settingsObserver = nil
        }
        if let path = devtoolsLogPath {   // ephemeral: log dies with the tab
            let url = URL(fileURLWithPath: path)
            DevtoolsLog.shared.drop(url)
            try? FileManager.default.removeItem(at: url)
        }
        webView.stopLoading()
    }

    // MARK: - Devtools awareness (console / errors / network → log file)

    /// Recent devtools events ("12:01:33 [error] …"), capped — included in
    /// Ask-Agent context files.
    private(set) var recentDevtoolsEvents: [String] = []

    /// The per-tab devtools log on disk (created on the first event). An
    /// agent can `tail -f` this to watch the page live. Deleted with the tab.
    private(set) var devtoolsLogPath: String?
    private let devtoolsID = UUID().uuidString

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func ingestDevtoolsEvent(_ body: [String: Any]?) {
        guard let body, body["kind"] is String else { return }
        // Disk gets structured NDJSON (agents parse fields, not prose);
        // the in-memory ring keeps human-readable lines for the Ask-Agent
        // markdown context.
        if let line = DevtoolsRelay.ndjsonLine(from: body) {
            appendDevtoolsLine(line)
        }
        if let human = Self.humanLine(from: body) {
            recentDevtoolsEvents.append(
                "\(Self.timeFormatter.string(from: Date())) \(human)")
            if recentDevtoolsEvents.count > 500 { recentDevtoolsEvents.removeFirst(100) }
        }
    }

    /// Renders a structured event as one readable line for inline context.
    private static func humanLine(from e: [String: Any]) -> String? {
        switch e["kind"] as? String {
        case "loaded":
            return "── page loaded: \(e["url"] as? String ?? "?") ──"
        case "console":
            return "[\(e["level"] as? String ?? "log")] \(e["text"] as? String ?? "")"
        case "error":
            let msg = e["message"] as? String ?? "?"
            if let src = e["source"] as? String {
                return "[error] \(msg) @ \(src):\(e["line"] ?? 0)"
            }
            return "[error] \(msg)"
        case "network":
            let m = e["method"] as? String ?? "?"
            let u = e["url"] as? String ?? "?"
            if let status = e["status"] {
                return "[network] \(m) \(u) → \(status) (\(e["ms"] ?? 0)ms)"
            }
            return "[network] \(m) \(u) → FAILED \(e["error"] as? String ?? "")"
        default:
            return nil
        }
    }

    private func appendDevtoolsLine(_ line: String) {
        let url: URL
        if let path = devtoolsLogPath {
            url = URL(fileURLWithPath: path)
        } else {
            // Provenance in the filename: the host this tab was on when its
            // first event arrived, plus a short id so two tabs on the same
            // site don't collide. Lives under Devtools/tabs/ (remote pages
            // get Devtools/remote/). The shared sink owns the handle and
            // recreates the file if a sweep deletes it mid-session.
            let host = DevtoolsRelay.sanitize(webView.url?.host ?? "tab")
            url = DevtoolsRelay.logDirectory(category: "tabs")
                .appendingPathComponent("\(host)-\(devtoolsID.prefix(8)).ndjson")
            devtoolsLogPath = url.path
        }
        DevtoolsLog.shared.append(line + "\n", to: url)
    }

    /// Console/error/network tap, installed before page code runs.
    private static let devtoolsCaptureJS = #"""
    (function () {
        if (window.__floatyDevtools) return; window.__floatyDevtools = true;

        // ── User-action context (the causal chain) ──
        // Records the last interaction so each event can carry what the user
        // did right before it ("clicked Submit" → POST → 500). Capture phase
        // so stopPropagation can't hide actions. Input VALUES are never read.
        var lastAction = null;
        function recordAction(type, target) {
            try {
                var el = (target && target.closest)
                    ? (target.closest('button,a,[role="button"],input,select,textarea,form') || target)
                    : target;
                if (!el || !el.tagName) return;
                var text;
                if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT') {
                    text = el.name || el.placeholder || el.type || '';
                } else {
                    text = (el.innerText || '').trim().slice(0, 40);
                }
                lastAction = { type: type, element: el.tagName,
                               id: el.id || '', text: text, ts: Date.now() };
            } catch (e) {}
        }
        document.addEventListener('click',   function (e) { recordAction('click', e.target);  }, true);
        document.addEventListener('input',   function (e) { recordAction('input', e.target);  }, true);
        document.addEventListener('submit',  function (e) { recordAction('submit', e.target); }, true);
        document.addEventListener('focusin', function (e) { recordAction('focus', e.target);  }, true);
        // Attached per event at post() time (NOT at batch-flush time, which
        // would mis-attribute) when the action is fresh enough to be causal.
        function withAction(p) {
            if (lastAction && Date.now() - lastAction.ts <= 3000) p.triggered_by = lastAction;
            return p;
        }
        function post(p) {
            try { window.webkit.messageHandlers.floatyDevtools.postMessage(withAction(p)); } catch (e) {}
        }
        post({ kind: 'loaded', url: location.href });
        function fmt(a) {
            if (typeof a === 'string') return a;
            try { return JSON.stringify(a); } catch (e) { return String(a); }
        }
        ['log','info','warn','error','debug'].forEach(function (level) {
            const orig = console[level];
            console[level] = function () {
                const args = [...arguments];
                post({ kind: 'console', level: level,
                       text: args.map(fmt).join(' ').slice(0, 2000) });
                return orig.apply(this, args);
            };
        });
        window.addEventListener('error', function (e) {
            post({ kind: 'error', message: e.message || '?',
                   source: e.filename || '?', line: e.lineno || 0 });
        });
        window.addEventListener('unhandledrejection', function (e) {
            post({ kind: 'error',
                   message: 'Unhandled rejection: ' + fmt(e.reason).slice(0, 1000) });
        });
        const ofetch = window.fetch;
        if (ofetch) window.fetch = function (input, init) {
            const url = (typeof input === 'string') ? input : ((input && input.url) || '');
            const method = ((init && init.method) || (input && input.method) || 'GET').toUpperCase();
            const t0 = Date.now();
            return ofetch.apply(this, arguments).then(function (r) {
                post({ kind: 'network', method: method, url: url,
                       status: r.status, ms: Date.now() - t0 });
                return r;
            }, function (err) {
                post({ kind: 'network', method: method, url: url,
                       error: String(err).slice(0, 300) });
                throw err;
            });
        };
        const oopen = XMLHttpRequest.prototype.open;
        const osend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function (m, u) {
            this.__floaty = { m: String(m).toUpperCase(), u: String(u) };
            return oopen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function () {
            const info = this.__floaty || { m: '?', u: '?' };
            const t0 = Date.now(), xhr = this;
            this.addEventListener('loadend', function () {
                post({ kind: 'network', method: info.m, url: info.u,
                       status: xhr.status, ms: Date.now() - t0 });
            });
            return osend.apply(this, arguments);
        };
    })();
    """#

    /// Pings the native side on every genuine user interaction. Capture phase
    /// so a page can't hide the gesture with stopPropagation; no values are
    /// read — it only signals "the user just did something".
    private static let gestureBeaconJS = """
    (function () {
        if (window.__floatyGesture) return; window.__floatyGesture = true;
        function ping() {
            try { window.webkit.messageHandlers.floatyGesture.postMessage(1); } catch (e) {}
        }
        ['pointerdown', 'keydown', 'wheel', 'touchstart'].forEach(function (t) {
            document.addEventListener(t, ping, true);
        });
    })();
    """

    /// Replaces `window.open` with a stub that returns a believable but inert
    /// window object, so anti-adblock gates ("if (window.open(ad)) unlock()")
    /// pass without anything actually opening. Honours `__floatyAllowPopups`:
    /// when set (per-site shield off, or blocking disabled) it defers to the
    /// real opener. The Proxy returns a no-op function for any unknown property
    /// so however the page pokes at the returned window, nothing throws.
    private static let popupFakerJS = """
    (function () {
        if (window.__floatyPopupFaker) return; window.__floatyPopupFaker = true;
        var realOpen = window.open;
        function makeStub() {
            var loc = { href: '', protocol: '', host: '', pathname: '', search: '', hash: '',
                        assign: function () {}, replace: function () {}, reload: function () {},
                        toString: function () { return ''; } };
            var win = {
                closed: false, opener: null, name: '', length: 0,
                close:  function () { win.closed = true; },
                focus:  function () {}, blur: function () {},
                postMessage: function () {}, scrollTo: function () {}, scrollBy: function () {},
                location: loc, self: null, window: null, top: null, frames: [],
                document: { write: function () {}, writeln: function () {},
                            open: function () {}, close: function () {} },
                open: function () { return makeStub(); }
            };
            win.self = win; win.window = win; win.top = win;
            return new Proxy(win, {
                get: function (t, p) {
                    if (p in t) return t[p];
                    return function () { return undefined; };
                },
                set: function (t, p, v) { t[p] = v; return true; }
            });
        }
        window.open = function (url, name, features) {
            if (window.__floatyAllowPopups) return realOpen.apply(window, arguments);
            try { window.webkit.messageHandlers.floatyPopup.postMessage(String(url || '')); } catch (e) {}
            return makeStub();
        };
    })();
    """

    // MARK: - Selection bridge

    /// Fired whenever the page's selection changes — with the capture, or nil
    /// when the selection collapsed. The window controller shows/hides the
    /// "Ask Agent" chip off this.
    var onSelectionChanged: ((BrowserSelection?) -> Void)?

    /// The most recent non-empty selection, consumed by "Ask Agent".
    private(set) var latestSelection: BrowserSelection?

    /// Fetches the page content as STRUCTURED markdown (for the context file
    /// an agent can read). Flat `innerText` collapses cards, tables, and
    /// sections into an undifferentiated stream; this serializer keeps the
    /// grouping: headings → #, lists → bullets, tables → markdown tables,
    /// links/buttons/inputs annotated, named sections marked with dividers.
    func fetchFullPageText(completion: @escaping (String) -> Void) {
        webView.evaluateJavaScript(Self.structuredCaptureJS) { result, _ in
            completion(result as? String ?? "")
        }
    }

    /// DOM → markdown serializer, evaluated at send time (not on every
    /// selection — pages like the BigQuery console are enormous). Raw string
    /// so the JS regex backslashes survive.
    private static let structuredCaptureJS = #"""
    (function () {
        const SKIP = new Set(['SCRIPT','STYLE','NOSCRIPT','TEMPLATE','SVG',
                              'CANVAS','VIDEO','AUDIO','IFRAME','OBJECT']);
        const BLOCK = new Set(['P','DIV','SECTION','ARTICLE','ASIDE','MAIN','HEADER',
                               'FOOTER','NAV','FORM','FIELDSET','UL','OL','TABLE','PRE',
                               'BLOCKQUOTE','H1','H2','H3','H4','H5','H6','BUTTON','INPUT',
                               'TEXTAREA','SELECT','FIGURE','FIGCAPTION','DL','DT','DD',
                               'LI','TR','HR','DETAILS','SUMMARY']);
        const SEMANTIC = new Set(['SECTION','ARTICLE','ASIDE','MAIN','HEADER',
                                  'FOOTER','NAV','FORM','FIELDSET','DETAILS']);
        function visible(el) {
            if (el.getAttribute && el.getAttribute('aria-hidden') === 'true') return false;
            const st = window.getComputedStyle(el);
            return st.display !== 'none' && st.visibility !== 'hidden';
        }
        function clean(s) {
            return s.replace(/[ \t ]+/g, ' ').replace(/ ?\n ?/g, '\n').trim();
        }
        // Inline content: text with links, code spans, images annotated.
        function inline(node) {
            if (node.nodeType === 3) return node.textContent;
            if (node.nodeType !== 1) return '';
            const el = node, tag = el.tagName;
            if (SKIP.has(tag) || !visible(el)) return '';
            if (tag === 'BR') return '\n';
            if (tag === 'IMG') return el.alt ? '![' + el.alt + ']' : '';
            if (tag === 'CODE') return '`' + el.textContent + '`';
            const t = [...el.childNodes].map(inline).join('');
            if (tag === 'A') {
                const txt = t.trim(), href = el.getAttribute('href') || '';
                if (!txt) return '';
                return href && !href.startsWith('javascript:')
                    ? '[' + txt + '](' + href + ')' : txt;
            }
            return t;
        }
        function sectionName(el) {
            return el.getAttribute('aria-label')
                || el.getAttribute('data-testid')
                || (SEMANTIC.has(el.tagName) ? el.id : '')
                || '';
        }
        function block(el, depth, out) {
            if (out.length > 4000 || depth > 25) return;
            if (el.nodeType !== 1 || SKIP.has(el.tagName) || !visible(el)) return;
            const tag = el.tagName;
            const h = tag.match(/^H([1-6])$/);
            if (h) { const t = clean(inline(el)); if (t) out.push('#'.repeat(+h[1]) + ' ' + t); return; }
            if (tag === 'P' || tag === 'FIGCAPTION' || tag === 'DT' ||
                tag === 'DD' || tag === 'SUMMARY') {
                const t = clean(inline(el)); if (t) out.push(t); return;
            }
            if (tag === 'BLOCKQUOTE') {
                const t = clean(inline(el)); if (t) out.push('> ' + t.replace(/\n/g, '\n> ')); return;
            }
            if (tag === 'HR') { out.push('---'); return; }
            if (tag === 'PRE') { out.push('```\n' + el.textContent.trim() + '\n```'); return; }
            if (tag === 'UL' || tag === 'OL') {
                let i = 1;
                for (const li of el.children) {
                    if (li.tagName !== 'LI' || !visible(li)) continue;
                    const t = clean(inline(li));
                    if (t) out.push((tag === 'OL' ? (i++) + '. ' : '- ') + t.replace(/\n+/g, ' · '));
                }
                return;
            }
            if (tag === 'TABLE') {
                let first = true;
                for (const tr of [...el.querySelectorAll('tr')].slice(0, 80)) {
                    const cells = [...tr.children].map(c => clean(inline(c)).replace(/\|/g, '/').replace(/\n+/g, ' '));
                    if (!cells.some(c => c)) continue;
                    out.push('| ' + cells.join(' | ') + ' |');
                    if (first) { out.push('|' + cells.map(() => ' --- ').join('|') + '|'); first = false; }
                }
                return;
            }
            if (tag === 'BUTTON') {
                const t = clean(inline(el)); if (t) out.push('[button: ' + t + ']'); return;
            }
            if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') {
                if (el.type === 'hidden') return;
                const name = el.getAttribute('aria-label') || el.placeholder || el.name || el.type || 'field';
                const val = (el.value || '').slice(0, 300);
                out.push('[' + tag.toLowerCase() + ': ' + name + (val ? ' = "' + val + '"' : '') + ']');
                return;
            }
            // Containers: named/semantic ones get a divider so grouping survives.
            const name = sectionName(el);
            if (SEMANTIC.has(tag) || name) {
                out.push('—— ' + tag.toLowerCase() + (name ? ' "' + name + '"' : '') + ' ——');
            }
            // Walk children, accumulating inline runs between block children
            // so mixed content ("text <div>…</div> text") loses nothing.
            let buf = '';
            for (const n of el.childNodes) {
                if (n.nodeType === 1 && BLOCK.has(n.tagName)) {
                    const t = clean(buf); if (t) out.push(t); buf = '';
                    block(n, depth + 1, out);
                } else {
                    buf += inline(n);
                }
            }
            const t = clean(buf); if (t) out.push(t);
        }
        const out = [];
        block(document.body, 0, out);
        return out.join('\n\n').slice(0, 200000);
    })()
    """#

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "floatyGesture" {
            lastGestureAt = Date()
            return
        }
        if message.name == "floatyPopup" {   // a window.open the faker stubbed
            noteBlocked()
            return
        }
        if message.name == "floatyDevtools" {
            ingestDevtoolsEvent(message.body as? [String: Any])
            return
        }
        guard message.name == "floatySelection",
              let body = message.body as? [String: Any] else { return }
        guard let text = body["selected"] as? String,
              !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            latestSelection = nil
            onSelectionChanged?(nil)
            return
        }
        // CSS coords have a top-left origin; AppKit views are bottom-left.
        let cssX = body["x"] as? Double ?? 0
        let cssY = body["y"] as? Double ?? 0
        let selection = BrowserSelection(
            text: text,
            context: body["context"] as? String ?? "",
            pageTitle: body["title"] as? String ?? title,
            urlString: body["url"] as? String ?? (webView.url?.absoluteString ?? ""),
            viewPoint: NSPoint(x: cssX, y: webView.bounds.height - cssY)
        )
        latestSelection = selection
        onSelectionChanged?(selection)
    }

    /// Reports the selection (and its enclosing block's text, trimmed to a
    /// window around the selection) on mouse-up. An empty report clears.
    private static let selectionCaptureJS = """
    (function () {
        function capture() {
            const s = window.getSelection();
            if (!s || s.isCollapsed) return null;
            const text = s.toString();
            if (!text.trim()) return null;
            let node = s.anchorNode;
            if (node && node.nodeType === 3) node = node.parentElement;
            let ctx = '';
            while (node && node !== document.body) {
                ctx = node.innerText || '';
                if (ctx.length > 80) break;
                node = node.parentElement;
            }
            if (ctx.length > 600) {
                const i = Math.max(0, ctx.indexOf(text.slice(0, 50)));
                const start = Math.max(0, i - 250);
                ctx = ctx.slice(start, start + 600);
            }
            const r = s.getRangeAt(0).getBoundingClientRect();
            return { selected: text.slice(0, 4000), context: ctx,
                     title: document.title, url: location.href,
                     x: r.left + r.width / 2, y: r.top };
        }
        function report() {
            try {
                window.webkit.messageHandlers.floatySelection
                    .postMessage(capture() || {});
            } catch (e) {}
        }
        // Small delay lets the selection settle after the mouse releases.
        document.addEventListener('mouseup', () => setTimeout(report, 50));
        document.addEventListener('keyup', (e) => {
            if (e.key === 'Escape') setTimeout(report, 50);
        });
    })();
    """

    // MARK: - Navigation API

    /// Loads a URL string or (if it isn't a valid URL) treats the input as a
    /// DuckDuckGo search query.
    func load(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // An explicit load (URL bar / restore / homepage) is user-intended, so
        // count it as a gesture — otherwise redirect blocking, which sees a
        // programmatic cross-site `.other` navigation, would cancel it.
        lastGestureAt = Date()

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

    /// New document committed: re-assert the popup policy (the previous page's
    /// flag doesn't carry over) before the page's gate code runs.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        applyPopupPolicy()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Title is updated via KVO; reset the per-page intrusion tally so the
        // shield's count reflects only the page now in view.
        if navigation != nil, blockedCount != 0 {
            blockedCount = 0
            onBlockedCountChanged?()
        }
        applyPopupPolicy()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                 withError error: Error) {
        // Swallow navigation errors silently in Phase 1 — the web view shows
        // its own built-in error page.
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if Settings.shared.blockRedirects, !protectionDisabled,
           isUnsolicitedRedirect(navigationAction) {
            noteBlocked()
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// True for a main-frame navigation to a *different* site that fires with
    /// no recent user interaction — the timer-driven ad-redirect signature.
    /// Same-site navigations, downloads, link clicks, and anything within ~1s
    /// of a real gesture are treated as legitimate.
    private func isUnsolicitedRedirect(_ action: WKNavigationAction) -> Bool {
        guard action.targetFrame?.isMainFrame == true,
              action.navigationType == .other,
              let destHost = action.request.url?.host,
              let currentHost = webView.url?.host,
              destHost != currentHost else { return false }
        return Date().timeIntervalSince(lastGestureAt) > 1.0
    }

    // MARK: - WKUIDelegate stubs

    /// A page asked to open a new window (window.open / target=_blank). We
    /// never spawn a window we can't manage, so the choice is only: drop it, or
    /// follow it in this same view.
    ///
    /// With popup blocking on (and not disabled for this site) we drop it
    /// entirely — this is the "click play → new ad tab" defence: the user's
    /// real click still drives the page, the spawned popup just dies. With
    /// blocking off we preserve the old behaviour and follow the link in place.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if Settings.shared.blockPopups, !protectionDisabled {
            noteBlocked()
            return nil
        }
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

/// WKUserContentController retains its message handlers; this proxy keeps the
/// BrowserController weakly so closing a tab actually releases it.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
