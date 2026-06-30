# Handoff: Emulating Warp's inline image + markdown rendering in FloatyTerm

> Paste this into Claude-on-web (claude.ai) for a deep research pass. It contains the
> baseline already gathered in Claude Code plus the open questions to drive deeper.

## Goal

FloatyTerm is a macOS Swift app (terminal + browser tabs) using **SwiftTerm** as its
emulator. I want to emulate how **Warp terminal** renders **images** and **markdown files**.

The desired UX is a **three-stage progression**, not a single behavior:

1. **Inline (default).** The image renders **inline in the terminal scrollback** at a modest
   thumbnail size, in place where the command emitted it.
2. **Click to expand.** Clicking the inline image **expands it in place** to a larger preview
   (still within the terminal view / as an overlay), so it takes up more of the view without
   leaving the session. Clicking again (or some affordance) collapses it back.
3. **Open in new tab.** There is also an explicit option (context menu / button) to **open the
   image in a new child tab placed directly next to the parent tab** for a full dedicated view.

Markdown follows the same spirit: it can render inline/expanded, with an option to open the
`.md` in a dedicated child-tab viewer.

I need a deeply-researched implementation plan + protocol reference I can hand to an engineer.

## Baseline already established (don't re-derive — build on this)

**Two distinct rendering models exist; my target is Model B but I want both documented:**

- **Model A — in-stream graphics protocols.** Warp supports the **Kitty graphics protocol**
  and the **iTerm2 inline image protocol** (NOT Sixel). FloatyTerm's emulator, **SwiftTerm,
  already supports Sixel + the iTerm2 image protocol** natively, so `imgcat`-style in-stream
  rendering is largely already available through the emulator.
- **Model B — file/link detection → open in a viewer (my target).** This is Warp's
  "Files, Links & Scripts" + "Markdown Viewer" features. Warp detects file paths in output,
  makes them clickable, and opens markdown/images in a dedicated viewer pane.

**Warp Markdown Viewer behavior (from docs):** opens `.md` in a split pane with edit +
rendered modes; renders headings/tables; fenced code blocks with no language or
`sh`/`shell`/`bash`/`fish`/`zsh`/`warp-runnable-command` get a run (`>_`) icon that inserts
the command into the active terminal; `CMD-UP/DOWN` navigate shell blocks, `CMD-ENTER` runs.

**FloatyTerm architecture (already mapped):**
- Tabs: heterogeneous `[any TabContent]` in `TerminalWindowController`. `TabContent` protocol
  exposes `view: NSView`, `displayName`, `restorableRecord`, `onTitleChanged`, `onTerminated`,
  `focus(in:)`, `cleanup()`.
- Existing viewer controllers to copy as templates: `NoteController` (NSTextView markdown
  editor), `DiffViewerController` (custom NSView canvas), `MirrorController` (CALayer/IOSurface),
  `BrowserController` (WKWebView).
- **Known gap:** `insertTab(_:)` only *appends* (`tabs.append`) then selects last. There is no
  insert-at-index and no parent/child relationship. `moveTab(from:to:)` already exists.

## What I need from you (deep research deliverables)

1. **Protocol reference.** Precise wire format for the **iTerm2 inline image protocol**
   (OSC 1337 `File=...`) and the **Kitty graphics protocol** (APC `_G...`). Include how Warp
   chooses between them, base64 chunking, sizing/scaling params, and how each terminates.
   Confirm exactly what SwiftTerm's image API exposes (delegate hooks, callbacks, or
   automatic rendering) — cite SwiftTerm source (github.com/migueldeicaza/SwiftTerm).

2. **Warp's file/link detection.** How Warp identifies file paths + URLs in output (regex?
   semantic prompt markers? OSC 8 hyperlinks? shell integration?), and how a click resolves
   to "open in viewer." Is the markdown viewer a separate pane type or a block? Cite Warp docs
   + any open-source signal from github.com/warpdotdev/Warp issues.

3. **Markdown rendering choice for FloatyTerm.** Compare: (a) render md→HTML in a `WKWebView`
   (reuse `BrowserController`), vs (b) attributed-string rendering in `NSTextView` (extend
   `NoteController`), vs (c) a Swift markdown lib (swift-markdown / Down / cmark). Recommend one
   for a macOS-14+ app, with rationale on tables, code highlighting, runnable code blocks, and
   theming to match the app's blur/transparency aesthetic.

4. **Image rendering — the three-stage interaction (most important).** Design the full
   progression:
   - **(a) Inline thumbnail in scrollback.** How does an inline image rendered via SwiftTerm
     (iTerm2/Kitty protocol) become *clickable*? Does SwiftTerm expose hit-testing / a
     delegate for the image cell, or do we need an overlay NSView positioned over the image
     region? Detail how to track the image's bounds as the terminal scrolls/reflows.
   - **(b) Click-to-expand in place.** How to present a larger preview without leaving the
     session — an overlay/popover anchored to the inline image, an expanded inline cell, or a
     floating panel? Cover collapse-back, sizing limits, and not disrupting scrollback layout.
   - **(c) Open in new child tab.** The dedicated full viewer: minimal `TabContent` wrapping
     `NSImageView` (or CALayer) — zoom/fit, animated GIF, transparency, large-image handling.
   Recommend the affordances for each transition (single click → expand, context menu →
   open in tab, etc.) and what state must persist across them.

5. **Child-tab insertion + parent/child model.** Design the `insertTab(_:after:)` /
   `insertTab(_:at:)` overload and a parent→child link so the viewer tab sits adjacent to its
   opener and (optionally) closes/reorders with it. Address persistence (`restorableRecord`)
   and what happens on parent close.

6. **Concrete implementation plan** for FloatyTerm: new files, changed files
   (`TerminalWindowController`, `TabContent`), the detection trigger (click handler vs OSC 8 vs
   path regex on selection), and a phased rollout:
   - **Phase 1:** inline image rendering in scrollback (verify SwiftTerm path) + click-to-expand
     in place.
   - **Phase 2:** "open in new child tab" full image viewer + the `insertTab(_:after:)` /
     parent-child tab model.
   - **Phase 3:** markdown — inline/expanded rendering + dedicated child-tab viewer.
   - **Phase 4:** runnable code blocks in markdown → insert into terminal input.

## Sources to start from
- Warp Markdown Viewer: https://docs.warp.dev/terminal/more-features/markdown-viewer/
- Warp Files & Links: https://docs.warp.dev/terminal/more-features/files-and-links/
- Warp Blocks: https://docs.warp.dev/terminal/blocks/
- Kitty graphics protocol: https://sw.kovidgoyal.net/kitty/graphics-protocol/
- iTerm2 inline images: https://iterm2.com/documentation-images.html
- Terminal graphics protocols overview: https://akmatori.com/blog/terminal-graphics-protocols
- Warp Kitty protocol issues: https://github.com/warpdotdev/Warp/issues/26 , https://github.com/warpdotdev/Warp/issues/4446
- Warp markdown tables: https://github.com/warpdotdev/Warp/issues/8299
- SwiftTerm source: https://github.com/migueldeicaza/SwiftTerm

Produce a single structured report with the protocol reference, the recommendation per
decision point, and the phased FloatyTerm implementation plan with file-level specifics.
