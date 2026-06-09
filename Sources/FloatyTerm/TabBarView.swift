import AppKit

// MARK: - Drag-handle helper

/// Mix-in behaviour: any NSView that adopts this override will forward its
/// mouseDown events to `window?.performDrag(with:)`, making the view act as a
/// window-drag handle while still letting subview NSControls receive their own
/// clicks normally (AppKit delivers mouseDown to the front-most hit-tested view
/// first, so buttons/chips are never preempted).
class DragHandleView: NSView {
    /// Returning false here is belt-and-suspenders: we're already disabling
    /// isMovableByWindowBackground globally, but this makes the intent explicit.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Initiate a window drag. If the user just clicks without moving, this
        // is a harmless no-op from AppKit's perspective.
        window?.performDrag(with: event)
    }
}

// MARK: - Tab drop zone (whole-window)

/// A non-hit-testing overlay that draws the "drop a tab here to merge" cue.
private final class DropHighlightView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil } // never block clicks
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 2, dy: 2)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        bounds.fill()
        let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        path.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}

/// The window's content view, which doubles as the tab drop destination so a
/// tab can be dropped ANYWHERE on the window (not just the sometimes-hidden tab
/// strip). Shows a highlight while a tab from another window hovers over it.
final class WindowDropView: NSView {
    weak var windowController: TerminalWindowController?
    private let highlight = DropHighlightView()

    func registerDrop() {
        registerForDraggedTypes([NSPasteboard.PasteboardType(TabDragRegistry.uti)])
        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.isHidden = true
        addSubview(highlight)
        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    private func setHighlighted(_ on: Bool) {
        if on { addSubview(highlight, positioned: .above, relativeTo: nil) } // bring to front
        highlight.isHidden = !on
    }

    private func token(from sender: NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(forType: NSPasteboard.PasteboardType(TabDragRegistry.uti))
    }

    /// Accept any FloatyTerm tab drag so dropping on a window never triggers a
    /// (false) tear-off; only highlight when the drag is from ANOTHER window.
    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard let token = token(from: sender),
              let entry = TabDragRegistry.shared.entry(for: token) else {
            setHighlighted(false)
            return []
        }
        let other = entry.sourceController !== windowController
        // Reject the SOURCE window's own tab so that releasing over it — or
        // anywhere off another window — falls through to the tear-off path.
        // Only ANOTHER window accepts the drop (→ merge), and only it highlights.
        guard other else {
            setHighlighted(false)
            return []
        }
        setHighlighted(true)
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setHighlighted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setHighlighted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setHighlighted(false) }
        guard let token = token(from: sender),
              let entry = TabDragRegistry.shared.entry(for: token),
              let destWC = windowController else { return false }
        TabDragRegistry.shared.remove(token: token)
        let tab = entry.tab
        if let sourceWC = entry.sourceController, sourceWC !== destWC {
            sourceWC.releaseTab(tab)
            destWC.adoptTab(tab)
            return true
        }
        return false
    }
}

// MARK: - PassthroughTextField

/// A non-interactive label that ignores mouse events so they fall through to
/// the TabChip behind it — letting the whole chip be click-to-select and
/// drag-to-tear, instead of an NSButton swallowing the events.
private final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - TabChip

/// A single tab "chip": a title label plus a small close (×) button.
/// It is also a drag source: moving the pointer more than `dragThreshold`
/// points from the mouseDown location starts a tab-drag session; a pointer
/// movement below that threshold (or no movement) is a normal click-to-select.
final class TabChip: NSView, NSDraggingSource {
    private let titleLabel = PassthroughTextField(labelWithString: "")
    private let closeButton = NSButton()
    var onSelect: () -> Void = {}
    var onClose:  () -> Void = {}

    // Set by TabStripView so the chip knows what to put in the registry.
    var tabIndex: Int = 0
    weak var dragDelegate: TabChipDragDelegate?

    // The chip background itself must not move the window; clicks on the chip
    // background (not on a button) should not propagate up as drag handles.
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: - Drag threshold tracking
    private let dragThreshold: CGFloat = 5.0
    private var mouseDownEvent: NSEvent?
    private var dragStarted = false

