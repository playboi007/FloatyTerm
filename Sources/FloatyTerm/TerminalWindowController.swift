import AppKit
import SwiftTerm
import WebKit

/// Owns one floating window:
///  - a frosted top region (header controls + a tab strip that appears when
///    there are 2+ tabs) that stays opaque as a visual reference,
///  - a content area below it that shows the active tab's view and whose
///    opacity/blur is configurable.
///
/// Tabs are heterogeneous: any object conforming to `TabContent` may live in
/// `tabs`. Terminal-specific paths (find bar, recent-commands palette, foreground-
/// job check, font updates) are guarded with `as? TerminalController` casts.
final class TerminalWindowController: NSObject, NSWindowDelegate {
    let panel: FloatingPanel

    /// Stable identifier so the menu bar can address this specific window
    /// (e.g. to restore it after it has been minimized/hidden).
    let id = UUID()

    /// True while this window is individually hidden via the minimize button
    /// (as opposed to the global ⌥⌘7 hide). Minimized windows are restorable
    /// from the menu-bar "Hidden Windows" list.
    private(set) var isMinimized = false

    /// True while this window is collapsed into its floating avatar bubble.
    private(set) var isCollapsed = false

    /// True while this window is collapsed into a one-line ticker strip.
    private(set) var isTicker = false
    private var ticker: TickerPanel?

    /// True while this window is "ghosted": click-through and faded, for
    /// watching logs over another app. Restored from the menu-bar icon or by
    /// summoning the session (the window itself can't be clicked).
    private(set) var isGhosted = false

    /// True while this window is in AGENT GHOST mode: click-through AND non-key
    /// (so synthetic input passes to the app being driven and the floating panel
    /// can't steal the text cursor back), but STILL fully visible — unlike
    /// `isGhosted`, it stays readable so the user watches the agent work. Exited
    /// via the floating unlock badge, the `floaty host` route, or auto-surfaced
    /// when the agent stops for user input.
    private(set) var isAgentGhosted = false
    private var unlockBadge: AgentGhostBadge?

    /// Per-window opacity override (0.1–1.0) set from the double-click header
    /// overlay. When non-nil it wins over the global focused/unfocused-dim
    /// settings for this window. Session-scoped (not persisted).
    private var opacityOverride: Double?

    /// The window-options popover (opacity + ghost), opened from the header
    /// utils button; at most one at a time.
    private var optionsPopover: NSPopover?

    // Avatar (bubble) collapse state.
    private var avatar: AvatarPanel?
    private var collapsedSnapshot: NSImage?
    private var savedFrameForExpand: NSRect = .zero
    /// Where the cursor sat WITHIN the window when it collapsed (offset from the
    /// window's bottom-left origin). On expand we place the window so this same
    /// point — the collapse icon — returns to the bubble, preserving spatial
    /// awareness instead of re-centering the window on the bubble.
    private var collapseCursorOffset: NSPoint = .zero

    private let root        = WindowDropView()
    private let topBlur     = NSVisualEffectView()   // header + tab strip backdrop (always)
    private let contentBlur = NSVisualEffectView()   // content backdrop (toggleable)
    private let contentArea = NSView()
    private let header      = HeaderControlsView()
    private let tabStrip    = TabStripView()

    private var _startEmpty: Bool = false

    // MARK: - Find bar (terminal-only overlay)
    private let findBar = FindBarView()
    private var findBarTrailingConstraint: NSLayoutConstraint!
    private var findBarTopConstraint: NSLayoutConstraint!
    private var isFindBarVisible = false

    // MARK: - Recent-commands palette (terminal-only overlay)
    private let recentPalette = RecentCommandsPaletteView()
    private var isPaletteVisible = false

    // MARK: - Selection action bar (terminal-only overlay)
    private let selectionBar = SelectionActionBar()
    private var selectionText = ""

    // MARK: - Transcript reader (live clean view of one session's output)
    private var transcriptReader: TranscriptReaderController?
    private let readerButton = NSButton()

    // MARK: - URL bar (browser-only overlay)
    private let urlBar = URLBarView()
    private var isURLBarVisible = false

    private let headerHeight: CGFloat = 28
    private let tabStripHeight: CGFloat = 30
    private var tabStripHeightConstraint: NSLayoutConstraint!

    // MARK: - Heterogeneous tab list

    /// Exposed (internal) so TabStripView's drag delegate can read it.
    var tabs: [any TabContent] = []
    private var activeIndex = 0

    /// Viewer child tabs (e.g. images) → their parent terminal tab. In-memory
    /// only (TabContent is class-bound, so ObjectIdentifier is a stable key for
    /// the session's lifetime); used so closing a parent closes its viewers.
    private var parentByChild: [ObjectIdentifier: ObjectIdentifier] = [:]

    /// Held only during init so the first addTerminalTab() call can use it.
    /// Cleared after the first tab is created.
    private var pendingInitialDirectory: String?

    /// Pending debounced frame save (see scheduleFrameSave()).
    private var frameSaveWork: DispatchWorkItem?

    /// Periodic refresh of chip labels / status dots / bubble badge (auto-labels
    /// and running-state come from polling the pty). Invalidated on close.
    private var activityTimer: Timer?

    /// Tabs borrowed from another window via the session switcher, so they can
    /// be sent back. Keyed by tab identity; sources are weak (a closed source
    /// simply means there's nothing to return to).
    private struct BorrowRecord {
        let tabID: ObjectIdentifier
        weak var source: TerminalWindowController?
    }
    private var borrows: [BorrowRecord] = []

    /// True while this window's ONLY tab is borrowed away (session-switcher
    /// summon of a single-tab pinned window). The window stays alive on its
    /// Space — bubble, ticker strip, or an empty panel with a note — as the
    /// anchor the Return arrow sends the tab home to. Cleared by `insertTab`
    /// (the tab coming home, or any new tab opened here).
    private(set) var isLent = false
    /// Weak ref to the lent-away tab: when it deallocates (closed at the
    /// borrower instead of returned), the empty husk reaps itself.
    private weak var lentTab: (any TabContent)?
    private var lentPlaceholder: NSTextField?

    var onNewWindow:       (() -> Void)?
    var onClosed:          ((TerminalWindowController) -> Void)?
    var onOpenPreferences: (() -> Void)?

    /// Notifies the app delegate that this window's persistable state (frame,
    /// avatar style) changed, so the per-window records can be rewritten.
    var onStateChanged:    (() -> Void)?

    /// Asks the app delegate to open the global session switcher (⌘K).
    var onOpenSwitcher:    (() -> Void)?

    /// This window's avatar-bubble personalization (icon + ring color).
    /// Set via right-click on the bubble; restored from the window record.
    private(set) var avatarStyle = AvatarStyle()

    /// Called when a tab should be torn off into a new window.
    /// Parameters: the live tab object and the screen point where the drag ended.
    var onDetachTab: ((any TabContent, NSPoint) -> Void)?

    /// An armed session ("Notify When Done") just finished — the app should
    /// summon it to the user's current Space.
    var onSessionDone: ((any TabContent) -> Void)?

