import AppKit

/// Content for the window-options popover, opened from the header's utils
/// (ellipsis) button. Hosts per-window controls: an opacity slider and a Ghost
/// (click-through) toggle. Designed to grow more window-level extras over time.
final class WindowOptionsViewController: NSViewController {
    /// Live opacity changes as the slider moves (0.1–1.0).
    var onOpacityChange: (Double) -> Void = { _ in }
    /// Clears the per-window override, reverting to the global setting.
    var onResetOpacity: () -> Void = {}
    /// Ghost (click-through) the window.
    var onGhost: () -> Void = {}

    /// The window's current effective opacity — the slider's starting value.
    var initialOpacity: Double = 1.0

    private let slider = NSSlider()
    private let valueLabel = NSTextField(labelWithString: "")

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 252, height: 116))

        let title = NSTextField(labelWithString: "Window opacity")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let reset = NSButton(title: "Reset", target: self, action: #selector(resetTapped))
        reset.bezelStyle = .inline
        reset.controlSize = .mini
        reset.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = NSStackView(views: [title, valueLabel, reset])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        titleRow.alignment = .firstBaseline

        slider.minValue = 0.1
        slider.maxValue = 1.0
        slider.doubleValue = initialOpacity
        slider.target = self
        slider.action = #selector(sliderChanged)
        updateValueLabel()

        let sep = NSBox()
        sep.boxType = .separator

        let ghost = NSButton(title: "👻  Ghost (click-through)",
                             target: self, action: #selector(ghostTapped))
        ghost.bezelStyle = .rounded
        ghost.toolTip = "Make this window click-through and faded. Restore from the menu-bar icon."

        let stack = NSStackView(views: [titleRow, slider, sep, ghost])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            slider.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            ghost.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28)
        ])

        view = root
    }

    private func updateValueLabel() {
        valueLabel.stringValue = "\(Int((slider.doubleValue * 100).rounded()))%"
    }

    @objc private func sliderChanged() {
        updateValueLabel()
        onOpacityChange(slider.doubleValue)
    }

    @objc private func resetTapped() {
        onResetOpacity()
        // Reflect the reverted value in the slider, but keep the popover open.
        slider.doubleValue = initialOpacity
        updateValueLabel()
    }

    @objc private func ghostTapped() {
        onGhost()
        view.window?.close()   // dismiss the popover after ghosting
    }
}
