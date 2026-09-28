/*
 * Sample replies for SkimRender: the design's pattern sources, real replies
 * from a Claude Code session, and negative cases that must stay plain.
 * Shared by fixtures.html (visual check) and classify.test.js (rules check).
 * `expect` lists the block kinds the classifier should emit, in order.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.SkimSamples = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  const sp = n => ' '.repeat(n);
  const ASCII = [
    '┌────────────┐  refresh()   ┌────────────────┐',
    '│ useSession │ ───────────▶ │ refreshSession │',
    '└────────────┘' + sp(14) + '└───────┬────────┘',
    sp(36) + '│ requestToken()',
    sp(36) + '▼',
    sp(28) + '┌────────────────┐',
    sp(28) + '│    auth API    │',
    sp(28) + '└────────────────┘'].join('\n');

  return [
    {
      name: 'Options & trade-offs',
      expect: ['md', 'options'],
      md: `There are three ways to fix the race. They differ mainly in how much of the session lifecycle they touch.

### Option A: Share the in-flight request
Dedupe concurrent callers with one module-level promise.
- **Pros:** smallest diff; no API change; fixes the flaky test directly
- **Cons:** stale-timestamp bug remains
- **Effort:** S — about 10 lines

### Option B: Schedule from the response
Compute the next refresh after \`requestToken()\` resolves, clamped to ≥ 0.
- **Pros:** fixes negative delays; easy to test with fake timers
- **Cons:** concurrent callers can still double-refresh
- **Effort:** S — about 6 lines

### Option C: Dedicated refresh worker
Move refresh into a single scheduler owned by \`SessionProvider\`.
- **Pros:** one owner for all timers; handles tab visibility
- **Cons:** touches 6 files; needs a migration for useSession callers
- **Effort:** L — half a day

**Recommendation:** Option A + Option B together. They're small, independent, and cover both failure modes.`
    },
    {
      name: 'Phased plan',
      expect: ['md', 'phases'],
      md: `## Plan

### Phase 1: Stabilize the test (today)
1. [x] Share the in-flight refresh promise
2. [x] Clamp the timer delay to ≥ 0
3. [ ] Add a regression test for concurrent callers

### Phase 2: Harden the session lifecycle
1. [ ] Move scheduling out of \`refreshSession()\`
2. [ ] Cancel pending timers on sign-out
3. [ ] Log refresh failures to \`telemetry.auth\`

### Phase 3: Follow-ups (optional)
1. [ ] Replace the timer with a visibility-aware scheduler
2. [ ] Drop \`--runInBand\` from CI`
    },
    {
      name: 'ASCII diagram',
      expect: ['ascii'],
      md: '```text\n' + ASCII + '\n```'
    },
    {
      name: 'Mermaid diagram',
      expect: ['mermaid'],
      md: '```mermaid\nsequenceDiagram\n  participant A as useSession\n  participant I as interceptor\n  participant S as refreshSession()\n  participant API as auth API\n  A->>S: refresh\n  I->>S: refresh (401 retry)\n  Note over S: reuse inflight promise\n  S->>API: requestToken()\n  API-->>S: token\n  S-->>A: session\n  S-->>I: session\n```'
    },
    {
      name: 'File tree',
      expect: ['tree'],
      md: '```\nsrc/auth/\n├── session.ts          # refresh + scheduling (modified)\n├── useSession.ts       # React hook (modified)\n├── api.ts              # token endpoint\n└── types.ts\ntests/auth/\n├── session.test.ts     # concurrent-caller case (new)\n└── useSession.test.ts\n```'
    },
    {
      name: 'Nested file tree (│ indent)',
      expect: ['tree'],
      md: '```\nResources/\n├── SkimRender/\n│   ├── skim.css\n│   └── vendor/\n│       └── marked.min.js   # v12 (new)\n└── README.md\n```'
    },
    {
      name: 'Callouts',
      expect: ['callout', 'callout', 'callout'],
      md: `> **Note:** \`refreshSession()\` now returns a shared promise. Callers that expected a fresh request on every call will get the cached one.

> [!WARNING]
> \`--runInBand\` hides ordering bugs. Keep it in CI until the regression test has passed 20 runs in a row.

**Tip:** Run \`npm test -- --watch tests/auth\` while iterating.`
    },
    {
      name: 'Change log',
      expect: ['changelog'],
      md: `- **Fixed** the race in \`refreshSession()\` by sharing one in-flight request
- **Changed** timer scheduling to run after the response, clamped to ≥ 0
- **Removed** the unused \`expiresAt\` binding in \`src/auth/useSession.ts\`
- **Added** a concurrent-caller case to \`tests/auth/session.test.ts\``
    },
    {
      name: 'Key facts',
      expect: ['keyfacts'],
      md: `- **Root cause:** two callers refresh in the same tick, so \`requestToken()\` runs twice
- **Why only on CI:** slower runners widen the window between the two calls
- **Blast radius:** \`useSession\`, the axios interceptor, and \`sw/refresh.ts\`
- **Confidence:** high, reproduced 7/50 runs before the fix and 0/50 after`
    },
    {
      name: 'Nested findings',
      expect: ['findings'],
      md: `- Refresh is triggered from three places — \`useSession\`, the axios interceptor, and \`sw/refresh.ts\`
  - The interceptor retries on 401, which can overlap with the timer
  - The service worker only refreshes when the tab is hidden
- Test fixtures expire tokens after 60 s, prod after 15 min
  - \`SKEW_MS\` (30 s) is half the test lifetime, so timing is tight on slow runners`
    },
    {
      name: 'Table',
      expect: ['table'],
      md: `| Suite                 | Tests |   Time | Before | After |
|-----------------------|------:|-------:|--------|-------|
| session.test.ts       |     7 | 1.21 s | flaky  | pass  |
| useSession.test.ts    |     5 | 0.64 s | pass   | pass  |
| interceptor.test.ts   |     9 | 0.98 s | fail   | pass  |
| sw/refresh.test.ts    |     3 | 0.33 s | skip   | skip  |`
    },
    {
      name: 'Checklist',
      expect: ['checklist'],
      md: `- [x] Reproduce the flake locally (50 runs without \`--runInBand\`)
- [x] Patch \`refreshSession()\`
- [ ] Add concurrent-caller regression test
- [ ] Re-run CI 20 times`
    },
    {
      name: 'Code block (Swift)',
      expect: ['code'],
      md: '```swift\nfunc clampToVisibleScreen(_ f: NSRect) -> NSRect {\n    // Fall back to the screen under the mouse.\n    let mouse = NSEvent.mouseLocation\n    return f\n}\n```'
    },
    {
      name: 'Real reply: commit report',
      expect: ['md', 'table', 'md', 'section'],
      md: `I committed all the work. I did not create a branch and I did not build anything. All commits are on \`feature/devtools-diagnosis-window-mgmt\`:

| Commit | Contents |
|---|---|
| \`16e5376\` | ⌘/ opens the selected text as a link or a path |
| \`ef36e3a\` | The FloatyRS v1 Linux rewrite handoff doc |
| \`b431990\` | Network recording (\`floaty net\`, the Dart package, Chrome capture through the extension, the REC pill and menu), and window recovery after Space or display changes |

I put the network recording and window recovery work in one commit. The two are mixed together in \`AppDelegate.swift\`, and I did not want to split that file by hand.

**Things to know:**
- I did not commit \`files (2)/\`. It holds old patch files from June. It is still in the folder, untracked.
- I added \`.dart_tool/\` to \`.gitignore\` because it is Dart build output.
- I did not push.`
    },
    {
      name: 'Labeled sections',
      expect: ['section', 'section', 'section'],
      md: `**Risks:**
- The JSONL format is not a public API, so it can change.
- Hook setup edits global settings.

**Next steps:**
- [ ] Make the branch
- [ ] Build the renderer

**What I changed:**
- **Fixed** the tree depth for 2-space indents
- **Added** a rule for labeled sections`
    },
    {
      name: 'Long: code block',
      expect: ['code'],
      md: '```swift\nfunc long() {\n    let line1 = compute(1)   // step 1\n    let line2 = compute(2)   // step 2\n    let line3 = compute(3)   // step 3\n    let line4 = compute(4)   // step 4\n    let line5 = compute(5)   // step 5\n    let line6 = compute(6)   // step 6\n    let line7 = compute(7)   // step 7\n    let line8 = compute(8)   // step 8\n    let line9 = compute(9)   // step 9\n    let line10 = compute(10)   // step 10\n    let line11 = compute(11)   // step 11\n    let line12 = compute(12)   // step 12\n    let line13 = compute(13)   // step 13\n    let line14 = compute(14)   // step 14\n    let line15 = compute(15)   // step 15\n    let line16 = compute(16)   // step 16\n    let line17 = compute(17)   // step 17\n    let line18 = compute(18)   // step 18\n    let line19 = compute(19)   // step 19\n    let line20 = compute(20)   // step 20\n    let line21 = compute(21)   // step 21\n    let line22 = compute(22)   // step 22\n    let line23 = compute(23)   // step 23\n    let line24 = compute(24)   // step 24\n    let line25 = compute(25)   // step 25\n    let line26 = compute(26)   // step 26\n    let line27 = compute(27)   // step 27\n    let line28 = compute(28)   // step 28\n    let line29 = compute(29)   // step 29\n    let line30 = compute(30)   // step 30\n}\n```'
    },
    {
      name: 'Long: file tree',
      expect: ['tree'],
      md: '```\napp/lib/src/\n├── core/\n│   ├── models/\n│   │   ├── plan.dart\n│   │   └── rule.dart\n│   └── api/\n│       ├── client.dart\n│       └── endpoints.dart\n├── features/\n│   ├── plan_edit/\n│   │   ├── plan_edit_view.dart      # new layout (modified)\n│   │   └── plan_edit_rail.dart\n│   └── plan_new/\n│       ├── new_plan_screen.dart\n│       └── new_plan_widgets.dart\n└── l10n/\n    ├── app_en.arb\n    └── app_de.arb\n```'
    },
    {
      name: 'Long: table',
      expect: ['table'],
      md: '| Suite | Tests | Result |\n|---|--:|---|\n| suite_1.dart | 3 | pass |\n| suite_2.dart | 6 | pass |\n| suite_3.dart | 9 | pass |\n| suite_4.dart | 12 | fail |\n| suite_5.dart | 15 | pass |\n| suite_6.dart | 18 | pass |\n| suite_7.dart | 21 | pass |\n| suite_8.dart | 24 | fail |\n| suite_9.dart | 27 | pass |\n| suite_10.dart | 30 | pass |\n| suite_11.dart | 33 | pass |\n| suite_12.dart | 36 | fail |'
    },
    {
      name: 'Long: checklist',
      expect: ['checklist'],
      md: '- [x] Task number 1\n- [x] Task number 2\n- [x] Task number 3\n- [ ] Task number 4\n- [ ] Task number 5\n- [ ] Task number 6\n- [ ] Task number 7\n- [ ] Task number 8'
    },
    {
      name: 'Long: section',
      expect: ['section'],
      md: '**Things to know:**\n- Point 1: something worth knowing about item 1.\n- Point 2: something worth knowing about item 2.\n- Point 3: something worth knowing about item 3.\n- Point 4: something worth knowing about item 4.\n- Point 5: something worth knowing about item 5.\n- Point 6: something worth knowing about item 6.\n- Point 7: something worth knowing about item 7.\n- Point 8: something worth knowing about item 8.\n- Point 9: something worth knowing about item 9.'
    },
    {
      name: 'Long: plan without status',
      expect: ['phases'],
      md: '### Phase 1: Part 1 of the plan\n1. Step 1 of phase 1\n2. Step 2 of phase 1\n3. Step 3 of phase 1\n4. Step 4 of phase 1\n\n### Phase 2: Part 2 of the plan\n1. Step 1 of phase 2\n2. Step 2 of phase 2\n3. Step 3 of phase 2\n4. Step 4 of phase 2\n\n### Phase 3: Part 3 of the plan\n1. Step 1 of phase 3\n2. Step 2 of phase 3\n3. Step 3 of phase 3\n4. Step 4 of phase 3\n\n### Phase 4: Part 4 of the plan\n1. Step 1 of phase 4\n2. Step 2 of phase 4\n3. Step 3 of phase 4\n4. Step 4 of phase 4'
    },
    {
      name: 'Negative: prose list with bold words',
      expect: ['md'],
      md: `- **Fonts**: bundle Geist or use the system fonts?
- The **renderer** is plain JS, so it has no build step.
- Streaming stays plain until each block closes.`
    },
    {
      name: 'Negative: list with commas, no children',
      expect: ['md'],
      md: `- Read the file, then parse it
- Parse the tokens, then classify them`
    },
    {
      name: 'Negative: one option heading only',
      expect: ['md'],
      md: `### Option A: Keep it
Nothing else to compare.`
    },
    {
      name: 'Negative: bare bold label',
      expect: ['md'],
      md: '**Important**\n\nThe rest of the reply.'
    },
    {
      name: 'Negative: box comment in a real language',
      expect: ['code'],
      md: '```swift\n// ┌──────────┐\n// │  header  │\n// └──────────┘\nlet x = 1\n```'
    }
  ];
});
