# Codex event to DOM map

Implemented destinations for the installed Codex 0.159.2 inventory: **83 notifications, 11 server requests, 19 item types**. The routing registry is `Resources/CodexSidecar/event-routes.mjs`. Coverage means each protocol variant has a destination or explicit availability handling; it does not imply every optional host integration is connected.

## Pipeline

`app-server JSON-RPC → CodexSidecar → AgentEvents v1 → reducer state → AgentChat DOM`

Provider handling stays in the bridge. The renderer consumes `content.*`, `tool.*`, `turn.*`, `plan.snapshot`, `surface.snapshot`, `media.snapshot` and request lifecycle events. Named detail panels use one safe structured-value renderer with specialized goal, queue, transcript and interactive forms.

## Ownership and updates

- Item IDs combine thread, turn and item. Turn plans/diffs use thread and turn. Registered child threads render in the owning Agent transcript; their interactive cards remain visible in the main conversation.
- Content deltas append; content snapshots replace. Reasoning summaries assemble by part index. Raw reasoning text is omitted, with a metadata panel identifying that stream.
- Turn diffs replace the named historical Changes fold. Plans replace their turn panel and the current task board. Tool completion preserves media and named detail panels.
- Output decodes incrementally, separates stderr, and retains the last 262144 characters per stream with truncation metadata. An empty final process capture keeps previously streamed output.
- Native numeric/string request IDs remain distinct. Submitted controls disable immediately. Offered decisions and permission scope are validated before the bridge responds once.
- Thread status, safety buffering and closed/deleted state update the dock. Goals, queued messages, attachments, account, integrations and environment details appear in a folded session section.
- Safe links allow HTTP(S). Tokens, audio bytes, SDP and challenges are excluded from general detail inspection. Future unknown variants retain a bounded diagnostic view.

## Availability boundaries

Native command/file approvals, questions, permission grants and MCP form/URL elicitation are connected. MCP forms support scalar fields, titled/untitled enums and multiple selection. Device verification requires a host authenticator and is visibly unavailable. Three native host tools are registered for new conversations: `floatyterm_get_context`, `floatyterm_reveal_path`, and `floatyterm_open_file`. Workspace paths are checked after resolving symlinks. Unknown tools return failed results; resume/fork do not send a new catalog. See [host tool support](codex-host-tools.md). Managed credentials refresh through `account/read`; browser sign-in and cancellation use native Codex OAuth. External-token callbacks and attestation return explicit unsupported errors. Realtime microphone capture and playback use native PCM16 audio through app-server WebSocket transport, with start/mute/end controls; WebRTC SDP negotiation is not used. See [voice and credentials](codex-voice-and-credentials.md). Embedded MCP provider applications display structured resource details rather than execute provider HTML.

Catalog, search, import, hook, review and platform events display named detail state. Receiving these notifications does not add a feature launcher or implement a remote environment controller. History retains recorded item details; image previews are loaded for live image results. No live model generation was performed for this change.

## Persistent preview

Open `Resources/SkimRender/dev/codex-ui-preview/` via the repository HTTP server on port 4318. **Implemented renderer** links to `codex-event-surfaces.html` for remaining components and `codex-turn-diff.html` for Changes. The lab keeps the existing 28 component IDs and browser review notes. All preview controls operate locally.

## Protocol destinations

### Server notifications

