import AppKit
import Carbon.HIToolbox

/// Small runtime flags shared across the app.
enum AppRuntime {
    /// Set while the app is quitting so per-window close prompts are skipped.
    static var isQuitting = false
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
            "hotKeyDisplay": "⌥⌘7"
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

    private func notify() {
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }
}
