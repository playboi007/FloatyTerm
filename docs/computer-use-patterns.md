# Patterns from Claude's browser and computer toolsets — what floaty should take

Sources (read 2026-10-09):
- docs: `agents-and-tools/tool-use/browser-use-sdk`, `browser-use-tool`, `computer-use-tool`
- example drivers: `anthropics/claude-quickstarts` → `browser-toolset/` (raw CDP, one
  Chromium tab) and `computer-toolset/` (raw VNC)

Floaty does not adopt the SDK. This note lists the SDK's patterns and implementation
details, compares each with floaty, and says which ones to move into floaty.

## How the toolsets work

- **Tools.** The model sees one tool per action, such as `left_click`, `read_page` or
  `hold_key`. A driver (your code) runs each call. The SDK runs the loop, the
  policies and the approvals.
- **Browser targets.** A target is a `ref` (`ref_3`, from `read_page` / `find`) or
  `{x,y}` in viewport pixels.
- **Computer targets.** A target is a pixel in the last screenshot. A missing
  coordinate means "at the cursor".
- **Batches.** The model can send several calls in one turn. They run in order. At
  the first failure, every later call gets the exact text `Not executed: an earlier
  action in this turn failed.`
- **State report.** Every successful browser result ends with a `browser_state`
  block: all tabs, plus `state_changes` since the last report (tab opened, download
  events, navigations refused, dialogs dismissed).
- **Results.** Results are short: `Clicked.`, `Navigated to {url} — {title} (HTTP
  200)`, one image, or a string.

## Comparison

`Take` = move into floaty. `Have` = floaty already does it as well or better.
`Skip` = not right for floaty.

