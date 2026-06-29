import AppKit
import ScreenCaptureKit

/// Layer C — scoped screenshot of a NAMED external window, for canvas/GPU apps
/// (Flutter desktop builds, games) that expose neither a DOM (Layer A/CDP) nor
/// a useful Accessibility tree (Layer A-native). This is the universal
/// fallback: every app can be photographed.
///
/// This deliberately reuses ContextSnap's machinery rather than reinventing it:
///   • ContextSnap already migrated to ScreenCaptureKit because
///     CGWindowListCreateImage was deprecated in macOS 14 and REMOVED in 15.
///   • ContextSnap already owns the Screen Recording permission flow
///     (ensurePermission), the snaps directory, PNG saving, pruning, and OCR.
/// We only add the "target a specific window by name" variant; everything else
/// routes back through ContextSnap.
///
/// Difference from ContextSnap.captureBehind: that captures everything BELOW a
/// FloatyTerm window (what the panel overlays). Here we capture a SPECIFIC
/// external window's own pixels, found by owner-app name or window title.
enum AgentCapture {

    enum CaptureError: LocalizedError {
        case permissionDenied
        case windowNotFound(String)
        case windowOffScreen(String, Int)
        case captureFailed
        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Screen Recording permission not granted."
            case .windowNotFound(let n): return "No on-screen window matches: \(n)"
            case .windowOffScreen(let n, let c):
                return "\"\(n)\" has \(c) window\(c == 1 ? "" : "s") open but off the current "
                    + "Space/Stage (another desktop, minimized, or Stage Manager). Run "
                    + "`floaty raise --app \"\(n)\"` to surface it (or bring it forward manually), then retry "
                    + "— off-screen windows can't be captured. Don't just re-run this command."
            case .captureFailed: return "ScreenCaptureKit capture failed."
            }
        }
    }

    // MARK: - Capture frames (the native-app loop-breaker)
    //
    // A capture returns, alongside the PNG, the spatial metadata to invert it:
    // map any image-PIXEL coordinate (what a vision model reads off the PNG)
    // back to a global screen POINT (what a click needs). FloatyTerm does that
    // transform in `click-in-frame`, so the agent never re-perceives to correct
    // for scale — one capture, one handoff, one click.

    /// The geometry of one capture, kept so a later `click-in-frame` can invert it.
    struct CaptureFrame {
        let id: String
        let windowID: CGWindowID
        let owner: String          // owning app — raised before the click
        let origin: CGPoint        // window top-left, global screen POINTS
        let size: CGSize           // captured region, POINTS
        let scale: CGFloat         // backing scale at capture time
        let imageWidth: Int        // PNG dimensions, PIXELS
        let imageHeight: Int
        let capturedAt: Date
    }

    struct CaptureResult {
        let imagePath: String
        let textPath: String?
        let frame: CaptureFrame
    }

    enum FrameError: LocalizedError {
        case unknownFrame
        case windowMoved
        var errorDescription: String? {
            switch self {
            case .unknownFrame: return "unknown or expired frame_id; re-capture"
            case .windowMoved:  return "window moved or closed since capture; re-capture"
            }
        }
    }

    // Short-lived, bounded ring of recent frames (no need to survive restart).
    @MainActor private static var frames: [CaptureFrame] = []
    @MainActor private static var frameSeq = 0

    @MainActor private static func remember(_ f: CaptureFrame) {
        frames.append(f)
        if frames.count > 16 { frames.removeFirst(frames.count - 16) }
    }
    @MainActor static func frame(id: String) -> CaptureFrame? {
        frames.last { $0.id == id }
    }
    @MainActor private static func nextFrameID() -> String {
        frameSeq += 1
        return "cap_\(Int(Date().timeIntervalSince1970 * 1000))_\(frameSeq)"
    }

    /// Invert an image-pixel coordinate to a global screen point using the
    /// stored frame. Refuses (rather than misclicking) if the frame is unknown
    /// or the window has moved/resized/closed since capture. Returns the screen
    /// point plus the owning app so the caller can raise it before clicking.
    ///
    /// Transform (stays correct even if the PNG was downscaled, because it uses
    /// the real pixel:point ratio, not just `scale`):
    ///     screen = origin + image_coord / (image_dim / region_dim)
    @MainActor
    static func resolveInFrame(frameID: String, imageX: Double, imageY: Double) throws
        -> (point: CGPoint, owner: String?)
    {
        guard let f = frame(id: frameID) else { throw FrameError.unknownFrame }
        guard f.size.width > 0, f.size.height > 0 else { throw FrameError.windowMoved }

        // Staleness guard: re-read the window's current bounds; bail if it drifted.
        guard let current = listWindows().first(where: { $0.id == f.windowID }) else {
            throw FrameError.windowMoved
        }
        let tol: CGFloat = 4
        if abs(current.bounds.origin.x - f.origin.x) > tol
            || abs(current.bounds.origin.y - f.origin.y) > tol
            || abs(current.bounds.size.width - f.size.width) > tol
            || abs(current.bounds.size.height - f.size.height) > tol {
            throw FrameError.windowMoved
        }

        let pppX = Double(f.imageWidth) / Double(f.size.width)
        let pppY = Double(f.imageHeight) / Double(f.size.height)
        let point = CGPoint(x: f.origin.x + imageX / pppX,
                            y: f.origin.y + imageY / pppY)
        return (point, f.owner.isEmpty ? nil : f.owner)
    }

    // MARK: - Mark frames (Set-of-Mark: id → screen point)
    //
    // `floaty som` annotates a page's interactable elements with numbered boxes
    // and returns the screenshot; the model reads a NUMBER off the image instead
    // of guessing a pixel. We keep each mark's screen center here so
    // `click-mark --id N` resolves N → a click — the model never emits a
    // coordinate. Mirrors the capture-frame ring above: short-lived, bounded.

    struct Mark {
        let id: Int
        let role: String
        let name: String
        let rect: CGRect
        let center: CGPoint
    }

    /// One set-of-mark pass, kept so `click-mark` can resolve an id and refuse
    /// (rather than misclick) if the target changed since. Two flavors:
    ///   • `source == "cdp"` — DOM page: validated by re-reading url/scroll/origin.
    ///   • `source == "ax"`  — native/AX window: validated by re-reading the
    ///     window's bounds (by `windowID`), and raised by `pid` before clicking.
    struct MarkFrame {
        let id: String
        let source: String          // "cdp" | "ax"
        let marks: [Mark]
        let capturedAt: Date
        // CDP staleness
        var port: UInt16 = 9222
        var match: String? = nil
        var url: String = ""
        var screenX: Double = 0
        var screenY: Double = 0
        var scrollX: Double = 0
        var scrollY: Double = 0
        // AX staleness / actuation
        var pid: pid_t = 0
        var owner: String = ""
        var windowID: CGWindowID = 0
        var windowBounds: CGRect = .zero
    }

    @MainActor private static var markFrames: [MarkFrame] = []
    @MainActor private static var markSeq = 0

    @MainActor static func rememberMarks(_ f: MarkFrame) {
        markFrames.append(f)
        if markFrames.count > 16 { markFrames.removeFirst(markFrames.count - 16) }
    }
    @MainActor static func markFrame(id: String) -> MarkFrame? {
        markFrames.last { $0.id == id }
    }
    @MainActor static func nextMarkFrameID() -> String {
        markSeq += 1
        return "som_\(Int(Date().timeIntervalSince1970 * 1000))_\(markSeq)"
    }

    /// A capturable on-screen window (always someone else's — never ours).
    struct WindowInfo {
        let id: CGWindowID
        let pid: pid_t            // owning process — disambiguates two same-named apps (two Chromes)
        let owner: String
        let title: String
        let bounds: CGRect
        let onScreen: Bool        // false = open but on another Space / minimized / off-stage (Stage Manager)
        var area: CGFloat { bounds.width * bounds.height }
    }

    /// Every normal, on-screen window except FloatyTerm's own. Powers
    /// `floaty list-windows` so an agent can see exactly what it can target
    /// (id + owner + title + bounds) instead of guessing by name and hoping the
    /// right window matched.
    @MainActor
    static func listWindows(includingOffScreen: Bool = false) -> [WindowInfo] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        // `.optionOnScreenOnly` only sees the ACTIVE Space/stage — so a window
        // that's open but on another Space, minimized, or off-stage under Stage
        // Manager is invisible to it (an agent then wrongly concludes "no
        // window"). When asked, widen to `.optionAll` and flag each window's
        // on-screen membership so the agent can see it exists and raise it.
        let onScreenIDs: Set<CGWindowID> = includingOffScreen
            ? Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? [])
                .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
            : []
        let option: CGWindowListOption = includingOffScreen
            ? [.optionAll, .excludeDesktopElements]
            : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return infoList.compactMap { info -> WindowInfo? in
            let ownerPID = (info[kCGWindowOwnerPID as String] as? Int32) ?? 0
            if ownerPID == myPID { return nil }  // never us
            // Layer 0 == normal app windows. Higher layers are menus, the Dock,
            // status items, tab-drag overlays, window shadows — never content.
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { return nil }
            let b = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
            func n(_ k: String) -> CGFloat { CGFloat((b[k] as? NSNumber)?.doubleValue ?? 0) }
            let bounds = CGRect(x: n("X"), y: n("Y"), width: n("Width"), height: n("Height"))
            let onScreen = includingOffScreen ? onScreenIDs.contains(id) : true
            // Off-screen additions are noisy: a single Chrome window backs a dozen
            // tab-strip/shadow sliver windows. Keep only real content windows (the
            // ≥200² floor bestMatch uses); on-screen results are left untouched.
            if !onScreen && (bounds.width < 200 || bounds.height < 200) { return nil }
            return WindowInfo(
                id: id,
                pid: ownerPID,
                owner: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? "",
                bounds: bounds,
                onScreen: onScreen)
        }
    }

    /// Best window for a name query: case-insensitive match on owner OR title,
    /// excluding sliver/utility windows, then the LARGEST by area. The size
    /// rule is what stops `--window "Chrome"` grabbing a full-width ~82px-tall
    /// tab-strip overlay instead of the actual page content (the exact bug an
    /// agent hit in the field).
    @MainActor
    static func bestMatch(named name: String) -> WindowInfo? {
        listWindows()
            .filter { $0.owner.localizedCaseInsensitiveContains(name)
                   || $0.title.localizedCaseInsensitiveContains(name) }
            .filter { $0.bounds.width >= 200 && $0.bounds.height >= 200 }
            .max { $0.area < $1.area }
    }

    /// Capture a window to ~/.floatyterm/snaps (via ContextSnap.saveImage, so it
    /// shows up in snap history and gets pruned with everything else). Always
    /// returns the PNG path.
    ///
    /// Target resolution: an explicit `windowID` (from `list-windows`) wins and
    /// is unambiguous; otherwise `name` matches owner/title and resolves to the
    /// LARGEST such window (see `bestMatch`).
    ///
    /// When `ocr` is set, ALSO runs Vision OCR and returns the recognized-text
    /// file path when text was found — best-effort: an image-heavy window (a
    /// video, a canvas) legitimately has no text, which is NOT a failure; in
    /// that case `textPath` is nil and the screenshot still comes back.
    @MainActor
    static func captureWindow(named name: String?, windowID: CGWindowID? = nil,
                              ocr: Bool = false) async throws -> CaptureResult
    {
        // Reuse ContextSnap's permission gate (Screen Recording). Note the
        // purpose string so the prompt is honest about why.
        guard ContextSnap.ensurePermission(
            purpose: "FloatyTerm captures a target window so your agent's vision model can read it."
        ) else { throw CaptureError.permissionDenied }

        // Resolve the target: explicit id, else the largest name match.
        let targetID: CGWindowID
        if let windowID {
            targetID = windowID
        } else if let name, let win = bestMatch(named: name) {
            targetID = win.id
        } else if let name {
            // Distinguish "open but off-stage" from "genuinely no window" so the
            // agent can raise it instead of declaring the window closed.
            let off = listWindows(includingOffScreen: true).filter {
                !$0.onScreen && ($0.owner.localizedCaseInsensitiveContains(name)
                                 || $0.title.localizedCaseInsensitiveContains(name))
            }
            throw off.isEmpty ? CaptureError.windowNotFound(name)
                              : CaptureError.windowOffScreen(name, off.count)
        } else {
            throw CaptureError.windowNotFound("(neither window nor window-id given)")
        }

        let shot = try await rawCapture(windowID: targetID, fallbackName: name)

        // Always save the screenshot (history + pruning come for free). A nil
        // here is a genuine save failure, so it's the one case that throws.
        guard let imageURL = ContextSnap.saveImage(shot.image) else { throw CaptureError.captureFailed }

        // Build + remember the frame from the EXACT region we captured
        // (scWindow.frame is the window's global-point rect) and the image's
        // real pixel dimensions, so click-in-frame can invert it precisely.
        let frame = CaptureFrame(
            id: nextFrameID(),
            windowID: targetID,
            owner: shot.owner,
            origin: shot.origin,
            size: shot.size,
            scale: shot.scale,
            imageWidth: shot.image.width,
            imageHeight: shot.image.height,
            capturedAt: Date())
        remember(frame)

        // OCR is additive and best-effort. recognizeText yields nil when the
        // window has no readable text — return the screenshot anyway rather
        // than masquerading "no text" as a capture failure.
        var textPath: String? = nil
        if ocr {
            let text: String? = await withCheckedContinuation { cont in
                ContextSnap.recognizeText(in: shot.image) { cont.resume(returning: $0) }
            }
            if let text, let textURL = ContextSnap.saveText(text) { textPath = textURL.path }
        }
        return CaptureResult(imagePath: imageURL.path, textPath: textPath, frame: frame)
    }

    /// SCK capture of one window → its CGImage plus the geometry needed to map
    /// image pixels ↔ screen points. Does NOT save or remember a frame — used
    /// both by `captureWindow` (which then saves) and by the AX Set-of-Mark path
    /// (which draws numbered boxes onto the image first).
    @MainActor
    static func rawCapture(windowID: CGWindowID, fallbackName: String?) async throws
        -> (image: CGImage, origin: CGPoint, size: CGSize, scale: CGFloat, owner: String)
    {
        guard ContextSnap.ensurePermission(
            purpose: "FloatyTerm captures a target window so your agent's vision model can read it."
        ) else { throw CaptureError.permissionDenied }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID })
        else { throw CaptureError.windowNotFound(fallbackName ?? "window id \(windowID)") }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let config = SCStreamConfiguration()
        let scale = scWindow.frame.width > 0 ? (NSScreen.main?.backingScaleFactor ?? 2) : 2
        config.width  = max(1, Int((scWindow.frame.width  * scale).rounded()))
        config.height = max(1, Int((scWindow.frame.height * scale).rounded()))
        config.showsCursor = false

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.captureFailed
        }
        return (image, scWindow.frame.origin, scWindow.frame.size, scale,
                scWindow.owningApplication?.applicationName ?? (fallbackName ?? ""))
    }

    /// Draw numbered boxes onto a captured image for the AX Set-of-Mark path.
    /// `boxes` are in IMAGE-PIXEL coords (top-left origin); we flip to AppKit's
    /// bottom-left space for drawing. Mirrors the colors/labels the in-page DOM
    /// overlay uses, so both `som` paths look the same to the model.
    @MainActor
    static func annotate(image: CGImage, boxes: [(label: Int, rect: CGRect)]) -> CGImage? {
        let w = image.width, h = image.height
        let palette: [NSColor] = [
            .init(srgbRed: 0.90, green: 0.10, blue: 0.29, alpha: 1), .init(srgbRed: 0.24, green: 0.71, blue: 0.29, alpha: 1),
            .init(srgbRed: 0.26, green: 0.39, blue: 0.85, alpha: 1), .init(srgbRed: 0.96, green: 0.51, blue: 0.19, alpha: 1),
            .init(srgbRed: 0.57, green: 0.12, blue: 0.71, alpha: 1), .init(srgbRed: 0.26, green: 0.83, blue: 0.96, alpha: 1),
            .init(srgbRed: 0.94, green: 0.20, blue: 0.90, alpha: 1), .init(srgbRed: 0.27, green: 0.60, blue: 0.56, alpha: 1),
            .init(srgbRed: 0.60, green: 0.39, blue: 0.14, alpha: 1), .init(srgbRed: 0.50, green: 0.00, blue: 0.00, alpha: 1),
        ]
        let out = NSImage(size: NSSize(width: w, height: h))
        out.lockFocus()
        NSImage(cgImage: image, size: NSSize(width: w, height: h))
            .draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        let fontSize = max(11.0, 11.0 * CGFloat(w) / 1200.0)   // scale label with image resolution
        for box in boxes {
            let color = palette[(box.label - 1 + palette.count) % palette.count]
            // image px (top-left) → AppKit (bottom-left)
            let r = NSRect(x: box.rect.minX, y: CGFloat(h) - box.rect.minY - box.rect.height,
                           width: box.rect.width, height: box.rect.height)
            let path = NSBezierPath(rect: r)
            path.lineWidth = max(2, fontSize / 5)
            color.setStroke(); path.stroke()
            // number badge at the box's top-left (its top in AppKit space)
            let label = String(box.label) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let textSize = label.size(withAttributes: attrs)
            let pad: CGFloat = 2
            let badge = NSRect(x: r.minX, y: r.maxY - (textSize.height + pad),
                               width: textSize.width + pad * 2, height: textSize.height + pad)
            color.setFill(); NSBezierPath(rect: badge).fill()
            label.draw(at: NSPoint(x: badge.minX + pad, y: badge.minY), withAttributes: attrs)
        }
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let cg = rep.cgImage else { return nil }
        return cg
    }
}

