import AppKit
import Carbon.HIToolbox

/// Registers global hotkeys using the Carbon Hot Key API.
///
/// We use Carbon on purpose: it does NOT require Accessibility permission,
/// unlike NSEvent global key monitors. Multiple hotkeys are supported, each
/// keyed by a small integer `id`; the shared C event handler dispatches to the
/// matching Swift callback. Key combos come from `Settings` and can change at
/// runtime — just call `register(...)` again with the same id.
final class HotKey {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    // The Carbon C callback can't capture Swift context, so we route through
    // a single shared instance.
    private static var shared: HotKey?

    private let signature: OSType = 0x46544B59 // 'FTKY'

    init() {
        HotKey.shared = self
        installHandler()
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, _) -> OSStatus in
                guard let event else { return noErr }
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkID
                )
                HotKey.shared?.fire(id: hkID.id)
                return noErr
            },
            1, &eventType, nil, &eventHandler
        )
    }

    /// Registers (or replaces) the hotkey stored under `id`.
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        if let existing = refs[id] {
            UnregisterEventHotKey(existing)
            refs[id] = nil
        }
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        refs[id] = ref
    }

    private func fire(id: UInt32) {
        handlers[id]?()
    }

    deinit {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