    init(title: String, active: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.backgroundColor = active
            ? NSColor.white.withAlphaComponent(0.20).cgColor
            : NSColor.white.withAlphaComponent(0.06).cgColor

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = active ? .white : NSColor.white.withAlphaComponent(0.7)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        closeButton.title = "×"
        closeButton.isBordered = false
        closeButton.font = .systemFont(ofSize: 13)
        closeButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(closeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 140),

            closeButton.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 2),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeTapped()  { onClose()  }

    // MARK: - Mouse tracking for drag-vs-click disambiguation

    override func mouseDown(with event: NSEvent) {
        // Record the start event; do NOT call super (which would forward to the
        // DragHandleView and start a window drag).  We handle in mouseUp/mouseDragged.
        mouseDownEvent = event
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startEvent = mouseDownEvent, !dragStarted else { return }
        let startLoc = startEvent.locationInWindow
        let currLoc  = event.locationInWindow
        let dx = currLoc.x - startLoc.x
        let dy = currLoc.y - startLoc.y
        let dist = hypot(dx, dy)
        guard dist >= dragThreshold else { return }

        // Threshold crossed — begin a tab drag.
        dragStarted = true
        mouseDownEvent = nil
        beginTabDrag(event: startEvent)
    }

    override func mouseUp(with event: NSEvent) {
        guard !dragStarted else {
            mouseDownEvent = nil
            dragStarted = false
            return
        }
        // No drag happened — treat as select.
        mouseDownEvent = nil
        onSelect()
    }

    // MARK: - Begin drag session

    private func beginTabDrag(event: NSEvent) {
        guard let delegate = dragDelegate else { return }

        let token = UUID().uuidString
        delegate.chipWillBeginDrag(chip: self, tabIndex: tabIndex, token: token)

        // Drag image: snapshot of the chip itself.
        let dragImage: NSImage
        if let cgImg = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: cgImg)
            dragImage = NSImage(size: bounds.size)
            dragImage.addRepresentation(cgImg)
        } else {
            dragImage = NSImage(size: bounds.size)
        }

        let item = NSDraggingItem(pasteboardWriter: makePasteboardItem(token: token))
        // Position the drag image so the cursor stays where it started.
        let locInChip = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(
            NSRect(origin: NSPoint(x: -locInChip.x, y: -(bounds.height - locInChip.y)),
                   size: bounds.size),
            contents: dragImage
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func makePasteboardItem(token: String) -> NSPasteboardItem {
        let pb = NSPasteboardItem()
        pb.setString(token, forType: NSPasteboard.PasteboardType(TabDragRegistry.uti))
        return pb
    }

    // MARK: - NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // If operation is empty, no destination accepted the drop → tear off.
        if operation == [] {
            dragDelegate?.chipDidEndDragWithNoDestination(tabIndex: tabIndex, screenPoint: screenPoint)
        }
    }
}

// MARK: - TabChipDragDelegate

/// Implemented by TabStripView; bridges chip events back to the window controller.
protocol TabChipDragDelegate: AnyObject {
    /// Called just before the drag session begins so the strip can register
    /// the token in the registry and store which tab is being dragged.
    func chipWillBeginDrag(chip: TabChip, tabIndex: Int, token: String)

    /// Called when the drag ended with no accepted destination (tear-off).
    func chipDidEndDragWithNoDestination(tabIndex: Int, screenPoint: NSPoint)
}

// MARK: - DragHandleClipView

/// An NSClipView subclass that acts as a drag handle. Needed because the
/// NSScrollView inside TabStripView intercepts mouseDown on its clip view;
/// replacing it with this subclass ensures clicks on empty strip space still
/// initiate a window drag.
private final class DragHandleClipView: NSClipView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - TabStripView