    /// - Parameter initialDirectory: The directory in which to open the first
    ///   terminal tab. nil → $HOME (the default / original behaviour).
    /// - Parameter startEmpty: When true, no initial tab is created.  Used by
    ///   the tear-off path so `adoptTab` can install the reparented tab.
    init(initialDirectory: String? = nil, startEmpty: Bool = false) {
        self.pendingInitialDirectory = initialDirectory
        self._startEmpty = startEmpty
        let initial = NSRect(x: 0, y: 0, width: 720, height: 460)
        panel = FloatingPanel(contentRect: initial)
        super.init()

        panel.delegate = self
        panel.setupFloatingBehavior()

        root.frame = initial
        root.autoresizingMask = [.width, .height]
        panel.contentView = root
        root.windowController = self
        root.registerDrop()

        topBlur.material     = .hudWindow
        topBlur.blendingMode = .behindWindow
        topBlur.state        = .active

        contentBlur.material     = .hudWindow
        contentBlur.blendingMode = .behindWindow
        contentBlur.state        = .active

        for v in [topBlur, contentBlur, contentArea, header, tabStrip] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        root.addSubview(contentBlur)
        root.addSubview(contentArea)
        root.addSubview(topBlur)
        topBlur.addSubview(header)
        topBlur.addSubview(tabStrip)

        tabStripHeightConstraint = tabStrip.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            topBlur.topAnchor.constraint(equalTo: root.topAnchor),
            topBlur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topBlur.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            header.topAnchor.constraint(equalTo: topBlur.topAnchor),
            header.leadingAnchor.constraint(equalTo: topBlur.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: topBlur.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: headerHeight),

            tabStrip.topAnchor.constraint(equalTo: header.bottomAnchor),
            tabStrip.leadingAnchor.constraint(equalTo: topBlur.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: topBlur.trailingAnchor),
            tabStrip.bottomAnchor.constraint(equalTo: topBlur.bottomAnchor),
            tabStripHeightConstraint,

            contentBlur.topAnchor.constraint(equalTo: topBlur.bottomAnchor),
            contentBlur.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentBlur.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentBlur.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            contentArea.topAnchor.constraint(equalTo: contentBlur.topAnchor),
            contentArea.leadingAnchor.constraint(equalTo: contentBlur.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: contentBlur.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: contentBlur.bottomAnchor)
        ])

        header.onAddTab       = { [weak self] in self?.addTerminalTab() }
        header.onNewWindow    = { [weak self] in self?.onNewWindow?() }
        header.onToggleURLBar = { [weak self] in self?.toggleURLBarCollapsed() }
        header.onMinimize       = { [weak self] in self?.minimize() }
        header.onTogglePin      = { [weak self] in self?.togglePin() }
        header.onBuildAppLinkMenu = { [weak self] menu in self?.buildAppLinkMenu(menu) }
        header.onCollapse       = { [weak self] in self?.collapseToAvatar() }
        header.onCollapseTicker = { [weak self] in self?.collapseToTicker() }
        header.onShowUtils      = { [weak self] button in self?.showWindowOptions(from: button) }
        header.onSnap           = { [weak self] asText in self?.captureContext(asText: asText) }
        header.onBuildSnapMenu  = { [weak self] menu in self?.buildSnapHistoryMenu(menu) }
        tabStrip.onSelect     = { [weak self] i in self?.selectTab(i) }
        tabStrip.onCloseTab   = { [weak self] i in self?.closeTab(i) }
        tabStrip.onRenameTab  = { [weak self] i in self?.promptRename(i) }
        tabStrip.onToggleNotifyTab = { [weak self] i in self?.toggleNotifyWhenDone(i) }
        tabStrip.onReturnTab  = { [weak self] i in self?.returnBorrowedTab(at: i) }
        header.onReturnTab    = { [weak self] in self?.returnBorrowedTab() }

        // Wire drag-support back-references.
        tabStrip.windowController = self
        header.tabStripView       = tabStrip

        panel.keyCommandHandler = { [weak self] event in
            self?.handleKeyCommand(event) ?? false
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: Settings.didChange, object: nil
        )

        // When the active Space changes, re-assert a pinned window so it doesn't
        // intermittently drop out of view during rapid Space swipes (a window-
        // server quirk with fullScreenAuxiliary windows). Guarded by
        // isOnActiveSpace so we only nudge it when it actually belongs to the
        // now-active Space — never pulling it onto a Space it isn't pinned to.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(activeSpaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil
        )

        setupFindBar()
        setupRecentPalette()
        setupURLBar()
        setupSelectionBar()
        setupAskAgentChip()
        setupReaderButton()
        installSelectionMonitor()
        if !_startEmpty {
            addTerminalTab() // start with one terminal tab
        }

        // Auto-labels ("flutter · myapp") and running-state dots come from
        // polling the pty; 2s with generous tolerance keeps it imperceptible.
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshActivity()
        }
        timer.tolerance = 0.5
        activityTimer = timer
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Active Space changed: if this window is pinned and now belongs to the
    /// active Space, nudge the compositor to re-display it (fixes the temporary
    /// disappearance after several fullscreen-Space swipes). The second, delayed
    /// pass catches cases where the window server is still re-attaching the
    /// auxiliary window when the notification fires.
    @objc private func activeSpaceChanged() {
        reassertIfPinnedOnActiveSpace()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.reassertIfPinnedOnActiveSpace()
        }
    }

    private func reassertIfPinnedOnActiveSpace() {
        guard panel.isPinned else { return }
        // When collapsed/tickered, the pinned bubble or strip (not the panel)
        // is what's on screen; nudge whichever one is live so it doesn't drop
        // out during swipes.
        if isCollapsed, let av = avatar {
            if av.isOnActiveSpace { av.orderFrontRegardless() }
        } else if isTicker, let t = ticker {
            if t.isOnActiveSpace { t.orderFrontRegardless() }
        } else if panel.isVisible, panel.isOnActiveSpace {
            panel.orderFrontRegardless()
        }
    }

    // MARK: - Window placement / visibility

    /// Positions a newly-created window.
    /// - reference: frame of the window currently on the user's Space, if any —
    ///   the new window cascades from it so it lands where the user is looking.
    /// - isLaunchWindow: true only for the first window at app launch, which
    ///   restores the remembered cross-launch frame. Otherwise (a window spawned
    ///   onto a fresh Space with no reference) it centers on the active screen.
    func placeInitialFrame(reference: NSRect?, isLaunchWindow: Bool) {
        if let ref = reference {
            panel.cascade(from: ref)
        } else if isLaunchWindow {
            panel.restoreSavedFrame()
        } else {
            panel.restoreSavedFrame()      // adopt remembered size…
            panel.centerOnActiveScreen()   // …but center on the Space in view
        }
    }

    func show() {
        isMinimized = false
        // Use orderFrontRegardless + makeKey (NOT NSApp.activate) so the panel
        // appears over another app's fullscreen Space without stealing it. This
        // is what makes the overlay reliably show over Chrome/Cursor and lets
        // every window come back together on ⌥⌘7.
        panel.presentOverlay()
        focusActiveTab()
        updateViewedFlags()
    }

    func hide() {
        closeReaderIfNeeded()
        panel.orderOut(nil)
        updateViewedFlags()
    }

    // MARK: - Per-window persisted state

    /// The frame worth persisting: a collapsed/tickered window's panel is
    /// hidden, so its pre-collapse frame is the meaningful one.
    private var persistableFrame: NSRect {
        (isCollapsed || isTicker) ? savedFrameForExpand : panel.frame
    }

    /// Snapshot of this window's persistable state for the window-records store.
    var stateRecord: WindowRecord {
        WindowRecord(frame: NSStringFromRect(persistableFrame),
                     avatarSymbol: avatarStyle.symbol,
                     avatarColor: avatarStyle.colorName,
                     tabs: tabs.compactMap(\.restorableRecord),
                     activeIndex: activeIndex,
                     linkedAppBundleID: linkedAppBundleID,
                     linkedAppName: linkedAppName)
    }

    /// Recreates tabs from a saved session: terminals restart in their last
    /// directory, browsers reload their page, custom names survive.
    /// Used only on launch, on a window created with startEmpty.
    func restoreTabs(_ records: [TabRecord], activeIndex savedActive: Int) {
        for record in records {
            if record.kind == "browser" {
                let tab = BrowserController(initialURL: record.url)
                tab.customName = record.customName
                tab.onTitleChanged = { [weak self] in
                    self?.refreshTabStrip()
                    self?.syncURLBar()
                }
                tab.onNavChanged = { [weak self] in self?.syncURLBar() }
                insertTab(tab)
            } else if record.kind == "note" {
                // Reopen the autosaved markdown file; a path-less record (or a
                // file the janitor swept) falls back to a fresh scratch note.
                let url = record.path.map(URL.init(fileURLWithPath:))
                    ?? NotesStore.newScratchNote()
                let tab = NoteController(fileURL: url)
                tab.customName = record.customName
                installSimpleTab(tab)
            } else {
                // Hand back the saved sessionID so the tab reclaims its
                // transcript log; a pre-sessionID record just mints a new one.
                let tab = TerminalController(startDirectory: record.directory,
                                             sessionID: record.sessionID)
                tab.customName = record.customName
                tab.onTerminated = { [weak self, weak tab] in
                    guard let self, let tab,
                          let idx = self.tabs.firstIndex(where: { $0 === tab }) else { return }
                    self.closeTab(idx)
                }
                tab.onTitleChanged = { [weak self] in self?.refreshTabStrip() }
                insertTab(tab)
            }
        }
        if tabs.isEmpty { addTerminalTab() }   // corrupt record safety net
        selectTab(min(max(0, savedActive), tabs.count - 1))
    }

    /// Adopts a persisted record at launch: frame (clamped on-screen, in case
    /// displays changed since last run) and avatar style.
    func applyRestored(_ record: WindowRecord) {
        avatarStyle = AvatarStyle(symbol: record.avatarSymbol,
                                  colorName: record.avatarColor)
        let f = NSRectFromString(record.frame)
        if f.width >= 320, f.height >= 180 {
            panel.setFrame(panel.clampToVisibleScreen(f), display: false)
        } else {
            panel.restoreSavedFrame()   // corrupt record → legacy fallback
        }
        if let bundleID = record.linkedAppBundleID {
            linkedAppBundleID = bundleID
            linkedAppName = record.linkedAppName
            header.setLinkedApp(record.linkedAppName)
            // makeWindow() calls show() right after this — defer one runloop
            // turn so the link's verdict (is the app frontmost right now?)
            // lands last and the window doesn't start visible over the
            // wrong app.
            DispatchQueue.main.async { [weak self] in
                self?.applyAppLinkVisibility(
                    frontmost: NSWorkspace.shared.frontmostApplication)
            }
        }
    }

    // MARK: - Collapse to / expand from the floating avatar bubble

    /// Morphs this window into a small floating avatar bubble (hero transition).
    /// The session stays alive; double-clicking the bubble expands it back.
    func collapseToAvatar() {
        guard !isCollapsed else { return }
        closeReaderIfNeeded()
        let termFrame = panel.frame
        let snapshot = HeroTransition.snapshot(of: root) ?? NSImage(size: termFrame.size)
        collapsedSnapshot = snapshot
        savedFrameForExpand = termFrame

        // Bubble lands at the mouse cursor (where the collapse icon was clicked),
        // clamped on-screen — so the window appears to implode toward the click.
        let d = AvatarPanel.diameter
        let mouse = NSEvent.mouseLocation
        // Remember the cursor's position within the window (the collapse icon)
        // so expand can return that exact point to the bubble.
        collapseCursorOffset = NSPoint(x: mouse.x - termFrame.minX,
                                       y: mouse.y - termFrame.minY)
        let avatarFrame = panel.clampToVisibleScreen(
            NSRect(x: mouse.x - d / 2, y: mouse.y - d / 2, width: d, height: d))

        isCollapsed = true
        panel.orderOut(nil)
        updateViewedFlags()

        HeroTransition.morph(snapshot: snapshot, from: termFrame, to: avatarFrame,
                             startRadius: 8, endRadius: d / 2, fadeToGlyph: true,
                             style: avatarStyle) { [weak self] in
            self?.showAvatar(at: avatarFrame)
        }
    }

    private func showAvatar(at frame: NSRect) {
        let av = avatar ?? AvatarPanel()
        avatar = av
        av.sharingType = Settings.shared.hideFromScreenCapture ? .none : .readOnly
        av.onExpand = { [weak self] in self?.expandFromAvatar() }
        av.apply(style: avatarStyle)
        av.onStyleChange = { [weak self] style in
            guard let self else { return }
            self.avatarStyle = style
            self.onStateChanged?()   // persist the new personalization
        }
        av.setFrame(frame, display: false)
        // Bring the bubble up as ROAMING first so it attaches to the CURRENT
        // Space — including another app's fullscreen Space. A brand-new managed
        // window ordered onto a foreign fullscreen Space won't attach (it lands
        // on the desktop). So for a linked window we pin on the next runloop
        // tick, once the bubble is actually displayed here — mirroring how the
        // window itself got pinned (it was already shown on this Space).
        av.setPinned(false)
        av.orderFrontRegardless()
        if panel.isPinned {
            DispatchQueue.main.async { [weak av] in av?.setPinned(true) }
        }
    }

    /// Reverses the collapse: the bubble grows back into the terminal, expanding
    /// from wherever the user has moved the bubble.
    /// - Parameter overrideTarget: explicit destination frame (summoning a
    ///   pinned bubble from another Space lands at the summon grid point
    ///   instead of wherever the off-Space bubble happened to sit).
    func expandFromAvatar(to overrideTarget: NSRect? = nil) {
        guard isCollapsed, let av = avatar else { return }
        let avatarFrame = av.frame
        let size = savedFrameForExpand.size
        // Place the window so the collapse-icon point (where the cursor was) lands
        // at the bubble's center — the window unfolds back to where the eye expects.
        let center = NSPoint(x: avatarFrame.midX, y: avatarFrame.midY)
        let raw = overrideTarget ?? NSRect(x: center.x - collapseCursorOffset.x,
                                           y: center.y - collapseCursorOffset.y,
                                           width: size.width, height: size.height)
        let target = panel.clampToVisibleScreen(raw)
        let image = collapsedSnapshot ?? HeroTransition.snapshot(of: root) ?? NSImage(size: size)
        let d = AvatarPanel.diameter

        av.orderOut(nil)
        HeroTransition.morph(snapshot: image, from: avatarFrame, to: target,
                             startRadius: d / 2, endRadius: 8, fadeToGlyph: false,
                             style: avatarStyle) { [weak self] in
            guard let self else { return }
            self.isCollapsed = false
            self.panel.setFrame(target, display: false)
            self.panel.presentOverlay()
            self.focusActiveTab()
            self.updateViewedFlags()
        }
    }

    // MARK: - Ghost mode (click-through log watching)

    /// Ghosts/unghosts this window: ghosted windows ignore all mouse events
    /// (clicks pass through to the app beneath) and fade to the configurable
    /// ghost opacity. Because a ghosted window can't be clicked, restoring
    /// happens from the menu-bar icon or by summoning the session (⌥⌘K).
    func setGhosted(_ on: Bool) {
        isGhosted = on
        panel.ignoresMouseEvents = on
        panel.alphaValue = on ? CGFloat(max(0.1, Settings.shared.ghostOpacity)) : 1.0
        if !on { panel.presentOverlay() }
    }

    // MARK: - Agent Ghost mode (drive an app through the window)

    /// Enter/leave AGENT GHOST: the panel becomes click-through (`ignoresMouseEvents`)
    /// and refuses key status (`blocksKey`) so synthetic clicks/keystrokes pass to
    /// the app the agent is driving and can't be stolen back by a stray hover —
    /// the root-cause fix for "typing scattered / the field wouldn't focus". The
    /// window stays fully visible; a floating unlock badge signals the state and
    /// is the click-to-release escape hatch (the panel itself can't be clicked).
    func setAgentGhost(_ on: Bool) {
        guard on != isAgentGhosted else { return }
        isAgentGhosted = on
        panel.blocksKey = on
        panel.ignoresMouseEvents = on
        panel.alphaValue = 1.0                 // stay readable — the badge is the cue
        if on {
            // Relinquish key focus NOW. `blocksKey` only stops the panel becoming
            // key in future; a panel that's ALREADY key keeps eating keystrokes
            // (you could still type into the terminal). Ordering a key window out
            // resigns it; re-show without makeKey — `blocksKey` stops it re-grabbing
            // — so it's visible but inert. (In the agent flow the next
            // `type --target/--pid` would re-activate the target anyway; this makes
            // ghost-on feel right immediately and for manual use.)
            if panel.isKeyWindow {
                panel.orderOut(nil)
                panel.reassertFloatingBehavior()
                panel.orderFrontRegardless()
            }
            let badge = unlockBadge ?? AgentGhostBadge { [weak self] in self?.setAgentGhost(false) }
            unlockBadge = badge
            badge.show(over: panel.frame)
        } else {
            unlockBadge?.hide()
            panel.presentOverlay()             // reclaim interactivity + key focus
        }
    }

    // MARK: - Ticker mode (one-line live strip)

    /// Collapses this window into a one-line floating strip showing the active
    /// session's name, status, and live last line of output. ⌥-click the
    /// collapse button; double-click the strip to expand back.
    func collapseToTicker() {
        guard !isCollapsed, !isTicker else { return }
        closeReaderIfNeeded()
        savedFrameForExpand = panel.frame
        isTicker = true
        panel.orderOut(nil)
        updateViewedFlags()

        let t = ticker ?? TickerPanel()
        ticker = t
        t.sharingType = Settings.shared.hideFromScreenCapture ? .none : .readOnly
        t.onExpand = { [weak self] in self?.expandFromTicker() }
        // The strip takes the window's top edge, so it stays where the eye was.
        let f = savedFrameForExpand
        let raw = NSRect(x: f.minX, y: f.maxY - TickerPanel.height,
                         width: min(TickerPanel.defaultWidth, f.width),
                         height: TickerPanel.height)
        t.setFrame(panel.clampToVisibleScreen(raw), display: false)
        // Same Space dance as the avatar: attach roaming first, then re-pin.
        t.setPinned(false)
        t.orderFrontRegardless()
        if panel.isPinned {
            DispatchQueue.main.async { [weak t] in t?.setPinned(true) }
        }
        refreshTicker()
    }

    /// - Parameter overrideTarget: explicit destination frame (see
    ///   expandFromAvatar — used when summoning across Spaces).
    func expandFromTicker(to overrideTarget: NSRect? = nil) {
        guard isTicker else { return }
        ticker?.orderOut(nil)
        isTicker = false
        let raw = overrideTarget ?? savedFrameForExpand
        panel.setFrame(panel.clampToVisibleScreen(raw), display: false)
        panel.presentOverlay()
        focusActiveTab()
        updateViewedFlags()
    }

    private func refreshTicker() {
        guard isTicker, let t = ticker else { return }
        let tab = tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
        t.update(name: tab?.displayName ?? "FloatyTerm",
                 line: (tab as? TerminalController)?.lastOutputLine ?? "",
                 status: tab.map { status(of: $0) } ?? .idle)
    }

    /// Hides only THIS window (session preserved) and flags it as minimized so
    /// it appears in the menu-bar "Hidden Windows" list for individual restore.
    /// Distinct from the global ⌥⌘7 hide, which hides every window at once.
    func minimize() {
        closeReaderIfNeeded()
        isMinimized = true
        panel.orderOut(nil)
        updateViewedFlags()
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }

    /// True when this window is linked/pinned to a specific Space.
    var isPinned: Bool { panel.isPinned }

    /// True when this window currently lives on the Space the user is viewing.
    var isOnActiveSpace: Bool { panel.isOnActiveSpace }

    /// Whether this window's visible representative — the panel, or its bubble
    /// / ticker strip when collapsed — is on the user's current Space.
    /// `panel.isOnActiveSpace` LIES for hidden panels (it answers "where would
    /// it land if shown"), so combined states like pinned+collapsed must ask
    /// the thing that's actually on screen. nil = nothing on screen, unknowable
    /// (pinned + minimized/hidden).
    var presenceOnActiveSpace: Bool? {
        if isCollapsed { return avatar?.isOnActiveSpace }
        if isTicker { return ticker?.isOnActiveSpace }
        if panel.isVisible { return panel.isOnActiveSpace }
        return nil
    }

    /// Toggles whether this window is linked to the current Space. When linked,
    /// it stays on that Space (with its session) instead of floating over all of
    /// them; the pin button reflects the new state.
    private func togglePin() {
        panel.setPinned(!panel.isPinned)
        if panel.isPinned, linkedAppBundleID != nil {
            // Space pin and app link can't both drive visibility.
            linkedAppBundleID = nil
            linkedAppName = nil
            header.setLinkedApp(nil)
            onStateChanged?()
        }
        header.setPinned(panel.isPinned)
        // FloatyTerm never activates itself, so the frontmost app right now is
        // the one this window is being pinned OVER — the session switcher
        // shows it ("another Space (Chrome)").
        pinnedAppName = panel.isPinned
            ? NSWorkspace.shared.frontmostApplication?.localizedName
            : nil
        scheduleFrameSave()   // pinned windows are excluded from saved sessions
    }

    /// The app that was frontmost when this window was pinned — i.e. what it
    /// overlays on its Space. Runtime-only, cleared on unpin.
    private(set) var pinnedAppName: String?

    // MARK: - Pin to app (show only while a chosen app is frontmost)

    /// When set, this window follows that app's activation instead of a
    /// Space: it appears (without stealing focus) whenever the app becomes
    /// frontmost — on whatever Space that happens — and tucks away when the
    /// user switches to anything else. A build terminal that only exists
    /// while its IDE does. Mutually exclusive with pin-to-Space; persisted
    /// (bundle IDs are stable across launches, unlike Spaces).
    private(set) var linkedAppBundleID: String?
    private(set) var linkedAppName: String?

    func linkToApp(bundleID: String?, name: String?) {
        linkedAppBundleID = bundleID
        linkedAppName = name
        if bundleID != nil, panel.isPinned {
            // Space pin and app link can't both drive visibility.
            panel.setPinned(false)
            pinnedAppName = nil
        }
        header.setPinned(panel.isPinned)
        header.setLinkedApp(name)
        onStateChanged?()   // persist the link with the window record
        if bundleID == nil {
            show()          // unlinked: back to a normal always-available window
        } else {
            applyAppLinkVisibility(frontmost: NSWorkspace.shared.frontmostApplication)
        }
    }

    /// Builds the pin button's right-click menu: every regular running app,
    /// the linked one checkmarked, plus Unlink.
    private func buildAppLinkMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let caption = NSMenuItem(title: "Show Only While Active:", action: nil, keyEquivalent: "")
        caption.isEnabled = false
        menu.addItem(caption)
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
        for app in apps {
            guard let name = app.localizedName else { continue }
            let item = NSMenuItem(title: name, action: #selector(appLinkPicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = app.bundleIdentifier
            item.state = app.bundleIdentifier == linkedAppBundleID ? .on : .off
            if let icon = app.icon?.copy() as? NSImage {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let unlink = NSMenuItem(title: "Always Available (Unlink)",
                                action: #selector(appLinkCleared), keyEquivalent: "")
        unlink.target = self
        unlink.state = linkedAppBundleID == nil ? .on : .off
        menu.addItem(unlink)
    }

    @objc private func appLinkPicked(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        // Picking the already-linked app unlinks it (toggle semantics).
        if bundleID == linkedAppBundleID {
            linkToApp(bundleID: nil, name: nil)
        } else {
            linkToApp(bundleID: bundleID, name: sender.title)
        }
    }

    @objc private func appLinkCleared() {
        linkToApp(bundleID: nil, name: nil)
    }

    /// NSWorkspace app-activation events drive linked visibility.
    @objc private func frontAppChanged(_ note: Notification) {
        guard linkedAppBundleID != nil,
              let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication,
              // Our own activations (settings window, alerts) must not hide
              // the terminal the user is working over.
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        applyAppLinkVisibility(frontmost: app)
    }

    private func applyAppLinkVisibility(frontmost: NSRunningApplication?) {
        guard let linked = linkedAppBundleID else { return }
        // The link only drives the plain window; modes the user chose
        // explicitly (minimized, bubble, ticker, lent-away husk) keep
        // owning their own visibility.
        guard !isMinimized, !isCollapsed, !isTicker, !isLent else { return }
        if frontmost?.bundleIdentifier == linked {
            // Appear WITHOUT taking key — the user just focused their app;
            // stealing its keyboard would defeat the point.
            panel.reassertFloatingBehavior()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
        updateViewedFlags()
    }

    /// A short title for menus, taken from the active tab (honours renames).
    var displayTitle: String {
        guard tabs.indices.contains(activeIndex) else { return "FloatyTerm" }
        let t = tabs[activeIndex].displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled" : t
    }

    /// Public entry for the menu bar's "New Tab" (terminal).
    func openNewTab() { addTerminalTab() }

    /// Public entry for the menu bar's "New Browser Tab".
    func openNewBrowserTab() { addBrowserTab() }

    /// Public entry for the menu bar's "New Note".
    func openNewNote() { addNoteTab() }

    /// Public entry for the menu bar's "Mirror a Window…".
    func openNewMirror() { addMirrorTab() }

    // MARK: - Keyboard commands

    private func handleKeyCommand(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if flags == .command {
            switch chars {
            case "t": addTerminalTab(); return true
            case "b": addBrowserTab();  return true
            case "e": addNoteTab();     return true
            case "s":
                // ⌘S saves-as the active note; harmless no-op for other tabs
                // (notes already autosave, so this is "save a copy / relocate").
                guard let note = activeNote else { return false }
                note.presentSaveAs(in: panel)
                return true
            case "w": closeTab(activeIndex); return true
            case "n": onNewWindow?(); return true
            case ",": onOpenPreferences?(); return true
            case "f":
                // ⌘F is terminal-only; no-op when a browser tab is active.
                if activeTabIsTerminal { toggleFindBar() }
                return true
            case "g":
                if activeTabIsTerminal { findNext() }
                return true
            case "r":
                // ⌘R: recent-commands palette for terminal tabs, reload for
                // browser tabs (standard browser muscle memory).
                if activeTabIsTerminal { toggleRecentPalette() }
                else { activeBrowser?.reload() }
                return true
            case "k":
                // ⌘K: global session switcher (find/summon any session).
                onOpenSwitcher?()
                return true
            case "l":
                // ⌘L: focus the address bar (expanding it first if collapsed).
                guard activeTabIsBrowser else { return false }
                if Settings.shared.urlBarCollapsed {
                    Settings.shared.urlBarCollapsed = false  // didChange shows the bar
                } else if !isURLBarVisible {
                    showURLBar()
                }
                urlBar.focusURLField()
                return true
            case "=", "+":
                zoomOrFontStep(+1); return true
            case "-":
                zoomOrFontStep(-1); return true
            case "0":
                zoomOrFontStep(0); return true
            default:
                if let n = Int(chars), (1...9).contains(n) {
                    selectTab(n - 1)
                    return true
                }
            }
        } else if flags == [.command, .shift] {
            if event.keyCode == 30 { cycleTab(+1); return true }  // ⌘⇧]  next
            if event.keyCode == 33 { cycleTab(-1); return true }  // ⌘⇧[  prev
            if chars == "g" {
                if activeTabIsTerminal { findPrevious() }
                return true
            }
            if chars.lowercased() == "d" {   // ⇧⌘D — Compare Two Files…
                openCompareFilesPanel()
                return true
            }
            if chars.lowercased() == "m" {   // ⇧⌘M — Mirror a Window…
                addMirrorTab()
                return true
            }
        }
        return false
    }

    private func cycleTab(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        selectTab((activeIndex + delta + tabs.count) % tabs.count)
    }

    /// ⌘+/⌘−/⌘0. Browser tabs zoom the page; terminal tabs step the global
    /// font size (which Settings.didChange propagates to every terminal).
    private func zoomOrFontStep(_ direction: Int) {
        if let bc = activeBrowser {
            switch direction {
            case 0:  bc.resetZoom()
            case 1:  bc.zoomIn()
            default: bc.zoomOut()
            }
            return
        }
        let defaultSize = 13.0
        switch direction {
        case 0:  Settings.shared.fontSize = defaultSize
        case 1:  Settings.shared.fontSize = min(24, Settings.shared.fontSize + 1)
        default: Settings.shared.fontSize = max(9, Settings.shared.fontSize - 1)
        }
    }

    // MARK: - Working-directory inheritance

    /// Returns the current working directory of the active terminal tab when the
    /// "Inherit working directory" setting is ON and the active tab is a terminal.
    /// Returns nil otherwise (callers should fall back to $HOME).
    var activeTerminalWorkingDirectory: String? {
        guard Settings.shared.inheritWorkingDirectory else { return nil }
        guard let tc = tabs.indices.contains(activeIndex)
                ? tabs[activeIndex] as? TerminalController : nil else { return nil }
        return tc.currentWorkingDirectory
    }

    // MARK: - Convenience type checks

    private var activeTabIsTerminal: Bool {
        tabs.indices.contains(activeIndex) && tabs[activeIndex] is TerminalController
    }

    private var activeTabIsBrowser: Bool {
        tabs.indices.contains(activeIndex) && tabs[activeIndex] is BrowserController
    }

    private var activeBrowser: BrowserController? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] as? BrowserController : nil
    }

    private var activeNote: NoteController? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] as? NoteController : nil
    }

    // MARK: - Appearance (transparency + blur)

    private func applyAppearance(focused: Bool) {
        contentBlur.isHidden = !Settings.shared.backgroundBlur
        // Agent Ghost is intentionally non-key while the agent drives "through"
        // it, but must stay fully readable — so treat it as focused for dimming.
        let effectiveFocused = focused || isAgentGhosted
        // A per-window override (from the header double-click overlay) wins over
        // the global focused/unfocused-dim settings for this window.
        let alpha: Double
        if let override = opacityOverride {
            alpha = override
        } else {
            alpha = (Settings.shared.dimWhenUnfocused && !effectiveFocused)
                ? Settings.shared.unfocusedOpacity
                : Settings.shared.focusedOpacity
        }
        // Floor at 0.1: the alpha applies to the terminal text itself, so 0
        // would render the content invisible with no way to see what you type.
        contentArea.alphaValue = CGFloat(max(0.1, alpha))
    }

    // MARK: - Window options popover (header utils button)

    /// Shows the per-window options popover (opacity slider + ghost toggle)
    /// anchored to the header utils `button`. Re-invoking while it's open
    /// toggles it closed.
    private func showWindowOptions(from button: NSButton) {
        if let p = optionsPopover, p.isShown {
            p.close()
            optionsPopover = nil
            return
        }
        let vc = WindowOptionsViewController()
        vc.initialOpacity = opacityOverride ?? Settings.shared.focusedOpacity
        vc.onOpacityChange = { [weak self] value in
            guard let self else { return }
            self.opacityOverride = value
            self.applyAppearance(focused: self.panel.isKeyWindow)
        }
        vc.onResetOpacity = { [weak self] in
            guard let self else { return }
            self.opacityOverride = nil
            self.applyAppearance(focused: self.panel.isKeyWindow)
        }
        vc.onGhost = { [weak self] in self?.setGhosted(true) }
        vc.onAgentGhost = { [weak self] in self?.setAgentGhost(true) }

        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient            // auto-closes on outside click
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        optionsPopover = popover
    }

    private func dismissWindowOptions() {
        optionsPopover?.close()
        optionsPopover = nil
    }

    @objc private func settingsChanged() {
        // Only apply font / renderer to terminal tabs.
        tabs.compactMap { $0 as? TerminalController }.forEach {
            $0.applyFont()
            $0.applyMetalRenderer()
        }
        applyAppearance(focused: panel.isKeyWindow)
        updateURLBarVisibility()  // reflect URL-bar collapse state changes
        syncURLBar()              // reflect popup/redirect blocking toggles in the shield
        if isGhosted {            // live-apply a ghost-opacity slider change
            panel.alphaValue = CGFloat(max(0.1, Settings.shared.ghostOpacity))
        }
        // Live-apply screen-capture privacy to every surface this window owns
        // (the panel also reasserts it on every show).
        let sharing: NSWindow.SharingType =
            Settings.shared.hideFromScreenCapture ? .none : .readOnly
        panel.sharingType = sharing
        avatar?.sharingType = sharing
        ticker?.sharingType = sharing
    }

    /// Collapses/expands the browser URL bar (persisted; applies to all windows).
    private func toggleURLBarCollapsed() {
        Settings.shared.urlBarCollapsed.toggle()
        // The Settings.didChange notification triggers settingsChanged(), which
        // refreshes URL-bar visibility everywhere.
    }

    // MARK: - Tabs (heterogeneous)

    private func addTerminalTab() {
        // For the very first tab (created during init) use the initialDirectory
        // that was passed to init(); for all subsequent tabs, inherit from the
        // currently-active terminal when the setting is ON.
        let startDir: String?
        if tabs.isEmpty, let pending = pendingInitialDirectory {
            startDir = pending
            pendingInitialDirectory = nil   // consume so later tabs use normal logic
        } else {
            // Capture the active terminal's cwd before creating the new controller
            // (once the new tab is inserted it becomes active, so read now).
            startDir = activeTerminalWorkingDirectory
        }
        let tab = TerminalController(startDirectory: startDir)
        tab.onTerminated = { [weak self, weak tab] in
            guard let self, let tab,
                  let idx = self.tabs.firstIndex(where: { $0 === tab }) else { return }
            self.closeTab(idx)
        }
        tab.onTitleChanged = { [weak self] in self?.refreshTabStrip() }
        insertTab(tab)
    }

    func addBrowserTab(initialURL: String? = nil) {
        // One-time resource notice.
        showBrowserResourceNoticeIfNeeded()

        let tab = BrowserController(initialURL: initialURL)
        tab.onTitleChanged = { [weak self] in
            self?.refreshTabStrip()
            self?.syncURLBar()
        }
        // Fires on URL / canGoBack / canGoForward changes — title KVO alone
        // misses same-title navigations and back/forward state flips.
        tab.onNavChanged = { [weak self] in self?.syncURLBar() }
        insertTab(tab)
    }

    /// Wires the baseline title callback (refresh the strip on rename) and
    /// inserts the tab — for tab kinds that need no callbacks beyond that.
    private func installSimpleTab(_ tab: any TabContent) {
        tab.onTitleChanged = { [weak self] in self?.refreshTabStrip() }
        insertTab(tab)
    }

    /// Opens a new markdown note tab, backed by a fresh scratch file in the
    /// managed Notes directory.
    func addNoteTab() {
        installSimpleTab(NoteController(fileURL: NotesStore.newScratchNote()))
    }

    /// Opens a new tab showing a side-by-side diff of two files.
    func addDiffTab(left: URL, right: URL) {
        installSimpleTab(DiffViewerController(left: left, right: right))
    }

    /// Opens a new tab that live-mirrors another app's window (it starts on a
    /// window picker, then shows the chosen window's live content).
    func addMirrorTab() {
        installSimpleTab(MirrorController())
    }

    /// Public entry for "Compare Two Files…": pick exactly two files, then open
    /// a diff tab. Used by the ⇧⌘D shortcut and the status-bar menu.
    func openCompareFilesPanel() {
        let panel = NSOpenPanel()
        panel.title = "Compare Two Files"
        panel.message = "Choose two files to compare."
        panel.prompt = "Compare"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let dir = activeTerminalWorkingDirectory {
            panel.directoryURL = URL(fileURLWithPath: dir)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self, response == .OK else { return }
            let urls = panel.urls
            guard urls.count == 2 else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Select exactly two files"
                alert.informativeText = "A diff compares two files — you chose \(urls.count)."
                alert.runModal()
                return
            }
            self.addDiffTab(left: urls[0], right: urls[1])
        }
    }

    /// Inserts `tab` into the window. When `at` is provided the tab lands at
    /// that index (used for child tabs placed next to a parent); otherwise it is
    /// appended. The inserted tab becomes active either way.
    private func insertTab(_ tab: any TabContent, at index: Int? = nil) {
        // A tab arriving — the lent one coming home, or a fresh one — means
        // this window is a real session host again, not a waiting husk.
        if isLent {
            isLent = false
            lentTab = nil
            lentPlaceholder?.removeFromSuperview()
            lentPlaceholder = nil
        }
        let v = tab.view
        v.translatesAutoresizingMaskIntoConstraints = false
        contentArea.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: contentArea.topAnchor),
            v.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor)
        ])

        let insertionIndex: Int
        if let index, index >= 0, index <= tabs.count {
            tabs.insert(tab, at: index)
            insertionIndex = index
        } else {
            tabs.append(tab)
            insertionIndex = tabs.count - 1
        }
        // (Re)wire the selection bridge here — insertTab is the single entry
        // for tabs joining a window (new, restored, AND adopted from another
        // window), so the chip always reports to the current host.
        if let bc = tab as? BrowserController {
            bc.onSelectionChanged = { [weak self, weak bc] sel in
                guard let self, let bc else { return }
                self.browserSelectionChanged(bc, sel)
            }
            // Refresh the shield's count live — but only while this tab is the
            // one on screen (a background tab's blocks shouldn't move the bar).
            bc.onBlockedCountChanged = { [weak self, weak bc] in
                guard let self, let bc, bc === self.activeBrowser else { return }
                self.syncURLBar()
            }
        }
        // Terminals route "Open in Image Viewer" through here — insertTab is the
        // single entry for every terminal tab (new, restored, adopted), so the
        // child-tab hook is always wired to the current host.
        if let tc = tab as? TerminalController {
            tc.onOpenChildTab = { [weak self, weak tc] viewer in
                guard let self, let tc else { return }
                self.insertChildTab(viewer, after: tc)
            }
        }
        selectTab(insertionIndex)
        applyAppearance(focused: panel.isKeyWindow)
        scheduleFrameSave()   // tabs are part of the persisted session now
    }

    /// Inserts `child` immediately after `parent`'s tab and records the link so
    /// the child closes with its parent. Used for viewer tabs (e.g. images)
    /// spawned from a terminal.
    private func insertChildTab(_ child: any TabContent, after parent: any TabContent) {
        child.onTitleChanged = { [weak self] in self?.refreshTabStrip() }
        parentByChild[ObjectIdentifier(child)] = ObjectIdentifier(parent)
        let at = tabs.firstIndex(where: { $0 === parent }).map { $0 + 1 }
        insertTab(child, at: at)
    }

    /// Closes every viewer child tab of `parent`. Children always sit at a
    /// higher index than their parent (inserted at parentIndex+1), so closing
    /// them never shifts the parent's own index.
    private func closeChildren(of parent: any TabContent) {
        let parentID = ObjectIdentifier(parent)
        let childIDs = parentByChild.compactMap { $0.value == parentID ? $0.key : nil }
        for cid in childIDs {
            parentByChild.removeValue(forKey: cid)
            if let idx = tabs.firstIndex(where: { ObjectIdentifier($0) == cid }) {
                closeTab(idx)
            }
        }
    }

    private func selectTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        // Hide terminal-only overlays when switching tabs.
        if isFindBarVisible   { hideFindBar()       }
        if isPaletteVisible   { hideRecentPalette() }
        hideSelectionBar()
        askAgentBar.isHidden = true
        activeIndex = index
        for (i, tab) in tabs.enumerated() {
            tab.view.isHidden = (i != index)
        }
        refreshTabStrip()
        updateURLBarVisibility()
        updateViewedFlags()
        updateReturnButton()
        readerButton.isHidden = !activeTabIsTerminal
        focusActiveTab()
    }

    private func closeTab(_ index: Int) {
        guard tabs.indices.contains(index) else { return }

        // ⌘W / chip-✕ on a terminal with a running foreground job: confirm
        // before killing it. (The shell-exited path arrives here too, but by
        // then the job is gone, so the prompt never fires for it.)
        if !AppRuntime.isQuitting,
           let tc = tabs[index] as? TerminalController, tc.hasRunningForegroundJob {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "A process is still running in this tab."
            alert.informativeText = "Closing the tab will end it."
            alert.addButton(withTitle: "Close Tab")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        // Committed to closing now (any running-job prompt has been accepted).
        // Drop this tab's own parent link (it may itself be a viewer child),
        // then close any viewer children it owns. Children sit after `index`,
        // so it stays valid for the removal below.
        parentByChild.removeValue(forKey: ObjectIdentifier(tabs[index]))
        closeChildren(of: tabs[index])
        guard tabs.indices.contains(index) else { return }

        if index == activeIndex && isFindBarVisible  { hideFindBar()       }
        if index == activeIndex && isPaletteVisible  { hideRecentPalette() }
        if index == activeIndex && isURLBarVisible   { hideURLBar()        }
        let tab = tabs.remove(at: index)
        closeReaderIfNeeded(forClosing: tab)
        // If this tab was lent here by a window that gave up its ONLY session,
        // that husk now waits for nothing — close it along with the tab.
        if let lender = borrowSource(for: tab), lender.isLent, lender.tabs.isEmpty {
            lender.panel.close()
        }
        clearBorrow(for: tab)
        tab.view.removeFromSuperview()
        tab.cleanup()

        if tabs.isEmpty {
            panel.close()
            return
        }
        activeIndex = min(activeIndex, tabs.count - 1)
        selectTab(activeIndex)
        scheduleFrameSave()
    }

    private func focusActiveTab() {
        guard tabs.indices.contains(activeIndex) else { return }
        tabs[activeIndex].focus(in: panel)
    }

    // MARK: - Tab tear-off / re-dock support

    /// Remove `tab` from this window WITHOUT calling `cleanup()`.
    /// The tab's session stays alive; its view is removed from the contentArea.
    /// If this was the last tab, the window is closed.
    func releaseTab(_ tab: any TabContent) {
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }

        // Hide overlays if the active (about-to-leave) tab owns them.
        if idx == activeIndex {
            if isFindBarVisible  { hideFindBar()       }
            if isPaletteVisible  { hideRecentPalette() }
            if isURLBarVisible   { hideURLBar()        }
        }

        closeReaderIfNeeded(forClosing: tab)
        tab.view.removeFromSuperview()
        tabs.remove(at: idx)
        clearBorrow(for: tab)

        if tabs.isEmpty {
            panel.close()
            return
        }
        activeIndex = min(activeIndex, tabs.count - 1)
        selectTab(activeIndex)
        scheduleFrameSave()
    }

    /// Reorders a tab within this window (tab-strip drag). The active tab stays
    /// active regardless of where it (or its neighbours) moved.
    func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from) else { return }
        let target = max(0, min(tabs.count - 1, to))
        guard target != from else { return }
        let activeTab = tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: target)
        if let activeTab, let idx = tabs.firstIndex(where: { $0 === activeTab }) {
            activeIndex = idx
        }
        refreshTabStrip()
        scheduleFrameSave()
    }

    /// Host `tab` in this window and select it.
    /// Re-wires the tab's callbacks so title/termination events reference THIS controller.
    func adoptTab(_ tab: any TabContent) {
        // Re-wire callbacks before inserting so the refreshes land correctly.
        tab.onTitleChanged = { [weak self] in
            self?.refreshTabStrip()
            // If it's a browser tab, sync the URL bar too.
            if (tab as? BrowserController) != nil {
                self?.syncURLBar()
            }
        }
        if let termTab = tab as? TerminalController {
            termTab.onTerminated = { [weak self, weak termTab] in
                guard let self, let termTab,
                      let idx = self.tabs.firstIndex(where: { $0 === termTab }) else { return }
                self.closeTab(idx)
            }
        }
        if let browserTab = tab as? BrowserController {
            browserTab.onNavChanged = { [weak self] in self?.syncURLBar() }
        }

        insertTab(tab)
    }

    /// Updates the tab strip contents and shows/hides it (only visible with 2+ tabs).
    private func refreshTabStrip() {
        let items = tabs.map {
            // "✦" marks agent sessions on the chip only — displayName itself
            // stays clean (it feeds persistence and menus).
            TabStripView.Item(title: (($0 as? TerminalController)?.isAgentSession == true ? "✦ " : "") + $0.displayName,
                              status: status(of: $0),
                              canReturn: isBorrowed($0),
                              canNotify: $0 is TerminalController,
                              notifyArmed: ($0 as? TerminalController)?.notifyWhenDone == true)
        }
        tabStrip.reload(items: items, activeIndex: activeIndex)
        let show = tabs.count >= 2
        tabStrip.isHidden = !show
        tabStripHeightConstraint.constant = show ? tabStripHeight : 0
    }

    // MARK: - Session status / activity refresh

    /// The attention state of one tab
    /// (needs-input wins over unseen output wins over running).
    func status(of tab: any TabContent) -> SessionStatus {
        if let tc = tab as? TerminalController, tc.awaitingInput { return .needsInput }
        if tab.hasUnseenOutput { return .unseenOutput }
        if let tc = tab as? TerminalController, tc.hasRunningForegroundJob { return .running }
        return .idle
    }

    /// Timer tick: refresh chip labels/dots, the ticker strip, and the bubble
    /// badge. Skipped when nothing of this window is on screen.
    private func refreshActivity() {
        // Husk self-reap: the lent-away tab died with its borrower (closed
        // instead of returned), so nothing can ever come home — don't strand
        // an empty shell on its Space.
        if isLent, lentTab == nil {
            panel.close()
            return
        }
        // Armed "notify when done" sessions are checked regardless of how this
        // window is presented — the whole point is that a hidden / collapsed /
        // away window comes to the user when its work finishes.
        for tab in tabs {
            guard let tc = tab as? TerminalController else { continue }
            if tc.checkDoneIfArmed() { onSessionDone?(tc) }
        }
        // Keep the "waiting on you" state fresh regardless of presentation —
        // the bubble badge and the menu-bar fleet summary read it even while
        // this window is collapsed, tickered, or hidden.
        for tab in tabs {
            (tab as? TerminalController)?.updateAttentionState()
        }
        if isTicker {
            refreshTicker()
            return
        }
        if isCollapsed {
            // Aggregate across tabs for the bubble badge
            // (needsInput > unseenOutput > running).
            let agg: SessionStatus
            if tabs.contains(where: { ($0 as? TerminalController)?.awaitingInput == true }) {
                agg = .needsInput
            } else if tabs.contains(where: { $0.hasUnseenOutput }) {
                agg = .unseenOutput
            } else if tabs.contains(where: { ($0 as? TerminalController)?.hasRunningForegroundJob == true }) {
                agg = .running
            } else {
                agg = .idle
            }
            avatar?.setStatus(agg)
            return
        }
        guard panel.isVisible else { return }
        refreshTabStrip()
        updateReturnButton()   // self-heal: never let a borrowed tab hide its way back
    }

    /// Keeps each tab's "the user can see me" flag honest. New output while a
    /// tab is viewed never counts as unseen; marking a tab viewed clears its badge.
    private func updateViewedFlags() {
        let viewing = panel.isVisible && !isCollapsed
        for (i, tab) in tabs.enumerated() {
            tab.isCurrentlyViewed = viewing && i == activeIndex
        }
    }

    /// Right-click → Notify When Done: arms/disarms the one-shot summon.
    private func toggleNotifyWhenDone(_ index: Int) {
        guard tabs.indices.contains(index),
              let tc = tabs[index] as? TerminalController else { return }
        tc.notifyWhenDone.toggle()
        refreshTabStrip()
    }

    /// Flashes an accent ring around the window — the "I just arrived because
    /// you asked to be notified" cue after an armed session summons itself.
    func pulseAttention() {
        guard let root = panel.contentView else { return }
        let ring = NSView(frame: root.bounds)
        ring.autoresizingMask = [.width, .height]
        ring.wantsLayer = true
        ring.layer?.borderColor = NSColor.controlAccentColor.cgColor
        ring.layer?.borderWidth = 3
        ring.layer?.cornerRadius = 12
        ring.layer?.opacity = 0
        root.addSubview(ring)
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0, 1, 0.15, 1, 0]
        pulse.duration = 1.2
        ring.layer?.add(pulse, forKey: "pulse")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
            ring.removeFromSuperview()
        }
    }

    // MARK: - Rename

    /// Right-click → Rename Tab…: sets the custom name (empty clears it,
    /// falling back to the automatic label).
    private func promptRename(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Leave empty to go back to the automatic name."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = tab.customName ?? ""
        field.placeholderString = tab.displayName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.customName = name.isEmpty ? nil : name
        refreshTabStrip()
        scheduleFrameSave()
    }

    // MARK: - Borrowed tabs (session-switcher summon / return)

    /// Records that `tab` was borrowed from `source`, so the header can offer
    /// to send it back. Call after adopting the tab.
    func markBorrowed(_ tab: any TabContent, from source: TerminalWindowController) {
        borrows.append(BorrowRecord(tabID: ObjectIdentifier(tab), source: source))
        updateReturnButton()
    }

    private func borrowSource(for tab: any TabContent) -> TerminalWindowController? {
        borrows.first { $0.tabID == ObjectIdentifier(tab) }?.source
    }

    private func clearBorrow(for tab: any TabContent) {
        borrows.removeAll { $0.tabID == ObjectIdentifier(tab) }
    }

    /// Shows the header's return arrow only while the ACTIVE tab is borrowed
    /// and its source window still exists. The tooltip names where home is.
    private func updateReturnButton() {
        let active = tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
        let source = active.flatMap { borrowSource(for: $0) }
        let hint = source?.pinnedAppName.map {
            "Return this tab to its window on the \($0) Space"
        }
        header.setReturnVisible(source != nil, hint: hint)
    }

    /// True when `tab` was borrowed here and its source window still exists.
    func isBorrowed(_ tab: any TabContent) -> Bool {
        borrowSource(for: tab) != nil
    }

    /// Sends the active borrowed tab back (header arrow).
    private func returnBorrowedTab() {
        returnBorrowedTab(at: activeIndex)
    }

    /// Sends the borrowed tab at `index` back to the window it came from
    /// (which never left its Space). Closes this window if that was its last tab.
    func returnBorrowedTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]
        guard let source = borrowSource(for: tab) else {
            clearBorrow(for: tab)
            updateReturnButton()
            return
        }
        releaseTab(tab)          // also clears the borrow record
        source.adoptTab(tab)
    }

    // MARK: - Switcher summon support

    /// Selects a tab by index (public entry for the session switcher).
    func selectTab(at index: Int) { selectTab(index) }

    /// Closes a specific tab (public entry for the session switcher's ✕ /
    /// ⌘⌫). Runs the same running-job confirmation as ⌘W; closing the last
    /// tab closes the window.
    func closeSession(_ tab: any TabContent) {
        guard let idx = tabs.firstIndex(where: { $0 === tab }) else { return }
        closeTab(idx)
    }

    /// Lends this window's ONLY tab to a borrower on the user's Space. Unlike
    /// `releaseTab`, the emptied window does NOT close: it stays behind on its
    /// own Space — still pinned, still collapsed / tickered / ghosted, exactly
    /// as it was — so the borrower's Return arrow has a permanent home to send
    /// the tab back to. Pin state, the pinned-over app name, frame, and avatar
    /// style all survive untouched; an expanded panel shows a note instead of
    /// a dead content area. An existing borrow record on the tab is kept, so
    /// chained returns (A → B → C) unwind one hop at a time.
    func lendOnlyTab() -> (any TabContent)? {
        guard tabs.count == 1, let tab = tabs.first else { return nil }
        if isFindBarVisible { hideFindBar()       }
        if isPaletteVisible { hideRecentPalette() }
        if isURLBarVisible  { hideURLBar()        }
        hideSelectionBar()
        closeReaderIfNeeded(forClosing: tab)
        tab.view.removeFromSuperview()
        tabs.removeAll()
        activeIndex = 0
        isLent = true
        lentTab = tab
        showLentPlaceholder()
        refreshTabStrip()
        updateViewedFlags()
        updateReturnButton()
        return tab
    }

    private func showLentPlaceholder() {
        if lentPlaceholder == nil {
            let label = NSTextField(wrappingLabelWithString:
                "Session lent to another Space — press ↩ there to send it home.")
            label.alignment = .center
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.isSelectable = false
            label.translatesAutoresizingMaskIntoConstraints = false
            contentArea.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: contentArea.centerYAnchor),
                label.widthAnchor.constraint(lessThanOrEqualTo: contentArea.widthAnchor,
                                             constant: -32)
            ])
            lentPlaceholder = label
        }
        lentPlaceholder?.isHidden = false
    }

    // MARK: - One-time browser resource notice

    private func showBrowserResourceNoticeIfNeeded() {
        let key = "didShowBrowserResourceNotice"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.alertStyle        = .informational
        alert.messageText       = "Browser tabs use more resources"
        alert.informativeText   = """
            Browser tabs are powered by the system WebKit engine. \
            They will use more CPU and RAM than terminal tabs, especially \
            with rich web applications. This message appears only once.
            """
        alert.addButton(withTitle: "Got It")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Find bar (terminal-only)

    private func setupFindBar() {
        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        root.addSubview(findBar)

        findBarTrailingConstraint = findBar.trailingAnchor.constraint(
            equalTo: contentArea.trailingAnchor, constant: -10)
        findBarTopConstraint = findBar.topAnchor.constraint(
            equalTo: contentBlur.topAnchor, constant: 8)

        NSLayoutConstraint.activate([
            findBarTopConstraint,
            findBarTrailingConstraint,
            findBar.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            findBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])

        findBar.onSearchChanged = { [weak self] text in
            guard let self else { return }
            if text.isEmpty {
                self.activeTerminalView?.clearSearch()
            } else {
                self.activeTerminalView?.findNext(text)
            }
        }
        findBar.onFindNext     = { [weak self] in self?.findNext()     }
        findBar.onFindPrevious = { [weak self] in self?.findPrevious() }
        findBar.onClose        = { [weak self] in self?.hideFindBar()  }
    }

    private var activeTerminalView: FloatyTerminalView? {
        (tabs.indices.contains(activeIndex) ? tabs[activeIndex] as? TerminalController : nil)?.terminalView
    }

    func findNext() {
        guard let tv = activeTerminalView else { return }
        let term = findBar.searchText
        guard !term.isEmpty else { showFindBar(); return }
        tv.findNext(term)
    }

    func findPrevious() {
        guard let tv = activeTerminalView else { return }
        let term = findBar.searchText
        guard !term.isEmpty else { showFindBar(); return }
        tv.findPrevious(term)
    }

    private func toggleFindBar() {
        if isFindBarVisible { hideFindBar() } else { showFindBar() }
    }

    private func showFindBar() {
        guard !isFindBarVisible else { findBar.focusSearchField(); return }
        isFindBarVisible = true
        findBar.isHidden = false
        findBar.focusSearchField()
    }

    private func hideFindBar() {
        guard isFindBarVisible else { return }
        isFindBarVisible = false
        findBar.isHidden = true
        activeTerminalView?.clearSearch()
        focusActiveTab()
    }

    // MARK: - Selection action bar (terminal-only)

    // MARK: - Browser selection → agent ("Ask Agent" chip)

    private let askAgentBar = NSVisualEffectView()
    private let askAgentButton = NSButton()

    /// A one-button floating chip that appears next to a text selection in a
    /// browser tab. Clicking it stages the selection (plus a context file
    /// with the full page text) at the prompt of an agent terminal in this
    /// window — the user types their actual question and submits.
    private func setupAskAgentChip() {
        askAgentBar.material = .hudWindow
        askAgentBar.blendingMode = .withinWindow
        askAgentBar.state = .active
        askAgentBar.wantsLayer = true
        askAgentBar.layer?.cornerRadius = 8
        askAgentBar.layer?.masksToBounds = true
        askAgentBar.layer?.borderWidth = 1
        askAgentBar.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        askAgentBar.isHidden = true

        askAgentButton.title = "✦ Ask Agent"
        askAgentButton.font = .systemFont(ofSize: 11, weight: .medium)
        askAgentButton.isBordered = false
        askAgentButton.contentTintColor = NSColor.white.withAlphaComponent(0.9)
        askAgentButton.target = self
        askAgentButton.action = #selector(askAgentTapped)
        askAgentButton.toolTip = "Stage this selection (plus page context) at the agent's prompt"
        askAgentButton.translatesAutoresizingMaskIntoConstraints = false
        askAgentBar.addSubview(askAgentButton)
        NSLayoutConstraint.activate([
            askAgentButton.topAnchor.constraint(equalTo: askAgentBar.topAnchor, constant: 4),
            askAgentButton.bottomAnchor.constraint(equalTo: askAgentBar.bottomAnchor, constant: -4),
            askAgentButton.leadingAnchor.constraint(equalTo: askAgentBar.leadingAnchor, constant: 8),
            askAgentButton.trailingAnchor.constraint(equalTo: askAgentBar.trailingAnchor, constant: -8)
        ])
        root.addSubview(askAgentBar)
    }

    private func browserSelectionChanged(_ bc: BrowserController, _ sel: BrowserSelection?) {
        guard let sel,
              tabs.indices.contains(activeIndex), tabs[activeIndex] === bc,
              panel.isVisible, !isCollapsed, !isTicker else {
            askAgentBar.isHidden = true
            return
        }
        let p = bc.webView.convert(sel.viewPoint, to: root)
        let size = NSSize(width: 110, height: 26)
        var origin = NSPoint(x: p.x - size.width / 2, y: p.y + 8)
        origin.x = max(4, min(origin.x, root.bounds.width - size.width - 4))
        origin.y = max(4, min(origin.y, root.bounds.height - size.height - 4))
        askAgentBar.frame = NSRect(origin: origin, size: size)
        askAgentBar.isHidden = false
    }

    @objc private func askAgentTapped() {
        askAgentBar.isHidden = true
        guard tabs.indices.contains(activeIndex),
              let bc = tabs[activeIndex] as? BrowserController,
              let sel = bc.latestSelection else { return }
        // Snapshot the full page text at send time (not on every mouseup —
        // pages like the BigQuery console have enormous innerText).
        bc.fetchFullPageText { [weak self, weak bc] fullText in
            guard let bc else { return }
            self?.stageBrowserContext(sel, fullText: fullText, from: bc)
        }
    }

    /// Writes the capture to a context file and stages a one-line pointer at
    /// the agent's prompt — WITHOUT pressing Enter, so the user appends their
    /// actual question ("write a query that joins these…") and submits.
    private func stageBrowserContext(_ sel: BrowserSelection, fullText: String,
                                     from bc: BrowserController) {
        // Target: an agent session in this window, else any terminal tab,
        // else a fresh one.
        var index = tabs.firstIndex { ($0 as? TerminalController)?.isAgentSession == true }
            ?? tabs.firstIndex { $0 is TerminalController }
        if index == nil {
            addTerminalTab()
            index = tabs.indices.last
        }
        guard let idx = index, let tc = tabs[idx] as? TerminalController else { return }

        let path = Self.writeBrowserContextFile(
            sel, fullText: fullText,
            devtoolsEvents: Array(bc.recentDevtoolsEvents.suffix(40)))
        let inline = sel.text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
            .prefix(300)
        var message = "[from browser] \"\(inline)\" — on \(sel.pageTitle)"
        if let path { message += ". Full page context: \(path)" }
        if let log = bc.devtoolsLogPath {
            message += ". Live console/network log (tail it): \(log)"
        }
        message += " — "
        selectTab(idx)
        show()
        tc.terminalView.send(txt: message)
    }

    /// One markdown file per capture under Application Support, pruned to the
    /// most recent 50 — big page context goes here for the agent to read,
    /// instead of being dumped into the prompt. (StorageJanitor additionally
    /// enforces age- and size-based limits on this directory.)
    private static func writeBrowserContextFile(_ sel: BrowserSelection,
                                                fullText: String,
                                                devtoolsEvents: [String]) -> String? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("FloatyTerm/BrowserContext", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("ctx-\(stamp.string(from: Date())).md")
        let content = """
        # Browser context

        - Page: \(sel.pageTitle)
        - URL: \(sel.urlString)

        ## Highlighted by the user

        \(sel.text)

        ## Surrounding block

        \(sel.context)

        ## Recent console & network (newest last)

        \(devtoolsEvents.isEmpty ? "(no events captured)" : devtoolsEvents.joined(separator: "\n"))

        ## Page content (structured markdown — headings, sections, tables, controls)

        \(fullText)
        """
        guard (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil else {
            return nil
        }
        if let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) {
            let captures = files.filter { $0.lastPathComponent.hasPrefix("ctx-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            for old in captures.dropLast(50) { try? FileManager.default.removeItem(at: old) }
        }
        return url.path
    }

    private func setupSelectionBar() {
        selectionBar.isHidden = true
        // Frame-positioned (follows the mouse), so no Auto Layout here.
        selectionBar.translatesAutoresizingMaskIntoConstraints = true
        root.addSubview(selectionBar)

        selectionBar.onCopy = { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.selectionText, forType: .string)
            self.hideSelectionBar()
        }
        selectionBar.onOpen = { [weak self] in
            guard let self else { return }
            self.openSelectionTarget()
            self.hideSelectionBar()
        }
        selectionBar.onSearch = { [weak self] in
            guard let self else { return }
            self.openBrowserTab(loading: self.selectionText)   // non-URL → DDG search
            self.hideSelectionBar()
        }
        selectionBar.onInsert = { [weak self] in
            guard let self else { return }
            self.activeTerminalView?.send(txt: self.selectionText)
            self.hideSelectionBar()
            self.focusActiveTab()
        }
    }

    /// SwiftTerm's mouse handlers aren't `open`, so selection is detected via
    /// a local event monitor: mouse-up over the active terminal with a live
    /// selection shows the bar; mouse-down anywhere else dismisses it.
    private var mouseMonitor: Any?

    private func installSelectionMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            self?.handleSelectionMouse(event)
            return event
        }
    }

    private func handleSelectionMouse(_ event: NSEvent) {
        guard event.window === panel else { return }

        if event.type == .leftMouseDown {
            // Keep the bar when the click is ON the bar (its buttons).
            let p = root.convert(event.locationInWindow, from: nil)
            if selectionBar.isHidden || !selectionBar.frame.contains(p) {
                hideSelectionBar()
            }
            return
        }

        // Mouse-up: show the bar if the active terminal has a selection.
        guard let tv = activeTerminalView else { return }
        let pInTV = tv.convert(event.locationInWindow, from: nil)
        guard tv.bounds.contains(pInTV) else { return }
        let windowPoint = event.locationInWindow
        // Defer one tick so SwiftTerm finishes committing the selection.
        DispatchQueue.main.async { [weak self] in
            guard let self, let tv = self.activeTerminalView else { return }
            guard tv.hasSelection,
                  let text = tv.selectedText,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            self.showSelectionBar(at: windowPoint, text: text)
        }
    }

    private func showSelectionBar(at windowPoint: NSPoint, text: String) {
        selectionText = text
        selectionBar.setOpenAvailable(selectionOpenTarget() != nil)

        let size = NSSize(width: selectionBar.naturalWidth, height: SelectionActionBar.barHeight)
        let p = root.convert(windowPoint, from: nil)
        var origin = NSPoint(x: p.x - size.width / 2, y: p.y + 14)
        // Keep the bar inside the content area (below the header/tab strip).
        let area = contentArea.frame
        origin.x = min(max(origin.x, area.minX + 6), area.maxX - size.width - 6)
        origin.y = min(max(origin.y, area.minY + 6), area.maxY - size.height - 6)
        selectionBar.frame = NSRect(origin: origin, size: size)
        root.addSubview(selectionBar, positioned: .above, relativeTo: nil)
        selectionBar.isHidden = false
    }

    private func hideSelectionBar() {
        selectionBar.isHidden = true
    }

    /// What "Open" would do with the current selection: a web URL, or an
    /// existing file/folder (relative paths resolve against the shell's cwd).
    private enum OpenTarget {
        case url(String)
        case file(URL)
    }

    private func selectionOpenTarget() -> OpenTarget? {
        let t = selectionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains("\n") else { return nil }
        if t.contains("://") { return .url(t) }
        if t.lowercased().hasPrefix("www."), !t.contains(" ") { return .url("https://\(t)") }
        guard !t.contains(" ") else { return nil }

        // Strip a trailing :line(:col) suffix from compiler/stack-trace paths.
        let pathPart = t.replacingOccurrences(of: #":\d+(:\d+)?$"#, with: "",
                                              options: .regularExpression)
        var candidate = (pathPart as NSString).expandingTildeInPath
        if !candidate.hasPrefix("/") {
            let cwd = (tabs.indices.contains(activeIndex)
                       ? tabs[activeIndex] as? TerminalController : nil)?
                .currentWorkingDirectory ?? NSHomeDirectory()
            candidate = (cwd as NSString).appendingPathComponent(candidate)
        }
        if FileManager.default.fileExists(atPath: candidate) {
            return .file(URL(fileURLWithPath: candidate))
        }
        return nil
    }

    private func openSelectionTarget() {
        switch selectionOpenTarget() {
        case .url(let s):     openBrowserTab(loading: s)
        case .file(let url):  NSWorkspace.shared.open(url)
        case nil:             break
        }
    }

    /// Opens a new in-app browser tab loading `text` (URL or search query).
    private func openBrowserTab(loading text: String) {
        addBrowserTab()
        (tabs.indices.contains(activeIndex)
         ? tabs[activeIndex] as? BrowserController : nil)?.load(text)
    }

    // MARK: - Context Snap (give the terminal agent eyes on what's behind)

    /// Captures what this window is overlaying and points the active terminal
    /// agent (Claude / Fable) at it. Flow: a ⇧⌘4-style region picker appears —
    /// drag to capture a portion, click for the whole screen behind, Esc to
    /// cancel — then:
    /// - image mode: PNG saved, its path typed at the prompt;
    /// - asText (⌥): local OCR, then a review sheet where the wanted portion
    ///   of the text can be selected before inserting.
    private func captureContext(asText: Bool) {
        guard activeTabIsTerminal else { return }   // needs a prompt to type into
        guard ContextSnap.ensurePermission() else { return }
        RegionSelector.begin(on: panel.screen) { [weak self] region in
            guard let self, let region else { return }   // nil = Esc
            let area: NSRect? = region.isEmpty ? nil : region
            // captureBehind is async (ScreenCaptureKit one-shot); hop to the main
            // actor to read the window/screen, then await the capture off it.
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let image = await ContextSnap.captureBehind(self.panel, region: area) else {
                    NSLog("FloatyTerm: context snap capture returned nil")
                    return
                }
                if asText {
                    ContextSnap.recognizeText(in: image) { [weak self] text in
                        self?.presentOCRReview(text ?? "")
                    }
                } else if let url = ContextSnap.saveImage(image) {
                    self.insertSnapPath(url)
                }
            }
        }
    }

    /// Shows the recognized text for review: the user selects just the portion
    /// they want (or leaves it all), then inserts it as typed text or as a
    /// saved .txt path.
    private func presentOCRReview(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        guard !text.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "No text recognized"
            alert.informativeText = "The captured area didn't contain readable text."
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Captured text"
        alert.informativeText = "Select just the part you want — or leave it unselected to use everything."
        alert.addButton(withTitle: "Insert Text")
        alert.addButton(withTitle: "Insert as File")
        alert.addButton(withTitle: "Cancel")

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
        let textView = NSTextView(frame: scroll.bounds)
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll

        let response = alert.runModal()
        let range = textView.selectedRange()
        let chosen = range.length > 0 ? (text as NSString).substring(with: range) : text
        switch response {
        case .alertFirstButtonReturn:
            activeTerminalView?.send(txt: chosen)
            focusActiveTab()
        case .alertSecondButtonReturn:
            if let url = ContextSnap.saveText(chosen) { insertSnapPath(url) }
        default:
            break
        }
    }

    /// Types the snap's path at the prompt (trailing space so the user can
    /// continue with their question) and focuses the terminal.
    private func insertSnapPath(_ url: URL) {
        activeTerminalView?.send(txt: url.path + " ")
        focusActiveTab()
    }

    // MARK: - Snap history (right-click the camera button)

    /// Rebuilds the camera button's history menu: recent snaps (thumbnails for
    /// images), each insertable with a click or revealable with ⌥-click.
    private func buildSnapHistoryMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let snaps = ContextSnap.listSnaps()

        if snaps.isEmpty {
            let empty = NSMenuItem(title: "No snaps yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for url in snaps.prefix(12) {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(insertSnapFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.image = url.pathExtension == "png"
                ? Self.snapThumbnail(url)
                : NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Text snap")
            menu.addItem(item)

            // ⌥ variant of the same row: reveal in Finder instead of insert.
            let alt = NSMenuItem(title: "Reveal \(url.lastPathComponent) in Finder",
                                 action: #selector(revealSnapFromMenu(_:)), keyEquivalent: "")
            alt.target = self
            alt.representedObject = url
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = [.option]
            menu.addItem(alt)
        }

        menu.addItem(.separator())
        let reveal = NSMenuItem(title: "Reveal Snaps Folder",
                                action: #selector(revealSnapsFolder), keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        if !snaps.isEmpty {
            let clear = NSMenuItem(title: "Delete All Snaps",
                                   action: #selector(deleteAllSnaps), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
    }

    @objc private func insertSnapFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if activeTabIsTerminal {
            insertSnapPath(url)
        } else {
            // No prompt to type into — make the path available anyway.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
    }

    @objc private func revealSnapFromMenu(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func revealSnapsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([ContextSnap.snapsDirectory])
    }

    @objc private func deleteAllSnaps() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete all snaps?"
        alert.informativeText = "Sessions that reference these paths will no longer find them."
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ContextSnap.deleteAllSnaps()
    }

    /// Small menu thumbnail for an image snap.
    private static func snapThumbnail(_ url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let size = NSSize(width: 46, height: 29)
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: .zero, operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }

    // MARK: - Transcript reader

    /// A subtle button in the content area's bottom-right corner — "next to
    /// what the agent is outputting" — toggling the live transcript reader.
    private func setupReaderButton() {
        readerButton.image = NSImage(systemSymbolName: "doc.plaintext",
                                     accessibilityDescription: "Live transcript")
        readerButton.isBordered = false
        readerButton.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        readerButton.toolTip = "Live transcript — scroll & search this session's output as it streams"
        readerButton.target = self
        readerButton.action = #selector(toggleTranscriptReader)
        readerButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(readerButton)
        NSLayoutConstraint.activate([
            readerButton.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor, constant: -10),
            readerButton.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor, constant: -8),
            readerButton.widthAnchor.constraint(equalToConstant: 24)
        ])
    }

    @objc private func toggleTranscriptReader() {
        if let reader = transcriptReader {
            reader.close()       // onClosed clears transcriptReader
            return
        }
        guard let tc = tabs.indices.contains(activeIndex)
                ? tabs[activeIndex] as? TerminalController : nil else { return }
        let reader = TranscriptReaderController(session: tc, parent: panel,
                                                displayName: tc.displayName)
        reader.onClosed = { [weak self] in self?.transcriptReader = nil }
        transcriptReader = reader
        reader.show()
    }

    /// The reader docks to the panel as a child window; close it whenever the
    /// panel leaves the screen or its session goes away, so it can't orphan.
    private func closeReaderIfNeeded(forClosing tab: (any TabContent)? = nil) {
        guard let reader = transcriptReader else { return }
        if tab == nil || reader.session === (tab as? TerminalController) {
            reader.close()
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if AppRuntime.isQuitting || tabs.isEmpty { return true }

        // Only terminal tabs can have a running foreground job.
        let terminalTabs = tabs.compactMap { $0 as? TerminalController }
        let busy = terminalTabs.contains { $0.hasRunningForegroundJob }

        // A single idle terminal (or any mix without a running job) closes freely.
        if !busy && tabs.count == 1 { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = busy ? "A process is still running." : "Close this window?"
        let termCount = terminalTabs.count
        let browCount = tabs.count - termCount
        var parts: [String] = []
        if termCount > 0 { parts.append("\(termCount) terminal session\(termCount == 1 ? "" : "s")") }
        if browCount > 0 { parts.append("\(browCount) browser tab\(browCount == 1 ? "" : "s")") }
        alert.informativeText = "Closing will end \(parts.joined(separator: " and "))."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        closeReaderIfNeeded()
        // Closing a window discards its sessions for good (every tab-removal
        // path that keeps a session alive — tear-off, borrow, lend — empties
        // `tabs` before closing the panel), so clean them up like closed tabs:
        // their transcript logs must not linger as orphans. At quit the saved
        // records still reference them, so cleanup() keeps the files then.
        tabs.forEach { $0.cleanup() }
        activityTimer?.invalidate()
        activityTimer = nil
        if let m = mouseMonitor { NSEvent.removeMonitor(m); mouseMonitor = nil }
        // A collapsed/tickered window can be closed (e.g. its tab was borrowed
        // away); don't leave an orphaned bubble or strip floating around.
        avatar?.orderOut(nil)
        avatar = nil
        ticker?.orderOut(nil)
        ticker = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onClosed?(self)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { applyAppearance(focused: true)  }
    func windowDidResignKey(_ notification: Notification) {
        dismissWindowOptions()   // don't leave the overlay floating over an inactive window
        applyAppearance(focused: false)
    }
    func windowDidMove(_ notification: Notification)      { scheduleFrameSave(); repositionAgentBadge() }
    func windowDidResize(_ notification: Notification)    { scheduleFrameSave(); repositionAgentBadge() }

    /// Keep the Agent Ghost unlock badge pinned to the window's corner as it moves.
    private func repositionAgentBadge() {
        if isAgentGhosted { unlockBadge?.reposition(over: panel.frame) }
    }

    /// Move/resize fire continuously during a drag; coalesce into one
    /// state-record write shortly after the gesture settles. Per-window records
    /// mean a pinned window's geometry is safe to persist too — it can no
    /// longer clobber a shared default.
    private func scheduleFrameSave() {
        frameSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onStateChanged?() }
        frameSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Recent-commands palette (terminal-only)

    private func setupRecentPalette() {
        recentPalette.translatesAutoresizingMaskIntoConstraints = false
        recentPalette.isHidden = true
        root.addSubview(recentPalette)

        NSLayoutConstraint.activate([
            recentPalette.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
            recentPalette.topAnchor.constraint(equalTo: contentBlur.topAnchor, constant: 20),
            recentPalette.widthAnchor.constraint(equalTo: contentArea.widthAnchor, multiplier: 0.75),
            recentPalette.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            recentPalette.widthAnchor.constraint(lessThanOrEqualToConstant: 700),
            recentPalette.heightAnchor.constraint(equalToConstant: 340)
        ])

        recentPalette.onInsert = { [weak self] command, run in
            guard let self, let tv = self.activeTerminalView else { return }
            tv.send(txt: command)
            if run { tv.send([0x0D]) }
            self.hideRecentPalette()
        }
        recentPalette.onClose = { [weak self] in self?.hideRecentPalette() }
    }

    private func toggleRecentPalette() {
        if isPaletteVisible { hideRecentPalette() } else { showRecentPalette() }
    }

    private func showRecentPalette() {
        guard !isPaletteVisible else { recentPalette.focusSearchField(); return }
        isPaletteVisible = true
        recentPalette.isHidden = false
        recentPalette.reloadHistory()
        recentPalette.focusSearchField()
    }

    private func hideRecentPalette() {
        guard isPaletteVisible else { return }
        isPaletteVisible = false
        recentPalette.isHidden = true
        focusActiveTab()
    }

    // MARK: - URL bar (browser-only)

    private func setupURLBar() {
        urlBar.translatesAutoresizingMaskIntoConstraints = false
        urlBar.isHidden = true
        // Layer above contentArea (inside root, like findBar and recentPalette).
        root.addSubview(urlBar)

        // Centred horizontally; pinned near the top of the content area.
        NSLayoutConstraint.activate([
            urlBar.centerXAnchor.constraint(equalTo: contentArea.centerXAnchor),
            urlBar.topAnchor.constraint(equalTo: contentBlur.topAnchor, constant: 8),
            urlBar.widthAnchor.constraint(equalTo: contentArea.widthAnchor, multiplier: 0.80),
            urlBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            urlBar.widthAnchor.constraint(lessThanOrEqualToConstant: 700)
        ])

        urlBar.onLoad    = { [weak self] text in self?.browserLoad(text)  }
        urlBar.onBack    = { [weak self] in self?.activeBrowser?.goBack()    }
        urlBar.onForward = { [weak self] in self?.activeBrowser?.goForward() }
        urlBar.onReload  = { [weak self] in self?.activeBrowser?.reload()    }
        urlBar.onToggleShield = { [weak self] in
            guard let bc = self?.activeBrowser else { return }
            bc.protectionDisabled.toggle()
            self?.syncURLBar()
        }
    }

    private func browserLoad(_ text: String) {
        activeBrowser?.load(text)
        focusActiveTab()
    }

    /// Shows the URL bar with current state (called when a browser tab becomes active).
    private func showURLBar() {
        guard !isURLBarVisible else { return }
        isURLBarVisible = true
        urlBar.isHidden = false
        syncURLBar()
    }

    private func hideURLBar() {
        guard isURLBarVisible else { return }
        isURLBarVisible = false
        urlBar.isHidden = true
    }

    /// Updates URL field text and nav button enabled state from the active browser.
    func syncURLBar() {
        guard let bc = activeBrowser else { return }
        let urlString = bc.webView.url?.absoluteString ?? ""
        urlBar.updateURL(urlString)
        urlBar.updateNavState(canGoBack: bc.canGoBack, canGoForward: bc.canGoForward)
        let blocking = (Settings.shared.blockPopups || Settings.shared.blockRedirects)
            && !bc.protectionDisabled
        urlBar.updateShield(blocking: blocking, count: bc.blockedCount)
    }

    /// Called after selectTab / settings change to show/hide the URL bar based
    /// on tab type and the collapse toggle. The globe toggle in the header is
    /// shown only for browser tabs and reflects the expanded/collapsed state.
    private func updateURLBarVisibility() {
        let expanded = !Settings.shared.urlBarCollapsed
        if activeTabIsBrowser && expanded {
            showURLBar()
        } else {
            hideURLBar()
        }
        header.setURLBarToggleVisible(activeTabIsBrowser)
        header.setURLBarToggleActive(expanded)
    }
}
