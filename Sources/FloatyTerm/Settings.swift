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
            "summonPosition": SummonPosition.center.rawValue,
            "ghostOpacity": 0.35
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

    /// When true, new terminal tabs and new windows inherit the working directory
    /// of the currently-active terminal tab instead of always opening in $HOME.
    var inheritWorkingDirectory: Bool {
        get { d.bool(forKey: "inheritWorkingDirectory") }
        set { d.set(newValue, forKey: "inheritWorkingDirectory"); notify() }
    }

    private func notify() {
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }
}
