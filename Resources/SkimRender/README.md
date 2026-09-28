# SkimRender

Renders Claude's Markdown replies so they are easy to skim. It follows the
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
swift Resources/SkimRender/dev/snapshot.swift Resources/SkimRender/dev/dock-test.html /tmp/dock.png 700 8 420
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
