# SkimRender

Renders agent Markdown replies so they are easy to skim. It follows the
"Markdown, made skimmable" design: each reply is split into typed blocks, and
each block kind gets its own layout. A block that no rule matches stays plain
Markdown.

| Kind | Detected from |
|---|---|
| `options` | 2+ `### Option A: …` headings, optional `**Pros:**` / `**Cons:**` / `**Effort:**`, `**Recommendation:**` |
| `phases` | 2+ `### Phase 1: … (tag)` headings with their steps (status only when steps use `[ ]` / `[x]`) |
| `ascii` | a plain code block with 8+ box-drawing characters |
| `mermaid` | a ` ```mermaid ` block (Mermaid loads only when one appears) |
| `tree` | a plain code block with 2+ `├──` / `└──` rows; `# note`, `(modified\|new\|deleted)` |
| `callout` | `> [!NOTE]` … `> [!CAUTION]`, `> **Note:** …`, `**Tip:** …` |
| `section` | a bold label ending in a colon (`**Things to know:**`) directly above a list |
| `changelog` | every item starts with a bold verb: `- **Fixed** …` |
| `keyfacts` | every item starts with `- **Key:** …` |
| `findings` | nested lists whose top items use a lead phrase before " — " |
| `table` | any pipe table: status pills, right-aligned numbers, commit hashes, `+11 −4` |
| `checklist` | every item is a task: `- [ ]` / `- [x]` |
| `code` | any other code block, highlighted with highlight.js |

## Files

- `skim-classify.js`: pure rules, markdown to blocks (runs in Node too).
- `skim-render.js`: blocks to DOM. All Markdown-derived HTML goes through DOMPurify.
- `skim.css`, `fonts.css`, `fonts/`: design tokens and the bundled fonts.
- `vendor/`: marked 12.0.2, DOMPurify 3.4.16, highlight.js 11.12.0 (+ Dart), Mermaid 11.17.2.
- `dev/`: test samples and tools. Not copied into the app.

The app loads these files through `Sources/FloatyTerm/SkimAssets.swift`. `build.sh`
copies this folder, without `dev/`, to `FloatyTerm.app/Contents/Resources/SkimRender`.

## Shared agent tabs

`AgentChat` renders both Claude and Codex through the v1 contract in
`agent-events.js`. `agent-claude.js` and `agent-codex.js` translate native events;
each conversation owns its normalizer and reducer. `ClaudeChat` remains an alias
for existing replay callers. Text snapshots replace previous text, while explicit
deltas append; native tool IDs and per-turn Codex IDs keep activity separate.
Unknown events appear as folded, bounded JSON details.

The menu bar's **New Codex Tab** starts the installed `codex` through the
dependency-free `Resources/CodexSidecar/sidecar.mjs`. It maintains a Codex
`app-server --listen stdio://` connection and translates JSON-RPC notifications
into the shared renderer contract. The existing `exec --json` normalizer remains
available for replay fixtures. Codex retains its installed authentication and
configured model unless a model is selected.

The dock provides model/effort selection, workspace-write or read-only permissions,
token/context usage and account limits, slash commands, and the ⋮ actions menu.
Approvals use app-server request IDs and explicit allow/deny responses. Commands
such as `/usage`, `/model`, `/resume`, `/fork`, `/compact`, and `/new` route through
local controls; unknown slash commands report an error. Codex reasoning display
uses summaries. Side chats fork native threads, and TUI handoff uses `codex resume`.
Closing a tab stops its runner and active process group.

The existing Claude SDK driver retains its controls, approvals, and side chats.
No Headless CLI dependency is required. HTTP SSE and ACP remain future input
adapters. See [the implementation plan](../../docs/shared-agent-renderer-plan.md).

Verify the shared path without an account or model call:

```sh
node --test Resources/SkimRender/dev/agent-events.test.js Resources/SkimRender/dev/codex-events.test.js
node --test Resources/CodexSidecar/sidecar.test.mjs
```

`dev/codex-replay.html` is a synthetic Codex fixture. `dev/chat-replay.html` uses
the existing recorded Claude fixture. Both run through the same page renderer.

## The Claude tab

`chat.js` and `chat.css` are the Claude tab's page (⇧⌘A, or "New Claude Tab" in
the menu bar). It draws the event stream of `Resources/ClaudeSidecar/sidecar.mjs`
(Node + the Claude Agent SDK, which drives the installed `claude`): replies
through SkimRender, tool calls as activity groups with a time bar for each call,
and approval requests as cards. `ClaudeChatController.swift` hosts it.
`Resources/ClaudeSidecar/prompt-contract.md` tells Claude which shapes the page
renders specially.

