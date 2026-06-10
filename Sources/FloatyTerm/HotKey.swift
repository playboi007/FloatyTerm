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
    private var releaseHandlers: [UInt32: () -> Void] = [:]
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
        // Listen for both press AND release so callers can implement
        // hold-to-peek (show while held, hide on release).
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                          eventKind: UInt32(kEventHotKeyReleased))
        ]
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
                if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                    HotKey.shared?.fireRelease(id: hkID.id)
                } else {
                    HotKey.shared?.fire(id: hkID.id)
                }
                return noErr
            },
            2, &eventTypes, nil, &eventHandler
        )
    }

    /// Registers (or replaces) the hotkey stored under `id`.
    /// - Parameter onRelease: optional callback when the combo is released.
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32,
                  action: @escaping () -> Void,
                  onRelease: (() -> Void)? = nil) {
        if let existing = refs[id] {
            UnregisterEventHotKey(existing)
            refs[id] = nil
        }
        handlers[id] = action
        releaseHandlers[id] = onRelease
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            keyCode, modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        // A combo already claimed system-wide (or by another app) fails here;
        // don't store a nil ref as if it succeeded.
        guard status == noErr, let ref else {
            NSLog("FloatyTerm: hotkey %u registration failed (OSStatus %d) — combo may be taken", id, status)
            refs[id] = nil
            return
        }
        refs[id] = ref
    }

    private func fire(id: UInt32) {
        handlers[id]?()
    }

    private func fireRelease(id: UInt32) {
        releaseHandlers[id]?()
    }

    deinit {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