/// Layer A-native — element targeting for NATIVE apps (Notes, Finder, system
/// dialogs) AND for live Chrome/Electron the DOM path can't reach. The macOS
/// Accessibility tree IS the queryable element hierarchy, the native analog of
/// `query-dom`. Two properties make it the answer to the "two Chromes / Chrome
/// 136+ debug-port block" problem:
///
///   • It binds by **PID**, not app name — `AXUIElementCreateApplication(pid)`
///     reads and presses a SPECIFIC process, so two windows both named "Google
///     Chrome" are no longer ambiguous (CDP solved this for itself via the port;
///     AX solves it for everything else).
///   • It needs **no debug port** — so it drives the user's real, default-profile
///     Chrome that Chrome 136+ refuses to expose over CDP. One Chrome, no spawn.
///
/// Reading the tree costs no new permission: Layer B already forces the
/// Accessibility grant. AXPosition/AXSize are ALREADY global screen points — no
/// transform, unlike CDP.
@MainActor
enum AgentAX {

    enum AXError: LocalizedError {
        case notTrusted
        case appNotFound(String)
        case ambiguousApp(String, [pid_t])
        case noMatch(String)
        var errorDescription: String? {
            switch self {
            case .notTrusted:
                return "FloatyTerm needs Accessibility access — grant it under System Settings → "
                    + "Privacy & Security → Accessibility, then relaunch."
            case .appNotFound(let s):
                return "No running app matches \"\(s)\". Run `floaty list-windows` for owners + pids."
            case .ambiguousApp(let s, let pids):
                let list = pids.map(String.init).joined(separator: ", ")
                return "Multiple running apps match \"\(s)\" (pids: \(list)). Pass --pid to pick one "
                    + "(see `floaty list-windows`)."
            case .noMatch(let s):
                return "No accessibility element matches \(s)."
            }
        }
    }