**Side chats.** The switch at the left of the status line opens a side chat: a
fork of the main session as it is at that moment (`forkSession`), in its own
sidecar and session file, with main's model and effort (so it reads main's
prompt cache) and manual approvals. The switch then flips the full view
between main and the last side chat; its caret lists every conversation and
opens more. A dot on the switch says a conversation out of view is working,
waits for you, or has news. Each conversation keeps its own log, draft,
scroll position, cards, model and mode. Side chats do not refresh: open a new
one for a newer fork. Close one from the ⋮ menu.

**Thinking.** Claude Code's default thinking display sends the blocks empty,
and over the SDK it does not apply `showThinkingSummaries` itself. So the
sidecar does: at start it follows the merged settings (what `/config` says;
off when unset), and "Show thinking" in the ⋮ menu turns it on or off at once
(`setMaxThinkingTokens(null, 'summarized' | 'omitted')`). The tab keeps that
choice across a restart, and a new side chat takes main's. Each thinking block is one folded line: while it runs, a
rotating word ("Canoodling…"), the latest line of the summary and a timer;
when done, "Thought for 12s". Click it to read the summary. A block with no
text shows only its time.

**/resume** (also "Resume a conversation…" in the ⋮ menu) lists the other
conversations of this folder, newest first, with age, branch and size; type
after `/resume ` to filter, or give an ID. Picking one restarts main's sidecar
on that session and draws its history: prompts as turns, commands and their
output, referenced passages as chips, tool calls as rows with their real
times. The sidecar sends at most the last 400 messages, starting at a prompt,
with long tool output and file contents cut. A conversation changed in the
last two minutes is tagged "active now": it may be open in another tab or
terminal, and two writers must not share a session.

**@ mentions.** Type `@` for Claude Code's own fuzzy file search (the sidecar
sends the `file_suggestions` control request) and for `@agent-…` subagents;
a folder keeps the list open. Claude Code expands `@path` itself. Files dropped
from Finder become mentions (the host's `DropWebView` takes file drags, so
WebKit does not open them).

**Images.** Paste or drop images: chips in the composer, sent as image blocks
before the text; big ones are downscaled to 1568 px.

**Questions and plans.** `AskUserQuestion` and `ExitPlanMode` get their own
cards. Answers go back through the approval (`updatedInput.answers`); a plan
approval can switch the mode (`updatedPermissions` setMode).

**Status and tasks.** Retries, rate-limit warnings, hook output, blocked tools
and notifications show as notices (mapped in `agent-claude.js`). TodoWrite and
TaskCreate/TaskUpdate feed a task line above the status line.

**Subagents and background work.** `task_started` / `task_progress` /
`task_notification` join their tool row by `tool_use_id`: a running Agent row
shows its tool count and tokens (the progress summary in its tooltip), a
background command or agent gets a "background" badge, and when a background
one ends a notice says so, with its summary. `background_tasks_changed` counts
the live ones in the idle status line ("Ready · 2 in the background").
Ambient (housekeeping) tasks stay hidden. `thinking_tokens` puts a running
estimate on the thinking line ("12s · ~1.5k tokens") when the thinking text
itself is not shown.

**Tool tray.** Each turn's tool calls go into a tray: a pill under the
prompt, sticky at the top of the view while you read that turn. It counts the
calls by phase ("8 tools · Explore 5 · Change 2 · Verify 1"), shows failures,
and names the call that runs now (or "waiting for you") with its time. A click
opens the turn's whole tool history over the reply; Esc or a click outside
closes it. Where a run happened, a faint mark ("3 tools") stays in the reply
and opens the tray at that run. Approval cards stay in the reply. ⋮ "Tool
calls inline" puts the runs back in the reply, after their marks (kept in
localStorage `ck.toolsInline`). A subagent's panel keeps its runs inline.

**Stops and endings.** A stop arrives as `error_during_execution` with an
`aborted_…` terminal reason and an `[ede_diagnostic] …` line; the normalizer
makes it `turn.end` with status `interrupted` and drops diagnostic lines, so
the footer says "Stopped · 1.9s" and no error notice shows. Limits say which
("Stopped at the turn limit"); other errors keep their message.

