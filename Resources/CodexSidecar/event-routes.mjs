/* Installed Codex 0.159.2 protocol inventory. Semantic destinations, not DOM selectors. */
export const eventRoutes = {
  "error": {
    "surface": "notice",
    "title": "Notices / recovery",
    "kind": "notification"
  },
  "thread/started": {
    "surface": "session",
    "title": "Thread / project details",
    "kind": "notification"
  },
  "thread/status/changed": {
    "surface": "status",
    "title": "Status / buffering",
    "kind": "notification"
  },
  "thread/archived": {
    "surface": "session",
    "title": "Thread / project details",
    "kind": "notification"
  },
  "thread/deleted": {
    "surface": "session",
    "title": "Thread / project details",
    "kind": "notification"
  },
  "thread/unarchived": {
    "surface": "session",
    "title": "Thread / project details",
    "kind": "notification"
  },
  "thread/closed": {
    "surface": "session",
    "title": "Thread / project details",
    "kind": "notification"
  },
  "thread/reverted": {
    "surface": "session",
    "title": "Thread / project details",
    "kind": "notification"
  },
  "skills/changed": {
    "surface": "integrations",
    "title": "Integrations / MCP progress",
    "kind": "notification"
  },
  "thread/name/updated": {
    "surface": "session",
    "title": "Thread / project details",
    "kind": "notification"
  },
  "thread/attachment/updated": {
    "surface": "session",
    "title": "Thread / project details",
    "kind": "notification"
  },
  "thread/goal/updated": {
    "surface": "goal",
    "title": "Goal progress",
    "kind": "notification"
  },
  "thread/goal/cleared": {
    "surface": "goal",
    "title": "Goal progress",
    "kind": "notification"
  },
  "thread/queue/changed": {
    "surface": "queue",
    "title": "Queued messages",
    "kind": "notification"
  },
  "project/changed": {
    "surface": "session",
    "title": "Thread / project details",
    "kind": "notification"
  },
  "thread/project/updated": {
    "surface": "session",
    "title": "Thread / project details",
    "kind": "notification"
  },
  "thread/environment/connected": {
    "surface": "environment",
    "title": "Environment / remote control",
    "kind": "notification"
  },
  "thread/environment/disconnected": {
    "surface": "environment",
    "title": "Environment / remote control",
    "kind": "notification"
  },
  "thread/settings/updated": {
    "surface": "session",
    "title": "Thread / project details",
    "kind": "notification"
  },
  "thread/tokenUsage/updated": {
    "surface": "account",
    "title": "Account / usage / auth",
    "kind": "notification"
  },
  "turn/started": {
    "surface": "status",
    "title": "Status / buffering",
    "kind": "notification"
  },
  "hook/started": {
    "surface": "hook",
    "title": "Hook activity",
    "kind": "notification"
  },
  "turn/completed": {
    "surface": "footer",
    "title": "Turn completion / metadata",
    "kind": "notification"
  },
  "hook/completed": {
    "surface": "hook",
    "title": "Hook activity",
    "kind": "notification"
  },
  "turn/diff/updated": {
    "surface": "turn-diff",
    "title": "Turn Changes fold",
    "kind": "notification"
  },
  "turn/plan/updated": {
    "surface": "plan",
    "title": "Structured plan",
    "kind": "notification"
  },
  "item/started": {
    "surface": "inspector",
    "title": "Protocol / host diagnostics",
    "kind": "notification"
  },
  "item/autoApprovalReview/started": {
    "surface": "approval-review",
    "title": "Automatic approval review",
    "kind": "notification"
  },
  "item/autoApprovalReview/completed": {
    "surface": "approval-review",
    "title": "Automatic approval review",
    "kind": "notification"
  },
  "autoApprovalReview/strictReviewRequired": {
    "surface": "approval-review",
    "title": "Automatic approval review",
    "kind": "notification"
  },
  "item/completed": {
    "surface": "inspector",
    "title": "Protocol / host diagnostics",
    "kind": "notification"
  },
  "item/agentMessage/delta": {
    "surface": "assistant",
    "title": "Assistant message",
    "kind": "notification"
  },
  "item/plan/delta": {
    "surface": "plan",
    "title": "Structured plan",
    "kind": "notification"
  },
  "command/exec/outputDelta": {
    "surface": "process",
    "title": "Process / terminal input",
    "kind": "notification"
  },
  "process/outputDelta": {
    "surface": "process",
    "title": "Process / terminal input",
    "kind": "notification"
  },
  "process/exited": {
    "surface": "process",
    "title": "Process / terminal input",
    "kind": "notification"
  },
  "item/commandExecution/outputDelta": {
    "surface": "command",
    "title": "Command tool",
    "kind": "notification"
  },
  "item/commandExecution/terminalInteraction": {
    "surface": "process",
    "title": "Process / terminal input",
    "kind": "notification"
  },
  "item/fileChange/outputDelta": {
    "surface": "file",
    "title": "File changes",
    "kind": "notification"
  },
  "item/fileChange/patchUpdated": {
    "surface": "file",
    "title": "File changes",
    "kind": "notification"
  },
  "serverRequest/resolved": {
    "surface": "approval",
    "title": "Command / file approval",
    "kind": "notification"
  },
  "item/mcpToolCall/progress": {
    "surface": "integrations",
    "title": "Integrations / MCP progress",
    "kind": "notification"
  },
  "mcpServer/oauthLogin/completed": {
    "surface": "integrations",
    "title": "Integrations / MCP progress",
    "kind": "notification"
  },
  "mcpServer/startupStatus/updated": {
    "surface": "integrations",
    "title": "Integrations / MCP progress",
    "kind": "notification"
  },
  "mcpServer/event/stream/notification": {
    "surface": "integrations",
    "title": "Integrations / MCP progress",
    "kind": "notification"
  },
  "account/updated": {
    "surface": "account",
    "title": "Account / usage / auth",
    "kind": "notification"
  },
  "account/gatewayOAuth/changed": {
    "surface": "account",
    "title": "Account / usage / auth",
    "kind": "notification"
  },
  "account/rateLimits/updated": {
    "surface": "account",
    "title": "Account / usage / auth",
    "kind": "notification"
  },
  "app/list/updated": {
    "surface": "integrations",
    "title": "Integrations / MCP progress",
    "kind": "notification"
  },
  "remoteControl/status/changed": {
    "surface": "environment",
    "title": "Environment / remote control",
    "kind": "notification"
  },
  "externalAgentConfig/import/progress": {
    "surface": "integrations",
    "title": "Integrations / MCP progress",
    "kind": "notification"
  },
  "externalAgentConfig/import/completed": {
    "surface": "integrations",
    "title": "Integrations / MCP progress",
    "kind": "notification"
  },
  "fs/changed": {
    "surface": "session",
    "title": "Thread / project details",
    "kind": "notification"
  },
  "item/reasoning/summaryTextDelta": {
    "surface": "thinking",
    "title": "Thinking fold",
    "kind": "notification"
  },
  "item/reasoning/summaryPartAdded": {
    "surface": "thinking",
    "title": "Thinking fold",
    "kind": "notification"
  },
  "item/reasoning/textDelta": {
    "surface": "thinking",
    "title": "Thinking fold",
    "kind": "notification"
  },
  "thread/compacted": {
    "surface": "status",
    "title": "Status / buffering",
    "kind": "notification"
  },
  "model/rerouted": {
    "surface": "notice",
    "title": "Notices / recovery",
    "kind": "notification"
  },
  "model/verification": {
    "surface": "notice",
    "title": "Notices / recovery",
    "kind": "notification"
  },
  "modelProvider/authRecoveryStarted": {
    "surface": "notice",
    "title": "Notices / recovery",
    "kind": "notification"
  },
  "modelProvider/authRecoveryCompleted": {
    "surface": "notice",
    "title": "Notices / recovery",
    "kind": "notification"
  },
  "turn/moderationMetadata": {
    "surface": "footer",
    "title": "Turn completion / metadata",
    "kind": "notification"
  },
  "model/safetyBuffering/updated": {
    "surface": "status",
    "title": "Status / buffering",
    "kind": "notification"
  },
  "warning": {
    "surface": "notice",
    "title": "Notices / recovery",
    "kind": "notification"
  },
  "guardianWarning": {
    "surface": "notice",
    "title": "Notices / recovery",
    "kind": "notification"
  },
  "deprecationNotice": {
    "surface": "notice",
    "title": "Notices / recovery",
    "kind": "notification"
  },
  "configWarning": {
    "surface": "notice",
    "title": "Notices / recovery",
    "kind": "notification"
  },
  "fuzzyFileSearch/sessionUpdated": {
    "surface": "search",
    "title": "Search / file picker",
    "kind": "notification"
  },
  "fuzzyFileSearch/sessionCompleted": {
    "surface": "search",
    "title": "Search / file picker",
    "kind": "notification"
  },
  "thread/realtime/started": {
    "surface": "realtime",
    "title": "Realtime voice",
    "kind": "notification"
  },
  "thread/realtime/itemAdded": {
    "surface": "realtime",
    "title": "Realtime voice",
    "kind": "notification"
  },
  "thread/realtime/item/started": {
    "surface": "realtime",
    "title": "Realtime voice",
    "kind": "notification"
  },
  "thread/realtime/item/transcript/delta": {
    "surface": "realtime",
    "title": "Realtime voice",
    "kind": "notification"
  },
  "thread/realtime/item/completed": {
    "surface": "realtime",
    "title": "Realtime voice",
    "kind": "notification"
  },
  "thread/realtime/transcript/delta": {
    "surface": "realtime",
    "title": "Realtime voice",
    "kind": "notification"
  },
  "thread/realtime/transcript/done": {
    "surface": "realtime",
    "title": "Realtime voice",
    "kind": "notification"
  },
  "thread/realtime/outputAudio/delta": {
    "surface": "realtime",
    "title": "Realtime voice",
    "kind": "notification"
  },
  "thread/realtime/sdp": {
    "surface": "realtime",
    "title": "Realtime voice",
    "kind": "notification"
  },
  "thread/realtime/error": {
    "surface": "realtime",
    "title": "Realtime voice",
    "kind": "notification"
  },
  "thread/realtime/closed": {
    "surface": "realtime",
    "title": "Realtime voice",
    "kind": "notification"
  },
  "windows/worldWritableWarning": {
    "surface": "environment",
    "title": "Environment / remote control",
    "kind": "notification"
  },
  "windowsSandbox/setupCompleted": {
    "surface": "environment",
    "title": "Environment / remote control",
    "kind": "notification"
  },
  "account/login/completed": {
    "surface": "account",
    "title": "Account / usage / auth",
    "kind": "notification"
  },
  "item/commandExecution/requestApproval": {
    "surface": "approval",
    "title": "Command / file approval",
    "kind": "request"
  },
  "item/fileChange/requestApproval": {
    "surface": "approval",
    "title": "Command / file approval",
    "kind": "request"
  },
  "item/tool/requestUserInput": {
    "surface": "questions",
    "title": "Questions",
    "kind": "request"
  },
  "mcpServer/elicitation/request": {
    "surface": "elicitation",
    "title": "MCP elicitation",
    "kind": "request"
  },
  "item/permissions/requestApproval": {
    "surface": "permissions",
    "title": "Permission scope",
    "kind": "request"
  },
  "item/tool/call": {
    "surface": "integrations",
    "title": "Integrations / MCP progress",
    "kind": "request"
  },
  "account/chatgptAuthTokens/refresh": {
    "surface": "account",
    "title": "Account / usage / auth",
    "kind": "request"
  },
  "attestation/generate": {
    "surface": "environment",
    "title": "Environment / remote control",
    "kind": "request"
  },
  "currentTime/read": {
    "surface": "inspector",
    "title": "Protocol / host diagnostics",
    "kind": "request"
  },
  "applyPatchApproval": {
    "surface": "approval",
    "title": "Command / file approval",
    "kind": "request"
  },
  "execCommandApproval": {
    "surface": "approval",
    "title": "Command / file approval",
    "kind": "request"
  },
  "userMessage": {
    "surface": "assistant",
    "title": "Assistant message",
    "kind": "item"
  },
  "hookPrompt": {
    "surface": "hook",
    "title": "Hook activity",
    "kind": "item"
  },
  "agentMessage": {
    "surface": "assistant",
    "title": "Assistant message",
    "kind": "item"
  },
  "functionCallOutput": {
    "surface": "command",
    "title": "Command tool",
    "kind": "item"
  },
  "plan": {
    "surface": "plan",
    "title": "Structured plan",
    "kind": "item"
  },
  "reasoning": {
    "surface": "thinking",
    "title": "Thinking fold",
    "kind": "item"
  },
  "commandExecution": {
    "surface": "command",
    "title": "Command tool",
    "kind": "item"
  },
  "fileChange": {
    "surface": "file",
    "title": "File changes",
    "kind": "item"
  },
  "mcpToolCall": {
    "surface": "integrations",
    "title": "Integrations / MCP progress",
    "kind": "item"
  },
  "dynamicToolCall": {
    "surface": "integrations",
    "title": "Integrations / MCP progress",
    "kind": "item"
  },
  "collabAgentToolCall": {
    "surface": "agent",
    "title": "Agent transcript",
    "kind": "item"
  },
  "subAgentActivity": {
    "surface": "agent",
    "title": "Agent transcript",
    "kind": "item"
  },
  "webSearch": {
    "surface": "search",
    "title": "Search / file picker",
    "kind": "item"
  },
  "imageView": {
    "surface": "image",
    "title": "Image / generated result",
    "kind": "item"
  },
  "sleep": {
    "surface": "status",
    "title": "Status / buffering",
    "kind": "item"
  },
  "imageGeneration": {
    "surface": "image",
    "title": "Image / generated result",
    "kind": "item"
  },
  "enteredReviewMode": {
    "surface": "review",
    "title": "Review mode",
    "kind": "item"
  },
  "exitedReviewMode": {
    "surface": "review",
    "title": "Review mode",
    "kind": "item"
  },
  "contextCompaction": {
    "surface": "status",
    "title": "Status / buffering",
    "kind": "item"
  }
};
export function safePayload(value, depth = 0) {
  if (depth > 8) return '[nested details omitted]';
  if (typeof value === 'string') return value.length > 16000 ? value.slice(0, 16000) + '\n[Details truncated]' : value;
  if (Array.isArray(value)) return value.slice(0, 100).map(v => safePayload(v, depth + 1));
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).slice(0, 100).map(([k, v]) => [k,
    /^(accessToken|refreshToken|idToken|apiKey|clientSecret|password|secret|token|authorization|challenge|sdp|deltaBase64)$/i.test(k) && !(v && typeof v === 'object' && ['string','number','integer','boolean','array'].includes(v.type)) ? '[not displayed]' : safePayload(v, depth + 1)]));
  return value;
}
