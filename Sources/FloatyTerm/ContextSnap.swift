import AppKit
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
    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
            Context Snap captures what's behind this window so your terminal \
            agent can read it.

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
    /// - Parameter region: optional rect in AppKit GLOBAL screen coordinates
    ///   (from the ⇧⌘4-style region selector); nil = the whole screen.
    static func captureBehind(_ window: NSWindow, region: NSRect? = nil) -> CGImage? {
        guard let screen = window.screen ?? NSScreen.main,
              let reference = NSScreen.screens.first else { return nil }
        let target = region.map { $0.intersection(screen.frame) } ?? screen.frame
        guard !target.isEmpty else { return nil }
        // AppKit (bottom-left origin, y up) → CG global (top-left origin, y down).
        let cgRect = CGRect(x: target.origin.x,
                            y: reference.frame.height - target.maxY,
                            width: target.width,
                            height: target.height)
        return CGWindowListCreateImage(cgRect,
                                       [.optionOnScreenBelowWindow],
                                       CGWindowID(window.windowNumber),
                                       [.bestResolution])
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