**A prompt's fate.** Prompts sent with an ID get `command_lifecycle` frames
(`prompt.state`): a message that waits for the running turn says "Queued"
(after 600 ms, so a quick start shows nothing); one cancelled or discarded
before it ran says "Not sent", and "Refused" when the session declined it — a
click puts its text back in the composer. Other frames the TUI shows as banners
(API errors, model fallbacks, memories saved, agents stopped, the away
summary, scheduled tasks, Stop-hook problems, published changes, feedback
drafts, peer notices) become notices; `vcs_state_changed` re-reads git and
`task_summary` is the status line's live phrase. Heartbeats, transcript
mirroring and cloud-session frames are dropped.

**Side questions.** `/btw <question>` asks Claude a quick question about the
conversation without adding to it: the sidecar sends Claude Code's
`side_question` control request (answered from the conversation so far, no
tools, not saved to the transcript; it works while a turn runs). The answer
shows in a panel above the status line, with a field for follow-ups: each
follow-up sends the earlier questions and answers of that panel as `history`.
Esc or × closes the panel and drops its thread. `/btw` alone opens an empty one.

**Rewind.** Each prompt sent here carries its own ID (`send.uuid`; Claude Code
keeps it in the transcript), and the page remembers the transcript entry before
it (the newest `uuid` of a main-chain assistant or user message; the history
sends `uuid`s and `before`). Hover a prompt for ↺, press Esc Esc in an empty
composer, or type `/rewind` (alias `/checkpoint`) for a list. The panel above
the status line asks the sidecar for a dry run (`rewindFiles` with `dryRun`:
files, +/− lines), then offers 1 Code and conversation, 2 Conversation only,
3 Code only, Esc Cancel. Files: `Query.rewindFiles(promptId)` (the sidecar
starts every session with `enableFileCheckpointing`). Conversation: the page
removes that turn and everything after it, puts the prompt's text back in the
composer, and the host restarts the session with `resumeAt` / `dropsTurn`
(`resumeSessionAt` / `resumeDropsTurn`); before the first prompt, main starts a
new conversation and a side chat forks main again. If Claude Code refuses the
cut ("Resume rejected by --resume-drops-turn"), the session goes on whole.

**Long prompts.** A prompt over about 6 lines (or 420 characters) folds to its
first lines, faded at the bottom; "Show all" (or a click on the text) opens
it. A prompt that fits once laid out loses the fold.

**Subagent transcripts.** A subagent's messages carry the id of the Agent
call that started it (`parent_tool_use_id`); the normalizer marks its text,
thinking and tool results with that `parentId`. The page draws them into a
transcript of its own (a hidden conversation, with the same code as the main
one), so the conversation keeps only the Agent row. Click the row (it counts
the agent's tools) to open a panel above the dock: type, description, state,
the prompt (folded) and every step, live while it runs. A nested agent opens
from the panel, with a back button. Esc or × closes it. The approval card for a
subagent's tool stays in the conversation. A resumed chat has no subagent
messages, so the panel shows the agent's result and says why.

**Motion.** One set of values (`--m-fast` 120 ms, `--m-mid` 180 ms,
`--m-slow` 260 ms, one easing; `M` in `chat.js`). In a live reply, new words
fade in: `SkimRender.render(…, { reveal: true })` wraps the text that arrived
since the last render in `.sk-fresh` spans, and because the growing block is
rebuilt on every render, words still fading are wrapped again with a negative
animation delay, so the fade goes on instead of starting over. A new non-text
block, tool row, run, thinking line, card, notice and your own message rise in
(`enter()`); menus, the usage panel, the subagent panel, chips, the lightbox and
the reference button open softly. Folds slide: thinking, tool details, runs,
the subagent prompt, the task list and the usage panel (`expand()` /
`collapse()`); the state (the hidden attribute or class) changes at once and
only the drawing follows, so no other code waits for a slide. Nothing moves
while a history is drawn, in a conversation out of view, with macOS "Reduce
motion", or with `class="no-motion"` on `<html>` (the test pages; dock-test
section 31 turns it on to check the motion).

**Session name.** The ⋮ menu shows the conversation's name (the one you gave
it, else Claude Code's summary or first prompt) and "Rename…". `/rename <name>`
(alias `/name`) names it here: the sidecar sends Claude Code the
`rename_session` control request (`source: 'host'`), so the running session and
its transcript agree, and `/resume` lists it by that name.

