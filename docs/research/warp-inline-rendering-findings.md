# FloatyTerm — Inline Image & Markdown Rendering (deep findings)

> Deep-research deliverable from Claude-on-web, building on
> [warp-inline-rendering-handoff.md](warp-inline-rendering-handoff.md).
> Companion to the handoff prompt. Validation status of load-bearing claims is tracked at
> the bottom (see "Local verification").

> ## ⚠️ Corrections after local verification against SwiftTerm 1.13.0
> The report below was written against general SwiftTerm knowledge. Verified against the
> **actually pinned** version (`Package.resolved` → SwiftTerm **1.13.0**, rev `8e7a1e15`),
> three load-bearing claims are wrong or imprecise. Read these before the report:
>
> 1. **Kitty graphics IS supported (report says it isn't).** SwiftTerm 1.13 ships a full Kitty
>    decoder — `KittyGraphics.swift` (transmit/put/delete/query, shm + temp-file transports) and
>    `KittyPlaceholder.swift` (Unicode placeholder protocol), wired into the parser at
>    `EscapeSequenceParser.swift:554` (`handleKittyGraphics`). iTerm2 OSC 1337 is also wired
>    (`EscapeSequenceParser.swift:541` → `osciTerm2`). **You inherit BOTH protocols for free.**
>    §1.4 and §7's "treat Kitty as unverified / may need a parser contribution" is obsolete.
>
> 2. **`TerminalImage` exposes `pixelWidth`, `pixelHeight`, `col` only — there is NO `row`.**
>    (`Terminal.swift:264`.) The report's bounds-tracking hook ("read fresh `image.col/row`") is
>    wrong: on macOS the row is implicit in the per-line container, not on the image.
>
> 3. **The no-fork overlay route does NOT work on macOS as written.** The report's
>    `terminalView.images: [(image, col, row)]` is the **iOS** view's property
>    (`iOSTerminalView.swift:218`). On macOS, image placements live in the **internal** struct
>    `ViewLineInfo { var images: [TerminalImage]? }` (`AppleTerminalView.swift:80`) and
>    `BufferLine.images` — neither is `public`. The only public image API on the Mac view is the
>    *ingest* side (`createImage`, `createImageFromBitmap`), not an enumeration of placed images
>    with positions. **So Phase-1 click-to-expand requires the SwiftTerm fork (report's "option
>    2"), not the "start no-fork, escalate if janky" path.** For macOS the recommendation
>    inverts: fork to expose image placements / hit-testing from the start, OR drop click-to-
>    expand and go straight to a context-menu "Open in tab" (which can hang off OSC-8-style
>    affordances or a command/selection trigger rather than per-image hit-testing).
>
> ## ✅ v1 implemented (no-fork image-in-child-tab)
> Shipped on branch `feature/devtools-diagnosis-window-mgmt`:
> - **[ImageViewerController.swift](../../Sources/FloatyTerm/ImageViewerController.swift)** — a
>   `TabContent` image viewer (NSScrollView + NSImageView, fit-to-window, scroll/pinch zoom,
>   animated GIF). Ephemeral (`restorableRecord` = nil), like DiffViewer/Mirror.
> - **[FloatyTerminalView.swift](../../Sources/FloatyTerm/FloatyTerminalView.swift)** — right-click
>   context-menu item **"Open in Image Viewer"**, shown only when the current selection resolves
>   to an image file on disk (absolute, or relative to the shell cwd).
> - **[TerminalController.swift](../../Sources/FloatyTerm/TerminalController.swift)** — wires the
>   cwd provider (`currentWorkingDirectory`, via `proc_pidinfo` — no OSC 7 dependency) and the
>   open-image callback; exposes `onOpenChildTab`.
> - **[TerminalWindowController.swift](../../Sources/FloatyTerm/TerminalWindowController.swift)** —
>   `insertTab(_:at:)`, `insertChildTab(_:after:)`, a `parentByChild` ObjectIdentifier map, and a
>   close cascade (closing a terminal closes its viewer children). Terminal hook is wired at the
>   single `insertTab` choke point so it covers new/restored/adopted tabs.
> - **[MarkdownViewerController.swift](../../Sources/FloatyTerm/MarkdownViewerController.swift)** +
>   **[MarkdownAssets.swift](../../Sources/FloatyTerm/MarkdownAssets.swift)** — `.md` **view + edit**.
>   Preview renders in a `WKWebView` via **vendored marked.js v12** (MIT, embedded as a Swift
>   string — not an SPM resource, since `build.sh` hand-assembles the .app and wouldn't copy a
>   resource bundle — so it works fully offline; dark/transparent theme, GFM tables + code, file's
>   dir as `baseURL` so relative images resolve). Edit is an editable `NSTextView` (raw source).
>   An **expandable icon toolbar pinned top-left** toggles Edit/Preview, saves (explicit; dirty-dot
>   on the chip; flush-on-close so edits aren't lost), and reveals in Finder. Switching to preview
>   re-renders the live editor text. Same select→right-click trigger ("Open in Markdown Viewer");
>   same child-tab plumbing — no window-controller changes needed.
> - **Helper:** a `pic` script (`~/.local/bin/pic`) emits the iTerm2 OSC 1337 sequence so inline
>   images can be tested without iTerm2's `imgcat`.
>
> **Trigger reality (important):** the interaction is **select the path → right-click → "Open in
> Image Viewer"**, NOT a single ⌘-click on the path. True click-on-text interception is blocked
> without a fork: `requestOpenLink` is satisfied by a protocol-extension default on
> `LocalProcessTerminalView` (static witness — a subclass can't override it), and the detection
> APIs (`linkMatch`, `getPayload`) are internal. Single-⌘-click-the-path remains a fork-gated
> follow-up (the deferred "fork later" option). The implicit-path regex finding still matters for
> that future fork.
>
> Also confirmed: `TerminalViewDelegate.requestOpenLink` exists on Mac and fires
> (`MacTerminalView.swift:2005`); FloatyTerm does **not** implement it yet
> ([TerminalController.swift:679](../../Sources/FloatyTerm/TerminalController.swift:679) has the
> delegate but no `requestOpenLink`). `hostCurrentDirectoryUpdate` is implemented but empty
> ([TerminalController.swift:694](../../Sources/FloatyTerm/TerminalController.swift:694)), so OSC
> 7 working-dir is available to wire. Everything else in the report stands.

**Engineering handoff: emulating Warp's inline-image and markdown UX on a SwiftTerm core.**

This report covers (1) the wire protocols, (2) what SwiftTerm actually gives you, (3) how Warp
detects files/links, (4) the markdown-rendering decision, (5) the three-stage image
interaction, (6) the parent/child tab model, and (7) a phased, file-level implementation plan.

The single most important finding up front, because it reshapes the plan:

> **SwiftTerm renders inline images itself, inside its own `draw(_:)`, by drawing
> `NSImage`/`CGImage` data directly onto the terminal canvas. Images are *not* `NSView`s. They
> are stored as `[(image: TerminalImage, col: Int, row: Int)]` on the view, and there is no
> built-in hit-test, click delegate, or context-menu hook for an image cell.** SwiftTerm's only
> click affordance for "things in the scrollback" is the OSC 8 hyperlink path
> (`requestOpenLink`), which is text-anchored, not image-anchored.

Everything in Phase 1's "click-to-expand" therefore hinges on either (a) an overlay `NSView`
you position over the image's drawn region, or (b) a small fork/extension of SwiftTerm to
expose image hit-testing. Both are detailed below. This is not a blocker — it's a design fork
you need to decide early.

---

## 1. Protocol reference

### 1.1 iTerm2 inline image protocol (OSC 1337)

The classic single-shot form is an OSC sequence terminated by BEL (`^G`, `0x07`) or ST (`ESC \`):

```
ESC ] 1337 ; File = <args> : <base64 file bytes> BEL
```

`<args>` is a semicolon-separated `key=value` list (no spaces in the real stream). Keys:

| Key | Value |
|---|---|
| `name` | base64-encoded filename. Defaults to "Unnamed file". |
| `size` | file size in bytes; only used for the progress indicator. |
| `width` | render width — `N` (cells), `Npx` (pixels), `N%` (percent of session width), or `auto`. |
| `height` | render height — same unit grammar as width. |
| `preserveAspectRatio` | `1` (default) fits without stretching; `0` stretches to fill. |
| `inline` | `1` = display inline; `0` (default) = download only, no inline render. |

Crucially the payload is the **full encoded image file** (PNG/GIF/JPEG/PDF — anything macOS
image I/O can decode), not raw pixels. Animated GIFs are supported.

A newer multipart form (iTerm2 3.5+) exists for tmux passthrough, splitting the giant sequence:

```
ESC ] 1337 ; MultipartFile = <args> BEL
ESC ] 1337 ; FilePart = <base64 chunk> BEL      (repeat)
ESC ] 1337 ; FileEnd BEL
```

Chunk ceiling is 1,048,576 bytes (also iTerm2's own cap). You almost certainly do not need to
*emit* these — SwiftTerm consumes them on the read side. They matter only if you ever proxy
output through tmux. This is the protocol `imgcat` uses, and the one SwiftTerm has supported
the longest.

### 1.2 Kitty graphics protocol (APC `_G`)

Kitty wraps an **Application Programming Command** — `ESC _ G <control data> ; <payload> ESC \`
— which most emulators safely ignore if unsupported. Control data is comma-separated
`key=value`:

- **Action (`a`)**: `t` transmit only, `T` transmit + display, `p` put/display a
  previously-transmitted image, `q` query, `d` delete, `f` animation frame, `a` animate.
- **Format (`f`)**: `24` (RGB), `32` (RGBA), `100` (PNG). Unlike iTerm2, the default expectation
  is *raw pixel data*; you must send `f=100` to ship a PNG container.
- **Transmission medium (`t`)**: `d` direct/inline-base64 (default), `f` regular file, `t` temp
  file (terminal deletes it; must live in a known temp dir and contain `tty-graphics-protocol`
  in the path), `s` POSIX/Windows shared-memory object.
- **Dimensions**: `s`/`v` = source pixel width/height; `c`/`r` = display columns/rows;
  `x`/`y`/`w`/`h` = source crop rectangle; `X`/`Y` = sub-cell pixel offset; `z` = z-index.
- **Identity**: `i` = image id (1…4294967295, non-zero); `p` = placement id. Sending `i` makes
  the terminal reply OK/error after load.
- **Chunking (`m`)**: base64-encode, then split into chunks ≤ 4096 bytes; every chunk except the
  last carries `m=1`, the last `m=0`. All but the last chunk must be a multiple of 4 in length.
  Only the first chunk needs the full control set; later chunks need only `m`.

Minimal "show a PNG" example, chunked:

```
ESC _G a=T,f=100,m=1; <chunk-1> ESC \
ESC _G m=1; <chunk-2> ESC \
ESC _G m=0; <chunk-3> ESC \
```

Kitty has features iTerm2's protocol lacks: transmit-once/display-many (virtual placements via
`i`), source-rect cropping, z-layering, animation frames, and shm/file transports that skip
base64 entirely (the recommended fast path for local video/large images).

### 1.3 How Warp chooses between them

Warp supports **both** iTerm2 and Kitty image protocols on macOS and Linux (it does **not**
support Sixel). Per Warp's own docs, the choice is driven by what the *emitting CLI tool* sends
— Warp is the receiver/parser, so the tool decides the protocol. Warp notes that some tools
gate Kitty output on `TERM=kitty`, so users sometimes have to `TERM=kitty <tool>`. There is no
"Warp picks one"; Warp parses whichever arrives.

For FloatyTerm this means: **you don't choose either — you inherit whatever SwiftTerm's parser
accepts.** Which brings us to the gap.

### 1.4 What SwiftTerm actually exposes (the real constraint)

Confirmed from the SwiftTerm source and API docs (`github.com/migueldeicaza/SwiftTerm`):

- **Supported on the read side: Sixel and the iTerm2 inline-image protocol** ("iTerm2-style
  graphic rendering — use imgcat to test"). The feature list and package tags (`sixel`,
  `imgcat`) reflect this. **Kitty graphics is *not* listed as supported.** Treat Kitty as
  "needs verification / likely needs a parser contribution" — do not assume `_G` sequences
  render.
- Decoded images are stored on the view as
  `var images: [(image: TerminalImage, col: Int, row: Int)]`.
- The `TerminalImage` protocol is deliberately tiny: `var pixelWidth: Int { get }`,
  `var pixelHeight: Int { get }`, and **mutable** `var col: Int { get set }` /
  `var row: Int { get set }` (the engine rewrites col/row as the buffer scrolls/reflows — this
  is your bounds-tracking hook).
- Rendering is internal: the Apple front-end draws images during its own paint pass
  (`drawImageInStripe(...)` crops the image per scroll stripe and blits it). There is **no**
  delegate callback like "image was clicked" and **no** public hit-test that maps a point to an
  image.
- The one scrollback-click mechanism that *does* exist is OSC 8 hyperlinks. On macOS, link
  tracking is **hover-based** with default `linkHighlightMode = .hoverWithModifier`, i.e.
  Command-hover highlights and Command-click activates, surfaced through
  `TerminalViewDelegate.requestOpenLink(source:link:params:)`. On iOS/visionOS the same delegate
  fires from pointer/tap interactions.

**Implication.** Inline rendering (stage 1) is free. Click-to-expand (stage 2) and "open in
tab" (stage 3) require *you* to map a click point back to an image, because SwiftTerm won't.
Two viable routes:

1. **Overlay route (no fork).** After each render, walk `terminalView.images`, convert each
   `(col,row,pixelWidth,pixelHeight)` into a view-space `CGRect` using SwiftTerm's cell metrics,
   and place a transparent tracking/affordance `NSView` over each image rect. The overlay
   handles clicks and the context menu. You re-sync overlays on scroll, resize, and content
   change. This keeps SwiftTerm a clean dependency.
2. **Fork/extend route.** Add a public `imageHitTest(at:) -> TerminalImage?` plus an
   `onImageClicked` delegate method to your SwiftTerm fork, mirroring the existing link
   plumbing. Cleaner UX (uses SwiftTerm's own coordinate math) but you own a fork and its
   rebases.

Recommendation: **start with the overlay route** for Phase 1/2 (no fork risk, ships fast), and
only upgrade to the fork route if overlay bounds-tracking during fast reflow proves janky. The
coordinate math you write for overlays is reusable if you later move it into a fork.

---

## 2. Warp's file/link detection

From Warp's "Files, Links, & Scripts" and "Markdown Viewer" docs:

- **Scope:** detection runs over the text content of **Blocks** (Warp's command+output
  grouping). It is fundamentally *regex/heuristic path & URL parsing over rendered text*, not
  solely OSC 8. Warp recognizes multiple URL schemes (`https`, `ftp`, `file`, …) and both
  relative and absolute filesystem paths.
- **Line/column capture:** Warp extracts trailing position info in many shapes: `file:line`,
  `file:line:col`, `file[line, col]`, `file(line, col)`, `file, line: N, column: M`,
  `file, line: N, in`. This is the editor-jump metadata you'd forward when opening externally.
- **Click semantics (macOS):** plain click → a clickable tooltip ("Open File/Folder/Link");
  `CMD`-click → opens directly; right-click → context menu with "copy absolute path / URL".
  Default editor is configurable (VS Code, JetBrains, Zed, Cursor, etc., or system default).
- **Markdown specifically:** any local `.md`/`.markdown` file link can be opened in the Markdown
  Viewer via CMD-click, the tooltip, or the right-click menu. Remote markdown is not supported.
  There's a setting to make the viewer the default for `.md`.
- **Command-triggered banner:** if you run a known markdown-viewing command — `cat`, `glow`, or
  `less` — on a `.md`, Warp shows a **banner with an "open in Markdown viewer" button** rather
  than auto-opening. A nice low-friction pattern worth copying.
- **Viewer is a pane, not a block.** The Markdown Viewer opens in a **split pane**, toggleable
  between rendered and editor modes via the pane overflow menu. It is a distinct pane type, not
  an inline block decoration.

For FloatyTerm, the cleanest detection trigger is a hybrid:

1. **Prefer OSC 8 hyperlinks** when present — unambiguous and already wired through
   `requestOpenLink`. If your shell integration or the emitting tool emits OSC 8 for paths, you
   get clean clickable regions for free.
2. **Fall back to a path/URL regex** run over the selected text or the hovered line, resolving
   relative paths against the session's working directory (SwiftTerm exposes
   `hostCurrentDirectory` via the delegate when the shell emits OSC 7). Mirror Warp's CMD-click
   / tooltip / context-menu trichotomy.
3. **Command-name banner** (Phase 3+): watch executed command lines for
   `cat|glow|less|bat <something>.md` and surface an "Open in viewer" affordance.

Images don't need path detection at all in the common case — `imgcat foo.png` renders inline
directly through the protocol. Path detection matters for the markdown flow and for "open this
image file in a tab" when the image is referenced by name rather than streamed.

---

## 3. Markdown rendering choice

Three candidates:

**(a) md → HTML in `WKWebView` (reuse `BrowserController`).**
- Pros: best-in-class fidelity — tables, nested lists, task lists, syntax-highlighted fenced
  code (highlight.js/Prism), MathJax if ever needed, full CSS control to match the
  blur/transparency aesthetic (`backdrop-filter`, translucent backgrounds over an
  `NSVisualEffectView`). You already have the controller. Runnable-code-block affordances are
  trivial: inject a `>_` button per code block and bridge clicks to native via
  `WKScriptMessageHandler`.
- Cons: heaviest runtime; theming requires shipping CSS; need a md→HTML step.

**(b) Attributed-string rendering in `NSTextView` (extend `NoteController`).**
- Pros: lightest, fully native, trivially themeable, great text selection, no web runtime.
- Cons: tables are painful (NSTextTable is fiddly/ugly for complex tables — and Warp users file
  bugs about md tables, so it's a real UX surface); code highlighting is manual; runnable-block
  buttons require custom `NSTextAttachment`/overlay work. You'd reimplement a renderer.

**(c) Pure Swift markdown lib (swift-markdown / Down / cmark).**
- `swift-markdown` (Apple, swift-cmark/CommonMark + GFM) is a *parser/AST* — clean document
  tree but **not** a renderer; you still choose NSAttributedString or HTML as output target.
- `Down` renders Markdown → HTML (and to `NSAttributedString`) via cmark; convenience layer that
  lands you back at (a) or (b).

**Recommendation: (a) — md → HTML in a `WKWebView`, with `swift-markdown` (or `markdown-it`
in-page) doing the parse.** Rationale for a macOS-14+ app:
- Tables and code highlighting are exactly where (b) falls down, and they're table-stakes for a
  dev-facing markdown viewer.
- The blur/transparency look is far easier with CSS over a transparent `WKWebView` background on
  an `NSVisualEffectView` than with NSTextView attributes.
- The runnable-code-block feature (Phase 4) is dramatically simpler over a JS bridge: render
  each fenced block with a `>_` button, post the block's text to native via
  `window.webkit.messageHandlers.runBlock.postMessage(...)`, call your existing "insert into
  terminal input" path. CMD-UP/DOWN block navigation and CMD-ENTER become JS keyboard handlers +
  a native menu.
- You reuse `BrowserController` patterns rather than growing `NoteController` into a renderer.

Keep `NoteController` for the **editor** half of the toggle (raw `.md` editing in NSTextView),
and use the WKWebView for the **rendered** half — mirrors Warp's editor/viewer split precisely.

Use `swift-markdown` for parsing if you want native control over which fenced-code languages
count as "runnable" (replicate Warp's set: no-language, `sh`, `shell`, `bash`, `fish`, `zsh`,
`warp-runnable-command`). Otherwise `markdown-it` + a small plugin in-page is the least code.

---

## 4. Image rendering — the three-stage interaction (core)

### Stage (a) — inline thumbnail in scrollback

SwiftTerm already renders the image inline at the size the protocol requested. To get a *modest
thumbnail by default*, you can't rewrite the emitting tool's `width`/`height` args, so clamping
means post-processing. Two options:

- **Soft clamp via overlay only (recommended for v1):** let SwiftTerm draw at whatever size
  arrived; if it exceeds a max thumbnail height (say 8–10 rows), that's acceptable for v1 —
  Warp itself renders inline images at the size sent. Don't fight the protocol initially.
- **Hard clamp (needs fork):** intercept decoded images in a fork and downscale/relayout before
  storing in `images[]`. More control, more fork surface. Defer.

**Making it clickable.** Implement the **overlay route** from §1.4:

1. Add an `imageOverlayContainer: NSView` as a subview of (or layered above) the `TerminalView`,
   matching its bounds, `wantsLayer = true`, **not** intercepting events except over image rects
   (per-image child tracking views, or one container with precise hit regions).
2. After every relevant event (initial render, `draw`, scroll via the enclosing `NSScrollView`'s
   bounds-change notification, live resize, and content mutation), recompute overlays:
   - For each `(image, col, row)` in `terminalView.images`, compute the cell origin. Cell size
     comes from SwiftTerm's font metrics (cell width = glyph advance, cell height = line
     height). Drawn size in points = `pixelWidth/scale × pixelHeight/scale` clamped to SwiftTerm's
     layout (rows occupied ≈ `ceil(pixelHeight / cellHeight)`).
   - Convert buffer `row` → on-screen y by accounting for scrollback offset
     (`buffer.lines.count - rows` and current scroll position). SwiftTerm's iOS view does this
     via `contentOffset`; replicate for AppKit using the scroll view's `documentVisibleRect`.
   - Position a lightweight tracking view (or compute a hot rect) at that frame.
3. The overlay shows an affordance on hover (a subtle "expand" glyph in the corner, like Warp's
   hover chrome), handles `mouseDown` for expand, and provides `menu(for:)` for the context menu
   ("Open in New Tab", "Copy Image", "Save As…").

**Bounds tracking during scroll/reflow** is the hard part. Make recomputation cheap and
event-driven:
- Observe `NSView.boundsDidChangeNotification` on the scroll view's `contentView` (clip view) —
  fires on every scroll tick.
- Observe SwiftTerm's content-change signal (its delegate fires on new output; hook the same
  place you refresh the title).
- On resize, `col` is stable but wrap can change `row`; SwiftTerm mutates `image.col/row` for
  you, so always read fresh values rather than caching positions.
- Throttle/coalesce recomputation to once per run-loop pass to avoid thrash during fast output.

Because `TerminalImage.col`/`row` are kept current by the engine, your overlay frames stay
correct as long as you recompute from them after each scroll/output event. That's the linchpin
that makes the no-fork route viable.

### Stage (b) — click-to-expand in place

When the overlay receives a click (single click → expand recommended; reserve double-click for
nothing, to avoid latency):

**Recommended presentation: a floating `NSPanel`/popover-style overlay anchored to the image
rect, layered above the terminal — NOT an expanded inline cell.** Growing a cell in place means
forking the layout engine or fighting reflow; an anchored floating preview leaves scrollback
untouched.

Mechanics:
- Present a borderless child `NSView`/`NSPanel` (your own, not a system popover, so you control
  blur/corners) sized to a larger preview — e.g. fit within
  `min(0.7 × terminalView.bounds, image native size)`, preserving aspect ratio.
- Animate from the inline rect to the expanded frame (quick scale/position spring) so the user
  sees *this* image growing, not a disconnected window.
- `NSVisualEffectView` behind it for blur/transparency; rounded corners; faint border.
- Collapse-back: click outside, Esc, or click the image again. Modeless; dismissal via a
  transparent click-catcher behind the panel but above the terminal.
- Sizing limits: never exceed the window's content bounds; if native > window, fit-to-window and
  let stage (c) handle true full-size/zoom.
- Do **not** reflow scrollback. The inline image stays underneath; expansion is purely overlay.

State to persist across expand/collapse: the source `TerminalImage` (or a decoded `NSImage`
copy), its inline rect at expansion time, and a toggle flag.

### Stage (c) — open in new child tab

A dedicated viewer is a `TabContent`-conforming controller wrapping an image surface:

```swift
final class ImageViewerController: NSObject, TabContent {
    let view: NSView                 // container with NSVisualEffectView + scrollable image
    var displayName: String          // file name or "Image"
    var restorableRecord: ...        // see §5
    var onTitleChanged: ((String) -> Void)?
    var onTerminated: (() -> Void)?
    func focus(in window: NSWindow) { ... }
    func cleanup() { ... }
}
```

Implementation notes:
- Back it with `NSImageView` inside `NSScrollView` for pan, or a CALayer-hosting view for
  GPU-cheap zoom. `NSImageView` with `.scaleProportionallyUpOrDown` covers fit; add a zoom
  slider / pinch / ⌘+/⌘− for zoom-to-pixels.
- **Animated GIF:** `NSImageView` animates GIFs natively with `.animates = true` fed the
  original GIF data (not a flattened snapshot). Preserve original bytes from the payload.
- **Transparency:** draw a checkerboard backing (image-viewer convention) so transparent PNGs
  read correctly, or honor the translucent background — checkerboard is clearer for design work.
- **Large images:** decode with `CGImageSourceCreateThumbnailAtIndex` for a fast thumbnail, then
  swap in full-res on demand; cap texture size and downsample beyond screen res to avoid VRAM
  spikes.
- Source bytes from the same decoded `TerminalImage` the overlay tracked (you may not have a
  path if it was streamed).

### Affordance summary (matches Warp's idiom)

| Transition | Affordance |
|---|---|
| inline → expanded | single click on the inline image (overlay), or hover-corner "expand" glyph |
| expanded → collapsed | click image again, click outside, or Esc |
| inline/expanded → new tab | right-click context menu → "Open in New Tab"; optionally ⌘-click |
| any → save/copy | context menu → "Save Image As…", "Copy Image" |

---

## 5. Child-tab insertion + parent/child model

Current gap: `insertTab(_:)` only appends. Add insert-at-index and a parent→child relationship.

**API additions on `TerminalWindowController`:**

```swift
func insertTab(_ content: any TabContent, at index: Int)          // primitive
func insertTab(_ content: any TabContent, after parent: any TabContent,
               linkAsChild: Bool = true)                          // convenience
```

`insertTab(_:after:)` finds the parent's index via identity, inserts the child at
`parentIndex + 1` (immediately right), selects it, and records the parent/child link.

**Parent/child link.** Since `TabContent` is a protocol on heterogeneous `[any TabContent]`,
track relationships *outside* the array to avoid forcing every conformer to carry linkage:

```swift
// Keyed by ObjectIdentifier of the controller instances.
private var childToParent: [ObjectIdentifier: ObjectIdentifier] = [:]
private var parentToChildren: [ObjectIdentifier: [ObjectIdentifier]] = [:]
```

Add a stable `id` to `TabContent` (e.g. `var tabID: UUID { get }`) if identity-by-pointer feels
fragile across restoration — recommended.

**Behavior on events:**
- **Parent closed:** either (i) close its viewer children too (tidy; "the viewer belongs to
  that session"), or (ii) orphan them. Recommend **close children with parent** for
  image/markdown viewers spawned from a session, with an optional guard for a child the user has
  interacted with heavily.
- **Reorder (`moveTab`)**: when the parent moves, optionally move its contiguous children with
  it (Warp-like "group" feel). v1 can skip this and just break adjacency gracefully.
- **Child closed:** remove from `parentToChildren`; no effect on parent.

**Persistence (`restorableRecord`).** Each viewer must serialize enough to rebuild:
- `ImageViewerController`: the image source. **Prefer a file path** when one exists; for streamed
  images with no path, persist a cached copy to app support
  (`~/Library/Application Support/FloatyTerm/restore/<uuid>.png`) and store that path. Restoring
  a multi-MB base64 blob inside the window state plist is a bad idea.
- `MarkdownViewerController`: the `.md` file path + view mode (rendered/editor) + scroll pos.
- Persist the parent link as `parentTabID` so adjacency re-establishes on relaunch (re-insert
  children after their parent during restore; if the parent is gone, append or drop per policy).

---

## 6. Concrete implementation plan

### New files
- `ImageOverlayManager.swift` — owns the overlay container, recomputes image hot-rects from
  `terminalView.images` + cell metrics, drives hover/click/context-menu, throttled to one pass
  per run loop. (Heart of stages a+b.)
- `ImagePreviewOverlay.swift` — the floating anchored expand/collapse panel (stage b), with
  NSVisualEffectView + spring animation.
- `ImageViewerController.swift` — `TabContent` full image viewer (stage c): scroll/zoom/fit,
  GIF, checkerboard, large-image downsampling.
- `MarkdownViewerController.swift` — `TabContent` markdown viewer: WKWebView (rendered) + reuse
  `NoteController` (editor) behind a toggle; JS bridge for runnable blocks (Phase 4).
- `FileLinkDetector.swift` — OSC 8-first, regex-fallback path/URL detection with Warp's line/col
  grammar; resolves relative paths against `hostCurrentDirectory`.
- `TabRelationships.swift` (or fold into `TerminalWindowController`) — parent/child maps +
  insert/close/reorder policy.

### Changed files
- `TerminalWindowController`
  - add `insertTab(_:at:)` and `insertTab(_:after:linkAsChild:)`,
  - add `childToParent` / `parentToChildren` (+ `tabID`),
  - implement parent-close cascade and (optional) child-follow-on-move,
  - wire restoration to re-link children to parents.
- `TabContent` protocol
  - add `var tabID: UUID { get }` (stable identity for linkage + restoration).
  - (optional) add `var parentTabID: UUID? { get }` if conformers should self-report.
- Terminal session view host (wherever SwiftTerm's `TerminalView` is embedded)
  - instantiate and attach `ImageOverlayManager`,
  - subscribe to scroll/content/resize notifications for overlay resync,
  - implement `TerminalViewDelegate.requestOpenLink` to route `.md`/image/file links through
    `FileLinkDetector` → open in child tab,
  - (Phase 3) watch executed command lines for `cat|glow|less|bat *.md` → "Open in viewer" banner.

### Detection trigger decision
Use **OSC 8 hyperlink → `requestOpenLink`** as the primary, authoritative click path (already
routed, unambiguous). Add a **path/URL regex over hovered line or selection** as fallback for
output lacking OSC 8, resolved against the OSC 7 working directory. Reserve the **command-name
banner** for the markdown convenience flow. Do **not** rely on a generic "click handler on the
whole terminal" for files — it conflicts with text selection; gate file activation behind CMD
(matching Warp and SwiftTerm's `.hoverWithModifier`).

For images specifically, the trigger is the **overlay**, not link detection — a streamed inline
image has no text/link to attach to.

### Phased rollout

**Phase 1 — inline image + click-to-expand.**
- Verify SwiftTerm renders `imgcat`-streamed images in your build (iTerm2 protocol path). Should
  work out of the box.
- Build `ImageOverlayManager`: map `terminalView.images` → hot rects, hover affordance,
  single-click → `ImagePreviewOverlay` expand, click-out/Esc/re-click → collapse.
- Nail bounds-tracking on scroll/resize/output (the main risk). Ship when expansion stays glued
  to the right image during fast scroll.
- *Risk flag:* if overlay tracking is too jittery under load, escalate to the SwiftTerm-fork
  hit-test route (§1.4 option 2).

**Phase 2 — open-in-new-child-tab + tab model.**
- Implement `insertTab(_:at:)` + `insertTab(_:after:)` + parent/child maps + close cascade.
- Build `ImageViewerController` (`TabContent`) with zoom/fit/GIF/large-image handling.
- Context menu on the overlay → "Open in New Tab" inserts the viewer adjacent to the session tab.
- Wire `restorableRecord` (cache streamed images to disk for restore).

**Phase 3 — markdown inline/expanded + dedicated viewer.**
- `FileLinkDetector` (OSC 8 + regex + working-dir resolution).
- `MarkdownViewerController`: WKWebView rendered view + `NoteController` editor + overflow-menu
  toggle; CSS theming for blur/transparency; table + code-highlight support.
- `cat|glow|less|bat *.md` banner → open viewer in child tab.
- (Optional) inline/expanded markdown preview reusing the overlay pattern, though markdown is
  usually better served by jumping straight to the pane/tab — consider skipping "inline
  markdown" and going pane-first like Warp.

**Phase 4 — runnable code blocks.**
- In the rendered WKWebView, render a `>_` button on fenced blocks whose language is empty or in
  `{sh, shell, bash, fish, zsh, warp-runnable-command}`.
- JS → native bridge (`WKScriptMessageHandler`) posts the block text; native inserts it into the
  **active terminal session's** input (not auto-run, matching Warp — insert, let the user press
  Enter).
- Keyboard nav: CMD-UP/DOWN select prev/next shell block, CMD-ENTER inserts the selected block,
  CMD-L returns focus to the terminal. JS key handlers + native menu items.
- Per-block copy button (cheap, do alongside).

---

## 7. Decision summary

| Decision point | Recommendation |
|---|---|
| Image protocols to rely on | iTerm2 inline-image (SwiftTerm-native). Treat Kitty as unverified — confirm in your build before promising it; may need a parser contribution. No Sixel UX needed. |
| Making inline images clickable | Overlay `NSView` route mapping `terminalView.images` (col/row/pixelW/pixelH) → hot rects. Fork SwiftTerm for a real hit-test only if overlay tracking is janky. |
| Click-to-expand presentation | Anchored floating overlay panel (NSVisualEffectView), animated from the inline rect. Never reflow scrollback. |
| Full image viewer | `TabContent` controller, `NSImageView`+`NSScrollView`, native GIF, checkerboard, thumbnail-then-fullres for large images. |
| Markdown renderer | md→HTML in `WKWebView` (reuse `BrowserController`), `swift-markdown`/`markdown-it` parse. Keep `NoteController` for the editor half of the toggle. |
| File/link detection | OSC 8 → `requestOpenLink` primary; path/URL regex (Warp's line/col grammar) fallback, resolved against OSC 7 working dir; CMD-gated activation. |
| Tab model | Add `insertTab(_:at:)` + `insertTab(_:after:)`; parent/child via `ObjectIdentifier`/`UUID` maps kept outside the `[any TabContent]` array; close children with parent. |
| Persistence | Viewers serialize a file path; cache streamed images to app-support for restore; persist `parentTabID` for adjacency. |

The one thing to validate before committing the plan: **stream an `imgcat` PNG and a Kitty `_G`
PNG into your current SwiftTerm build and watch what renders.** That single test confirms which
protocols you actually inherit and whether the overlay route's coordinate assumptions hold
against SwiftTerm's real layout.

---

## Local verification

> Filled in by grounding the report's load-bearing claims against FloatyTerm's pinned SwiftTerm
> and current delegate wiring. See the conversation that produced this file for the raw checks.

- SwiftTerm pin (Package.swift): declared `from: "1.2.0"`; **resolved to 1.13.0** (rev
  `8e7a1e154f470e19c709a00a8768df348ba5fc43`).
- iTerm2 OSC 1337 parser wired: **YES** — `EscapeSequenceParser.swift:541` → `osciTerm2`;
  handler documented at `Terminal.swift:1812`.
- Kitty graphics parser wired: **YES (corrects the report)** — `EscapeSequenceParser.swift:554`
  → `handleKittyGraphics`; full decoder in `KittyGraphics.swift`; state on
  `Terminal.swift:418` (`kittyGraphicsState`); Unicode placeholders in `KittyPlaceholder.swift`.
- `TerminalImage` protocol surface: `pixelWidth`, `pixelHeight`, `col {get set}` only — **no
  `row`** (`Terminal.swift:264`).
- macOS placed-images enumeration: **NOT public** — internal `ViewLineInfo.images`
  (`AppleTerminalView.swift:80`) + `BufferLine.images`; iOS-only public tuple array at
  `iOSTerminalView.swift:218`. Public Mac image API is ingest-only: `createImage` /
  `createImageFromBitmap` (`AppleTerminalView.swift:2044`, `:2067`).
- `TerminalViewDelegate.requestOpenLink`: exists + fires on Mac (`MacTerminalView.swift:2005`);
  **FloatyTerm does not implement it yet** (no override in TerminalController).
- `hostCurrentDirectory` / OSC 7: delegate `hostCurrentDirectoryUpdate` implemented but **empty**
  ([TerminalController.swift:694](../../Sources/FloatyTerm/TerminalController.swift:694)).
- iTerm2 `imgcat` render confirmed in-app: _TBD (requires running the app)_
- Kitty `_G` render confirmed in-app: _TBD (requires running the app)_