/// The strip that lives BELOW the header and shows one chip per tab. It is
/// shown only when there are at least two tabs.
///
/// It is both:
///  - a NSDraggingDestination (accepts tab chips from any window), and
///  - a TabChipDragDelegate (bridges chip drag events to the window controller).
final class TabStripView: DragHandleView, TabChipDragDelegate {
    var onSelect:     (Int) -> Void = { _ in }
    var onCloseTab:   (Int) -> Void = { _ in }

    /// Set by TerminalWindowController so we can call releaseTab/adoptTab.
    weak var windowController: TerminalWindowController?

    private let scroll = NSScrollView()
    private let stack  = NSStackView()

    // Active drag token being dragged out of THIS strip (used in the tear-off path).
    private var activeDragToken: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        // Replace the default NSClipView with our drag-handle subclass so that
        // mouseDown on empty space in the scroll area initiates a window drag.
        scroll.contentView = DragHandleClipView()
        scroll.documentView = stack
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.heightAnchor)
        ])
        // Note: the drop destination is the whole-window WindowDropView (root),
        // not this strip — the strip is hidden for single-tab windows. The strip
        // remains the drag SOURCE (via TabChip) only.
    }

    func reload(titles: [String], activeIndex: Int) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, title) in titles.enumerated() {
            let chip = TabChip(title: title.isEmpty ? "Tab \(index + 1)" : title,
                               active: index == activeIndex)
            chip.tabIndex = index
            chip.dragDelegate = self
            chip.onSelect = { [weak self] in self?.onSelect(index) }
            chip.onClose  = { [weak self] in self?.onCloseTab(index) }
            stack.addArrangedSubview(chip)
        }
    }

    // MARK: - TabChipDragDelegate

    func chipWillBeginDrag(chip: TabChip, tabIndex: Int, token: String) {
        guard let wc = windowController,
              wc.tabs.indices.contains(tabIndex) else { return }
        let tab = wc.tabs[tabIndex]
        TabDragRegistry.shared.register(token: token, sourceController: wc, tab: tab)
        activeDragToken = token
    }

    func chipDidEndDragWithNoDestination(tabIndex: Int, screenPoint: NSPoint) {
        guard let token = activeDragToken else { return }
        activeDragToken = nil
        guard let entry = TabDragRegistry.shared.entry(for: token),
              let sourceWC = entry.sourceController else {
            TabDragRegistry.shared.remove(token: token)
            return
        }
        TabDragRegistry.shared.remove(token: token)

        // Tear-off: first remove the tab from the source window (so its strip
        // and tabs array no longer hold it), THEN hand it to a new window.
        // Capture the detach closure before releaseTab, which may close (and
        // free) the source window if this was its last tab.
        let tab = entry.tab
        let detach = sourceWC.onDetachTab
        sourceWC.releaseTab(tab)
        detach?(tab, screenPoint)
    }

    // MARK: - NSDraggingDestination overrides

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard tokenFromSender(sender) != nil else { return [] }
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard tokenFromSender(sender) != nil else { return [] }
        return .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let token = tokenFromSender(sender),
              let entry = TabDragRegistry.shared.entry(for: token),
              let destWC = windowController else { return false }

        let tab = entry.tab
        let sourceWC = entry.sourceController

        TabDragRegistry.shared.remove(token: token)
        // Prevent the tear-off path from also firing.
        activeDragToken = nil

        if let sourceWC = sourceWC, sourceWC !== destWC {
            // Cross-window move.
            sourceWC.releaseTab(tab)
            destWC.adoptTab(tab)
        }
        // If same window, we could implement reorder here — skipped for now.
        return true
    }

    // MARK: - Helpers

    private func tokenFromSender(_ sender: NSDraggingInfo) -> String? {
        sender.draggingPasteboard.string(
            forType: NSPasteboard.PasteboardType(TabDragRegistry.uti))
    }
}

// MARK: - HeaderControlsView

/// The controls in the top header strip: a URL-bar toggle (browser tabs only),
/// "＋" (new tab) and "⧉" (new window).
final class HeaderControlsView: DragHandleView {
    var onAddTab:        () -> Void = {}
    var onNewWindow:     () -> Void = {}
    var onToggleURLBar:  () -> Void = {}
    var onMinimize:      () -> Void = {}

