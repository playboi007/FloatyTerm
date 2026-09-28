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
`?ref=select` shows a selected passage with its button, `?ref=chips` two referenced passages.
`?pop=` takes `model`, `mode`, `usage`, `slash` (with `q=`) or `slash-arg` (with
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