    /// One matched element: role + name (for the agent to read) and its global
    /// screen rect/center (directly clickable — AX coords need no transform).
    struct AXMatch: Sendable {
        let role: String
        let name: String
        let rect: CGRect
        let center: CGPoint
    }

    /// Resolve a target to a single pid: an explicit `pid` wins; else match
    /// running apps by localized name / bundle id. An ambiguous NAME (two
    /// Chromes!) throws asking for `--pid` rather than guessing.
    static func resolvePID(app: String?, pid: pid_t?) throws -> pid_t {
        if let pid { return pid }
        guard let app, !app.isEmpty else { throw AXError.appNotFound("(no app or pid given)") }
        let hits = NSWorkspace.shared.runningApplications.filter {
            ($0.localizedName?.localizedCaseInsensitiveContains(app) ?? false)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(app) ?? false)
        }
        // Prefer regular (Dock) apps; background-only helpers rarely have UI.
        let regular = hits.filter { $0.activationPolicy == .regular }
        let pool = regular.isEmpty ? hits : regular
        if pool.isEmpty { throw AXError.appNotFound(app) }
        if pool.count > 1 { throw AXError.ambiguousApp(app, pool.map { $0.processIdentifier }) }
        return pool[0].processIdentifier
    }

    /// Walk a target app's AX tree, returning interactable (or role/name-filtered)
    /// elements with screen rect + center. With `press`, AXPress the first match
    /// instead — a targeted activation that ignores which window is frontmost
    /// (the fix for keystrokes landing in the wrong Chrome). Bounded by node +
    /// match caps and a per-call messaging timeout so a huge tree can't hang.
    static func query(app: String?, pid: pid_t?, role: String?, title: String?,
                      max: Int = 100, press: Bool = false) async throws -> (matches: [AXMatch], pressed: AXMatch?) {
        guard AXIsProcessTrusted() else { throw AXError.notTrusted }
        let appPID = try resolvePID(app: app, pid: pid)
        let appEl = AXUIElementCreateApplication(appPID)
        // Don't let a busy/hung app block the main thread indefinitely.
        AXUIElementSetMessagingTimeout(appEl, 2.0)
        // Nudge Chromium/Electron to switch on its renderer accessibility tree
        // (lazily enabled only when an AT queries it). Harmless for native apps.
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        let wantRole = role.map(normalizeRole)
        let wantTitle = title?.lowercased()
        let interactable: Set<String> = [
            "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox",
            "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXMenuItem", "AXMenuButton",
            "AXTab", "AXSlider", "AXSearchField", "AXDisclosureTriangle", "AXSwitch",
        ]

        func name(of el: AXUIElement) -> String {
            for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, "AXHelp"] {
                if let s = copyString(el, attr as CFString), !s.isEmpty { return String(s.prefix(120)) }
            }
            return ""
        }

        // One full tree walk. Returns the matches plus the first press target.
        func sweep() -> (matches: [AXMatch], pressTarget: AXUIElement?, pressMatch: AXMatch?) {
            var out: [AXMatch] = []
            var pressTarget: AXUIElement?
            var pressMatch: AXMatch?
            var visited = 0
            let nodeCap = 6000

            func walk(_ el: AXUIElement) {
                if visited >= nodeCap { return }
                if out.count >= max && (!press || pressMatch != nil) { return }
                visited += 1
                let r = copyString(el, kAXRoleAttribute as CFString) ?? ""

                var isHit: Bool
                if let wantRole { isHit = (r == wantRole) }
                else if wantTitle == nil { isHit = interactable.contains(r) }   // default: interactables
                else { isHit = true }                                           // title-only → any role
                if isHit, let wantTitle { isHit = name(of: el).lowercased().contains(wantTitle) }

                if isHit, let rect = rectOf(el), rect.width > 0, rect.height > 0 {
                    let m = AXMatch(role: r, name: name(of: el), rect: rect,
                                    center: CGPoint(x: rect.midX, y: rect.midY))
                    if out.count < max { out.append(m) }
                    // Press the first ACTIONABLE match — a title filter can also
                    // hit the element's static-text twin; don't press dead text.
                    if press && pressMatch == nil, wantRole != nil || interactable.contains(r) {
                        pressTarget = el; pressMatch = m
                    }
                }
                if let kids = copyChildren(el) {
                    for k in kids {
                        if visited >= nodeCap { break }
                        if out.count >= max && (!press || pressMatch != nil) { break }
                        walk(k)
                    }
                }
            }
            walk(appEl)
            return (out, pressTarget, pressMatch)
        }

        // Chromium enables its a11y tree IN RESPONSE to the nudge above, so the
        // very first sweep often comes back near-empty. Retry a couple of times
        // (non-blocking) until the tree populates; native apps satisfy attempt 1.
        var result = sweep()
        var attempt = 0
        while result.matches.count < 2 && attempt < 2 {
            try await Task.sleep(nanoseconds: 250_000_000)
            result = sweep()
            attempt += 1
        }

        if press {
            guard let t = result.pressTarget, let m = result.pressMatch else {
                throw AXError.noMatch(describe(role: role, title: title))
            }
            AXUIElementPerformAction(t, kAXPressAction as CFString)
            return (result.matches, m)
        }
        return (result.matches, nil)
    }

    /// What the agent needs to answer "is there a text cursor here before I
    /// type?" — the target app's currently focused element.
    struct FocusedInfo: Sendable {
        let hasFocus: Bool
        let role: String
        let name: String
        let value: String
        let editable: Bool      // a text-entry role → typing will land
    }

    /// Read the target app's focused UI element (AXFocusedUIElement). Pairs with
    /// the typing fix: click → `focused` check → type, instead of click-and-pray.
    static func focused(app: String?, pid: pid_t?) throws -> FocusedInfo {
        guard AXIsProcessTrusted() else { throw AXError.notTrusted }
        let appPID = try resolvePID(app: app, pid: pid)
        let appEl = AXUIElementCreateApplication(appPID)
        AXUIElementSetMessagingTimeout(appEl, 2.0)
        // Chromium exposes the focused element only with a11y on — nudge it.
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var f: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &f) == .success,
              let f, CFGetTypeID(f) == AXUIElementGetTypeID()
        else { return FocusedInfo(hasFocus: false, role: "", name: "", value: "", editable: false) }
        let el = f as! AXUIElement
        let role = copyString(el, kAXRoleAttribute as CFString) ?? ""
        var name = ""
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", "AXHelp"] {
            if let s = copyString(el, attr as CFString), !s.isEmpty { name = String(s.prefix(120)); break }
        }
        let value = String((copyString(el, kAXValueAttribute as CFString) ?? "").prefix(300))
        let editable = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
        return FocusedInfo(hasFocus: true, role: role, name: name, value: value, editable: editable)
    }

    /// Bring a target app + window to the ACTIVE Space — the sanctioned twin of
    /// clicking a notification (public activation, no private SkyLight). Activates
    /// the process, AX-raises its main window, and marks it frontmost, so a window
    /// parked off-stage / on another Space / inactive-full-screen surfaces and
    /// becomes capture/click/type-able (Chrome also populates its a11y tree once
    /// foreground). Returns whether a window is on the active Space afterward.
    static func raise(app: String?, pid: pid_t?) async throws -> (pid: pid_t, onScreen: Bool, title: String) {
        guard AXIsProcessTrusted() else { throw AXError.notTrusted }
        let appPID = try resolvePID(app: app, pid: pid)

        let appEl = AXUIElementCreateApplication(appPID)
        AXUIElementSetMessagingTimeout(appEl, 2.0)
        var title = ""
        if let win = mainWindow(of: appEl) {
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            title = copyString(win, kAXTitleAttribute as CFString) ?? ""
        }
        AXUIElementSetAttributeValue(appEl, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: appPID)?.activate()

        // Let the Space switch / stage swap settle, then confirm a window is now
        // on the active Space (capturable).
        try await Task.sleep(nanoseconds: 450_000_000)
        let onScreen = AgentCapture.listWindows().contains { $0.pid == appPID }
        return (appPID, onScreen, title)
    }

    /// Extract readable text from a target via the AX tree — the structural,
    /// lossless analog of OCR, and the right way to "read this page" on live
    /// Chrome that Chrome 136+ won't expose over CDP. Walks the focused window
    /// collecting static-text / heading / field values. Returns "" when the tree
    /// carries no text, so the caller can fall back to OCR.
    static func extractText(app: String?, pid: pid_t?, maxChars: Int = 40000) async throws -> String {
        guard AXIsProcessTrusted() else { throw AXError.notTrusted }
        let appPID = try resolvePID(app: app, pid: pid)
        let appEl = AXUIElementCreateApplication(appPID)
        AXUIElementSetMessagingTimeout(appEl, 2.0)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let root = mainWindow(of: appEl) ?? appEl
        let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading"]

        func sweep() -> [String] {
            var out: [String] = []
            var visited = 0
            let nodeCap = 8000
            func walk(_ el: AXUIElement) {
                if visited >= nodeCap { return }
                visited += 1
                if textRoles.contains(copyString(el, kAXRoleAttribute as CFString) ?? "") {
                    let s = copyString(el, kAXValueAttribute as CFString)
                        ?? copyString(el, kAXTitleAttribute as CFString) ?? ""
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { out.append(t) }
                }
                if let kids = copyChildren(el) { for k in kids { if visited >= nodeCap { break }; walk(k) } }
            }
            walk(root)
            return out
        }
        // Chrome enables its a11y tree lazily — retry if the first sweep is empty.
        var parts = sweep()
        var attempt = 0
        while parts.joined(separator: "\n").count < 20 && attempt < 2 {
            try await Task.sleep(nanoseconds: 250_000_000)
            parts = sweep()
            attempt += 1
        }
        var lines: [String] = []
        for p in parts where lines.last != p { lines.append(p) }   // drop consecutive dupes
        let text = lines.joined(separator: "\n")
        return text.count > maxChars ? String(text.prefix(maxChars)) : text
    }

    private static func mainWindow(of appEl: AXUIElement) -> AXUIElement? {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXMainWindowAttribute as CFString, &v) == .success,
           let v, CFGetTypeID(v) == AXUIElementGetTypeID() {
            return (v as! AXUIElement)
        }
        return copyAXArray(appEl, kAXWindowsAttribute as CFString)?.first
    }

    // MARK: - AX attribute readers

    private static func copyAXArray(_ el: AXUIElement, _ attr: CFString) -> [AXUIElement]? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success else { return nil }
        return v as? [AXUIElement]
    }

    private static func rectOf(_ el: AXUIElement) -> CGRect? {
        guard let p = copyPoint(el, kAXPositionAttribute as CFString),
              let s = copySize(el, kAXSizeAttribute as CFString)
        else { return nil }
        return CGRect(origin: p, size: s)
    }

    private static func copyString(_ el: AXUIElement, _ attr: CFString) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func axValue(_ el: AXUIElement, _ attr: CFString) -> AXValue? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr, &v) == .success, let v,
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        return (v as! AXValue)
    }
    private static func copyPoint(_ el: AXUIElement, _ attr: CFString) -> CGPoint? {
        guard let v = axValue(el, attr) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }
    private static func copySize(_ el: AXUIElement, _ attr: CFString) -> CGSize? {
        guard let v = axValue(el, attr) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    private static func copyChildren(_ el: AXUIElement) -> [AXUIElement]? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success
        else { return nil }
        return v as? [AXUIElement]
    }

    /// Friendly role → AX role ("button" → "AXButton"); passes "AX…" through.
    private static func normalizeRole(_ r: String) -> String {
        if r.hasPrefix("AX") { return r }
        let map = ["button": "AXButton", "link": "AXLink", "textfield": "AXTextField",
                   "textarea": "AXTextArea", "checkbox": "AXCheckBox", "radio": "AXRadioButton",
                   "popup": "AXPopUpButton", "combobox": "AXComboBox", "menuitem": "AXMenuItem",
                   "tab": "AXTab", "slider": "AXSlider", "searchfield": "AXSearchField",
                   "switch": "AXSwitch"]
        if let mapped = map[r.lowercased()] { return mapped }
        return "AX" + r.prefix(1).uppercased() + r.dropFirst()
    }

    private static func describe(role: String?, title: String?) -> String {
        var parts: [String] = []
        if let role { parts.append("role=\(role)") }
        if let title { parts.append("title~=\"\(title)\"") }
        return parts.isEmpty ? "the interactable filter" : parts.joined(separator: " ")
    }
}