| # | Pattern (SDK / example driver) | Floaty today | Verdict |
|---|---|---|---|
| 1 | **Stable element refs.** `read_page` stores `ref → element` in the page (`WeakMap` both ways). The same element keeps its ref on every read. A click resolves the ref when it runs: `isConnected` check, `scrollIntoView({block:'center'})`, then the centre. Error: "Unknown or stale ref: ref_3. Call read_page again for current refs." | `som` marks are numbers inside one frame. `click-mark` uses the screen centre that was stored at `som` time, with a staleness guard on URL and scroll. A mark is not the element. `input` selectors are measured once, before the clock starts. | **Take.** Refs for CDP (in-page map) and for AX (the host keeps the `AXUIElement` per ref). `click-mark`, `input` and `query-ax` accept a ref and resolve it when they act. |
| 2 | **Hover before press.** The CDP click sends `mouseMoved`, then `mousePressed` / `mouseReleased`. | `input` `click` sends press/release only. Pages that need `pointerenter` / `mouseover` before a press can miss the click. | **Take** (small). |
| 3 | **Scroll into view when acting.** The ref resolver scrolls the element to the centre. | `input` refuses a selector outside the viewport. | **Take**, as the default for selector/ref targets; `[x,y]` points stay exact. |
| 4 | **Refuse, never clamp.** "A point off the screen is refused, not clamped, so the model sees its mistake." `wait` > 30 s, a huge `repeat` or `scroll_amount` are refused too. | `click-in-frame` checks the frame. Plain `click` / `move` / `drag` / `scroll` do not check that the point is on any display. | **Take**: refuse points that are on no display; bound `duration`, `--clicks`, scroll size. |
| 5 | **Key syntax that models already use.** `key` takes `"ctrl+s"`, a sequence `"Tab Tab Enter"`, `repeat` 1–100. Names such as `Return`, `Page_Up`, `super`. | `--key s --modifiers cmd`. A chord string or sequence fails with "not a known key". There is no repeat. Fewer aliases. | **Take**: accept `cmd+s`, sequences, `--repeat N` and the X11-style aliases, in `key` and in `input`. |
| 6 | **Navigate waits for the document.** CDP `Page.navigate`, then wait for `Page.lifecycleEvent` `DOMContentLoaded` with the same `loaderId` (30 s cap). It returns the URL, title and status. | CDP `navigate` returns as soon as `Page.navigate` returns. The next call can read the old page. (The AX address-bar path in background mode does wait.) | **Take**: wait for load. The extension does not forward events, so poll `document.readyState` and `location.href`. |
| 7 | **URL schemes.** The driver must refuse `javascript:` (runs script even with `javascript_exec` off), `file:` (reads local files), `data:` and `view-source:`. | `navigate` passes any URL. | **Take**: allow only `http`, `https` and `about:blank`, unless the call passes `--allow-scheme`. |
| 8 | **State delta on every reply.** `state_changes`: tab opened, download started / completed / failed, navigation refused, dialog dismissed. The model learns what changed without another look. | Background replies carry `interference`. `som --diff` and `query-ax --diff` give deltas on request. No reply says "a new window or dialog appeared" or "the URL changed". | **Take**: a small `changes` field on actuator replies: new / closed windows of the target, frontmost app change, tab URL/title change, a JS dialog, a download. Host-side, computed against the previous call. |
| 9 | **Dialogs.** The driver dismisses native JS dialogs (`alert` / `confirm` / `prompt`) and reports `dialog_dismissed` with kind and message. Without this, "every later call fails after 60 seconds". | Not handled. A JS dialog blocks `eval`, `input` and `som` until their timeouts. | **Take**: on a CDP timeout, check for a dialog (`Page.handleJavaScriptDialog`, or event forwarding in the extension) and report its text. Accept or dismiss only when the call asks for it. |
| 10 | **`find`.** A natural-language query ("add to cart button") returns up to 20 matches with refs. | `query-ax --title` and `query-dom --selector` need an exact substring or selector. | **Take** (medium): rank by words over name/role/description/placeholder, return the top 20 with refs. |
| 11 | **`read_page` options.** `filter`: `interactive` / visible (default) / `all` (includes off-screen). `depth` (default 15), `ref` (one subtree), a 50,000-character cap that says it cut. | `som` / `query-ax` have `--max`, `--role`, `--title`, `--brief`. No subtree read, no "off-screen too" switch, and no stated cut. | **Take**: `--interactive`, `--all`, `--under REF`, and a `truncated:true` note. |
| 12 | **`form_input` by ref.** Set a control's value (string / number / bool) on the element, not the focus. | `set-text` writes the FOCUSED field. `query-ax --set-value` sets the first match. | **Take**, with #1: `--set-value` on a ref. |
| 13 | **Short results.** `Clicked.`; the state block carries the rest. | JSON with many fields (`screen_x`, `pressed.center_x`, …). Every field costs tokens on every call. | **Take** (low): drop fields that echo the input; keep verdicts (`landed`, `interference`, `changes`). |
| 14 | **Approval gate (`confirm`).** Runs before every consequential call. It must be passed when `javascript_exec` or `file_upload` (browser) or `type` / `key` / `hold_key` (computer) are on. "Fail closed" = approve only read-only tools and ask for the rest. A refused call reads "The user did not grant permission … Do not retry it unless the user asks you to." | No gate. Floaty drives the user's live, signed-in session, where a gate matters more. | **Take**, opt-in per session: a policy file (verbs to ask about, allowed hosts). The ask is shown in FloatyTerm's HUD. The refusal text tells the agent not to retry. |
| 15 | **Terminals are dangerous targets.** "When a terminal has keyboard focus, `type`, `key` and `hold_key` run whatever Claude types." | The skill warns ("don't cancel yourself"). Background mode keys go to one pid. Foreground keys can still land in a terminal. | **Take**: refuse foreground `type`/`key` when the frontmost app is a terminal, unless the call names it with `--target` / `--pid`. |
| 16 | **Model-free exercise script.** `exercise.py` serves a local page, sends the exact calls a model would send, prints each result as the model sees it, and fails on any difference. No API key. | Manual tiers in `docs/floaty-test-cases.md`. The `input` harness (headless Chrome + logging page) exists only in /tmp. | **Take**: commit `dev/exercise` — a headless Chrome on a test page, floaty verbs through the relay, exit non-zero on regression. |
| 17 | **Batch failure rule.** In order; stop at the first failure; every later call answered "Not executed". | `run` stops at the first divergence and returns the failed step. `input` stops, releases held input, reports the step. | **Have.** |
| 18 | **`zoom`.** A region at full resolution; later points stay in the full screenshot's space. | `capture --region` (its own frame) + `click-in-frame` inverts any frame exactly. | **Have** (better: no shared coordinate space to keep in step). |
| 19 | **Image size and scaling.** The driver scales screenshots and maps coordinates back. Retina is 2×. Limits: 2576 px long edge / ~3.75 MP on current models; over 20 images in a request → each side ≤ 2000 px. Recommended 1280×800 for web. | Frames downscale to ~1440 px and invert exactly. | **Have.** Keep ≤ 2000 px per side. |
| 20 | **Screenshot history.** About 1,000–1,800 tokens per screenshot. Prune in batches (keep the last 3, every 25 turns) or use server-side tool-result clearing. | `--if-changed`, `--region`, table-first `som`, `--diff`, `--wait-change` avoid most screenshots. | **Have** (floaty avoids them instead of pruning them). |
| 21 | **Fixed sleeps for settling.** 100 ms after a CDP click; 500 ms before every VNC screenshot. | `--settle`, `--wait-change`, `run` checkpoints wait for the real change. | **Skip** — floaty's way is better. |
| 22 | **Hold / drag primitives.** `hold_key` (≤ 30 s browser / 300 s computer), `left_mouse_down/up`, `left_click_drag`. | `input` holds, `down`/`up`, `drag`, with exact timing and release on failure. | **Have** (better: timed scripts, chords). |
| 23 | **Isolation.** A dedicated container or VM, a fresh signed-out profile, egress rules. | Floaty's purpose is the user's live session. | **Skip** as a default. Items 7 and 14 are the parts of it that fit. |
| 24 | **Prompting tips.** Text before the image. Keyboard shortcuts for dropdowns and scrollbars. End each group of actions with one screenshot. Zoom for small text. | Partly in the skill ("verify once at the end"). | **Take** (skill, a few lines): the dropdown/scrollbar shortcut tip and "say what you look for before you look". |

