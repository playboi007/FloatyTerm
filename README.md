# FloatyTerm

A lightweight, native macOS **floating terminal** that overlays every app —
including other apps' fullscreen Spaces. Summon it with a global hotkey, drag it
anywhere, and keep typing in whatever's underneath: it never steals focus and
never disappears until you dismiss it.

Built with AppKit + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). No
Electron, no web stack — it idles at near-zero CPU and ~30–60 MB RAM.

## Features

- **Floats over everything**, including native-fullscreen apps (Cursor, Safari, …)
- **Global hotkey** to show/hide (default **⌥⌘7**, reconfigurable)
- **Drag anywhere**; every window remembers its own position, size, and avatar
  style across launches
- **Tab reordering** — drag chips within the strip; drag out to tear off into a
  new window, or onto another window to merge
- **Browser tabs** (⌘B) — a lightweight in-app WebKit tab for docs and
  dashboards: smart URL/search bar (⌘L), back/forward, page zoom, and an
  optional transparent page background so the blur shows through (Preferences)
- **Pin to a Space** — the pin button links a window to the Space (and app)
  it's overlaying, so it stays there instead of following you around; ideal
  for parking an agent session over each project
- **Personalizable avatar bubbles** — right-click a collapsed window's bubble
  to pick its icon and ring color (each window keeps its own)
- **Session switcher (⌥⌘K)** — fuzzy-search every tab in every window and
  summon it to the Space you're on; tabs borrowed from a pinned window get a
  return arrow that sends them back where they came from (a single-tab window
  lends its session and waits on its Space, so Return restores it exactly).
  Each row shows exactly where the session lives — its window's avatar glyph,
  a window number, its state, and the app it overlays ("win 2 · in bubble
  (Chrome)") — and ✕ / ⌘⌫ closes a session right from the list
- **Summon grid** — pick which of nine screen positions summoned and borrowed
  windows land on (Preferences), so they never cover the terminal you're
  already watching
- **Live session labels & status** — tabs auto-name themselves from the running
  process ("flutter · myapp"), with right-click → Rename to override; dots show
  running (green) and unseen-output (blue) state on chips and bubbles
- **Ghost mode** — the eye-slash button makes a window click-through and faded
  (opacity configurable): watch logs hovering over your IDE while clicking
  through into your code; restore from the menu-bar icon
- **Ticker strips** — ⌥-click the collapse button to shrink a window into a
  one-line live strip showing the latest output; double-click to expand
- **Hold-to-peek** — tap the hotkey to toggle, hold it to peek (windows hide
  again on release)
- **Selection actions** — select terminal text to get a floating bar: copy,
  open (URLs / file paths, in-app browser or default app), web search, insert
  back at the prompt
- **Context Snap** — the camera button captures what's *behind* the window
  (click for full screen, or drag a ⇧⌘4-style region) into
  `~/.floatyterm/snaps` and types the file path at your prompt, so a terminal
  agent can see what you see; ⌥-click for OCR text mode with a review sheet
  to pick just the lines you want; right-click for snap history with
  thumbnails
- **Recent-commands palette (⌘R)** — fuzzy-search your zsh history and insert
  a command at the prompt; **⌘F / ⌘G** find-in-terminal
- **Per-window hide** — the − button tucks one window away (its sessions keep
  running); restore it from the menu-bar icon's Hidden Windows list
- **Live transcript reader** — the page icon in a terminal's corner opens a
  docked companion view of that session's output: smooth scrolling, native ⌘F
  search, auto-follow that pauses when you scroll up, updating live as the
  agent streams
- **Session restore** — quitting offers to save your windows; they reopen with
  their tabs (terminals in their last directory, browsers on their last page;
  Space-pinned windows are dropped)
- **Non-stealing focus** — click the app behind it and keep typing; the terminal stays put
- **Tabs** (with a strip that appears for 2+ tabs) and **multiple windows**
- **Adjustable transparency** + optional background **blur** (turn blur off for true see-through)
- **Dim-when-unfocused** with its own opacity, while the top bar stays as a reference
- **Copy / paste / select-all** (⌘C / ⌘V / ⌘A) and **⌘Z** line-editor undo
- **Menu-bar icon** and a **Preferences** window
- **Launch at login** (toggleable)
- Loads your real login shell, so your **zsh + Oh My Zsh** config works as-is;
  new tabs and windows can inherit the active terminal's working directory
  (Preferences)

## Requirements

- macOS 13 (Ventura) or later
- Xcode / the Swift toolchain (`swift --version`)

## Build & run

```sh
./build.sh        # compiles and assembles FloatyTerm.app
open FloatyTerm.app
```

`build.sh` signs the bundle with the first code-signing identity in your
keychain (e.g. a free "Apple Development" certificate; override with
`FLOATY_SIGN_ID`), falling back to ad-hoc if none exists. A **stable identity
matters if you use Context Snap**: the Screen Recording grant is keyed to the
app's code signature, and ad-hoc signatures change on every build — you'd be
re-prompted after each rebuild. Without a paid Developer ID the first launch
may show an "unverified developer" prompt — right-click the app → **Open**,
or allow it under **System Settings → Privacy & Security**.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌥⌘7 | Show / hide all windows (configurable); hold to peek |
| ⌥⌘K (or ⌘K in a window) | Session switcher — search every tab everywhere, summon it here |
| ⌥⌘5 | Spawn a window on the current Space |
| ⌘T / ⌘B / ⌘W | New terminal tab / new browser tab / close tab |
| ⌘1–9 | Jump to tab N |
| ⌘⇧[ / ⌘⇧] | Previous / next tab |
| ⌘N | New window |
| ⌘F / ⌘G | Find in terminal / next match |
| ⌘R | Recent-commands palette (terminal) · reload (browser) |
| ⌘L | Focus the address bar (browser) |
| ⌘+ / ⌘− / ⌘0 | Font size (terminal) · page zoom (browser) |
| ⌘, | Preferences |
| ⌘C / ⌘V / ⌘A | Copy / paste / select all |
| ⌘Z | Undo current command line (zsh line editor) |
| ⌥-click collapse | Collapse to a live one-line ticker strip |

## Permissions & privacy

FloatyTerm needs **no special permissions** by default — no Accessibility or
network access. The global hotkey uses the Carbon Hot Key API (which doesn't
require Accessibility), and floating over fullscreen is just a window setting.
Everything runs locally against your own shell.

One optional exception: **Context Snap** (the camera button) captures what's
behind the window so a terminal agent can read it. That requires the Screen
Recording permission, requested only the first time you use it. OCR runs
locally via the Vision framework; snapshots stay in `~/.floatyterm/snaps/`
(last 20 kept).

## License

Dependencies: SwiftTerm (MIT).
