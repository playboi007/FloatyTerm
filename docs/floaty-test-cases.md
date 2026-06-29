# FloatyTerm agent — test cases & golden traces

Paste one **Prompt** at a time to an agent that has the `floaty-ui-control` skill.
Run top-to-bottom: smoke tests prove each path, then scenarios combine them.

**Safety:** comms apps (Slack, WhatsApp, X) cases are **read-only** — never send or
post (that's a fail). Doc edits use scratch content you can delete.

Legend: `CDP` = DevTools over a debug port · `AX` = Accessibility tree by PID ·
`SoM` = Set-of-Mark boxes + `click-mark` · `capture→frame` = screenshot then
`click-in-frame` · `osascript` = AppleScript build + `capture` verify · `ghost` =
`host --ghost` focus-safe mode · `focused` = `focused` cursor check.

---

## How to read & capture the traces

Every `floaty` call is now logged. After a run, compare what the agent **did** to
the **Trace** (the golden call sequence) — the first divergence is the bug locus.

- **Capture the real trace:**
  `tail -f "$HOME/Library/Application Support/FloatyTerm/Devtools/agent/calls.ndjson"`
  (or open it from FloatyTerm's log picker). Each line:
  `{"ts","route","ms","ok","args":{…},"result":{count,frame_id,source,…}}`.
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
- Notation: `⇒` = next step · `→ .field` = the result field that drives the decision.

> Tip: the `ms` field flags slow steps (big AX walks); a route repeating with an
> identical `args` line and unchanging `result` is the clearest loop tell.

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
- **Trace:** `list-windows {filter:Chrome} → .windows[] {pid, on_screen}` ⇒ `query-ax {pid} → .matches[]` ⇒ report.
- **Pass:** real elements + coords; no debug-port relaunch, no quitting Chrome.
- **Off-stage note (Stage Manager / other Space):** `list-windows` now lists Chrome with `on_screen:false` instead of empty; the agent should `raise --pid` to surface it, then `query-ax`/`som`. Self-recovery trace: `list-windows → on_screen:false ⇒ raise {pid} → on_screen:true ⇒ query-ax/som`. It should **never** conclude "no window open."
- **Loops:** concluding "Chrome has no window" when `list-windows` returns `[]` → `[framework]` (was: on-screen-only hid off-stage windows — now fixed; it shows them flagged). `query-ax` repeated waiting for a populated tree → `[framework]` if the internal retry isn't firing. Quitting/relaunching Chrome for a port → `[skill]`.

### S4 — Set-of-Mark on a web page
**Prompt:** "Annotate the current web page with numbered boxes, tell me which number is the search box, then click it."
- **Exercises:** `SoM` (DOM).
- **Trace:** `som {port} → .frame_id,.count,.marks[]` ⇒ read PNG ⇒ `click-mark {frame_id,id} → .ok`.
- **Pass:** right number off the image; `click-mark` focuses the field.
- **Loops:** uses `marks[].center_x/y` with `click --x --y` instead of `click-mark` → works but `[skill]` (defeats the id indirection). `click-mark` after a scroll → refuses (stale) → re-`som`; if it re-clicks the stale id forever → `[framework]` (guard not firing).

### S5 — Set-of-Mark on a native window
**Prompt:** "Open a new Finder window, put numbered boxes over it, and tell me what each numbered control is."
- **Exercises:** `SoM` (AX).
- **Trace:** `som {app:"Finder"} → .source:"ax",.marks[]` ⇒ report.
- **Pass:** boxes on real Finder controls with sensible labels.
- **Loops:** boxes on hidden/occluded elements (known AX limit) → `[framework]` candidate (add a visibility filter) if noisy.

### S6 — Capture → click-in-frame (no tree)
**Prompt:** "Screenshot VLC and tell me the exact screen coordinate of the play/pause button, using the capture frame."
- **Exercises:** `capture→frame`.
- **Trace:** `list-windows {filter:VLC} → .id` ⇒ `capture {window_id} → .frame_id,.image_width` ⇒ read PNG ⇒ `click-in-frame {frame,x,y} → .screen_x/y`.
- **Pass:** uses `frame_id` + image pixels; never feeds raw pixels to `click`.
- **Loops:** `capture`→`click {x:imgpx}`→miss→`capture` oscillation → **`[framework]`** (capture's x/y *look* clickable) **and** `[skill]` (ref didn't forbid it). The footgun from the Sonnet run.

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

### E2 — A game (no DOM, no useful tree)
**Prompt:** "Jump King is open. Screenshot it and click its on-screen Start/Play button."
- **Exercises:** `capture→frame` as the only option.
- **Trace:** `capture {window:"Jump King"} → .frame_id` ⇒ read PNG ⇒ `click-in-frame {frame,x,y} → .ok`.
- **Pass:** recognizes there's no tree, goes straight to the capture loop.
- **Loops:** `query-ax`/`som` first (returns ~empty) then flailing → `[skill]` (should recognize no-tree and use capture); a couple of empty AX calls is fine, a loop isn't.

### E3 — Two Chromes, disambiguate by PID
**Prompt:** "I want two separate Chrome instances. Launch a fresh isolated one alongside my normal Chrome, then use list-windows to tell them apart and report each window's title and pid."
- **Exercises:** two-Chrome `pid` disambiguation.
- **Trace:** `list-windows {filter:Chrome} → .windows[] (two pids)` ⇒ report.
- **Pass:** two distinct pids + titles; no confusion.
- **Loops:** conflating by name / coin-flipping `--target "Google Chrome"` → `[skill]` (docs now say key off pid); if `list-windows` omitted pid it'd be `[framework]` — but it doesn't.

---

## Quick-run shortlist

Cover the most + stress the new fixes:
**S3** (AX-by-PID) · **S6** (capture footgun) · **G1** (Notion typing + ghost) ·
**G2** (focus-steal stress) · **M2** (multi-app) · **E2** (game / capture fallback).
For each, `tail` the trace log and diff against the **Trace** above.
