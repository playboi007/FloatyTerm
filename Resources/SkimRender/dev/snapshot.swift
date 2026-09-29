// Renders a page in a real WKWebView (the engine FloatyTerm uses) and saves a
// full-page PNG, plus any JS errors the page logged. For checking SkimRender
// without launching the app.
//
//   swift Resources/SkimRender/dev/snapshot.swift <page.html> <out.png> [width] [settle-seconds] [viewport-height]
//
// With a .md file it renders through the app's own loader instead — the path
// the Markdown Viewer takes (user scripts, the skim bridge, lazy Mermaid):
//   cp Resources/SkimRender/dev/snapshot.swift /tmp/main.swift   (top-level code must live in main.swift)
//   swiftc -D SKIM_HOST Sources/FloatyTerm/SkimAssets.swift /tmp/main.swift -o /tmp/skimshot
//   /tmp/skimshot notes.md out.png
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: snapshot.swift <page.html> <out.png> [width] [settle]\n".data(using: .utf8)!)
    exit(2)
}
// `page.html?only=…` keeps the query: the fixture page filters samples with it.
let pageParts = args[1].split(separator: "?", maxSplits: 1).map(String.init)
let pageFile = URL(fileURLWithPath: pageParts[0]).standardizedFileURL
let page: URL = {
    guard pageParts.count > 1, var c = URLComponents(url: pageFile, resolvingAgainstBaseURL: false) else { return pageFile }
    c.percentEncodedQuery = pageParts[1]
    return c.url ?? pageFile
}()
let out = URL(fileURLWithPath: args[2])
let width = args.count > 3 ? Double(args[3]) ?? 1300 : 1300
let settle = args.count > 4 ? Double(args[4]) ?? 2.5 : 2.5
/// A fixed viewport height (e.g. 420 for the floating panel): the page is shot
/// scrolled to the bottom at that size, instead of at its full height.
let fixedHeight = args.count > 5 ? Double(args[5]) : nil

final class Shot: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let window: NSWindow
    var testsFailed = false

    override init() {
        let config = WKWebViewConfiguration()
        // Collect errors so a broken script shows up in the output, not as a blank image.
        let capture = """
        window.__errors = [];
        window.addEventListener('error', e => __errors.push('error: ' + e.message + ' @' + (e.filename||'').split('/').pop() + ':' + e.lineno));
        window.addEventListener('unhandledrejection', e => __errors.push('rejection: ' + (e.reason && e.reason.message || e.reason)));
        const ce = console.error; console.error = (...a) => { __errors.push('console.error: ' + a.map(String).join(' ')); ce(...a); };
        """
        config.userContentController.addUserScript(WKUserScript(source: capture, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // The window is offscreen, so WebKit treats the page as hidden and slows
        // its timers more and more (and skips animation frames). Scripted checks
        // that wait on timers would stall; turn that off (dev tool only).
        for key in ["hiddenPageDOMTimerThrottlingEnabled", "hiddenPageDOMTimerThrottlingAutoIncreases",
                    "pageVisibilityBasedProcessSuppressionEnabled"] {
            config.preferences.setValue(false, forKey: key)
        }
        #if SKIM_HOST
        if pageFile.pathExtension == "md" { SkimAssets.install(in: config) }
        #endif
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: fixedHeight ?? 1000), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.contentView = web
        // On screen, 1% opaque and click-through, for the few seconds of the run. An
        // offscreen, fully transparent or desktop-level window is "occluded", and
        // WebKit then skips animation frames, which the pages use. The snapshot
        // itself is WebKit's rendering, so the window's opacity does not show in it.
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        web.navigationDelegate = self
        #if SKIM_HOST
        if pageFile.pathExtension == "md" {
            let md = (try? String(contentsOf: pageFile, encoding: .utf8)) ?? ""
            web.loadHTMLString(SkimAssets.document(markdown: md), baseURL: pageFile.deletingLastPathComponent())
            return
        }
        #endif
        web.loadFileURL(page, allowingReadAccessTo: pageFile.deletingLastPathComponent().deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            self.web.evaluateJavaScript("window.__testResults || null") { result, _ in
                if let checks = result as? [String: Any] {
                    let failed = checks["failed"] as? Int ?? 0
                    self.testsFailed = failed > 0
                    print("DOM checks: \(checks["passed"] ?? 0) passed, \(failed) failed")
                }
                self.measure()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

    func fail(_ e: Error) { print("load failed: \(e)"); exit(1) }

    func measure() {
        if let fixedHeight {
            web.evaluateJavaScript("if (!window.__keepScroll) window.scrollTo(0, document.documentElement.scrollHeight); (window.__errors||[]).join('\\n')") { res, _ in
                if let errs = res as? String, !errs.isEmpty { print(errs) } else { print("no JS errors") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.snap(NSRect(x: 0, y: 0, width: width, height: fixedHeight)) }
            }
            return
        }
        web.evaluateJavaScript("[document.documentElement.scrollHeight, (window.__errors||[]).join('\\n')]") { res, _ in
            let arr = res as? [Any] ?? []
            let height = min((arr.first as? Double) ?? 1000, 30000)
            if let errs = arr.last as? String, !errs.isEmpty { print(errs) } else { print("no JS errors") }
            let frame = NSRect(x: 0, y: 0, width: width, height: height)
            self.window.setContentSize(frame.size)
            self.web.frame = frame
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.snap(frame) }
        }
    }

    func snap(_ frame: NSRect) {
        let cfg = WKSnapshotConfiguration()
        cfg.rect = frame
        web.takeSnapshot(with: cfg) { image, error in
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { print("snapshot failed: \(String(describing: error))"); exit(1) }
            try? png.write(to: out)
            print("wrote \(out.path) \(Int(frame.width))x\(Int(frame.height))")
            exit(self.testsFailed ? 1 : 0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let shot = Shot()
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("timed out"); exit(1) }
app.run()
