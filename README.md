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
- **Personalizable avatar bubbles** — right-click a collapsed window's bubble
  to pick its icon and ring color (each window keeps its own)
- **Session switcher (⌥⌘K)** — fuzzy-search every tab in every window and
  summon it to the Space you're on; tabs borrowed from a pinned window get a
  return arrow that sends them back where they came from
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
- Loads your real login shell, so your **zsh + Oh My Zsh** config works as-is

## Requirements

- macOS 13 (Ventura) or later
- Xcode / the Swift toolchain (`swift --version`)

## Build & run

```sh
./build.sh        # compiles and assembles FloatyTerm.app
open FloatyTerm.app
```

`build.sh` ad-hoc signs the bundle. Because it isn't signed with a paid Apple
Developer ID, the first launch may show an "unverified developer" prompt —
right-click the app → **Open**, or allow it under
**System Settings → Privacy & Security**.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌥⌘7 | Show / hide all windows (configurable) |
| ⌥⌘K (or ⌘K in a window) | Session switcher — search every tab everywhere, summon it here |
| ⌥⌘5 | Spawn a window on the current Space |
| ⌘T / ⌘W | New tab / close tab |
| ⌘1–9 | Jump to tab N |
| ⌘⇧[ / ⌘⇧] | Previous / next tab |
| ⌘N | New window |
| ⌘, | Preferences |
| ⌘C / ⌘V / ⌘A | Copy / paste / select all |
| ⌘Z | Undo current command line (zsh line editor) |

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