| Native variant | Handling | Shared event | DOM destination | Update rule |
|---|---|---|---|---|
| `error` | Mapped | `notice + surface.snapshot` | `.ck-notice; .ck-surface` | Supplied error message and retry flag; turn completion remains authoritative. |
| `thread/started` | Named details | `surface.snapshot` | `.ck-surface[data-surface="session"]` | Replace named detail state; preserve expansion. |
| `thread/status/changed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="status"]` | Update busy status; pending blocking requests keep Waiting for you. |
| `thread/archived` | Named details | `surface.snapshot` | `.ck-surface[data-surface="session"]` | Replace named detail state; preserve expansion. |
| `thread/deleted` | Named details | `surface.snapshot` | `.ck-surface[data-surface="session"]` | Disable composer and settle live controls; retain transcript. |
| `thread/unarchived` | Named details | `surface.snapshot` | `.ck-surface[data-surface="session"]` | Replace named detail state; preserve expansion. |
| `thread/closed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="session"]` | Disable composer and settle live controls; retain transcript. |
| `thread/reverted` | Named details | `surface.snapshot` | `.ck-surface[data-surface="session"]` | Replace named detail state; preserve expansion. |
| `skills/changed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="integrations"]` | Replace named detail state; preserve expansion. |
| `thread/name/updated` | Mapped | `title` | `.ck-info; session picker` | Replace thread title. |
| `thread/attachment/updated` | Named details | `surface.snapshot` | `.ck-surface[data-surface="session"]` | Fetch authoritative list after notification; display unavailable on RPC error. |
| `thread/goal/updated` | Named details | `surface.snapshot` | `.ck-surface[data-surface="goal"]` | Replace objective, budget, tokens, elapsed time and status. |
| `thread/goal/cleared` | Named details | `surface.snapshot` | `.ck-surface[data-surface="goal"]` | Remove goal state for the thread. |
| `thread/queue/changed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="queue"]` | Fetch authoritative list after notification; display unavailable on RPC error. |
| `project/changed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="session"]` | Replace named detail state; preserve expansion. |
| `thread/project/updated` | Named details | `surface.snapshot` | `.ck-surface[data-surface="session"]` | Replace named detail state; preserve expansion. |
| `thread/environment/connected` | Named details | `surface.snapshot` | `.ck-surface[data-surface="environment"]` | Replace named detail state; preserve expansion. |
| `thread/environment/disconnected` | Named details | `surface.snapshot` | `.ck-surface[data-surface="environment"]` | Replace named detail state; preserve expansion. |
| `thread/settings/updated` | Mapped | `surface.snapshot + model/effort` | `.ck-surface; .ck-status` | Retain settings details and update supported controls. |
| `thread/tokenUsage/updated` | Mapped | `usage; child surface.snapshot` | `.ck-ctx; .ck-usage-panel; child .ck-surface` | Replace token snapshots. |
| `turn/started` | Mapped | `turn.start` | `.ck-turn` | Bind thread and turn IDs. |
| `hook/started` | Named details | `surface.snapshot` | `.ck-surface[data-surface="hook"]` | Replace named detail state; preserve expansion. |
| `turn/completed` | Mapped | `turn.end` | `.ck-foot; .ck-status-text` | Finalize turn and settle active controls. |
| `hook/completed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="hook"]` | Replace named detail state; preserve expansion. |
| `turn/diff/updated` | Mapped | `turn.diff.snapshot` | `.ck-turn-diff` | Replace aggregate diff for named turn; empty diff clears it. |
| `turn/plan/updated` | Mapped | `plan.snapshot` | `.ck-surface[data-surface="plan"]; .ck-tasks` | Replace steps; retain turn plan and update current task board. |
| `item/started` | Mapped | `content/tool lifecycle or surface.snapshot` | `.ck-text; .ck-think; .ck-row; .ck-surface` | Upsert item by thread, turn and item ID. |
| `item/autoApprovalReview/started` | Named details | `surface.snapshot` | `.ck-surface[data-surface="approval-review"]` | Replace named detail state; preserve expansion. |
| `item/autoApprovalReview/completed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="approval-review"]` | Replace named detail state; preserve expansion. |
| `autoApprovalReview/strictReviewRequired` | Named details | `surface.snapshot` | `.ck-surface[data-surface="approval-review"]` | Replace named detail state; preserve expansion. |
| `item/completed` | Mapped | `content/tool lifecycle or surface.snapshot` | `.ck-text; .ck-think; .ck-row; .ck-surface` | Finalize the same item; retain detail panels. |
| `item/agentMessage/delta` | Mapped | `content.delta` | `.ck-text.sk-doc` | Append to the owning message. |
| `item/plan/delta` | Mapped | `tool.input` | `.ck-row; .ck-detail` | Append text to plan item. |
| `command/exec/outputDelta` | Mapped | `tool.output.delta` | `.ck-stream-output` | Incrementally decode UTF-8 bytes per stream. |
| `process/outputDelta` | Mapped | `tool.output.delta` | `.ck-stream-output; .ck-process-input` | Incrementally decode bytes; show stdin for supplied process handle. |
| `process/exited` | Mapped | `tool.result` | `.ck-row; .ck-detail` | Keep streamed output when final captures are empty. |
| `item/commandExecution/outputDelta` | Mapped | `tool.output.delta` | `.ck-stream-output` | Append bounded command output. |
| `item/commandExecution/terminalInteraction` | Named details | `surface.snapshot` | `.ck-surface[data-surface="process"]` | Replace named detail state; preserve expansion. |
| `item/fileChange/outputDelta` | Mapped | `tool.output.delta` | `.ck-stream-output` | Append bounded live output. |
| `item/fileChange/patchUpdated` | Mapped | `tool.input` | `.ck-row; .ck-change` | Replace current file changes. |
| `serverRequest/resolved` | Mapped | `approval.cancel` | `.ck-card; .ck-status-text` | Resolve the matching typed native request. |
| `item/mcpToolCall/progress` | Mapped | `tool.progress` | `.ck-row-meta` | Replace progress message. |
| `mcpServer/oauthLogin/completed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="integrations"]` | Replace named detail state; preserve expansion. |
| `mcpServer/startupStatus/updated` | Named details | `surface.snapshot` | `.ck-surface[data-surface="integrations"]` | Replace named detail state; preserve expansion. |
| `mcpServer/event/stream/notification` | Named details | `surface.snapshot` | `.ck-surface[data-surface="integrations"]` | Replace named detail state; preserve expansion. |
| `account/updated` | Named details | `surface.snapshot` | `.ck-surface[data-surface="account"]` | Replace named detail state; preserve expansion. |
| `account/gatewayOAuth/changed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="account"]` | Replace named detail state; preserve expansion. |
| `account/rateLimits/updated` | Mapped | `usage` | `.ck-usage-panel` | Replace rate limit windows. |
| `app/list/updated` | Named details | `surface.snapshot` | `.ck-surface[data-surface="integrations"]` | Replace named detail state; preserve expansion. |
| `remoteControl/status/changed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="environment"]` | Replace named detail state; preserve expansion. |
| `externalAgentConfig/import/progress` | Named details | `surface.snapshot` | `.ck-surface[data-surface="integrations"]` | Replace named detail state; preserve expansion. |
| `externalAgentConfig/import/completed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="integrations"]` | Replace named detail state; preserve expansion. |
| `fs/changed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="session"]` | Replace named detail state; preserve expansion. |
| `item/reasoning/summaryTextDelta` | Mapped | `content.snapshot` | `.ck-think` | Append per summary index and replace the assembled summary. |
| `item/reasoning/summaryPartAdded` | Named details | `surface.snapshot` | `.ck-surface[data-surface="thinking"]` | Replace named detail state; preserve expansion. |
| `item/reasoning/textDelta` | Mapped | `surface.snapshot` | `.ck-surface` | Show stream metadata; omit raw reasoning text. |
| `thread/compacted` | Mapped | `notice` | `.ck-notice` | Show context compaction notice. |
| `model/rerouted` | Named details | `surface.snapshot` | `.ck-surface[data-surface="notice"]` | Replace named detail state; preserve expansion. |
| `model/verification` | Named details | `surface.snapshot` | `.ck-surface[data-surface="notice"]` | Replace named detail state; preserve expansion. |
| `modelProvider/authRecoveryStarted` | Named details | `surface.snapshot` | `.ck-surface[data-surface="notice"]` | Replace named detail state; preserve expansion. |
| `modelProvider/authRecoveryCompleted` | Named details | `surface.snapshot` | `.ck-surface[data-surface="notice"]` | Replace named detail state; preserve expansion. |
| `turn/moderationMetadata` | Named details | `surface.snapshot` | `.ck-surface[data-surface="footer"]` | Replace named detail state; preserve expansion. |
| `model/safetyBuffering/updated` | Named details | `surface.snapshot` | `.ck-surface[data-surface="status"]` | Replace named detail state; preserve expansion. |
| `warning` | Mapped | `notice` | `.ck-notice` | Display supplied warning. |
| `guardianWarning` | Named details | `surface.snapshot` | `.ck-surface[data-surface="notice"]` | Replace named detail state; preserve expansion. |
| `deprecationNotice` | Named details | `surface.snapshot` | `.ck-surface[data-surface="notice"]` | Replace named detail state; preserve expansion. |
| `configWarning` | Named details | `surface.snapshot` | `.ck-surface[data-surface="notice"]` | Replace named detail state; preserve expansion. |
| `fuzzyFileSearch/sessionUpdated` | Named details | `surface.snapshot` | `.ck-surface[data-surface="search"]` | Replace named detail state; preserve expansion. |
| `fuzzyFileSearch/sessionCompleted` | Named details | `surface.snapshot` | `.ck-surface[data-surface="search"]` | Replace named detail state; preserve expansion. |
| `thread/realtime/started` | Named details | `surface.snapshot` | `.ck-surface[data-surface="realtime"]` | Native WebSocket PCM16 capture/playback; DOM receives session/transcript state and audio metadata. |
| `thread/realtime/itemAdded` | Named details | `surface.snapshot` | `.ck-surface[data-surface="realtime"]` | Native WebSocket PCM16 capture/playback; DOM receives session/transcript state and audio metadata. |
| `thread/realtime/item/started` | Named details | `surface.snapshot` | `.ck-surface[data-surface="realtime"]` | Native WebSocket PCM16 capture/playback; DOM receives session/transcript state and audio metadata. |
| `thread/realtime/item/transcript/delta` | Named details | `surface.snapshot` | `.ck-surface[data-surface="realtime"]` | Native WebSocket PCM16 capture/playback; DOM receives session/transcript state and audio metadata. |
| `thread/realtime/item/completed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="realtime"]` | Native WebSocket PCM16 capture/playback; DOM receives session/transcript state and audio metadata. |
| `thread/realtime/transcript/delta` | Named details | `surface.snapshot` | `.ck-surface[data-surface="realtime"]` | Native WebSocket PCM16 capture/playback; DOM receives session/transcript state and audio metadata. |
| `thread/realtime/transcript/done` | Named details | `surface.snapshot` | `.ck-surface[data-surface="realtime"]` | Native WebSocket PCM16 capture/playback; DOM receives session/transcript state and audio metadata. |
| `thread/realtime/outputAudio/delta` | Named details | `surface.snapshot` | `.ck-surface[data-surface="realtime"]` | Native WebSocket PCM16 capture/playback; DOM receives session/transcript state and audio metadata. |
| `thread/realtime/sdp` | Named details | `surface.snapshot` | `.ck-surface[data-surface="realtime"]` | Native WebSocket PCM16 capture/playback; DOM receives session/transcript state and audio metadata. |
| `thread/realtime/error` | Named details | `surface.snapshot` | `.ck-surface[data-surface="realtime"]` | Native WebSocket PCM16 capture/playback; DOM receives session/transcript state and audio metadata. |
| `thread/realtime/closed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="realtime"]` | Native WebSocket PCM16 capture/playback; DOM receives session/transcript state and audio metadata. |
| `windows/worldWritableWarning` | Named details | `surface.snapshot` | `.ck-surface[data-surface="environment"]` | Replace named detail state; preserve expansion. |
| `windowsSandbox/setupCompleted` | Named details | `surface.snapshot` | `.ck-surface[data-surface="environment"]` | Replace named detail state; preserve expansion. |
| `account/login/completed` | Named details | `surface.snapshot` | `.ck-surface[data-surface="account"]` | Replace named detail state; preserve expansion. |

