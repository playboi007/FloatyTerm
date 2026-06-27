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
        case captureFailed
        var errorDescription: String? {
            switch self {
            case .permissionDenied: return "Screen Recording permission not granted."
            case .windowNotFound(let n): return "No on-screen window matches: \(n)"
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

    /// A capturable on-screen window (always someone else's — never ours).
    struct WindowInfo {
        let id: CGWindowID
        let owner: String
        let title: String
        let bounds: CGRect
        var area: CGFloat { bounds.width * bounds.height }
    }

    /// Every normal, on-screen window except FloatyTerm's own. Powers
    /// `floaty list-windows` so an agent can see exactly what it can target
    /// (id + owner + title + bounds) instead of guessing by name and hoping the
    /// right window matched.
    @MainActor
    static func listWindows() -> [WindowInfo] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return infoList.compactMap { info -> WindowInfo? in
            if (info[kCGWindowOwnerPID as String] as? Int32) == myPID { return nil }  // never us
            // Layer 0 == normal app windows. Higher layers are menus, the Dock,
            // status items, tab-drag overlays, window shadows — never content.
            guard (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            else { return nil }
            let b = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
            func n(_ k: String) -> CGFloat { CGFloat((b[k] as? NSNumber)?.doubleValue ?? 0) }
            return WindowInfo(
                id: id,
                owner: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? "",
                bounds: CGRect(x: n("X"), y: n("Y"), width: n("Width"), height: n("Height")))
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
        } else {
            throw CaptureError.windowNotFound(name ?? "(neither window nor window-id given)")
        }

        // SCK capture of the single matched window.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let scWindow = content.windows.first(where: { $0.windowID == targetID })
        else { throw CaptureError.windowNotFound(name ?? "window id \(targetID)") }

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

        // Always save the screenshot (history + pruning come for free). A nil
        // here is a genuine save failure, so it's the one case that throws.
        guard let imageURL = ContextSnap.saveImage(image) else { throw CaptureError.captureFailed }

        // Build + remember the frame from the EXACT region we captured
        // (scWindow.frame is the window's global-point rect) and the image's
        // real pixel dimensions, so click-in-frame can invert it precisely.
        let frame = CaptureFrame(
            id: nextFrameID(),
            windowID: targetID,
            owner: scWindow.owningApplication?.applicationName ?? (name ?? ""),
            origin: scWindow.frame.origin,
            size: scWindow.frame.size,
            scale: scale,
            imageWidth: image.width,
            imageHeight: image.height,
            capturedAt: Date())
        remember(frame)

        // OCR is additive and best-effort. recognizeText yields nil when the
        // window has no readable text — return the screenshot anyway rather
        // than masquerading "no text" as a capture failure.
        var textPath: String? = nil
        if ocr {
            let text: String? = await withCheckedContinuation { cont in
                ContextSnap.recognizeText(in: image) { cont.resume(returning: $0) }
            }
            if let text, let textURL = ContextSnap.saveText(text) { textPath = textURL.path }
        }
        return CaptureResult(imagePath: imageURL.path, textPath: textPath, frame: frame)
    }
}

/// Layer A-native (STUB) — element targeting for NATIVE AppKit apps (Notes,
/// Finder, system dialogs, native preference panes) that have no DOM. The
/// macOS Accessibility tree IS their queryable element hierarchy, the native
/// analog of query-dom. Because Layer B already forces the Accessibility grant,
/// READING the AX tree costs nothing extra.
///
/// Not implemented in this pass (scope was Layer B + capture + CDP query-dom),
/// but stubbed so the agent knows the slot exists and roughly how it'd work.
@MainActor
enum AgentAX {

    /// Find a native UI element by role + title/label under a target app and
    /// return its screen rect. Outline:
    ///   1. AXUIElementCreateApplication(pid) for the target app.
    ///   2. Walk kAXChildrenAttribute recursively, matching kAXRoleAttribute
    ///      (e.g. "AXButton") and kAXTitleAttribute / kAXDescriptionAttribute.
    ///   3. Read kAXPositionAttribute (AXValue → CGPoint) and kAXSizeAttribute
    ///      (AXValue → CGSize). These are ALREADY in global screen coordinates —
    ///      no transform needed, unlike CDP. That's the payoff of the AX path.
    ///   4. Return CGRect(origin: pos, size: size); click its center via Layer B.
    static func screenRect(role: String, title: String, appPID: pid_t) async throws -> CGRect {
        // TODO(agent): implement AX walk. Needs the same Accessibility grant
        // AgentInput already requires, so no new permission.
        throw AgentCapture.CaptureError.captureFailed  // placeholder
    }
}
