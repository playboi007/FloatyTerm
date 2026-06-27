# FloatyTerm Agent Host

FloatyTerm doubles as an **agent host**: a terminal agent drives the macOS UI
through simple `floaty …` commands, and FloatyTerm handles the OS-level work
(permissions, coordinates, event injection) so the agent never touches CGEvent
C code or fights window focus.

This is the as-built reference. The transport is the existing loopback relay
(`DevtoolsRelay`, `127.0.0.1:7777`) — the same one `ftdiff` uses — extended with
`/agent/*` routes. No second IPC mechanism.

## The fallback ladder

The agent wants to "target an element and act on it." How it targets depends on
what the target app is. Three buckets collapse to one action sink (Layer B):

```
  target an element
     │
     ├─ Chromium / Electron?  (web pages, AND VS Code, Cursor, Slack desktop)
     │     → Layer A / CDP  (floaty query-dom)        exact, fast
     │
     ├─ Native AppKit?  (Notes, Finder, system dialogs)
     │     → Layer A-native / Accessibility tree (floaty query-ax)   STUB
     │
     └─ Canvas / GPU?  (Flutter desktop, games — no DOM, no useful AX tree)
           → Layer C / capture + vision (floaty capture)   approximate, universal
              │
              └──────────────► all three yield a screen (x, y) ──────────►
                                Layer B / input injection (floaty click / type / key)
```

**VS Code, Cursor, Slack are all Electron = Chromium**, so they speak the same
CDP protocol as Chrome — they just need a debug port. `query-dom` handles them
with the same code path; only the port differs:

| App        | Launch flag                          | `query-dom --port` |
|------------|--------------------------------------|--------------------|
| Chrome     | `--remote-debugging-port=9222`       | 9222 (default)     |
| VS Code    | `code --remote-debugging-port=9223`  | 9223               |
| Cursor     | `cursor --remote-debugging-port=9224`| 9224               |
| Slack      | `--remote-debugging-port=9225`       | 9225               |

An app must be **launched** with the flag — you can't attach to an instance
started without it. Native apps (Notes etc.) have no port; that's the (stubbed)
`query-ax` Accessibility path. Flutter/canvas falls back to `capture` + vision.

## Source layout

| File | Layer | Status |
|------|-------|--------|
| `Sources/FloatyTerm/AgentInput.swift` | **B** — mouse (click/move/drag/scroll/down-up, multi-click, modifiers) + keystrokes, optional human pacing, Accessibility gate. Mouse logic adapted from socsieng/sendkeys (Apache-2.0), in-process. | Complete |
| `Sources/FloatyTerm/AgentCapture.swift` | **C** (`AgentCapture`, reuses `ContextSnap`) + **A-native** (`AgentAX`, stub). | Capture complete; AX stubbed |
| `Sources/FloatyTerm/AgentDOM.swift` | **A / CDP** (`AgentDOM`) — discovery + WebSocket + coordinate transform. | Complete |
| `DevtoolsRelay.swift` | `onAgent*` callbacks, `/agent/*` switch cases, `agentSync`/`agentAsync` bridges. | Wired |
| `AppDelegate.swift` | Closure wiring + body-parsing helpers (`pacing`/`point`/`button`/`mods`/`target`). | Wired |
| `scripts/floaty` | Thin CLI (bash + python3 + curl). | Install per below |

## Install the CLI

```sh
cp scripts/floaty ~/.local/bin/floaty && chmod +x ~/.local/bin/floaty
# or anywhere else on PATH (e.g. /usr/local/bin with sudo)
```

The CLI holds no permissions: the long-running FloatyTerm.app holds the
Accessibility + Screen Recording grants (keyed to its code signature), which is
why this is a thin client and not its own signed binary.

## Permissions

Layer B (`CGEvent` injection) requires the macOS **Accessibility** (TCC) grant —
the first FloatyTerm feature to need it (HotKey uses Carbon to avoid it,
ContextSnap only needs Screen Recording). `AgentInput.ensureAccessibility()`
gates every input command, modeled on `ContextSnap.ensurePermission`: it checks
`AXIsProcessTrusted()`, triggers the system prompt, and offers an **Open System
Settings / Relaunch** alert. The grant only applies to a freshly-launched
process and is keyed to the code signature — so build with `build.sh` (stable
identity), not an ad-hoc signature, or the grant won't persist across builds.

Dropped CGEvents are silent — an ungranted injection looks identical to a
successful one — so the commands return an explicit error when the grant is
missing. Capture routes through the existing `ContextSnap.ensurePermission`
(Screen Recording), unchanged.

## Security model

The relay binds `127.0.0.1` only (`NWParameters.requiredLocalEndpoint`). The
`/agent/*` routes synthesize input and read the screen as the user, so they must
never be reachable off-localhost. They're called by `curl` from the CLI, not a
browser, so they don't rely on the relay's CORS headers. If you ever expose this
beyond loopback, add a token handshake first — but the right answer is: don't.

## Pacing

Every input command accepts an optional pacing hint:

- `--human` — human-paced over a default duration.
- `--duration N` — human-paced over N seconds (implies `--human`).
- absent — instant (agent default).

Pacing is a reliability knob, not just cosmetic: autocomplete menus need
keystroke gaps to populate; drag targets only fire if the cursor actually
travels (so `drag` always emits at least one intermediate event, even instant);
momentum/scroll UIs overshoot on one big instant scroll. Movement uses
ease-in-out; typing uses a ~60ms base delay with mild jitter.

## Smoke tests

```sh
# Relay reachable? (first input run pops the Accessibility prompt → grant → relaunch)
floaty key --key escape

# Keystrokes & text
floaty type --text "hello from the agent" --target "Notes"
floaty type --text "slow and human" --human --target "Notes"
floaty key  --key v --modifiers cmd --target "Cursor"

# Mouse
floaty click --x 200 --y 200
floaty click --x 200 --y 200 --button right
floaty click --x 200 --y 200 --clicks 2          # double-click
floaty click --x 200 --y 200 --modifiers cmd     # cmd-click
floaty move  --x 600 --y 300 --duration 1.0
floaty drag  --from-x 100 --from-y 100 --to-x 500 --to-y 100 --duration 0.8
floaty scroll --dx 0 --dy 600 --duration 0.5

# Capture a window for the vision model
floaty capture --window "Flutter"
floaty capture --window "Flutter" --ocr

# Locate an element via CDP, then click its center
floaty query-dom --selector "textarea[name=q]"
floaty query-dom --selector ".monaco-editor" --port 9224
```

A typical agent loop: `query-dom` (find target) → `click` (focus) → `type`
(enter text) → `key --key return` (submit) → optionally `capture` to verify.

## CLI error semantics

Legitimate failures (element not found, port closed, missing permission) come
back as HTTP 400 with a JSON `{"error":…}` body — those are real answers, not
transport faults, so the CLI prints the body and exits non-zero. Only a
connect-level failure (relay unreachable, curl status 000) prints "FloatyTerm
not reachable". The two are never conflated.

## What's left

- `AgentAX.screenRect` — native-app targeting via the Accessibility tree (stub +
  outline in `AgentCapture.swift`). Needs the same grant Layer B already takes,
  so no new permission. Add a `/agent/query-ax` route mirroring `query-dom`.
- Optionally cache the CDP WebSocket per port. The current cut opens a
  short-lived session per query — simpler, slightly slower.
- query-dom resolves elements in the main frame only; cross-iframe elements need
  per-frame execution contexts (out of scope for v1).