### Server requests

| Native variant | Handling | Shared event | DOM destination | Update rule |
|---|---|---|---|---|
| `item/commandExecution/requestApproval` | Interactive | `approval.request / approval.cancel` | `.ck-native-card[data-kind="approval"]` | Validate native response shape and offered decisions; respond exactly once. |
| `item/fileChange/requestApproval` | Interactive | `approval.request / approval.cancel` | `.ck-native-card[data-kind="approval"]` | Validate native response shape and offered decisions; respond exactly once. |
| `item/tool/requestUserInput` | Interactive | `approval.request / approval.cancel` | `.ck-native-card[data-kind="questions"]` | Validate native response shape and offered decisions; respond exactly once. |
| `mcpServer/elicitation/request` | Interactive | `approval.request / approval.cancel` | `.ck-native-card[data-kind="elicitation"]` | Validate native response shape and offered decisions; respond exactly once. |
| `item/permissions/requestApproval` | Interactive | `approval.request / approval.cancel` | `.ck-native-card[data-kind="permissions"]` | Validate native response shape and offered decisions; respond exactly once. |
| `item/tool/call` | Native host tools | `tool.start / tool.result` | `.ck-row; .ck-detail` | Validate arguments, dispatch to native host, return exactly one response; fail unknown tools or expired calls. |
| `account/chatgptAuthTokens/refresh` | Managed sign-in recovery | `surface.snapshot` | `.ck-surface[data-surface="account"]` | Explicit JSON-RPC error; no credentials or attestation fabricated. |
| `attestation/generate` | Unavailable callback | `surface.snapshot` | `.ck-surface[data-surface="environment"]` | Explicit JSON-RPC error; no credentials or attestation fabricated. |
| `currentTime/read` | Host response | `surface.snapshot` | `.ck-surface[data-surface="inspector"]` | Return host time and record completion. |
| `applyPatchApproval` | Interactive | `approval.request / approval.cancel` | `.ck-native-card[data-kind="approval"]` | Validate native response shape and offered decisions; respond exactly once. |
| `execCommandApproval` | Interactive | `approval.request / approval.cancel` | `.ck-native-card[data-kind="approval"]` | Validate native response shape and offered decisions; respond exactly once. |

