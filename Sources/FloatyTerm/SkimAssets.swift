import AppKit
import WebKit

/// Loads SkimRender into WKWebView as WKUserScripts to avoid HTML parsing;
/// Mermaid lazy-loaded on first use via skim bridge.
enum SkimAssets {

    /// The directory holding skim-render.js and its vendor files, if any.
    static let root: URL? = {
        let fm = FileManager.default
        let marker = "skim-render.js"
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("SkimRender"),
           fm.fileExists(atPath: bundled.appendingPathComponent(marker).path) {
            return bundled
        }
        // Development: this file is Sources/FloatyTerm/SkimAssets.swift.
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/SkimRender")
        return fm.fileExists(atPath: dev.appendingPathComponent(marker).path) ? dev : nil
    }()

    static var isAvailable: Bool { root != nil && coreScripts != nil }

    private static func read(_ name: String) -> String? {
        guard let root else { return nil }
        return try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
    }

    /// Libraries every page needs, in load order.
    private static let coreScripts: [String]? = {
        let names = ["vendor/marked.min.js", "vendor/purify.min.js", "vendor/highlight.min.js",
                     "vendor/hljs-dart.min.js", "skim-classify.js", "skim-render.js"]
        let sources = names.compactMap(read)
        return sources.count == names.count ? sources : nil
    }()

    static let mermaidScript: String? = read("vendor/mermaid.min.js")

    /// fonts.css with each `url(fonts/…)` inlined as a data URL, so the page
    /// needs no file access to draw Rubik and JetBrains Mono.
    private static let fontsCSS: String = {
        guard let root, var css = read("fonts.css") else { return "" }
        let pattern = try! NSRegularExpression(pattern: #"url\((fonts/[^)]+\.woff2)\)"#)
        for m in pattern.matches(in: css, range: NSRange(css.startIndex..., in: css)).reversed() {
            guard let whole = Range(m.range, in: css), let rel = Range(m.range(at: 1), in: css),
                  let data = try? Data(contentsOf: root.appendingPathComponent(String(css[rel]))) else { continue }
            css.replaceSubrange(whole, with: "url(data:font/woff2;base64,\(data.base64EncodedString()))")
        }
        return css
    }()

    private static let skimCSS: String = read("skim.css") ?? ""
    private static let chatCSS: String = read("chat.css") ?? ""
    private static let chatScript: String? = read("chat.js")
    private static let agentScripts: [String]? = {
        let names = ["agent-events.js", "agent-claude.js", "agent-codex.js"]
        let sources = names.compactMap(read)
        return sources.count == names.count ? sources : nil
    }()
    static var isChatAvailable: Bool { isAvailable && chatScript != nil && agentScripts != nil }

    // MARK: - Web view setup

    /// Add renderer scripts and skim bridge to WKWebViewConfiguration.
    /// onAction receives controls that answer Claude (e.g. choosing an option).
    static func install(in config: WKWebViewConfiguration, chat: Bool = false,
                        onAction: (([String: Any]) -> Void)? = nil) {
        guard var scripts = coreScripts else { return }
        if chat {
            guard let agentScripts, let chatScript else { return }
            scripts.append(contentsOf: agentScripts)
            scripts.append(chatScript)
        }
        let ucc = config.userContentController
        for source in scripts {
            ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let bridge = SkimBridge(onAction: onAction)
        ucc.addScriptMessageHandler(bridge, contentWorld: .page, name: "skim")
        // On first Mermaid block: load as <script> not eval (mermaid strict mode requires globalThis access).
        let hook = """
        SkimRender.requestMermaid = () =>
          window.webkit.messageHandlers.skim.postMessage({ type: 'loadMermaid' }).then(src => {
            const s = document.createElement('script');
            s.textContent = src;
            document.head.append(s);
            s.remove();
          });
        """
        ucc.addUserScript(WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    /// The renderer's appearance from Settings; nil follows macOS. The pages switch with prefers-color-scheme.
    static var appearance: NSAppearance? {
        switch Settings.shared.rendererAppearance {
        case 1: return NSAppearance(named: .aqua)
        case 2: return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    /// Keeps `webView` on the chosen appearance, now and when Settings change. Remove the token in the owner's cleanup.
    static func followAppearance(_ webView: WKWebView) -> NSObjectProtocol {
        webView.appearance = appearance
        return NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak webView] _ in
            guard let webView, webView.appearance?.name != appearance?.name else { return }
            webView.appearance = appearance
        }
    }

    /// Removes the bridge — call from the owner's cleanup; the user content
    /// controller keeps its handlers alive otherwise.
    static func uninstall(from config: WKWebViewConfiguration) {
        config.userContentController.removeScriptMessageHandler(forName: "skim", contentWorld: .page)
    }

    /// A complete page that renders `markdown` once. The Markdown travels as
    /// base64, which sidesteps every HTML and JS escaping issue.
    static func document(markdown: String, interactive: Bool = false) -> String {
        let b64 = Data(markdown.utf8).base64EncodedString()
        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(fontsCSS)</style>
        <style>\(skimCSS)</style>
        </head>
        <body><main id="doc" class="sk-doc"></main>
        <script>
        (function () {
          const bytes = Uint8Array.from(atob("\(b64)"), c => c.charCodeAt(0));
          const text = new TextDecoder("utf-8").decode(bytes);
          SkimRender.render(document.getElementById("doc"), text, {
            interactive: \(interactive ? "true" : "false"),
            onAction: a => window.webkit.messageHandlers.skim.postMessage({ type: 'action', action: a })
          });
        })();
        </script>
        </body></html>
        """
    }
}

extension SkimAssets {
    /// Shared agent page (chat.js on renderer); AgentChat.boot after parse;
    /// events via AgentChat.receive.
    static func chatDocument(cwd: String, intro: String? = nil, agent: String = "claude") -> String {
        let cfg: [String: Any] = ["cwd": cwd, "home": NSHomeDirectory(), "intro": intro ?? "", "agent": agent, "voice": true]
        let json = (try? JSONSerialization.data(withJSONObject: cfg)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(fontsCSS)</style>
        <style>\(skimCSS)</style>
        <style>\(chatCSS)</style>
        </head>
        <body><script>AgentChat.boot(\(json.replacingOccurrences(of: "</", with: "<\\/")));</script></body></html>
        """
    }
}

/// Page-to-native renderer side; retained by user content controller until uninstall;
/// onAction capturing owner must be weak.
private final class SkimBridge: NSObject, WKScriptMessageHandlerWithReply {
    private let onAction: (([String: Any]) -> Void)?

    init(onAction: (([String: Any]) -> Void)?) { self.onAction = onAction }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else {
            replyHandler(nil, "bad message"); return
        }
        switch type {
        case "loadMermaid":
            if let src = SkimAssets.mermaidScript { replyHandler(src, nil) } else { replyHandler(nil, "mermaid is not bundled") }
        case "action":
            if let action = body["action"] as? [String: Any] { onAction?(action) }
            replyHandler(nil, nil)
        default:
            replyHandler(nil, "unknown message \(type)")
        }
    }
}
