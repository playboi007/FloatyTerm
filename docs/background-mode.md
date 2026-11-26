# Background mode — concurrent human ↔ agent GUI work on one Mac

## Goal

The user and an agent use different apps on the same Mac at the same time,
without a VM. Example: the user writes code in Cursor on display A, while the
agent tests a Flutter web app in Chrome on display B. Neither takes the other's
frontmost app, keyboard focus, or pointer.

Foreground mode (the default, unchanged) posts HID-level CGEvents and activates
the target first. That path is reliable, but it takes the frontmost app and moves
the real cursor. Background mode uses element-addressed Accessibility actions and
process-targeted events instead. Isolation depends on the app, so it can't be
guaranteed. The host measures it on every call and reports it.

## Experiment 1 — 2026-10-09

**Setup.** Cursor frontmost on the external display (the user working in it
during the test). Chrome window on the built-in display. A standalone Swift probe
(run from FloatyTerm's terminal, so it had FloatyTerm's AX grant) recorded the
frontmost app, the cursor position, and the frontmost app's focused element
before and after each action. A second run used a sampler that read the
frontmost app every 50 ms.

**Results.**

| Action | Works in background | Interference |
|---|---|---|
| Read the Chrome web tree via AX | Yes (first build 2–5 s after `AXEnhancedUserInterface`) | None |
| `AXPress` button, link, off-viewport element | Yes (page sees `isTrusted` clicks) | None |
| `AXScrollToVisible` | Yes | None |
| `AXSetValue` on an HTML input | Yes (`input` event) | None |
| `AXSetValue` on a Flutter text field | **No** (Flutter ignores it) | None |
| `AXFocused` on a field | Yes | None |
| `CGEventPostToPid` keyboard (text, Return) | Yes, also into Flutter after an `AXPress` on the field | None |
| Address bar: `AXFocused` + `AXSetValue` + pid Return | Yes (navigated to the Flutter app) | None |
| Flutter: press nav item → press search field → type → Return | Yes (list filtered to the typed product) | Cursor frontmost for the whole 9 s sample |
| `CGEventPostToPid` mouse click | **No** (Chrome ignores it) | — |
| `AXUIElementCopyElementAtPosition` (point → element) | Yes | None |
| `open -g -a "Google Chrome" URL` | — | **Activated Chrome** |
| AppleScript `make new window` | — | **Activated Chrome**; window opened on a hidden Space |
| AppleScript `make new tab` | No activation | Tab went to a window on another Space |
| Windows on another Space | **Not reachable** (AX lists only active-Space windows) | — |

**Conclusions that shaped the design.**

1. Clicks must be AXPress, not synthetic mouse events. A coordinate click becomes
   "AXPress the control under this point" through the hit-test.
2. Keyboard input can go to a process (`CGEventPostToPid`). But it lands in that
   app's **key window**, which can be the user's own window of the same app. So
   the host checks the key window before it posts keys.
3. Window creation and URL opening from outside activate Chrome. Navigation goes
   through the address bar's AX element. Windows are set up before the run.
4. The agent's window must be on a visible Space. Background mode never raises.
5. Flutter needs press-then-type. `AXSetValue` reaches the DOM input but not
   Flutter's text-editing state.

## Experiment 2 — Electron, 2026-10-09

**Setup.** An instrumented Electron 44.7 test app on the built-in display,
shown with `showInactive()`, with CDP on port 9333. The page logged every event.
Terminal was frontmost (the user clicked into the test app once, during the
postToPid-mouse run). Full matrix: `/tmp/bgelectron/RESULTS.md`.

| Action | AX | postToPid mouse | CDP `Input.*` |
|---|---|---|---|
| Hover | none | fail | **pass** (CSS :hover applied) |
| Click | **pass** (also on a `div` that advertises no AXPress) | fail | **pass** |
| Double-click | none (two presses = two single clicks) | fail | **pass** |
| Right-click | **pass** (`AXShowMenu` → `contextmenu`) | fail | **pass** (button 2 + `contextmenu`) |
| Wheel scroll | none (no AXScrollArea for an overflow `div`) | fail | **pass** |
| Pointer drag | none | fail | **pass** |
| HTML5 drag-and-drop | none | — | **pass** (`setInterceptDrags` → `dispatchDragEvent`) |
| Type | `AXSetValue` pass; pid keys only after `AXMain` | — | **pass** |

No AX or CDP action changed the frontmost app or moved the cursor.

**Conclusions.**

1. For Chromium and Electron web content, CDP input covers all five
   pointer actions that AX cannot do: hover, double-click, wheel, drag and
   HTML5 drag-and-drop. It is renderer-level input: no OS pointer, no
   activation. Plain CDP worked on a visible, unfocused window; the
   focus-emulation calls were not needed.
2. Mouse events posted to a process do nothing in Chromium/Electron, whether or
   not the window-number fields are set, and even with the app frontmost.
3. An app that was never activated has no key window (`AXFocusedWindow` =
   none), so pid-posted keys go nowhere. `AXMain = true` on the window makes it
   key without activating the app. Electron still reports no focused element
   after that, so the key window is the reliable signal.

**Fixes made from this run.** `keyRoute` now decides from `AXFocusedWindow`,
with `AXMain` as the fix when there is no key window. Type verification falls
back to the element the agent last pressed or focused. A background click on
an element that advertises no `AXPress` tries `AXPress` on it anyway.

## Design (built)

- **Mode selection.** `--background` / `--foreground` per call, or
  `FLOATY_MODE=background` for a session. The CLI sends `mode` in the body. The
  host default is foreground.
