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
- **Drag anywhere**; remembers its position and size
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
| ⌘T / ⌘W | New tab / close tab |
| ⌘1–9 | Jump to tab N |
| ⌘⇧[ / ⌘⇧] | Previous / next tab |
| ⌘N | New window |
| ⌘, | Preferences |
| ⌘C / ⌘V / ⌘A | Copy / paste / select all |
| ⌘Z | Undo current command line (zsh line editor) |

## Permissions & privacy

FloatyTerm needs **no special permissions** — no Accessibility, Screen
Recording, or network access. The global hotkey uses the Carbon Hot Key API
(which doesn't require Accessibility), and floating over fullscreen is just a
window setting. Everything runs locally against your own shell.

## License

Dependencies: SwiftTerm (MIT).
