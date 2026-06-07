import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// A small Preferences window. Values write straight to `Settings`, which
/// notifies the rest of the app to update live.
final class SettingsWindowController: NSObject {
    private var window: NSWindow?

    private let fontValueLabel = NSTextField(labelWithString: "")
    private let blurCheckbox = NSButton(checkboxWithTitle: "Background blur (off = see-through)", target: nil, action: nil)
    private let focusedSlider = NSSlider()
    private let focusedValueLabel = NSTextField(labelWithString: "")
    private let opacitySlider = NSSlider()
    private let opacityValueLabel = NSTextField(labelWithString: "")
    private let dimCheckbox = NSButton(checkboxWithTitle: "Dim terminal when unfocused", target: nil, action: nil)
    private let inheritCwdCheckbox = NSButton(checkboxWithTitle: "Open new tabs in the current directory", target: nil, action: nil)
    private let recordButton = NSButton(title: "", target: nil, action: nil)

    // Hotkey recording state.
    private var recording = false
    private var keyMonitor: Any?

    func show() {
        if window == nil { build() }
        syncControls()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Build UI

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        w.title = "FloatyTerm Preferences"
        w.isReleasedWhenClosed = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Font size
        let fontSlider = NSSlider(value: Settings.shared.fontSize, minValue: 9, maxValue: 24,
                                  target: self, action: #selector(fontChanged(_:)))
        fontSlider.numberOfTickMarks = 16
        fontSlider.allowsTickMarkValuesOnly = true
        fontSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(row("Font size", fontSlider, fontValueLabel))

        // Background blur toggle
        blurCheckbox.target = self
        blurCheckbox.action = #selector(blurToggled(_:))
        stack.addArrangedSubview(blurCheckbox)

        // Focused opacity
        focusedSlider.minValue = 0.0
        focusedSlider.maxValue = 1.0
        focusedSlider.target = self
        focusedSlider.action = #selector(focusedChanged(_:))
        focusedSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(row("Focused opacity", focusedSlider, focusedValueLabel))

        // Dim when unfocused
        dimCheckbox.target = self
        dimCheckbox.action = #selector(dimToggled(_:))
        stack.addArrangedSubview(dimCheckbox)

        // Inherit working directory
        inheritCwdCheckbox.target = self
        inheritCwdCheckbox.action = #selector(inheritCwdToggled(_:))
        stack.addArrangedSubview(inheritCwdCheckbox)

        // Unfocused opacity
        opacitySlider.minValue = 0.0
        opacitySlider.maxValue = 1.0
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacitySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(row("Unfocused opacity", opacitySlider, opacityValueLabel))

        // Launch at login
        let loginCheckbox = NSButton(checkboxWithTitle: "Launch at login",
                                     target: self, action: #selector(loginToggled(_:)))
        loginCheckbox.state = launchAtLoginEnabled ? .on : .off
        stack.addArrangedSubview(loginCheckbox)

        // Hotkey recorder
        recordButton.bezelStyle = .rounded
        recordButton.target = self
        recordButton.action = #selector(recordTapped)
        recordButton.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(row("Toggle hotkey", recordButton))

        w.contentView?.addSubview(stack)
        if let cv = w.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: cv.topAnchor),
                stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor)
            ])
        }
        window = w
    }

    /// Builds a labeled horizontal row.
    private func row(_ title: String, _ controls: NSView...) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let h = NSStackView(views: [label] + controls)
        h.orientation = .horizontal
        h.spacing = 8
        h.alignment = .centerY
        return h
    }

    private func syncControls() {
        fontValueLabel.stringValue = "\(Int(Settings.shared.fontSize)) pt"
        blurCheckbox.state = Settings.shared.backgroundBlur ? .on : .off
        focusedSlider.doubleValue = Settings.shared.focusedOpacity
        focusedValueLabel.stringValue = "\(Int(Settings.shared.focusedOpacity * 100))%"
        dimCheckbox.state = Settings.shared.dimWhenUnfocused ? .on : .off
        opacitySlider.doubleValue = Settings.shared.unfocusedOpacity
        opacitySlider.isEnabled = Settings.shared.dimWhenUnfocused
        opacityValueLabel.stringValue = "\(Int(Settings.shared.unfocusedOpacity * 100))%"
        inheritCwdCheckbox.state = Settings.shared.inheritWorkingDirectory ? .on : .off
        recordButton.title = recording ? "Press a shortcut…" : Settings.shared.hotKeyDisplay
    }

    // MARK: - Actions

    @objc private func fontChanged(_ sender: NSSlider) {
        Settings.shared.fontSize = sender.doubleValue.rounded()
        fontValueLabel.stringValue = "\(Int(Settings.shared.fontSize)) pt"
    }

    @objc private func blurToggled(_ sender: NSButton) {
        Settings.shared.backgroundBlur = (sender.state == .on)
    }

    @objc private func focusedChanged(_ sender: NSSlider) {
        Settings.shared.focusedOpacity = sender.doubleValue
        focusedValueLabel.stringValue = "\(Int(sender.doubleValue * 100))%"
    }

    @objc private func dimToggled(_ sender: NSButton) {
        Settings.shared.dimWhenUnfocused = (sender.state == .on)
        opacitySlider.isEnabled = (sender.state == .on)
    }

    @objc private func inheritCwdToggled(_ sender: NSButton) {
        Settings.shared.inheritWorkingDirectory = (sender.state == .on)
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        Settings.shared.unfocusedOpacity = sender.doubleValue
        opacityValueLabel.stringValue = "\(Int(sender.doubleValue * 100))%"
    }

    @objc private func loginToggled(_ sender: NSButton) {
        setLaunchAtLogin(sender.state == .on)
    }

    // MARK: - Launch at login (SMAppService is the source of truth)

    private var launchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("FloatyTerm: login item toggle failed: \(error)")
            }
        }
    }

    // MARK: - Hotkey recording

    @objc private func recordTapped() {
        recording.toggle()
        syncControls()
        if recording {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.captureHotkey(event)
                return nil // swallow the key while recording
            }
        } else {
            removeMonitor()
        }
    }

    private func captureHotkey(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbonMods = Self.carbonModifiers(flags)
        // Require at least one non-shift modifier so the combo is global-safe.
        guard carbonMods != 0,
              carbonMods != UInt32(shiftKey) else { return }

        Settings.shared.hotKeyCode = UInt32(event.keyCode)
        Settings.shared.hotKeyModifiers = carbonMods
        let keyChar = (event.charactersIgnoringModifiers ?? "").uppercased()
        Settings.shared.hotKeyDisplay = Self.symbols(carbonMods) + keyChar

        recording = false
        removeMonitor()
        syncControls()
    }

    private func removeMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if flags.contains(.control) { c |= UInt32(controlKey) }
        if flags.contains(.option)  { c |= UInt32(optionKey) }
        if flags.contains(.shift)   { c |= UInt32(shiftKey) }
        if flags.contains(.command) { c |= UInt32(cmdKey) }
        return c
    }

    private static func symbols(_ carbon: UInt32) -> String {
        var s = ""
        if carbon & UInt32(controlKey) != 0 { s += "⌃" }
        if carbon & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbon & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbon & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s
    }
}
