# Shared agent renderer

Branch: `feature/shared-agent-renderer`, based on `feature/claude-rich-frontend`.

## First implementation

1. Define a versioned, transport-independent event contract and pure conversation
   reducer. Preserve native events for inspection; keep unknown events visible.
2. Extract Claude SDK interpretation from the page into a normalizer, preserving
   streaming/final reconciliation, tools, thinking, approvals, and history.
3. Add a persistent Codex app-server runner with sequential turns, native session
   resume/fork, approvals, cancellation, metadata controls, and canonical events.
   Retain the `exec --json` normalizer for fixtures and compatibility.
4. Feed both agents into the same page; advertise supported controls rather than
   assuming every backend has Claude's capabilities. Add a New Codex Tab entry.
5. Verify normalizers/reducer with fixtures, runner lifecycle with a fake process,
   existing Claude replay plus Codex replay, and the Swift build.

The primary agent owns the event foundations and integration review. GPT-6 Sol
workers may own the page migration, runner/native wiring, and Codex normalization
and fixtures. Maximum concurrent workers: three. No changes to `files (2)/`.

## Boundaries

Keep the existing Claude SDK session driver. Do not adopt Headless's permission
bypass or billing fallback defaults. Codex starts with workspace-write sandboxing
and on-request approvals, with a read-only mode available in the dock. Preserve
the user's configured model when none is selected. No automatic paid-agent calls
are required for fixture verification.

HTTP SSE is a later framing/transport addition. ACP and additional agent schemas
are follow-ups, not requirements for this first vertical slice. Do not claim a
live provider test from fixture results.

## Contract v1

`AgentEvents` (browser global / CommonJS module) owns `createNormalizer(agent)`,
`register(agent, factory)`, `createState()`, and `reduce(state, event)`.
Each normalizer has `normalize(envelope) -> event[]` and `reset()`.
Each emitted event has `v: 1`, `agent`, `type`, `t`, and `raw` (original envelope).
One normalizer/reducer instance per conversation. `content` identity is explicit
(`id`, `messageId`, `kind: text|thinking`); snapshots replace, deltas append.

Events:

- `session`: `sessionId`, optional `model`, `mode`, `cwd`, `info`, `terminalCommands`.
- `turn.start`; `turn.end`: `status: success|error|cancelled`, `message?`,
  `durationMs?`, `apiMs?`, `steps?`, `cost?`, `modelUsage?`, `usage?`.
- `content.start/delta/snapshot/end`: `id`, `messageId`, `kind`, `text?`,
  `redacted?`, `final?`. `delta.text` is appended; `snapshot.text` replaces.
- `tool.start/input/result`: `id`, `name?`, `parentId?`, `input?`, `output?`,
  `isError?`. Results may arrive without a start.
- `approval.request`: `request` (existing card payload); `approval.cancel`: `id`.
- `notice`: `kind`, `message`, `terminal?`; `unknown`: `name`, `raw`.
- Existing sidecar metadata/control events (`capabilities`, `model`, `mode`,
  `effort`, `git`, `sessions`, `history`, `history.replay`, `thinking`, `usage`, `local.output`)
  retain their payload fields, but are versioned at normalization.

Ingress: Claude's existing `{type:'sdk',msg,t}` and control messages stay valid.
The Codex app-server runner emits canonical v1 events directly. The exec replay
adapter also accepts `{type:'native',agent:'codex',event:<native JSON>,t}`.
Optional `turnId` scopes exec item IDs when separate processes reuse IDs.
Runner control messages include `capabilities.features`: `approvals`, `fork`,
`history`, `models`, `effort`, `permissionMode`, `thinking`, `usage`, `git`,
`tui`, `slashCommands`, `midTurnInput`. Claude defaults retain current features;
Codex advertises only implemented features. Boot accepts `{agent:'claude'|'codex'}`.

## Initial slice verification record

The initial slice used an exec backend; the app-server correction is described below. The primary agent built the
contract, reducer, Claude normalizer, native script loading, and integration
fixes. Three `gpt-6-sol` workers contributed renderer migration, Codex runner
and menu wiring, and Codex normalization/fixtures.

Verified locally:

- Debug Swift build passed with
  `CLANG_MODULE_CACHE_PATH=/private/tmp/floatyterm-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/floatyterm-swift-cache swift build --disable-sandbox -c debug`.
  Existing module-cache/link debug-info warnings do not prevent the build.
- 21 Node tests passed: six Claude/shared-state tests, eight Codex normalizer
  tests, and seven fake Codex subprocess lifecycle tests.
- Existing Markdown classification suite passed.
- Actual WebKit replays: Claude and Codex rendered with no JavaScript errors.
  DOM checks passed: Claude 15, Codex 11. They cover final-text reconciliation,
  thinking separation, tool completion, permissions, history, capability-hidden
  controls, draft preservation, bounded inert unknown payloads, and failure cleanup.
- JS syntax checks and `git diff --check` passed.

Reproduce UI checks (macOS, requires local WebKit access):

```sh
swift Resources/SkimRender/dev/snapshot.swift 'Resources/SkimRender/dev/agent-ui-check.html?agent=claude' /tmp/claude-check.png 900 2
swift Resources/SkimRender/dev/snapshot.swift 'Resources/SkimRender/dev/agent-ui-check.html?agent=codex' /tmp/codex-check.png 900 2
```

No live Claude/Codex model call or signed release bundle was tested in this run.
Build with `./build.sh`, relaunch `FloatyTerm.app`, choose **New Codex Tab**, and
check a prompt, follow-up, tool activity, and Stop using the installed Codex login.
The untracked `files (2)/` directory was left untouched. Changes are uncommitted.

## Rich controls correction

The exec-only slice hid too much of the existing dock. The replacement keeps one
renderer and adds app-server control support in the Codex runner. A `gpt-6-luna`
worker at `xhigh` owns the runner implementation; the primary agent owns UI/native
integration and independent review.

The restored UI has passed 25 Codex and 15 Claude WebKit DOM checks, including
model/effort, usage, permission modes, slash dispatch, approval routing, history,
and draft preservation. The Swift debug build passed. Installed Codex metadata
requests returned eight models and account-limit data without a model turn.
The primary agent reviewed and corrected model IDs, sandbox schemas, startup and
shutdown handling, usage counters, history ordering, and stale native callbacks.
All ten fake app-server integration tests passed independently after review,
including exactly-once approvals and child cleanup after oversized output.
Together with the fourteen normalizer tests, 24 Node tests passed. Both WebKit
suites reported no JavaScript errors; syntax and whitespace checks passed.

The final bridge itself was checked against installed Codex: eight models, a
native thread, two account-limit windows, session listing, and git metadata were
returned successfully. No live model generation or signed release bundle was
verified. Unsupported interactive app-server requests return explicit errors and
visible notices; they are not silently approved. HTTP SSE framing remains a
follow-up input adapter.
