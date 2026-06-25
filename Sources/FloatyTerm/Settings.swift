import AppKit
import Carbon.HIToolbox

/// Small runtime flags shared across the app.
enum AppRuntime {
    /// Set while the app is quitting so per-window close prompts are skipped.
    static var isQuitting = false
}

/// Where summon overlays (the session switcher palette and borrowed/summoned
/// windows) appear on the active screen: one of the 9 cardinal grid points.
/// Configurable in Preferences so the overlay doesn't land on top of a
/// terminal the user already has in view.
enum SummonPosition: String, CaseIterable {
    case topLeft, top, topRight
    case left, center, right
    case bottomLeft, bottom, bottomRight

    /// Row-major 3×3 layout for the Preferences grid picker.
    static let gridOrder: [[SummonPosition]] = [
        [.topLeft, .top, .topRight],
        [.left, .center, .right],
        [.bottomLeft, .bottom, .bottomRight]
    ]

    /// A frame of `size` anchored at this grid point within `vis`
    /// (the screen's visible frame), inset by `margin`.
    func frame(forSize size: NSSize, in vis: NSRect, margin: CGFloat = 24) -> NSRect {
        let x: CGFloat
        switch self {
        case .topLeft, .left, .bottomLeft:    x = vis.minX + margin
        case .top, .center, .bottom:          x = vis.midX - size.width / 2
        case .topRight, .right, .bottomRight: x = vis.maxX - size.width - margin
        }
        let y: CGFloat
        switch self {
        case .topLeft, .top, .topRight:          y = vis.maxY - size.height - margin
        case .left, .center, .right:             y = vis.midY - size.height / 2
        case .bottomLeft, .bottom, .bottomRight: y = vis.minY + margin
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// User-configurable settings, persisted in UserDefaults. Posts
/// `Settings.didChange` whenever a value is updated so the UI can react live.
final class Settings {
    static let shared = Settings()
    static let didChange = Notification.Name("FloatyTermSettingsDidChange")

    private let d = UserDefaults.standard

    private init() {
        register(defaults: [
            "fontSize": 13.0,
            "urlBarCollapsed": false,
            "backgroundBlur": true,
            "focusedOpacity": 0.30,
            "dimWhenUnfocused": true,
            "unfocusedOpacity": 0.6,
            "hotKeyCode": Int(kVK_ANSI_7),
            "hotKeyModifiers": Int(cmdKey | optionKey),
            "hotKeyDisplay": "⌥⌘7",
            "inheritWorkingDirectory": true,
            "browserTransparency": true,
            "blockPopups": true,
            "blockRedirects": false,
            "summonPosition": SummonPosition.center.rawValue,
            "ghostOpacity": 0.35,
            "hideFromScreenCapture": false,
            "mirrorSmoothCapture": false,
            "metalRenderer": false,
            "storageRetentionDays": 3,
            "storageCapMB": 100
        ])
    }

    private func register(defaults: [String: Any]) {
        for (k, v) in defaults where d.object(forKey: k) == nil {
            d.set(v, forKey: k)
        }
    }

    var fontSize: Double {
        get { d.double(forKey: "fontSize") }
        set { d.set(newValue, forKey: "fontSize"); notify() }
    }

    /// When true, the browser URL/navigation bar is collapsed (hidden) so it
    /// doesn't obscure page content. Toggled by the globe icon in the header.
    var urlBarCollapsed: Bool {
        get { d.bool(forKey: "urlBarCollapsed") }
        set { d.set(newValue, forKey: "urlBarCollapsed"); notify() }
    }

    /// When true, a frosted blur sits behind the terminal. Turn it off for a
    /// crisp, truly see-through background.
    var backgroundBlur: Bool {
        get { d.bool(forKey: "backgroundBlur") }
        set { d.set(newValue, forKey: "backgroundBlur"); notify() }
    }

    /// Background opacity (0–1) while the window is focused.
    var focusedOpacity: Double {
        get { d.double(forKey: "focusedOpacity") }
        set { d.set(newValue, forKey: "focusedOpacity"); notify() }
    }

    var dimWhenUnfocused: Bool {
        get { d.bool(forKey: "dimWhenUnfocused") }
        set { d.set(newValue, forKey: "dimWhenUnfocused"); notify() }
    }

    /// Opacity (0.2–1.0) applied to the terminal content when its window is
    /// unfocused. The top bar stays fully opaque as a visual reference.
    var unfocusedOpacity: Double {
        get { d.double(forKey: "unfocusedOpacity") }
        set { d.set(newValue, forKey: "unfocusedOpacity"); notify() }
    }

    var hotKeyCode: UInt32 {
        get { UInt32(d.integer(forKey: "hotKeyCode")) }
        set { d.set(Int(newValue), forKey: "hotKeyCode"); notify() }
    }

    var hotKeyModifiers: UInt32 {
        get { UInt32(d.integer(forKey: "hotKeyModifiers")) }
        set { d.set(Int(newValue), forKey: "hotKeyModifiers"); notify() }
    }

    /// Human-readable form of the hotkey, e.g. "⌥⌘7".
    var hotKeyDisplay: String {
        get { d.string(forKey: "hotKeyDisplay") ?? "⌥⌘7" }
        set { d.set(newValue, forKey: "hotKeyDisplay"); notify() }
    }

    /// Whole-window opacity applied to "ghosted" (click-through) windows.
    var ghostOpacity: Double {
        get { d.double(forKey: "ghostOpacity") }
        set { d.set(newValue, forKey: "ghostOpacity"); notify() }
    }

    /// When true, every FloatyTerm surface (terminal windows, bubbles, ticker
    /// strips, transcript readers, the switcher) is excluded from screen
    /// capture: invisible in screen recordings and screen-sharing sessions
    /// (Zoom, Meet…) while staying fully visible to the user. Terminals are
    /// full of secrets and these windows float over everything — this keeps
    /// them private when presenting.
    var hideFromScreenCapture: Bool {
        get { d.bool(forKey: "hideFromScreenCapture") }
        set { d.set(newValue, forKey: "hideFromScreenCapture"); notify() }
    }

    /// Grid point where the session switcher and summoned windows appear.
    var summonPosition: SummonPosition {
        get { SummonPosition(rawValue: d.string(forKey: "summonPosition") ?? "") ?? .center }
        set { d.set(newValue.rawValue, forKey: "summonPosition"); notify() }
    }

    /// When true, browser tabs force transparent page backgrounds so the blur
    /// shows through. Some dark-mode sites rely on their background color for
    /// readability — turn this off for normal opaque pages. Applies to browser
    /// tabs created after the change (the WKWebView config is fixed at creation).
    var browserTransparency: Bool {
        get { d.bool(forKey: "browserTransparency") }
        set { d.set(newValue, forKey: "browserTransparency"); notify() }
    }

    /// When true, browser tabs block popups / new windows (window.open and
    /// target=_blank that try to spawn a window) — the "click play → new ad
    /// tab" pattern on streaming sites. The user's real click still works; the
    /// spawned popup is dropped. A per-tab shield in the URL bar can disable
    /// this for the current site. Read live on each popup, so it applies to
    /// open tabs immediately (no reload needed).
    var blockPopups: Bool {
        get { d.bool(forKey: "blockPopups") }
        set { d.set(newValue, forKey: "blockPopups"); notify() }
    }

    /// When true, browser tabs cancel *unsolicited* navigations — a cross-site
    /// main-frame redirect that fires with no recent click or keypress behind
    /// it (the timer-driven "page yanked to an ad site" pattern). Aggressive:
    /// it can also cancel legitimate automatic cross-site redirects (some OAuth
    /// hops, link shorteners), so it's off by default and gated per-tab by the
    /// same shield. Read live on each navigation.
    var blockRedirects: Bool {
        get { d.bool(forKey: "blockRedirects") }
        set { d.set(newValue, forKey: "blockRedirects"); notify() }
    }

    /// Frame rate for window-mirror tabs. Off (default) = low-power ~12 fps,
    /// fine for glancing at code/ideas and easy on CPU. On = smooth ~30 fps for
    /// scrolling/animation, at higher CPU cost. A live mirror tab observes
    /// `Settings.didChange` and re-applies this without a restart.
    var mirrorSmoothCapture: Bool {
        get { d.bool(forKey: "mirrorSmoothCapture") }
        set { d.set(newValue, forKey: "mirrorSmoothCapture"); notify() }
    }

    /// When true, terminals render through SwiftTerm's experimental Metal (GPU)
    /// path instead of the default CoreText/CPU drawing: glyphs are rasterized
    /// into a texture atlas and cells drawn as GPU quads, which can lighten CPU
    /// load on heavy scrollback. Opt-in and off by default — the GPU path is
    /// still evolving (image caching is basic) and hardware without a usable
    /// Metal device silently falls back to CoreText. Applied live per terminal
    /// via `TerminalController.applyMetalRenderer()` on `Settings.didChange`.
    var metalRenderer: Bool {
        get { d.bool(forKey: "metalRenderer") }
        set { d.set(newValue, forKey: "metalRenderer"); notify() }
    }

    /// When true, new terminal tabs and new windows inherit the working directory
    /// of the currently-active terminal tab instead of always opening in $HOME.
    var inheritWorkingDirectory: Bool {
        get { d.bool(forKey: "inheritWorkingDirectory") }
        set { d.set(newValue, forKey: "inheritWorkingDirectory"); notify() }
    }

    /// How many days StorageJanitor keeps per-feature data on disk — Devtools
    /// logs, Browser Context captures and Context Snap files — before its
    /// hourly sweep deletes them. 0 = keep forever (the retention pass is
    /// skipped; the size cap below still applies). One shared knob for all
    /// managed directories; enforcement is per directory.
    var storageRetentionDays: Int {
        get { d.integer(forKey: "storageRetentionDays") }
        set { d.set(newValue, forKey: "storageRetentionDays"); notify() }
    }

    /// Size budget (megabytes) StorageJanitor trims the managed directories
    /// down to, oldest files first. Applied per managed root: Devtools gets
    /// the full cap; Browser Context and Snaps get a quarter of it each. One
    /// shared knob for all managed directories; enforcement is per directory.
    var storageCapMB: Int {
        get { d.integer(forKey: "storageCapMB") }
        set { d.set(newValue, forKey: "storageCapMB"); notify() }
    }

    private func notify() {
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }
}