**Mic.** The mic above the send button dictates into the composer, where the
caret was: the host uses the Mac's speech recognition (`Dictation.swift`,
`SFSpeechRecognizer`, on the device when it can), and asks for the Speech
Recognition and Microphone permissions the first time. Click again or press
Esc to stop; Return sends what it heard; typing stops it and keeps your text.
`/voice` toggles it too. Claude Code's own `/voice` cannot run here: it records
inside its terminal UI and is not available to non-interactive (SDK) sessions.

**Composer height.** Drag the grip on the text field's left edge (up is
taller, up to 60% of the window); double-click resets it to grow with the text.

The status line shows the session's folder and git branch (a dot when there
are uncommitted changes). The ⋮ button (or a click on the folder) opens a menu
with the full path, branch, change counts and ahead/behind, the last commit,
MCP servers, the session ID and Claude Code version, and actions: Copy path,
Reveal in Finder, Copy session ID, Open in TUI, Compact conversation, New
conversation. The sidecar reads git in the session's folder at start, after
each turn and when the menu opens.

The dock at the bottom has a model menu (with effort, ⌥P), a permission-mode
menu (Ask, Accept edits, Plan, Auto; ⇧Tab cycles), a usage chip that opens a
panel (session cost, context, plan limits) and the composer. Typing `/` in the
composer lists slash commands; after a command name it offers the argument
choices from its hint (`[low|high]`, `--fix`) and, for `/model`, `/effort` and
`/output-style`, the real values. `/model`, `/effort`, `/usage` and `/tui` run
in the page; every other command goes to Claude Code.

Select text in one of Claude's turns and a "Reference to Agent" button appears
(or press ⌘L). The passage becomes a chip in the composer — a one-line
preview; × or ⌫ in an empty composer removes it. On send, Claude gets each
passage in a `<referenced_text from_reply_to="…">` block after a short note
that the user took it from Claude's earlier replies; the conversation shows
only the chips and the message.

File changes (Edit, MultiEdit, Write) show in approval cards and in the tool
row's detail as a change view: **Now** (the text after the edit, new lines
marked, removed lines folded to "− N lines removed") or **Diff** (a line diff
with long unchanged runs folded). The body scrolls; when the change does not
fit, **Expand** makes it taller, and a card wider on a wide window.

`dev/chat-replay.html` replays a recorded session (`dev/session-sample.js`) into
the page, so it can be checked without the app or an API call:

```sh
swift Resources/SkimRender/dev/snapshot.swift Resources/SkimRender/dev/chat-replay.html /tmp/chat.png 700
swift Resources/SkimRender/dev/snapshot.swift "Resources/SkimRender/dev/chat-replay.html?stop=permission" /tmp/pending.png 700
# a dock menu at the panel's real size (width, settle seconds, viewport height)
swift Resources/SkimRender/dev/snapshot.swift "Resources/SkimRender/dev/chat-replay.html?pop=slash&q=co" /tmp/slash.png 700 2 420
# scripted checks of the dock (keys, menus, suggestions); failures print as errors
swift Resources/SkimRender/dev/snapshot.swift Resources/SkimRender/dev/dock-test.html /tmp/dock.png 700 1 420
```

`?change=edit|write|multi` (with `&diff=1`, `&big=1`) shows a file-change card (data: `dev/change-sample.js`).
`?resume=pick|done` shows the /resume list or a resumed conversation (data: `dev/history-sample.js`). `?think=live|done|open` shows a thinking block. `?side=1` shows a side chat (`&back=1`: main in view).
`?ref=select` shows a selected passage with its button, `?ref=chips` two referenced passages.
`?pop=` takes `model`, `mode`, `usage`, `more`, `slash` (with `q=`) or `slash-arg` (with
`q=/code-review%20`). The menu data is in `dev/dock-sample.js`.

## Checking a change

```sh
node Resources/SkimRender/dev/classify.test.js          # rules
node Resources/SkimRender/dev/scan-transcripts.js       # pattern counts over real replies
node Resources/SkimRender/dev/scan-transcripts.js --show section --limit 5
swift Resources/SkimRender/dev/snapshot.swift \
  "Resources/SkimRender/dev/fixtures.html?raw=0&only=table" /tmp/shot.png   # WebKit render
```

Open `dev/fixtures.html` in a browser to compare every sample with its raw
Markdown, try streaming, or paste a reply.

## Licenses

Rubik and JetBrains Mono: SIL Open Font License 1.1 (`fonts/OFL-*.txt`).
marked: MIT. DOMPurify: Apache-2.0 or MPL-2.0. highlight.js: BSD-3-Clause.
Mermaid: MIT.
