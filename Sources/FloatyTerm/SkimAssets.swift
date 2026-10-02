import Foundation
import WebKit

/// Loads the SkimRender web renderer (`Resources/SkimRender`) into a
/// `WKWebView`: skimmable Markdown — option cards, phase tracks, diagrams,
/// file trees, callouts, itemized notes, tables, checklists and labeled
/// sections — styled after the "Markdown, made skimmable" design.
///
/// The files ship in the app bundle (`Contents/Resources/SkimRender`, copied by
/// build.sh) rather than as Swift string literals: Mermaid alone is 3.5 MB,
/// which would make every compile slow. A `swift run` from the repo falls back
/// to the source tree. When neither is present, `isAvailable` is false and
/// callers keep their plain renderer.
///
/// Scripts go in as `WKUserScript`s, so no library text passes through the
/// HTML parser. Mermaid is not injected up front: the page asks for it over the
/// `skim` bridge the first time a reply contains a Mermaid block.
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

    /// Adds the renderer's scripts and the `skim` bridge to a configuration.
    /// `onAction` receives controls that answer Claude, e.g. choosing an option
    /// (`["type": "reply", "text": "Go with option A"]`).
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
        // The renderer calls this the first time it meets a Mermaid block. The
        // source runs as a <script> element, not through eval: mermaid.min.js
        // opens with "use strict", and strict eval keeps its top-level `var`s
        // local, so the library would never reach globalThis.
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
    /// The shared agent page (chat.js on top of the renderer). `AgentChat.boot`
    /// runs once the document has parsed; events arrive later through
    /// `AgentChat.receive`.
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

/// The page-to-native side of the renderer. The user content controller
/// retains it until `SkimAssets.uninstall` removes it, so an `onAction` that
/// captures its owner must capture it weakly.
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
