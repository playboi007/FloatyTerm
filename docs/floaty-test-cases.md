# FloatyTerm agent — test cases & golden traces

Paste one **Prompt** at a time to an agent that has the `floaty-ui-control` skill.
Run top-to-bottom: smoke tests prove each path, then scenarios combine them.

**Safety:** comms apps (Slack, WhatsApp, X) cases are **read-only** — never send or
post (that's a fail). Doc edits use scratch content you can delete.

Legend: `CDP` = DevTools over a debug port · `AX` = Accessibility tree by PID ·
`SoM` = Set-of-Mark marks + `click-mark` (table-first: image only when marks are
poorly named or `--image`) · `capture→frame` = screenshot then `click-in-frame` ·
`osascript` = AppleScript build + `capture` verify · `ghost` = `host --ghost`
focus-safe mode · `focused` = `focused` cursor check · `diff` = `--diff` element
deltas · `wait` = `capture --if-changed` / `--wait-change` screen-hash economy.

---

## How to read & capture the traces

Every `floaty` call is now logged. After a run, compare what the agent **did** to
the **Trace** (the golden call sequence) — the first divergence is the bug locus.

- **Capture the real trace:**
  `tail -f "$HOME/Library/Application Support/FloatyTerm/Devtools/agent/calls.ndjson"`
  (or open it from FloatyTerm's log picker). Each line:
  `{"ts","route","ms","ok","args":{…},"result":{…}}`.
  - `args` echoes the mode the agent ASKED for, including the perception flags:
    `region`, `full_res`, `image`, `json`, `brief`, `diff`, `if_changed`,
    `wait_change`, `timeout`, and the act-to-an-edge flags `until_change`,
    `settle`, `watch`, `every`, `max`.
  - `result` echoes decision-driving fields: `count`, `frame_id`, `source`,
    `truncated`, … plus the perception-economy signals: `image` (did som pay for
    a screenshot?), `diff`/`added`/`removed`/`unchanged`, `changed`/`waited_ms`
    (wait-change), `screen_hash`, `note` (the host's own explanation),
    `iterations`/`settled` (act-to-an-edge: how many host-side repeats one call
    absorbed — each was a model round trip before), and the `run` endgame
    (`completed`/`failed_step`/`steps_done`/`retries_total`/`reason`).
  - **`run.step` lines**: every step of a `run` plan logs its own entry
    (`step`/`verb`/`attempt` in args, `satisfied`/`reason` in result) — the
    per-step ledger lives HERE, not in the model-facing reply, so a fishy
    success is diggable for free.
- **Diff:** line up the actual `route` sequence against the case's **Trace**.
- **Attribution rule** (the point of all this) — at the divergence, read that
  line's `ok` / `result` / `error`:
  - tool returned a **correct, decisive** result (right data, clear field, a loud
    error) yet the agent still went wrong → **`[skill]`** (missing guidance /
    disambiguation) → fix `SKILL.md`/`ref`.
  - tool was **ambiguous, silently wrong, or success-shaped-but-wrong** →
    **`[framework]`** → fix code (richer field, a guard, or a refusing error).
- **Loop signatures:** *repeat* (same `route` ×3+) · *oscillation* (A→B→A→B) ·
  *escalation drift* (undo→undo past the goal). Each = a missing convergence signal;
  per-case **Loops** below name the likely one.
- **Waste signatures** (new — the perception-economy analog of loops; the run
  *succeeds* but burns tokens):
  - *image tax* — `som` lines with `result.image:true` on well-named apps, or
    `args.image:true` habitually. Check the som `note`: if the host said "table
    only" and the agent forced `--image` anyway → `[skill]`.
  - *poll burn* — plain `capture` ×N in a sleep loop (same target, `screen_hash`
    barely moving) instead of one `--wait-change` / `--if-changed` → `[skill]`.
  - *full-table re-scan* — full `query-ax`/`som` after every action instead of
    `--diff` (result shows `count:80` when `added:4` would have answered) → `[skill]`.
  - *round-trip burn* — actuator/`capture` alternation (`drag`⇒`capture`⇒`drag`⇒
    `capture` …, same action shape each time) instead of ONE
    `--until-change`/`--settle` call whose `iterations` field absorbs the loop
    → `[skill]`.
  - `--diff` returning the whole tree as `added` on an unchanged screen →
    `[framework]` (hash quantization broken).
- Notation: `⇒` = next step · `→ .field` = the result field that drives the decision.

> Tip: the `ms` field flags slow steps (big AX walks); a route repeating with an
> identical `args` line and unchanging `result` is the clearest loop tell. For
> waste, grep the trace: `grep '"route":"som"' calls.ndjson | grep '"image":true'`
> and count plain `capture`s between actions.

---

## Tier 0 — Smoke tests (one path each)

### S1 — Preflight
**Prompt:** "Confirm FloatyTerm's agent control is live and permitted, then tell me which capabilities are available."
- **Exercises:** preflight / permission state.
- **Trace:** `key {key:escape} → .ok` ⇒ report. (Accessibility error → surface it, don't retry.)
- **Pass:** reports relay + Accessibility OK; doesn't fire `escape` blindly into its own terminal.
- **Loops:** retrying `key` after an Accessibility error → `[skill]` (didn't recognize the permission message as terminal).

### S2 — CDP read (no screenshots)
**Prompt:** "Open Chrome to news.ycombinator.com and tell me the titles of the top 5 stories. Read them from the page — don't screenshot."
- **Exercises:** `CDP`.
- **Trace:** `navigate {url} → .ok` ⇒ `eval {expression:"…querySelectorAll…"} → .result[array]` ⇒ report.
- **Pass:** 5 real titles in 1–2 `eval`s; no `capture`.
- **Loops:** `capture`→read→`capture` oscillation → `[skill]` (reached for screenshots on a DOM app). `eval` returns null on a `chrome://` tab → `[framework]`-adjacent but correct; fix is `navigate` first.

### S3 — AX by PID on live Chrome (Chrome 136+)
**Prompt:** "My Chrome is already open. Without quitting it or opening a debug port, list the clickable things in the front Chrome window."
- **Exercises:** `AX`.
- **Trace:** `list-windows {filter:Chrome} → .windows[] {pid, on_screen}` ⇒ `query-ax {pid} → .count,.elements` ⇒ report.
- **Pass:** real elements + coords (from the `elements` lines — `id role "name" @x,y WxH`); no debug-port relaunch, no quitting Chrome.
- **Off-stage note (Stage Manager / other Space):** `list-windows` now lists Chrome with `on_screen:false` instead of empty; the agent should `raise --pid` to surface it, then `query-ax`/`som`. Self-recovery trace: `list-windows → on_screen:false ⇒ raise {pid} → on_screen:true ⇒ query-ax/som`. It should **never** conclude "no window open."
- **Loops:** concluding "Chrome has no window" when `list-windows` returns `[]` → `[framework]` (was: on-screen-only hid off-stage windows — now fixed; it shows them flagged). `query-ax` repeated waiting for a populated tree → `[framework]` if the internal retry isn't firing. Quitting/relaunching Chrome for a port → `[skill]`.

### S4 — Set-of-Mark on a web page (table-first)
**Prompt:** "Number the interactable elements on the current web page, tell me which number is the search box, then click it."
- **Exercises:** `SoM` (DOM), table-first.
- **Trace:** `som {port} → .frame_id,.count,.elements,.image:false` ⇒ pick the id from the TABLE ⇒ `click-mark {frame_id,id} → .ok`.
- **Pass:** right number straight off the `elements` table — **no PNG viewed** (a
  normal page's marks are well-named, so `image:false`); `click-mark` focuses the field.
- **Loops:** uses element `@x,y` with `click --x --y` instead of `click-mark` → works but `[skill]` (defeats the id indirection). `click-mark` after a scroll → refuses (stale) → re-`som`; if it re-clicks the stale id forever → `[framework]` (guard not firing).
- **Waste:** passes `--image` when the table already carried the names → *image tax*, `[skill]`.

### S5 — Set-of-Mark on a native window (table-first)
**Prompt:** "Open a new Finder window and give me a numbered list of its controls."
- **Exercises:** `SoM` (AX), table-first.
- **Trace:** `som {app:"Finder"} → .source:"ax",.count,.elements,.image:false` ⇒ report from the table.
- **Pass:** real Finder controls with sensible labels, straight from `elements`; `image:false` (Finder's tree is well-named — no screenshot should be paid for).
- **Loops:** marks on hidden/occluded elements (known AX limit) → `[framework]` candidate (add a visibility filter) if noisy.
- **Waste:** `--image` forced on a well-named native window → *image tax*, `[skill]`. (If the user explicitly asks to SEE boxes, `--image` is correct — the ask here doesn't.)

### S6 — Capture → click-in-frame (no tree)
**Prompt:** "Screenshot VLC and tell me the exact screen coordinate of the play/pause button, using the capture frame."
- **Exercises:** `capture→frame`.
- **Trace:** `list-windows {filter:VLC} → .id` ⇒ `capture {window_id} → .frame_id,.image_width` ⇒ read PNG ⇒ `click-in-frame {frame,x,y} → .screen_x/y`.
- **Pass:** uses `frame_id` + image pixels; never feeds raw pixels to `click`. (PNGs
  are now ~1440px long edge — coordinates are pixels in *that* PNG; the frame
  records the real ratio, so the transform stays exact.)
- **Loops:** `capture`→`click {x:imgpx}`→miss→`capture` oscillation → **`[framework]`** (capture's x/y *look* clickable) **and** `[skill]` (ref didn't forbid it). The footgun from the Sonnet run.

---

## Tier P — Perception economy (the token-lean loop)

These validate Levers 1+2: the run must not just *succeed* — the trace must show
it perceived cheaply. For every P case, also grep the trace for the **Waste
signatures** above; a correct answer with `image:true` everywhere is a fail here.

### P1 — Act and verify with zero images
**Prompt:** "In System Settings, use numbered marks to find and open the 'Appearance' pane, then tell me which new controls appeared — without taking or viewing a single screenshot."
- **Exercises:** table-first `SoM` + `click-mark` + `som --diff`.
- **Trace:** `som {app:"System Settings"} → .elements,.image:false` ⇒ `click-mark {frame,id} → .ok` ⇒ `som {app, diff:true} → .added,.elements_added,.image:false`.
- **Pass:** whole trace has `image:false` on every `som` and **zero `capture` lines**; the report lists the Appearance pane's controls from `elements_added`.
- **Loops/Waste:** `--image` on either som → *image tax* `[skill]`. `click-mark` id picked from a viewed PNG that was never produced → confabulation, `[skill]`. Diff returns the whole table as `added` though only the pane changed → `[framework]` (hash quantization).

### P2 — Delta after an action (`query-ax --diff`)
**Prompt:** "Snapshot Finder's elements, open one new Finder window with ⌘N, then report ONLY what appeared or disappeared — not the full list."
- **Exercises:** `diff` baseline → action → delta.
- **Trace:** `query-ax {pid:Finder} → .count` (or `diff:"baseline"` if `--diff` passed first — both fine) ⇒ `key {key:n, modifiers:[cmd], target:Finder}` ⇒ `query-ax {pid, diff:true} → .added,.removed,.unchanged`.
- **Pass:** final report is built from `elements_added`/`elements_removed`; `added` count ≪ full `count`; the agent does not re-list the world.
- **Loops/Waste:** full `query-ax` re-scan after the action instead of `--diff` → *full-table re-scan* `[skill]`. First `--diff` call returning `diff:"baseline"` treated as an error and retried → `[skill]` (the note explains it).

### P3 — Verify with a crop, not a frame
**Prompt:** "Open MarkEdit, type the line 'perception test' into a new document, then visually confirm it landed — but capture only the small region where the text is, not the whole window."
- **Exercises:** `capture --region` (geometry taken from an element's `@x,y WxH`).
- **Trace:** `host {ghost:on}` ⇒ (focus/click MarkEdit) ⇒ `focused → .editable:true` ⇒ `type {text}` ⇒ `query-ax {pid}|focused` → text-area rect ⇒ `capture {pid, region:"x,y,WxH"} → .image_width(small),.frame_id` ⇒ `host {ghost:off}`.
- **Pass:** the verifying capture's `image_width`/`image_height` are region-sized (hundreds of px, not ~1440); region coordinates came from an element rect, not guessed.
- **Loops/Waste:** full-window capture to check one line of text → `[skill]`. `--region` rejected as outside the window because it was guessed instead of read from `elements` → `[skill]` (the error names the fix).

### P4 — Don't poll: `--wait-change`
**Prompt:** "VLC is open and paused on a video. First prove the window is static by waiting for a change (it should time out), then press play and prove it's changing now — using exactly one wait call for each, no screenshot loops."
- **Exercises:** `wait` long-poll, both outcomes.
- **Trace:** `capture {pid:VLC, wait_change:true, timeout:5} → .changed:false,.waited_ms≈5000` (no image) ⇒ `key {key:space, target:VLC}`|`query-ax {pid, title:Play, press}` ⇒ `capture {pid, wait_change:true} → .changed:true,.waited_ms(small),.path`.
- **Pass:** exactly two `capture` lines, the first with `changed:false` and **no `path`**; no plain-capture polling anywhere.
- **Loops/Waste:** `capture` ×N with sleeps in between → *poll burn* `[skill]`. `wait_change` on the paused video returning `changed:true` instantly → `[framework]` (hash too sensitive — check threshold). Playing video returning `changed:false` → `[framework]` (hash too coarse).

### P5 — "Did anything change?" for one line (`--if-changed`)
**Prompt:** "Capture my Slack window once. Then check a second time whether anything changed — the second check must not produce a new image if nothing did. Read-only: don't click or type in Slack."
- **Exercises:** `wait` (`--if-changed` short-circuit); Slack safety.
- **Trace:** `capture {pid:Slack} → .path,.screen_hash` ⇒ `capture {pid, if_changed:true} → .unchanged:true,.screen_hash` (no path).
- **Pass:** second reply has `unchanged:true` and no `path`; the agent reports "no change" without viewing anything new; zero input events target Slack.
- **Loops/Waste:** second capture taken plain (new PNG of an identical window) → `[skill]`. `unchanged:true` while Slack visibly changed between the calls (new message arrived) → `[framework]` (hash too coarse — worth logging as a threshold data point).

### P6 — The ladder degrades honestly (canvas → auto-image)
**Prompt:** "VLC is playing a video in fullscreen (controls have auto-hidden). Number its interactable elements and tell me what you can see."
- **Exercises:** table-first SoM falling back to pixels when the table can't stand alone. (Fullscreen VLC with hidden controls ≈ a bare engine-drawn surface; any canvas web app tab — e.g. excalidraw — works as a stand-in.)
- **Trace:** `som {pid:VLC} → .count≈0,.image:true,.path` (host auto-decides: too few/unnamed marks → pixels included) ⇒ read PNG ⇒ report.
- **Pass:** the agent does NOT loop on empty tables — one som, sees `image:true` + the annotated/plain screenshot, reports from pixels (and says the tree is empty).
- **Loops/Waste:** repeated `som`/`query-ax` hoping for a tree → `[skill]` (E2's lesson); som returning `image:false` with 0 marks and no note → `[framework]` (the auto-image rule should have fired).

### P7 — Act to an edge (host-side repeat, one reply)
**Prompt:** "VLC is paused on a video. Step forward frame by frame until the picture visibly changes — but you may only issue ONE command for the whole advance and ONE for the verification."
- **Exercises:** `--until-change` + `--watch` (the deterministic act→look loop moved host-side); strict region hashing on a canvas where the full-window hash is blind. (VLC's frame-step key is `e`; adjacent frames often differ imperceptibly, so several steps accumulate before the strict hash flips — exactly the multi-iteration edge.)
- **Trace:** `capture {pid} → .path` (see the scene, pick the watch rect over the picture) ⇒ `key {key:e, pid, until_change:true, watch:"x,y,WxH", every:…, max:…} → .changed:true,.iterations:N,.path` — ONE line absorbing N repeats.
- **Pass:** exactly one actuator line for the advance, with `changed:true` + a fresh `frame_id` (iterations ≥ 2 on low-motion footage is the ideal exhibit); no plain `key`/`capture` alternation. The watch rect covers the video picture, not the (hidden) controls.
- **Loops/Waste:** `key → capture → key → capture` ping-pong anyway → *round-trip burn* `[skill]` (the edge verbs exist — declare the edge). `changed:false` though the picture clearly moved → `[framework]` (region hash too coarse — log the rect size as a data point). Also exercise `--settle` here: any act-then-capture pair on an animated surface should be one `… --settle` call (returned image is post-animation).

### P8 — Compile a plan (`run` — the whole flow in one round trip)
**Prompt:** "In MarkEdit: open a new document, type 'plan test', bring up the save dialog, then cancel it — and I want the entire flow executed as ONE pre-compiled plan, not action by action."
- **Exercises:** `run --steps` (linear plan, host-executed checkpoints); predicate-referenced steps; endgame-only reply.
- **Trace:** one look first (`query-ax`/`som` on MarkEdit — a plan is compiled knowledge, not hope) ⇒ `run {pid, steps:…} → .completed:true,.steps:4,.retries_total,.path` — ONE model-facing line for the whole flow ⇒ **route `run.step` ×4+** ledger lines between them (host-side, free), e.g. `key ⌘N → satisfied` ⇒ `type → satisfied` ⇒ `key ⌘S → expect appears AXSheet → satisfied` ⇒ `key escape → expect disappears AXSheet → satisfied`.
- **Pass:** exactly one `run` line for the flow with `completed:true`; per-step evidence exists as `run.step` lines; steps reference elements by role/title predicate (no mark ids inside the plan); the agent reads the endgame capture only.
- **Loops/Waste:** issuing the four actions as four separate calls after being asked for a plan → *round-trip burn* `[skill]`. Plan authored blind (no prior look at the surface) that then fails at step 1 → `[skill]` (compiled hope). `completed:true` with `retries_total>0` and the agent not glancing at `run.step` before reporting success → `[skill]` (fishy-success rule). A checkpoint that passes though the world visibly diverged (e.g. `appears` matched a different sheet) → `[framework]` (predicate too loose — log it; this is the accuracy ceiling of host-side checkpoints).
- **Sabotage variant (host self-verification):** while the plan runs, steal focus (click another app) during the type step. **Pass:** the step FAILS with "focus is on …, not the target" (and a `retry:1` on that step recovers by re-raising) — the run must NOT sail on to a false `completed:true`. Typed text is also re-read from the focused element's AX value ("keystrokes didn't land" = fail). On canvas targets, where neither check can read anything, the success reply must carry `unverified_steps` and the agent must re-check those effects before reporting — trusting a soft `completed:true` verbatim → `[skill]`; the reply omitting `unverified_steps` there → `[framework]`.

### P9 — Canvas plan with honest soft success (excalidraw)
**Prompt:** "In the excalidraw tab in Chrome: draw a rectangle, then add a text label reading 'canvas test' beside it — execute the drawing as ONE pre-compiled plan, be explicit about what you could and couldn't verify, and prove the result with a single OCR'd crop."
- **Exercises:** plans on a canvas surface (checkpoints must be `watch` rects — no AX for content); the `unverified_steps` soft-success contract; OCR as the canvas verification channel. (Excalidraw single-key tools: `r` = rectangle, `t` = text, `escape` commits; shapes/text live in a `<canvas>` — toolbar is DOM, content isn't.)
- **Trace:** one look (`som`/`capture` — toolbar marks are DOM/named, canvas content invisible) ⇒ `run {pid, steps:…}` with e.g. `press Rectangle` (expect valid-in-both-worlds — the tool may already be selected) → `drag` (watch rect over the draw area, strict) → `press Text` → `click` (where the label goes, expect `focused:{editable:true}` — a caret is pixel-invisible, `watch` falsely diverges on it) → `type "canvas test"` → `key escape`, → `.completed:true` ⇒ `capture {region, ocr:true}` → OCR text contains "canvas test" ⇒ report.
- **Pass:** one `run` line for the drawing; canvas *drawing* checkpoints are `watch` rects, the *text-editing* checkpoint is `focused` (verified live 2026-07-10: the caret `watch` falsely diverged; and the type step came back `verified:true` — excalidraw edits through a hidden textarea, so the host CAN verify mid-edit text on canvas; only the committed label is OCR-only). If the reply carries `unverified_steps`, the agent re-verifies those effects (the OCR crop) BEFORE reporting success and says which steps were soft.
- **Loops/Waste:** trusting a `completed:true` that carried `unverified_steps` without the OCR re-check → `[skill]`. Full-window captures to verify one label → *image tax* `[skill]` (a region crop + `--ocr` answers it). `watch` checkpoint on the draw step firing on iteration 1 from cursor/tool-preview noise → `[skill]` (place the rect where the SHAPE will land, not under the cursor path). OCR missing clean canvas text → `[framework]` (log it — OCR is the only reading channel here).
- **Sabotage variant:** steal focus while the plan is mid-`type` — same contract as P8: the step must fail ("focus is on …") or recover via `retry:1`, never a false `completed:true`.

---

## Tier 1 — Single-app scenarios

### T1 — Keynote via osascript, verified by capture
**Prompt:** "In Keynote, make a new presentation with a title slide reading 'Q3 Review' / subtitle 'Draft', then screenshot it so I can confirm."
- **Exercises:** `osascript` + `capture`.
- **Trace:** (osascript, off-trace) ⇒ `capture {window:"Keynote"} → .path` ⇒ show.
- **Pass:** built via AppleScript in ~one shot, then one verifying screenshot.
- **Loops:** capture→click-in-frame per field instead of scripting → `[skill]` (didn't prefer osascript for a scriptable app).

### T2 — Numbers spreadsheet
**Prompt:** "In Numbers, new spreadsheet: 'Item'/'Cost' in A1/B1, 3 sample rows, then screenshot it."
- **Exercises:** `osascript` + `capture`.
- **Trace:** (osascript) ⇒ `capture {window:"Numbers"} → .path`.
- **Loops:** same as T1 → `[skill]`.

### T3 — "Type as if I was typing" into a native editor
**Prompt:** "Open MarkEdit, create a new document, and write a short paragraph about why floating terminals are useful — as if I were typing it."
- **Exercises:** `type` (human cadence), native AX focus, `ghost`.
- **Trace:** `host {ghost:on} → .ok` ⇒ activate/click MarkEdit ⇒ `focused {app:"MarkEdit"} → .editable:true` ⇒ `type {text} → .ok` ⇒ `host {ghost:off}`.
- **Pass:** text lands in MarkEdit, reads naturally.
- **Loops:** `type` before `focused` check, text doesn't land, retype → repeat → `[skill]` if `focused` exists but unused; `[framework]` if FloatyTerm stole focus despite ghost.

### T4 — Code editor over CDP
**Prompt:** "In Cursor, open a new file and write a hello-world Python script."
- **Exercises:** `CDP` (port 9224) or `AX`/`type` fallback.
- **Trace:** `eval/query-dom {port:9224} …` OR `query-ax {pid} ⇒ click ⇒ focused ⇒ type`.
- **Loops:** retrying CDP when Cursor has no debug port → `[skill]` (should fall back to AX/type); `portClosed` error is loud, so a loop here is on the agent.

---

## Tier 2 — Focus-steal & ghost mode (the new fix)

### G1 — Reliable typing into Notion (the Sonnet failure, scoped)
**Prompt:** "Open Notion, create a page titled 'Floaty Test', and paste a two-sentence summary into the body. Make the title actually take the text, and don't let FloatyTerm steal focus while you type."
- **Exercises:** `ghost` + `focused` + clipboard-paste + Electron text fields.
- **Trace:** `host {ghost:on}` ⇒ `som {app:"Notion"}|query-ax {pid}` → locate title ⇒ `click-mark|click` ⇒ `focused {pid} → .editable:true` ⇒ `key {cmd+v}` (paste) or `type` ⇒ `host {ghost:off}`.
- **Pass:** title + body land; ghosted during typing; long text via paste.
- **Loops:**
  - type→vanish→retype repeat → `[framework]` if no `focused` / focus-steal; `[skill]` if `focused` exists but unused.
  - `key {cmd+a}` to "select title" wipes page → `[skill]` ("never Cmd+A in a page editor").
  - blind `key {cmd+z}` ×N past the goal → escalation drift → `[skill]` ("verify between ops").

### G2 — Focus-steal stress
**Prompt:** "Open MarkEdit, click into the document, then type three sentences while you also move the mouse around the screen. Afterward confirm every word landed in MarkEdit and nothing leaked elsewhere."
- **Exercises:** `ghost` (hover focus-safety), `focused`.
- **Trace:** `host {ghost:on}` ⇒ click doc ⇒ `focused → .editable:true` ⇒ `type` (with `move` interleaved) ⇒ verify ⇒ `host {ghost:off}`.
- **Pass:** all text in MarkEdit; nothing in the terminal even as the cursor drifts over FloatyTerm.
- **Loops:** missing chars / text in terminal → **`[framework]`** (ghost not applied or not effective) — the core thing this validates.

### G3 — The unlock badge
**Prompt:** "Put FloatyTerm into agent/ghost mode, do a few clicks in another app, then tell me how I'd bring FloatyTerm back to interactive myself."
- **Exercises:** the clickable unlock badge + ghost entry/exit.
- **Trace:** `host {ghost:on} → .ok,.window` ⇒ clicks ⇒ report (points to top-right badge).
- **Pass:** ghosts cleanly, stays readable, names the badge (not just the menu bar).
- **Loops:** n/a (manual); watch that `host {ghost:off}` or the badge actually restores interactivity.

---

## Tier 3 — Multi-app workflows (flagship regressions)

### M1 — The original (regression)
**Prompt:** "Do an internet search on how GenAI is used in production, and especially how it's helped content agencies in their operations. Open each site you navigate to as a separate Chrome tab so I can review them, and when you're done open Notion and add the findings as a new page '/ floaty-ui-control'."
- **Exercises:** the whole stack.
- **Trace:** (osascript: open N tabs) ⇒ `tabs → .tabs[]` ⇒ per tab `eval {match} → .result` (scrape) ⇒ `host {ghost:on}` ⇒ `som/query-ax {app:Notion}` ⇒ `click` ⇒ `focused` ⇒ `key {cmd+v}` ⇒ `host {ghost:off}`.
- **Pass:** ~5–7 tabs; a real Notion page with findings; no focus chaos, no page-wipe.
- **Loops:** every G1 trap, at scale — this is the end-to-end regression for all the fixes.

### M2 — Smaller multi-app variant
**Prompt:** "Find 3 well-reviewed coffee spots in Nairobi, open each in its own Chrome tab, then make a Notion page 'Coffee shortlist' listing the names with their links."
- **Exercises:** same stack, cheaper.
- **Trace:** as M1 but 3 tabs; URLs scraped via `eval`, not retyped.
- **Loops:** retyping URLs instead of scraping `.result` → `[skill]`.

### M3 — Read Slack → write a note (read-only on Slack)
**Prompt:** "Read the most recent message in my Slack #general channel — do NOT send or type anything in Slack — then write a one-line summary into a new MarkEdit note."
- **Exercises:** Slack `CDP`/`AX` read + native editor write.
- **Trace:** `query-ax {pid:Slack}|eval {port:9225} → read` ⇒ (MarkEdit) `host {ghost:on} ⇒ focused ⇒ type ⇒ host {ghost:off}`.
- **Pass:** summary in the editor; Slack untouched.
- **Loops:** **safety** — any `type`/`key` whose trace shows a Slack target/pid is a fail.

---

## Tier 4 — Edge cases / find the limits

### E1 — Huge AX tree (latency bound)
**Prompt:** "List the clickable elements in the front Xcode window."
- **Exercises:** `AX` against a very large tree.
- **Trace:** `list-windows {filter:Xcode} → .pid` ⇒ `query-ax {pid} → .count` (watch `ms`).
- **Pass:** returns in a few seconds, capped; says it capped rather than hanging.
- **Loops:** high `ms` then a repeat → `[framework]` (node cap / timeout too loose); silent truncation with no note → `[framework]` (add a `truncated` flag).

### E2 — A drawn surface (no DOM elements, no useful tree)
**Prompt:** "I have excalidraw open in a Chrome tab with a few shapes drawn. Screenshot it and click the rectangle on the canvas."
- **Exercises:** `capture→frame` as the only option for engine-drawn CONTENT (the shapes live in a `<canvas>` — no DOM nodes, no AX elements; only the app's toolbar has a tree).
- **Trace:** `capture {pid} → .frame_id` ⇒ read PNG ⇒ `click-in-frame {frame,x,y} → .ok`.
- **Pass:** recognizes the canvas content has no tree, goes straight to the capture loop for the shape (using the tree for toolbar buttons is fine — that's the ladder working).
- **Loops:** `query-dom`/`som` retried on the canvas hoping shapes appear → `[skill]` (should recognize drawn-content-vs-chrome and use capture); a couple of empty probes is fine, a loop isn't.

### E3 — Two Chromes, disambiguate by PID
**Prompt:** "I want two separate Chrome instances. Launch a fresh isolated one alongside my normal Chrome, then use list-windows to tell them apart and report each window's title and pid."
- **Exercises:** two-Chrome `pid` disambiguation.
- **Trace:** `list-windows {filter:Chrome} → .windows[] (two pids)` ⇒ report.
- **Pass:** two distinct pids + titles; no confusion.
- **Loops:** conflating by name / coin-flipping `--target "Google Chrome"` → `[skill]` (docs now say key off pid); if `list-windows` omitted pid it'd be `[framework]` — but it doesn't.

---

## Quick-run shortlist

Cover the most + stress the new fixes:
**S3** (AX-by-PID) · **S4** (table-first SoM) · **S6** (capture footgun) ·
**P1** (zero-image act+verify) · **P2** (diff delta) · **P4** (wait-change, both
outcomes) · **P7** (act to an edge) · **P8** (compiled plan) · **G1** (Notion
typing + ghost) · **M2** (multi-app) · **E2** (canvas / capture fallback).
For each, `tail` the trace log and diff against the **Trace** above — and for the
P cases, run the waste greps too:

```sh
LOG="$HOME/Library/Application Support/FloatyTerm/Devtools/agent/calls.ndjson"
grep '"route":"som"' "$LOG" | grep -c '"image":true'     # image tax (want: ~0 outside P6)
grep -c '"route":"capture"' "$LOG"                        # poll burn (want: few, mostly --region/--wait-change)
grep '"diff":' "$LOG" | tail -5                           # deltas actually used?
grep '"iterations":' "$LOG" | tail -5                     # act-to-an-edge used? (each absorbed N round trips)
grep '"route":"run.step"' "$LOG" | tail -8                # plan forensics (dig here when a run looks fishy)
```
