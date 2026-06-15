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
    private let ghostSlider = NSSlider()
    private let ghostValueLabel = NSTextField(labelWithString: "")
    private let dimCheckbox = NSButton(checkboxWithTitle: "Dim terminal when unfocused", target: nil, action: nil)
    private let inheritCwdCheckbox = NSButton(checkboxWithTitle: "Open new tabs in the current directory", target: nil, action: nil)
    private let browserTransparencyCheckbox = NSButton(checkboxWithTitle: "Transparent browser backgrounds (new tabs; some dark sites look better off)", target: nil, action: nil)
    private let recordButton = NSButton(title: "", target: nil, action: nil)
    private var summonGridButtons: [NSButton] = []   // 9 buttons, row-major
    private let retentionPopup = NSPopUpButton()
    private let capPopup = NSPopUpButton()
    private let usageStack = NSStackView()           // per-category usage rows

    // Hotkey recording state.
    private var recording = false
    private var keyMonitor: Any?

    func show() {
        if window == nil { build() }
        syncControls()
        refreshUsage()   // usage numbers are live — recompute on every appearance
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Build UI

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 740),
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

        // Focused opacity (floor 0.1 — 0 would make the terminal text invisible)
        focusedSlider.minValue = 0.1
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

        // Browser background transparency
        browserTransparencyCheckbox.target = self
        browserTransparencyCheckbox.action = #selector(browserTransparencyToggled(_:))
        stack.addArrangedSubview(browserTransparencyCheckbox)

        // Unfocused opacity (same floor as focused)
        opacitySlider.minValue = 0.1
        opacitySlider.maxValue = 1.0
        opacitySlider.target = self
        opacitySlider.action = #selector(opacityChanged(_:))
        opacitySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(row("Unfocused opacity", opacitySlider, opacityValueLabel))

        // Ghost opacity (click-through windows)
        ghostSlider.minValue = 0.1
        ghostSlider.maxValue = 0.9
        ghostSlider.target = self
        ghostSlider.action = #selector(ghostOpacityChanged(_:))
        ghostSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(row("Ghost opacity", ghostSlider, ghostValueLabel))

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

        // Summon position: a 3×3 grid of screen anchor points controlling
        // where the session switcher and summoned (borrowed) windows appear —
        // so they don't land on top of a terminal already in view.
        let gridStack = NSStackView()
        gridStack.orientation = .vertical
        gridStack.spacing = 2
        summonGridButtons = []
        for row in SummonPosition.gridOrder {
            let rowStack = NSStackView()
            rowStack.orientation = .horizontal
            rowStack.spacing = 2
            for position in row {
                let b = NSButton(title: "", target: self, action: #selector(summonPositionTapped(_:)))
                b.bezelStyle = .smallSquare
                b.setButtonType(.pushOnPushOff)
                b.identifier = NSUserInterfaceItemIdentifier(position.rawValue)
                b.toolTip = "Summon overlays appear here"
                b.widthAnchor.constraint(equalToConstant: 22).isActive = true
                b.heightAnchor.constraint(equalToConstant: 18).isActive = true
                summonGridButtons.append(b)
                rowStack.addArrangedSubview(b)
            }
            gridStack.addArrangedSubview(rowStack)
        }
        let gridCaption = NSTextField(labelWithString: "Where the switcher & summoned windows appear")
        gridCaption.font = .systemFont(ofSize: 11)
        gridCaption.textColor = .secondaryLabelColor
        stack.addArrangedSubview(row("Summon position", gridStack, gridCaption))

        // The fixed combos, surfaced here for discoverability.
        let spawnHint = NSTextField(labelWithString:
            "Spawn a window on this Space: ⌥⌘5 · Session switcher: ⌥⌘K (⌘K in a window)")
        spawnHint.font = .systemFont(ofSize: 11)
        spawnHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(spawnHint)

        // ── Storage ──────────────────────────────────────────────────────
        // Per-feature data on disk (devtools logs, page captures, snaps):
        // usage readouts with manual Clear, plus the two auto-clean knobs.
        let storageSeparator = NSBox()
        storageSeparator.boxType = .separator
        storageSeparator.widthAnchor.constraint(equalToConstant: 380).isActive = true
        stack.addArrangedSubview(storageSeparator)

        let storageHeader = NSTextField(labelWithString: "Storage")
        storageHeader.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(storageHeader)

        // Per-category usage rows, rebuilt by refreshUsage().
        usageStack.orientation = .vertical
        usageStack.alignment = .leading
        usageStack.spacing = 6
        stack.addArrangedSubview(usageStack)

        // Retention: how long files live before the hourly sweep removes them.
        for (title, days) in [("Keep 1 day", 1), ("Keep 3 days", 3), ("Keep 7 days", 7),
                              ("Keep 14 days", 14), ("Keep 30 days", 30), ("Forever", 0)] {
            retentionPopup.addItem(withTitle: title)
            retentionPopup.lastItem?.tag = days
        }
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionChanged(_:))
        retentionPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(row("Auto-clean", retentionPopup))

        // Cap: per-root size budget (Devtools full; Browser Context & Snaps ¼).
        for (title, mb) in [("50 MB", 50), ("100 MB", 100), ("250 MB", 250),
                            ("500 MB", 500), ("1 GB", 1024)] {
            capPopup.addItem(withTitle: title)
            capPopup.lastItem?.tag = mb
        }
        capPopup.target = self
        capPopup.action = #selector(capChanged(_:))
        capPopup.widthAnchor.constraint(equalToConstant: 200).isActive = true
        stack.addArrangedSubview(row("Total cap", capPopup))

        let storageHint = NSTextField(wrappingLabelWithString:
            "Auto-clean runs hourly — removes items older than the retention, " +
            "then trims oldest first to stay under the cap. Transcripts manage themselves.")
        storageHint.font = .systemFont(ofSize: 11)
        storageHint.textColor = .secondaryLabelColor
        storageHint.preferredMaxLayoutWidth = 380
        stack.addArrangedSubview(storageHint)

        // If the window closes mid-recording, tear the monitor down — a live
        // local monitor that returns nil would silently eat every keystroke.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main
        ) { [weak self] _ in
            guard let self, self.recording else { return }
            self.recording = false
            self.removeMonitor()
            self.syncControls()
        }

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
        browserTransparencyCheckbox.state = Settings.shared.browserTransparency ? .on : .off
        ghostSlider.doubleValue = Settings.shared.ghostOpacity
        ghostValueLabel.stringValue = "\(Int(Settings.shared.ghostOpacity * 100))%"
        recordButton.title = recording ? "Press a shortcut…" : Settings.shared.hotKeyDisplay
        let current = Settings.shared.summonPosition.rawValue
        for b in summonGridButtons {
            b.state = (b.identifier?.rawValue == current) ? .on : .off
        }
        _ = retentionPopup.selectItem(withTag: Settings.shared.storageRetentionDays)
        _ = capPopup.selectItem(withTag: Settings.shared.storageCapMB)
    }

    /// Rebuilds the per-category usage rows (name · size · file count · Clear).
    /// Called when the window appears and after a manual clear.
    private func refreshUsage() {
        usageStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for entry in StorageJanitor.shared.usage() {
            let detail = NSTextField(labelWithString:
                "\(Self.formatBytes(entry.bytes)) · \(entry.files) file\(entry.files == 1 ? "" : "s")")
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.widthAnchor.constraint(equalToConstant: 140).isActive = true
            // Transcripts have their own lifecycle — display-only, no Clear.
            if entry.name == StorageJanitor.Category.transcripts.rawValue {
                usageStack.addArrangedSubview(row(entry.name, detail))
            } else {
                let clear = NSButton(title: "Clear", target: self,
                                     action: #selector(clearStorageTapped(_:)))
                clear.bezelStyle = .rounded
                clear.controlSize = .small
                clear.identifier = NSUserInterfaceItemIdentifier(entry.name)
                clear.toolTip = "Delete all files in \(entry.path)"
                usageStack.addArrangedSubview(row(entry.name, detail, clear))
            }
        }
    }

    /// "12.4 MB"-style size for the Storage usage rows.
    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
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

    @objc private func browserTransparencyToggled(_ sender: NSButton) {
        Settings.shared.browserTransparency = (sender.state == .on)
    }

    @objc private func ghostOpacityChanged(_ sender: NSSlider) {
        Settings.shared.ghostOpacity = sender.doubleValue
        ghostValueLabel.stringValue = "\(Int(sender.doubleValue * 100))%"
    }

    @objc private func summonPositionTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let position = SummonPosition(rawValue: raw) else { return }
        Settings.shared.summonPosition = position
        syncControls()   // radio behaviour: exactly one grid cell stays on
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        Settings.shared.unfocusedOpacity = sender.doubleValue
        opacityValueLabel.stringValue = "\(Int(sender.doubleValue * 100))%"
    }

    @objc private func retentionChanged(_ sender: NSPopUpButton) {
        Settings.shared.storageRetentionDays = sender.selectedTag()
        StorageJanitor.shared.sweep()   // apply the tighter policy right away
    }

    @objc private func capChanged(_ sender: NSPopUpButton) {
        Settings.shared.storageCapMB = sender.selectedTag()
        StorageJanitor.shared.sweep()
    }

    @objc private func clearStorageTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let category = StorageJanitor.Category(rawValue: raw) else { return }
        StorageJanitor.shared.clear(category: category)
        refreshUsage()
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

        // Esc cancels recording (otherwise the only way out is the button,
        // since plain keys are swallowed by the guard below).
        if event.keyCode == UInt16(kVK_Escape), carbonMods == 0 {
            recording = false
            removeMonitor()
            syncControls()
            return
        }

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