## Plan

### Phase 1: Small fixes (S, each under an hour)
1. `input` `click` / `down`: send `mouseMoved` to the point first (#2).
2. `input`: scroll a selector target into view instead of refusing it (#3).
3. `key`: chord strings (`cmd+s`), sequences (`Tab Tab Enter`), `--repeat N`, aliases
   `Return` / `Page_Up` / `Page_Down` / `super` / `option` (#5). The same parser goes
   into `input`.
4. Refuse points that are on no display, and bound `--clicks`, `--duration`, scroll
   size (#4).
5. CDP `navigate`: allow only `http(s)` / `about:blank`, and wait for `readyState` plus
   the URL change (#6, #7).

### Phase 2: Element refs (M, about a day)
1. CDP: an in-page `ref ↔ element` map (as in the example driver), filled by `som` and
   `query-dom`, read by `input` / `click-mark` / `--set-value`; stale → a clear error.
2. AX: the host keeps `ref → AXUIElement` per pid (bounded, dropped when the app
   quits). `query-ax` / `som --pid` return refs; `--press` / `--focus` / `--set-value`
   accept them.
3. `find` (ranked word match, top 20) and the `read_page` options `--interactive`,
   `--all`, `--under REF`, `truncated` (#10, #11, #12).

### Phase 3: State deltas and dialogs (M)
1. A `changes` field on actuator replies (#8).
2. JS dialog detection and report (#9).
3. Leaner replies (#13).

### Phase 4: Policy and tests (M)
1. Opt-in session policy: verbs to ask about, allowed hosts, a HUD prompt, refusal
   text that stops retries (#14).
2. The terminal guard for foreground keys (#15).
3. `dev/exercise` smoke test (#16).
4. Skill: the prompting tips in #24 (lean).

## Status — Phases 1–3 built (2026-10-09, not yet live in the app)

| Item | Where |
|---|---|
| Hover before press; scroll target into view | `CDPInputScript` (move before press), `AgentCDPInput.resolve` |
| Key chords / sequences / `--repeat` / model-style names | `KeySpec` (shared by `key` foreground + background, and `input`) |
| Refuse off-display points; bound clicks, duration, scroll, repeat | `AppDelegate.offDisplay`, `inputBoundsError` |
| `navigate`: http(s) only, `localhost:3000` → http, wait for the new document | `AgentDOM.navigableURL`, `AgentDOM.navigate` (`performance.timeOrigin` changes) |
| Element refs: `ax_N` (host table, bounded) and `ref_N` (in-page, WeakRef) | `ElementRefs`; rows of `query-ax` / `query-dom` / `som` / `find` |
| `query-ax --ref / --under / --all`, `truncated`; `som --under / --all` | `AppDelegate`, `AgentAX.act`, `AgentDOM.setOfMarks` |
| `find` (ranked words → refs), DOM refs only for the winners | `ElementFind`, `AgentFind` |
| `input` `fill` | `AgentCDPInput.prepareFill` + `Input.insertText` |
| `changes` on actuator replies | `AgentChanges` (relay wrappers) + page URL/title in `input` |
| JS dialogs: answered in-session by policy, reported; `dialog` verb; `--reload` | `AgentDOM` (DialogPolicy, task-locals), extension 0.2.0 |
| Leaner background press reply (no echoed point) | `AppDelegate.backgroundPress` |

**Measured on headless Chrome (debug port), with the real code compiled into test
binaries:** unit suites (keys, find scoring, scripts) pass; 31 end-to-end checks
pass (refs and stale refs, hover, scroll-in, fill text/select/clear, cmd+a,
find, som --under, dialogs dismissed in-session, --on-dialog stop, recovery by
reload); timing unchanged (note spacing error median 1.8 ms, max 5.8 ms; chord
spread under 3 ms).

**Found while building:**
- Chrome lets only the CDP session that saw a dialog open answer it. A later
  session gets "No dialog is showing" and is itself blocked; a dialog already
  open is NOT reported when Page events are enabled. Only a reload clears an
  orphaned dialog. Hence: answer in-session by policy, `dialog --reload` to recover.
- A socket read does not end when its task is cancelled, so a timeout on a
  blocked page hung forever. A timed-out command now closes its socket.
- Waiting for a mouse move's ack costs about one frame (Chrome acks moves at the
  next frame): hover-before-press made notes ~32 ms late. A move followed by a
  press/release/wheel is now sent without waiting; that event flushes it in order.

**Not yet verified (needs a FloatyTerm relaunch, and the extension reloaded for
0.2.0):** the AX side (`ax_N` refs, `query-ax --ref`, `find --pid`), `changes`,
and every path through the extension (dialog policy in the extension, `post`).
A process started from FloatyTerm's terminal does not get its Accessibility grant,
so the AX side can't be tested from a harness.

## Status — Phase 4 built (2026-10-10, not yet live in the app)

| Item | Where |
|---|---|
| Opt-in approval policy: `agent-policy.json` (`ask`, `allow_hosts`, `timeout_seconds`); every route gated in the relay; steps inside `run` plans and `input` scripts count; a broken file fails closed; `host --policy` | `AgentPolicy` |
| The prompt: a non-activating panel (never takes focus), first-click buttons Deny / Allow once / Allow for this session, timeout = Deny, page text escaped; refusal text that stops retries | `ApprovalPanel` in `AgentPolicy.swift` |
| Terminal guard: foreground `type` / `key` (also `run` type steps) refused when the front app is a terminal and the call names no target; `--allow-terminal` | `AppDelegate.terminalGuard` |
| Hidden-tab warning on `input` (a background tab gets no frames: hover, wheel, drag stall — found by the harness) | `AgentCDPInput` |
| Exercise suites: `Tools/exercise/run.py` (CLI → live app → headless Chrome) and `Tools/exercise/harness/run.sh` (sources compiled, no app) | `Tools/exercise/` |
| Skill tips: know what you look for before you look; keys for dropdowns/sliders/scrollbars; how to read `denied_by_*` and `terminal` | `SKILL.md`, `ref/input.md` |

Tested: the policy's decisions in a test binary with a temporary policy file (17
checks: hosts incl. a suffix trick, read-only verbs, `*`, plan and script steps,
dialog answers only, fail-closed, escaping); the harness (both suites pass).
Not yet run: `run.py` (needs the relaunched app) and the prompt panel itself.