    /// Set by TerminalWindowController — used when a tab is dropped onto the header.
    weak var tabStripView: TabStripView?

    private let urlBarToggleButton = NSButton()
    private let addButton          = NSButton()
    private let newWindowButton    = NSButton()
    private let minimizeButton     = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        configure(addButton, glyph: "+", action: #selector(addTapped))
        configure(newWindowButton, glyph: "⧉", action: #selector(newWindowTapped))

        // Minimize: hides THIS window to the menu bar (session preserved).
        // Uses the conventional "minus" glyph (mirrors the macOS yellow button).
        minimizeButton.image = NSImage(systemSymbolName: "minus",
                                       accessibilityDescription: "Minimize window")
        minimizeButton.isBordered = false
        minimizeButton.font = .systemFont(ofSize: 15, weight: .semibold)
        minimizeButton.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        minimizeButton.target = self
        minimizeButton.action = #selector(minimizeTapped)
        minimizeButton.toolTip = "Hide this window (restore from the menu-bar icon)"
        minimizeButton.translatesAutoresizingMaskIntoConstraints = false

        // Globe toggle for the address bar — only shown when a browser tab is active.
        urlBarToggleButton.image = NSImage(systemSymbolName: "globe",
                                           accessibilityDescription: "Toggle address bar")
        urlBarToggleButton.isBordered = false
        urlBarToggleButton.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        urlBarToggleButton.target = self
        urlBarToggleButton.action = #selector(toggleURLBarTapped)
        urlBarToggleButton.toolTip = "Show / hide address bar"
        urlBarToggleButton.isHidden = true
        urlBarToggleButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(urlBarToggleButton)
        addSubview(addButton)
        addSubview(newWindowButton)
        addSubview(minimizeButton)

        NSLayoutConstraint.activate([
            urlBarToggleButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -6),
            urlBarToggleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            urlBarToggleButton.widthAnchor.constraint(equalToConstant: 24),

            addButton.trailingAnchor.constraint(equalTo: newWindowButton.leadingAnchor, constant: -4),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 24),

            newWindowButton.trailingAnchor.constraint(equalTo: minimizeButton.leadingAnchor, constant: -4),
            newWindowButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newWindowButton.widthAnchor.constraint(equalToConstant: 24),

            minimizeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            minimizeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            minimizeButton.widthAnchor.constraint(equalToConstant: 24)
        ])

        // The header also acts as a drop destination for cross-window moves when
        // the tab strip is hidden (single-tab windows).
        registerForDraggedTypes([NSPasteboard.PasteboardType(TabDragRegistry.uti)])
    }

    /// Shows/hides the address-bar toggle (only relevant for browser tabs).
    func setURLBarToggleVisible(_ visible: Bool) {
        urlBarToggleButton.isHidden = !visible
    }

    /// Reflects whether the address bar is currently expanded.
    func setURLBarToggleActive(_ active: Bool) {
        urlBarToggleButton.contentTintColor = active
            ? NSColor.controlAccentColor
            : NSColor.white.withAlphaComponent(0.55)
        urlBarToggleButton.toolTip = active ? "Hide address bar" : "Show address bar"
    }

    private func configure(_ button: NSButton, glyph: String, action: Selector) {
        button.title = glyph
        button.isBordered = false
        button.font = .systemFont(ofSize: 15)
        button.contentTintColor = NSColor.white.withAlphaComponent(0.8)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func addTapped()        { onAddTab()       }
    @objc private func newWindowTapped()  { onNewWindow()    }
    @objc private func toggleURLBarTapped() { onToggleURLBar() }
    @objc private func minimizeTapped()   { onMinimize()     }

    // MARK: - NSDraggingDestination overrides (forward to tabStripView)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        tabStripView?.draggingEntered(sender) ?? []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        tabStripView?.draggingUpdated(sender) ?? []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        tabStripView?.performDragOperation(sender) ?? false
    }
}