### Thread items

| Native variant | Handling | Shared event | DOM destination | Update rule |
|---|---|---|---|---|
| `userMessage` | Existing prompt | `optimistic prompt` | `.ck-user` | Local sent prompt owns the user message; replay reads recorded prompts. |
| `hookPrompt` | Mapped | `tool lifecycle / surface.snapshot` | `.ck-row; .ck-surface[data-surface="hook"]` | Keep native item details in a named panel; completed tools retain results. |
| `agentMessage` | Mapped | `content lifecycle + surface.snapshot` | `.ck-text; .ck-surface[data-surface="assistant"]` | Final snapshot replaces text; show citations/questions/phase details. |
| `functionCallOutput` | Mapped | `tool lifecycle / surface.snapshot` | `.ck-row; .ck-surface[data-surface="command"]` | Keep native item details in a named panel; completed tools retain results. |
| `plan` | Mapped | `tool lifecycle / surface.snapshot` | `.ck-row; .ck-surface[data-surface="plan"]` | Keep native item details in a named panel; completed tools retain results. |
| `reasoning` | Summary only | `content lifecycle` | `.ck-think` | Show indexed summary text; omit raw reasoning. |
| `commandExecution` | Mapped | `tool lifecycle / surface.snapshot` | `.ck-row; .ck-surface[data-surface="command"]` | Keep native item details in a named panel; completed tools retain results. |
| `fileChange` | Mapped | `tool lifecycle / surface.snapshot` | `.ck-row; .ck-surface[data-surface="file"]` | Keep native item details in a named panel; completed tools retain results. |
| `mcpToolCall` | Mapped | `tool lifecycle / surface.snapshot` | `.ck-row; .ck-surface[data-surface="integrations"]` | Keep native item details in a named panel; completed tools retain results. |
| `dynamicToolCall` | Mapped | `tool lifecycle / surface.snapshot` | `.ck-row; .ck-surface[data-surface="integrations"]` | Keep native item details in a named panel; completed tools retain results. |
| `collabAgentToolCall` | Mapped | `tool lifecycle / surface.snapshot` | `.ck-row; .ck-surface[data-surface="agent"]` | Keep native item details in a named panel; completed tools retain results. |
| `subAgentActivity` | Mapped | `tool lifecycle / surface.snapshot` | `.ck-row; .ck-surface[data-surface="agent"]` | Keep native item details in a named panel; completed tools retain results. |
| `webSearch` | Mapped | `tool lifecycle / surface.snapshot` | `.ck-row; .ck-surface[data-surface="search"]` | Keep native item details in a named panel; completed tools retain results. |
| `imageView` | Mapped | `tool lifecycle + media.snapshot` | `.ck-row; .ck-media` | Load supported local images up to 4 MiB; otherwise show unavailable preview. |
| `sleep` | Mapped | `tool lifecycle / surface.snapshot` | `.ck-row; .ck-surface[data-surface="status"]` | Keep native item details in a named panel; completed tools retain results. |
| `imageGeneration` | Mapped | `tool lifecycle + media.snapshot` | `.ck-row; .ck-media` | Load supported local images up to 4 MiB; otherwise show unavailable preview. |
| `enteredReviewMode` | Mapped | `tool lifecycle / surface.snapshot` | `.ck-row; .ck-surface[data-surface="review"]` | Keep native item details in a named panel; completed tools retain results. |
| `exitedReviewMode` | Mapped | `tool lifecycle / surface.snapshot` | `.ck-row; .ck-surface[data-surface="review"]` | Keep native item details in a named panel; completed tools retain results. |
| `contextCompaction` | Mapped | `tool lifecycle / surface.snapshot` | `.ck-row; .ck-surface[data-surface="status"]` | Keep native item details in a named panel; completed tools retain results. |
