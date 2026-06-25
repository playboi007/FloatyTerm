import AppKit
import ScreenCaptureKit
import Vision

/// Captures what a floating window is overlaying — every window BELOW it in
/// z-order on its screen — so the terminal session (e.g. a Claude/Fable agent)
/// can be pointed at it. Snapshots are written to ~/.floatyterm/snaps/ (a
/// space-free path that CLI agents handle cleanly) and the path is typed into
/// the prompt.
///
/// Requires the Screen Recording permission (TCC); requested on first use, so
/// the app stays permission-free until the feature is actually wanted.
enum ContextSnap {

    /// Where snaps live; exposed so the history menu can reveal it in Finder.
    static var snapsDirectory: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".floatyterm/snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// All snaps (png + txt), newest first.
    static func listSnaps() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: snapsDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files
            .filter { ["png", "txt"].contains($0.pathExtension) }
            .sorted { modificationDate($0) > modificationDate($1) }
    }

    static func deleteAllSnaps() {
        listSnaps().forEach { try? FileManager.default.removeItem(at: $0) }
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    // MARK: - Permission

    /// True when screen capture is permitted. When not, triggers the system
    /// prompt and shows guidance. The grant only takes effect after the app
    /// RESTARTS — and if it was granted while the app ran (or under an older
    /// signature), preflight keeps failing until relaunch — so the alert
    /// offers a one-click relaunch.
    /// - Parameter purpose: one sentence explaining why capture is needed, shown
    ///   in the prompt (so the same flow serves Context Snap, window mirroring, …).
    static func ensurePermission(
        purpose: String = "Context Snap captures what's behind this window so your terminal agent can read it."
    ) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
            \(purpose)

            1. Grant FloatyTerm access under System Settings → Privacy & \
            Security → Screen Recording.
            2. Relaunch FloatyTerm — macOS only applies the grant to a \
            freshly-started app.

            Already granted but still seeing this? That's step 2: relaunch.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Relaunch FloatyTerm")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        case .alertSecondButtonReturn:
            relaunch()
        default:
            break
        }
        return false
    }

    /// Quits and reopens the app (sessions end — same as any quit; the user
    /// initiated this knowingly from the alert).
    private static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(bundlePath)\""]
        try? task.run()
        AppRuntime.isQuitting = true
        NSApp.terminate(nil)
    }

    // MARK: - Capture

    /// Snapshot of everything below `window` on its screen — i.e. exactly what
    /// the floating window is overlaying, without the window itself.
    ///
    /// Migrated to ScreenCaptureKit: `CGWindowListCreateImage` (with
    /// `.optionOnScreenBelowWindow`) was deprecated in macOS 14 and REMOVED in
    /// macOS 15. We reproduce the same "everything below this window" semantics
    /// by capturing the whole display through an `SCContentFilter` that excludes
    /// our own window plus every window stacked in front of it, then cropping to
    /// the requested region via the configuration's `sourceRect`.
    ///
    /// - Parameter region: optional rect in AppKit GLOBAL screen coordinates
    ///   (from the ⇧⌘4-style region selector); nil = the whole screen.
    @MainActor
    static func captureBehind(_ window: NSWindow, region: NSRect? = nil) async -> CGImage? {
        guard let screen = window.screen ?? NSScreen.main,
              let displayID = displayID(of: screen) else { return nil }
        let target = region.map { $0.intersection(screen.frame) } ?? screen.frame
        guard !target.isEmpty else { return nil }

        let content: SCShareableContent
        do {
            // Keep desktop windows (the wallpaper shows through behind the panel);
            // on-screen only — off-screen windows can't be behind anything visible.
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch {
            NSLog("FloatyTerm: context snap shareable-content failed: \(error)")
            return nil
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID })
        else { return nil }

        // Reproduce `.optionOnScreenBelowWindow`: exclude our own window, any
        // other FloatyTerm window, and everything stacked in front of the panel.
        // The window-server list (still available on macOS 15) is authoritative
        // for z-order — front-to-back — so we collect IDs until we reach ours.
        let panelID = CGWindowID(window.windowNumber)
        var aboveIDs = Set<CGWindowID>()
        if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
            for info in infoList {
                guard let num = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
                if num == panelID { break }   // reached our window; the rest are behind it
                aboveIDs.insert(num)
            }
        }
        let ownBundle = Bundle.main.bundleIdentifier
        let excluded = content.windows.filter { w in
            w.windowID == panelID
                || aboveIDs.contains(w.windowID)
                || (ownBundle != nil && w.owningApplication?.bundleIdentifier == ownBundle)
        }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: excluded)

        // AppKit (bottom-left origin, y up) → display-local points (top-left,
        // y down) for `sourceRect`, which crops the captured display.
        let scale = screen.backingScaleFactor
        let sourceRect = CGRect(x: target.origin.x - screen.frame.origin.x,
                                y: screen.frame.maxY - target.maxY,
                                width: target.width,
                                height: target.height)

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width  = max(1, Int((sourceRect.width  * scale).rounded()))  // native pixels (was .bestResolution)
        config.height = max(1, Int((sourceRect.height * scale).rounded()))
        config.showsCursor = false

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch {
            NSLog("FloatyTerm: context snap capture failed: \(error)")
            return nil
        }
    }

    /// CoreGraphics display ID backing an `NSScreen`, for matching `SCDisplay`.
    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    // MARK: - Persistence

    /// Writes the capture as PNG; returns its path. Old snaps are pruned.
    static func saveImage(_ image: CGImage) -> URL? {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = snapsDirectory.appendingPathComponent("snap-\(timestamp()).png")
        do {
            try data.write(to: url)
            prune()
            return url
        } catch {
            NSLog("FloatyTerm: context snap write failed: \(error)")
            return nil
        }
    }

    /// Writes OCR'd text alongside the snaps; returns its path.
    static func saveText(_ text: String) -> URL? {
        let url = snapsDirectory.appendingPathComponent("snap-\(timestamp()).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            prune()
            return url
        } catch {
            NSLog("FloatyTerm: context snap text write failed: \(error)")
            return nil
        }
    }

    // MARK: - OCR (Vision, fully local)

    /// Extracts readable text from the capture off the main thread.
    static func recognizeText(in image: CGImage, completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let text = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                DispatchQueue.main.async { completion(text.isEmpty ? nil : text) }
            } catch {
                NSLog("FloatyTerm: OCR failed: \(error)")
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    // MARK: - Helpers

    private static func timestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return fmt.string(from: Date())
    }

    /// Keeps only the 20 most recent snaps so the directory can't grow unbounded.
    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: snapsDirectory,
                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for stale in sorted.dropFirst(20) {
            try? fm.removeItem(at: stale)
        }
    }
}
