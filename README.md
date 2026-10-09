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

- macOS 14 (Sonoma) or later
- Building from source requires Xcode / the Swift toolchain (`swift --version`)
- Claude/Codex tabs require Node.js and the corresponding installed,
  authenticated CLI (`claude` / `codex`)

## Build & run

```sh
./build.sh        # compiles and assembles FloatyTerm.app
open FloatyTerm.app
# Include the optional Claude rich renderer and its SDK dependencies:
./build.sh --RichRenderer-claude
# Include all optional components (currently Claude rich rendering):
./build.sh --all
```

`build.sh` signs the bundle with the first code-signing identity in your
keychain (e.g. a free "Apple Development" certificate; override with
`FLOATY_SIGN_ID`). Without an identity, explicitly set `FLOATY_ALLOW_ADHOC=1`
for a local test build. A **stable identity
matters if you use Context Snap**: the Screen Recording grant is keyed to the
app's code signature, and ad-hoc signatures change on every build — you'd be
re-prompted after each rebuild. A local package may be blocked on first launch;
use **System Settings → Privacy & Security → Open Anyway** if macOS offers it
and you trust the package.

## DMG releases and updates

Create a local test installer:

```sh
./scripts/package-dmg.sh --local
# Next release (or edit the two version fields in Info.plist first):
./scripts/package-dmg.sh --local --version 0.1.1 --build 2
# Same release, with the Claude rich renderer extra bundled:
./scripts/package-dmg.sh --local --version 0.1.1 --build 2 --RichRenderer-claude
# Include all optional components:
./scripts/package-dmg.sh --local --version 0.1.1 --build 2 --all
```

`Info.plist` is the default version source: `CFBundleShortVersionString` is
the public `X.Y.Z` version; `CFBundleVersion` is a positive, increasing build
number. Command-line overrides affect the packaged app, leaving the source
plist unchanged. Increase the build number for every shared build, including
rebuilds of the same public version. **About FloatyTerm** in the menu bar shows
the installed version and build.

Each core release creates `dist/FloatyTerm-VERSION-BUILD-ARCH/` containing the DMG,
`SHA256SUMS`, and `BUILD.txt` (commit, worktree changes, and signing details).
Claude-enabled releases append `-claude` to the directory and DMG name, so both
variants can coexist. `--RichRenderer-claude` and `--all` currently create the
same variant; `--all` will include any future optional components too.
The command refuses to overwrite an existing release. It compiles for the
build Mac's architecture: `arm64` for Apple silicon, `x86_64` for Intel. The
current Apple-silicon package is not an Intel installer. The default build
excludes the entire ClaudeSidecar directory and does not require npm. When
selected, production Claude SDK dependencies are installed from the lockfile
into the new bundle. Node.js and the user’s CLI installations and credentials
are not bundled. The shared renderer and dependency-free Codex sidecar remain
in the core app.

To add Claude rich rendering later, replace the core app with the Claude-enabled
DMG of the desired version. The optional component is selected at build time;
installing the expanded app preserves its code signature. The core build's
Claude tab explains how to get the extra rather than loading a sidecar from a
local source checkout. The ordinary terminal can still run an installed `claude`
CLI without the rich renderer extra.

To install, open the DMG and drag **FloatyTerm.app → Applications**. Eject the
DMG and launch from Applications. To update, quit FloatyTerm from its menu bar,
save sessions if prompted, then repeat the drag and choose **Replace**.
Preferences, notes, and snapshots live outside the app bundle. Updates are
manual; automatic in-app updates are not included in this release workflow.

For distribution with Apple notarization, install a **Developer ID Application**
certificate and store your notarization credentials in Keychain using
`xcrun notarytool store-credentials FloatyTerm-notary`. Then run:

```sh
FLOATY_SIGN_ID='Developer ID Application: Your Name (TEAMID)' \
  ./scripts/package-dmg.sh --notarize FloatyTerm-notary --version 0.1.1 --build 2
```

This mode uses the hardened runtime and timestamped signing, submits the app
and DMG to Apple, staples their tickets, and verifies them. It requires network
access and working Apple credentials. A local/ad-hoc or Apple Development
certificate does not replace Developer ID distribution signing. See Apple's
[packaging guide](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)
and [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

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