- **`AgentBackground.swift`.**
  - `press(at:pid:)`: hit-test, then prefer the control ancestor, then AXPress.
    It refuses surfaces (web area, large unnamed groups), because Chromium's
    AXPress clicks an element's center, not the point the agent asked for.
  - `keyRoute(pid:)`: posts keys only when the app's focused element is in an
    on-screen window that is the window the agent last acted in. If not, it tries
    `AXMain` on the agent's window (no activation). If that fails, it refuses.
  - `postText` / `postKey`: `CGEventPostToPid` with a private event source.
  - `navigate(pid:url:)`: address bar via AX. A URL change (redirects included)
    counts as committed.
- **`FocusShield`.** It records the frontmost app before each background action
  and checks it 180 ms after. If the target became frontmost, it gives focus back
  through `AXFrontmost` on the user's app. It stays armed for 1.5 s for late
  self-activation. It stands down when the user made a physical mouse click (the
  user chose that app). Every reply carries
  `interference: {human_app, focus_kept[, stolen_by_target, restored, late_restores]}`.
- **Refusals.** `move`, `drag`, `scroll`, right/double/modified clicks, `raise`,
  `focus`, `enable-cdp`, and `type`/`key` into a frontmost target. Each returns
  `needs_foreground: true` with a hint. Nothing falls back silently.
- **Element actions on `query-ax`** (both modes): `--press`, `--focus`,
  `--set-value`, `--scroll-to`, `--action <AXAction>`. In background mode the
  search is limited to the agent's window.
- **`run` plans.** The mode merges into every step. `drag`/`scroll` steps are
  refused before any step runs. The ledger records `focus_kept` per step, and the
  endgame records `focus_steals`.
- **Trace.** `calls.ndjson` records `mode`, `via`, `interference`, `landed`,
  `needs_foreground`.

## Experiment 3 — input speed and trusted page input, 2026-10-09

**Trigger.** An agent played a score on onlinepianist.com in background mode.
Each note cost 0.35–0.5 s, so the tempo could not be kept. Black keys went to
the wrong key, and events dispatched from page JavaScript did nothing.

**Where the time went** (agent-measured end to end; host time from
`calls.ndjson`, n = 815 background clicks, 238 background keys):

| Part | Before | Cause |
|---|---|---|
| CLI process start | ~100–150 ms | bash, then 3 `python3` starts, then 1–2 `curl` starts (background added a probe) |
| Relay round trip | ~1 ms | — |
| Host: background click / key | 196 / 199 ms | a fixed 180 ms `FocusShield` wait; the real work was ~16 ms |
| `run` step with no `expect` | +300 ms | a fixed pause |
| Foreground click / key | 60 / 46 ms | a 40 ms settle in `activate()`, paid even when the target was already in front |

**Changes.**
- The CLI is one Python process (`-I -S`, raw socket, no `http.client`, whose
  import alone costs ~14 ms). Same flags and bodies as before (26 parity cases).
  A call is ~30 ms end to end, of which ~20 ms is Python start.
- `FocusShield` waits 180 ms only until an app has done 3 clean background
  actions; then it checks at once. The 1.5 s observer still undoes a late steal
  (and resets that app's count).
- `activate()` returns at once when the target is already frontmost.
- `run`: `--pace MS` / a step's `"pause"` replace the fixed 300 ms;
  `--no-capture` skips the final PNG.
- Background `click`: when the AX control at the point does not cover the point
  (Chromium presses an element at its centre, so a piano's black keys pressed
  the white key beside them), the host refuses instead of pressing the wrong
  control.
- New verb `input` (`CDPInputScript` + `AgentCDPInput`): a timed script of CDP
  `Input.*` events through the extension or a debug port. The page gets trusted
  events (`isTrusted: true`). Selectors resolve once, and the timeline runs on a
  detached task with a continuous clock. Holds are measured from the real press.
  Anything still down at the end, or after a failure, is released.

**Measured** (headless Chrome, debug port, the real executor compiled into a
test binary, a page that logs every event):

| Check | Result |
|---|---|
| All events trusted | 40 / 40 |
| Black key under a white key, by selector | correct key |
| Hover, shift-click, double-click, right-click, wheel, pointer drag, typing, insertText | pass |
| 24 notes 100 ms apart — page-side spacing error | median 1.1–1.8 ms, max 4–5.6 ms |
| 3-key chord — spread of the keydowns | 1.7–3.8 ms |
| Key held 100 ms behind a burst of 20 events | 102 ms |
| Script ending with a key and a button down | both released, reported |

Not yet measured: the extension path (adds the WebSocket hop and
`chrome.debugger`; `eval --via-extension` round trips are 2–4 ms host-side), and
whether `chrome.debugger` key events reach a page whose window is not focused
(they do over a plain debug port on Electron, Experiment 2). HTML5
drag-and-drop needs `Input.dragIntercepted` events, which the bridge does not
forward, so `drag` is a pointer drag only.

## Status and next steps

- Built and signed. Live verification of the integrated host path (as opposed to
  the standalone probe) is still to do: run test case **B1** in
  `docs/floaty-test-cases.md` after a relaunch, then B4 (two windows of one app).
- Not yet measured: whether `AXPress` on a field makes Chrome switch its internal
  key window between two windows (B4 tests this; the guard refuses if it doesn't).
- Gaps: hover, double-click, wheel scroll and drag are still refused by the
  pointer verbs in background mode; on web pages `input` covers them
  (Experiment 3). Native apps (Notes, System Settings) are not measured yet.
  Native canvas apps stay foreground-only.
- Possible later work: a visible "agent is driving" frame on the agent's
  display, and assigning a display to each agent.
