import AppKit
import Carbon.HIToolbox

/// Registers the global toggle hotkey using the Carbon Hot Key API.
///
/// We use Carbon on purpose: it does NOT require Accessibility permission,
/// unlike NSEvent global key monitors. The key combo is read from `Settings`
/// and can be changed at runtime via `reregister()`.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let callback: () -> Void

    // The Carbon C callback can't capture Swift context, so we route through
    // a single shared instance.
    private static var shared: HotKey?

    init(callback: @escaping () -> Void) {
        self.callback = callback
        HotKey.shared = self
        installHandler()
        reregister()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, _) -> OSStatus in
                HotKey.shared?.callback()
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
    }

    /// (Re)registers the hotkey using the current `Settings` values.
    func reregister() {
        if let existing = hotKeyRef {
            UnregisterEventHotKey(existing)
            hotKeyRef = nil
        }
        let hotKeyID = EventHotKeyID(signature: OSType(0x46544B59), id: 1) // 'FTKY'
        RegisterEventHotKey(
            Settings.shared.hotKeyCode,
            Settings.shared.hotKeyModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
