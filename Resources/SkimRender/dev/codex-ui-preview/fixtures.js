/* Synthetic fixtures and current routing inventory. No provider calls. */
window.CODEX_UI_LAB = {
  "version": 1,
  "protocol": "0.159.2",
  "components": [
    {
      "id": "assistant",
      "title": "Assistant message",
      "group": "Conversation",
      "description": "Stream text into one message, then replace it with the authoritative final snapshot.",
      "dom": ".ck-text.sk-doc",
      "rule": "Append deltas; final snapshot replaces text.",
      "method": "item/agentMessage/delta",
      "fixture": {
        "method": "item/agentMessage/delta",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "delta": "The output stream now updates the existing command row."
        }
      },
      "initial": "done"
    },
    {
      "id": "thinking",
      "title": "Thinking fold",
      "group": "Conversation",
      "description": "A quiet summary line with elapsed time; expand for reasoning parts.",
      "dom": ".ck-think",
      "rule": "Track summary parts separately from raw reasoning.",
      "method": "item/reasoning/summaryTextDelta",
      "fixture": {
        "method": "item/reasoning/summaryTextDelta",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "summaryIndex": 0,
          "delta": "Checking stream ownership before changing the renderer."
        }
      },
      "initial": "running"
    },
    {
      "id": "command",
      "title": "Command tool",
      "group": "Activity",
      "description": "Live stdout, command details and exit status share one tool row.",
      "dom": ".ck-row + .ck-detail > .ck-out",
      "rule": "Append output to this item; replace with final aggregatedOutput.",
      "method": "item/commandExecution/outputDelta",
      "fixture": {
        "method": "item/commandExecution/outputDelta",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "delta": "Analyzing source files\u2026\n3 warnings found\n"
        }
      },
      "initial": "running"
    },
    {
      "id": "file",
      "title": "File changes",
      "group": "Activity",
      "description": "Per-file patches and application logs stay attached to their tool.",
      "dom": ".ck-file-changes",
      "rule": "Replace patch snapshots and update matching approval previews.",
      "method": "item/fileChange/patchUpdated",
      "fixture": {
        "method": "item/fileChange/patchUpdated",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "changes": [
            {
              "path": "src/events.ts",
              "kind": {
                "type": "update",
                "move_path": null
              },
              "diff": "@@ -12,2 +12,3 @@\n-  output += delta;\n+  streams.get(itemId).append(delta);\n+  paintOutput(itemId);"
            }
          ]
        }
      },
      "initial": "done"
    },
    {
      "id": "turn-diff",
      "title": "Turn Changes fold",
      "group": "Conversation",
      "description": "One aggregate Changes fold per turn, separate from individual file tools.",
      "dom": ".ck-turn-diff (proposed)",
      "rule": "Replace the complete diff on the same thread + turn.",
      "method": "turn/diff/updated",
      "fixture": {
        "method": "turn/diff/updated",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "diff": "diff --git a/src/events.ts b/src/events.ts\n@@ -12,2 +12,3 @@\n-  output += delta;\n+  streams.get(itemId).append(delta);\n+  paintOutput(itemId);"
        }
      },
      "initial": "done"
    },
    {
      "id": "plan",
      "title": "Structured plan",
      "group": "Progress",
      "description": "Steps remain visible above the dock with a compact progress summary.",
      "dom": ".ck-tasks",
      "rule": "Replace the step list and explanation; preserve the open fold.",
      "method": "turn/plan/updated",
      "fixture": {
        "method": "turn/plan/updated",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "explanation": "Route output into its owning item before painting.",
          "plan": [
            {
              "step": "Inspect event ownership",
              "status": "completed"
            },
            {
              "step": "Add live output rendering",
              "status": "inProgress"
            },
            {
              "step": "Review narrow layout",
              "status": "pending"
            }
          ]
        }
      },
      "initial": "running"
    },
    {
      "id": "approval",
      "title": "Command / file approval",
      "group": "Interaction",
      "description": "Show the action, scope and offered decisions before responding.",
      "dom": ".ck-card",
      "rule": "One card per request ID; submit and resolve exactly once.",
      "method": "item/commandExecution/requestApproval",
      "fixture": {
        "method": "item/commandExecution/requestApproval",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "command": "npm run build",
          "cwd": "/workspace/floatyterm",
          "reason": "Build the updated interface.",
          "availableDecisions": [
            "accept",
            "acceptForSession",
            "decline",
            "cancel"
          ]
        },
        "id": "request-9"
      },
      "initial": "waiting"
    },
    {
      "id": "questions",
      "title": "Questions",
      "group": "Interaction",
      "description": "Single or multiple questions, suggested answers and free text.",
      "dom": ".ck-question-card (proposed)",
      "rule": "Keep answers by question ID; submit native response once.",
      "method": "item/tool/requestUserInput",
      "fixture": {
        "method": "item/tool/requestUserInput",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "isBlocking": true,
          "questions": [
            {
              "id": "layout",
              "header": "Layout",
              "question": "Where should aggregate changes appear?",
              "options": [
                {
                  "label": "Below the reply",
                  "description": "Keep changes beside the turn that made them."
                },
                {
                  "label": "Inside the tool tray",
                  "description": "Keep all activity in one fold."
                }
              ],
              "isOther": true,
              "isSecret": false
            }
          ]
        },
        "id": "request-9"
      },
      "initial": "waiting"
    },
    {
      "id": "elicitation",
      "title": "MCP elicitation",
      "group": "Interaction",
      "description": "Structured input or an explicit external sign-in action for an MCP server.",
      "dom": ".ck-elicitation-card (proposed)",
      "rule": "Render supplied schema or URL mode; retain request ownership.",
      "method": "mcpServer/elicitation/request",
      "fixture": {
        "method": "mcpServer/elicitation/request",
        "params": {
          "threadId": "demo-thread",
          "serverName": "docs-server",
          "mode": "form",
          "message": "Choose the documentation workspace.",
          "requestedSchema": {
            "type": "object",
            "properties": {
              "workspace": {
                "type": "string",
                "title": "Workspace"
              }
            }
          }
        },
        "id": "request-9"
      },
      "initial": "waiting"
    },
    {
      "id": "permissions",
      "title": "Permission scope",
      "group": "Interaction",
      "description": "Present the requested capabilities and duration of a grant.",
      "dom": ".ck-permissions-card (proposed)",
      "rule": "Return granted permissions and scope; do not infer permission from UI state.",
      "method": "item/permissions/requestApproval",
      "fixture": {
        "method": "item/permissions/requestApproval",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "reason": "Write generated assets to the preview folder.",
          "permissions": {
            "fileSystem": {
              "write": [
                "/workspace/preview"
              ]
            }
          }
        },
        "id": "request-9"
      },
      "initial": "waiting"
    },
    {
      "id": "approval-review",
      "title": "Automatic approval review",
      "group": "Interaction",
      "description": "Review status and decision sit beside the action they evaluated.",
      "dom": ".ck-approval-review (proposed)",
      "rule": "Update by reviewId and link to targetItemId.",
      "method": "item/autoApprovalReview/completed",
      "fixture": {
        "method": "item/autoApprovalReview/completed",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "reviewId": "review-2",
          "targetItemId": "item-4",
          "action": {
            "command": "npm run build"
          },
          "review": {
            "status": "completed"
          },
          "decisionSource": "automatic"
        }
      },
      "initial": "done"
    },
    {
      "id": "agent",
      "title": "Agent transcript",
      "group": "Activity",
      "description": "A compact agent row opens its own transcript and child-agent statuses.",
      "dom": ".ck-row.is-agent + .ck-subpanel",
      "rule": "Route child thread events into their owning transcript.",
      "method": "item/started",
      "fixture": {
        "method": "item/started",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "item": {
            "type": "collabAgentToolCall",
            "id": "agent-call-1",
            "tool": "spawnAgent",
            "senderThreadId": "demo-thread",
            "receiverThreadIds": [
              "child-thread"
            ],
            "prompt": "Inspect output rendering",
            "status": "inProgress",
            "agentsStates": {
              "child-thread": {
                "status": "running"
              }
            }
          }
        }
      },
      "initial": "running"
    },
    {
      "id": "image",
      "title": "Image / generated result",
      "group": "Conversation",
      "description": "View an image or generation result with prompt and artifact details.",
      "dom": ".ck-image / .ck-generated-image (proposed)",
      "rule": "Replace result/status by item and preserve failure detail.",
      "method": "item/completed",
      "fixture": {
        "method": "item/completed",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "item": {
            "type": "imageGeneration",
            "id": "image-1",
            "status": "completed",
            "savedPath": "/workspace/artifacts/preview.png",
            "revisedPrompt": "A soft amber and blue abstract header",
            "transparentBackground": false
          }
        }
      },
      "initial": "done"
    },
    {
      "id": "review",
      "title": "Review mode",
      "group": "Conversation",
      "description": "Show review scope and findings with a clear running or final state.",
      "dom": ".ck-review (proposed)",
      "rule": "Link review entry/exit items to the same review surface.",
      "method": "item/completed",
      "fixture": {
        "method": "item/completed",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "item": {
            "type": "exitedReviewMode",
            "id": "review-item",
            "review": "One output ownership finding."
          }
        }
      },
      "initial": "done"
    },
    {
      "id": "hook",
      "title": "Hook activity",
      "group": "Activity",
      "description": "A folded activity row exposes hook output, timing and failures.",
      "dom": ".ck-row + .ck-detail",
      "rule": "Use hook run ID; complete the same running row.",
      "method": "hook/completed",
      "fixture": {
        "method": "hook/completed",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "run": {
            "id": "hook-1",
            "name": "Formatting check",
            "status": "completed"
          }
        }
      },
      "initial": "done"
    },
    {
      "id": "status",
      "title": "Status / buffering",
      "group": "Session",
      "description": "The dock communicates work, waiting, recovery and connection state.",
      "dom": ".ck-status-text + .ck-dot",
      "rule": "Replace status by thread; pending interactions take priority.",
      "method": "thread/status/changed",
      "fixture": {
        "method": "thread/status/changed",
        "params": {
          "threadId": "demo-thread",
          "status": {
            "type": "active",
            "activeFlags": []
          }
        }
      },
      "initial": "running"
    },
    {
      "id": "session",
      "title": "Thread / project details",
      "group": "Session",
      "description": "Title, lifecycle, settings, project and attachments belong in More.",
      "dom": ".ck-info + .ck-pop",
      "rule": "Replace thread metadata and invalidate authoritative lists.",
      "method": "thread/name/updated",
      "fixture": {
        "method": "thread/name/updated",
        "params": {
          "threadId": "demo-thread",
          "threadName": "Live event rendering"
        }
      },
      "initial": "done"
    },
    {
      "id": "goal",
      "title": "Goal progress",
      "group": "Progress",
      "description": "Goal status and budgets sit above the task panel.",
      "dom": ".ck-goal (proposed)",
      "rule": "Replace goal snapshot; remove current display on goal cleared.",
      "method": "thread/goal/updated",
      "fixture": {
        "method": "thread/goal/updated",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "goal": {
            "objective": "Give every Codex event a UI destination",
            "status": "active"
          }
        }
      },
      "initial": "done"
    },
    {
      "id": "queue",
      "title": "Queued messages",
      "group": "Progress",
      "description": "Pending messages stay beside the composer and have explicit controls.",
      "dom": ".ck-queue (proposed)",
      "rule": "Invalidate/refetch queue and reconcile messages by native ID.",
      "method": "thread/queue/changed",
      "fixture": {
        "method": "thread/queue/changed",
        "params": {
          "threadId": "demo-thread"
        }
      },
      "initial": "done"
    },
    {
      "id": "integrations",
      "title": "Integrations / MCP progress",
      "group": "Session",
      "description": "Server startup, app catalogs and MCP progress share scoped detail views.",
      "dom": ".ck-integrations / .ck-row (proposed / existing)",
      "rule": "Update by server, subscription or item; retain bounded detail logs.",
      "method": "item/mcpToolCall/progress",
      "fixture": {
        "method": "item/mcpToolCall/progress",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "message": "Fetching documentation: 2 of 3 pages"
        }
      },
      "initial": "done"
    },
    {
      "id": "account",
      "title": "Account / usage / auth",
      "group": "Session",
      "description": "Token usage, rate windows and safe account connection status.",
      "dom": ".ck-usage-panel + .ck-account (proposed)",
      "rule": "Replace usage snapshots; keep credentials outside the DOM.",
      "method": "account/rateLimits/updated",
      "fixture": {
        "method": "account/rateLimits/updated",
        "params": {
          "rateLimits": {
            "limitId": "codex",
            "primary": {
              "usedPercent": 32,
              "windowDurationMins": 300,
              "resetsAt": 1790856000
            }
          }
        }
      },
      "initial": "done"
    },
    {
      "id": "environment",
      "title": "Environment / remote control",
      "group": "Session",
      "description": "Connection, remote-control and platform setup information.",
      "dom": ".ck-environment (proposed)",
      "rule": "Update by environment/installation; show transport status only.",
      "method": "thread/environment/connected",
      "fixture": {
        "method": "thread/environment/connected",
        "params": {
          "threadId": "demo-thread",
          "environmentId": "local-mac"
        }
      },
      "initial": "done"
    },
    {
      "id": "process",
      "title": "Process / terminal input",
      "group": "Activity",
      "description": "External process streams and interactive stdin use a dedicated detail view.",
      "dom": ".ck-detail + .ck-stdin (proposed)",
      "rule": "Decode bytes per stream; final output reconciles without double appends.",
      "method": "process/outputDelta",
      "fixture": {
        "method": "process/outputDelta",
        "params": {
          "processHandle": "process-7",
          "stream": "stdout",
          "deltaBase64": "QnVpbGQgc3RhcnRlZAo=",
          "capReached": false
        }
      },
      "initial": "running"
    },
    {
      "id": "search",
      "title": "Search / file picker",
      "group": "Activity",
      "description": "Web result links and file suggestions remain separate from tool JSON.",
      "dom": ".ck-detail + .ck-pop",
      "rule": "Replace results for current query/session; reject stale search updates.",
      "method": "fuzzyFileSearch/sessionUpdated",
      "fixture": {
        "method": "fuzzyFileSearch/sessionUpdated",
        "params": {
          "sessionId": "search-8",
          "query": "event",
          "files": [
            {
              "path": "src/events.ts",
              "file_name": "events.ts",
              "score": 92
            }
          ]
        }
      },
      "initial": "done"
    },
    {
      "id": "realtime",
      "title": "Realtime voice",
      "group": "Session",
      "description": "Audio controls and per-role transcripts belong beside the composer.",
      "dom": ".ck-voice-start; .ck-surface[data-surface=\"realtime\"]",
      "rule": "Native microphone/playback plus start, mute and end controls; audio bytes stay outside the DOM.",
      "method": "thread/realtime/transcript/delta",
      "fixture": {
        "method": "thread/realtime/transcript/delta",
        "params": {
          "threadId": "demo-thread",
          "role": "user",
          "delta": "Show me the changes from this turn."
        }
      },
      "initial": "running"
    },
    {
      "id": "notice",
      "title": "Notices / recovery",
      "group": "Conversation",
      "description": "Actionable warnings and failures have concise messages with details.",
      "dom": ".ck-notice",
      "rule": "Deduplicate repeat notices; preserve actual willRetry/terminal state.",
      "method": "error",
      "fixture": {
        "method": "error",
        "params": {
          "threadId": "demo-thread",
          "turnId": "turn-12",
          "itemId": "item-4",
          "error": {
            "message": "Connection interrupted. Retrying the request."
          },
          "willRetry": true
        }
      },
      "initial": "done"
    },
    {
      "id": "footer",
      "title": "Turn completion / metadata",
      "group": "Conversation",
      "description": "A quiet footer records duration, status, model and supplied metadata.",
      "dom": ".ck-foot",
      "rule": "Finalize the named turn once; keep metadata in folded details.",
      "method": "turn/completed",
      "fixture": {
        "method": "turn/completed",
        "params": {
          "threadId": "demo-thread",
          "turn": {
            "id": "turn-12",
            "status": "completed",
            "durationMs": 8400
          }
        }
      },
      "initial": "done"
    },
    {
      "id": "inspector",
      "title": "Protocol / host diagnostics",
      "group": "Session",
      "description": "A bounded fallback keeps future events and host operations inspectable.",
      "dom": ".ck-event-inspector / .ck-unknown (proposed / existing)",
      "rule": "Retain safe diagnostic records; redact secret/transport payloads.",
      "method": "currentTime/read",
      "fixture": {
        "method": "currentTime/read",
        "params": {
          "threadId": "demo-thread"
        },
        "id": "request-9"
      },
      "initial": "done"
    }
  ],
  "coverage": [
    {
      "name": "error",
      "kind": "notification",
      "current": "Mapped",
      "shared": "notice + surface.snapshot",
      "dom": ".ck-notice; .ck-surface",
      "rule": "Supplied error message and retry flag; turn completion remains authoritative.",
      "component": "notice"
    },
    {
      "name": "thread/started",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"session\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "session"
    },
    {
      "name": "thread/status/changed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"status\"]",
      "rule": "Update busy status; pending blocking requests keep Waiting for you.",
      "component": "status"
    },
    {
      "name": "thread/archived",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"session\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "session"
    },
    {
      "name": "thread/deleted",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"session\"]",
      "rule": "Disable composer and settle live controls; retain transcript.",
      "component": "session"
    },
    {
      "name": "thread/unarchived",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"session\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "session"
    },
    {
      "name": "thread/closed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"session\"]",
      "rule": "Disable composer and settle live controls; retain transcript.",
      "component": "session"
    },
    {
      "name": "thread/reverted",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"session\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "session"
    },
    {
      "name": "skills/changed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"integrations\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "integrations"
    },
    {
      "name": "thread/name/updated",
      "kind": "notification",
      "current": "Mapped",
      "shared": "title",
      "dom": ".ck-info; session picker",
      "rule": "Replace thread title.",
      "component": "session"
    },
    {
      "name": "thread/attachment/updated",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"session\"]",
      "rule": "Fetch authoritative list after notification; display unavailable on RPC error.",
      "component": "session"
    },
    {
      "name": "thread/goal/updated",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"goal\"]",
      "rule": "Replace objective, budget, tokens, elapsed time and status.",
      "component": "goal"
    },
    {
      "name": "thread/goal/cleared",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"goal\"]",
      "rule": "Remove goal state for the thread.",
      "component": "goal"
    },
    {
      "name": "thread/queue/changed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"queue\"]",
      "rule": "Fetch authoritative list after notification; display unavailable on RPC error.",
      "component": "queue"
    },
    {
      "name": "project/changed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"session\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "session"
    },
    {
      "name": "thread/project/updated",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"session\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "session"
    },
    {
      "name": "thread/environment/connected",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"environment\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "environment"
    },
    {
      "name": "thread/environment/disconnected",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"environment\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "environment"
    },
    {
      "name": "thread/settings/updated",
      "kind": "notification",
      "current": "Mapped",
      "shared": "surface.snapshot + model/effort",
      "dom": ".ck-surface; .ck-status",
      "rule": "Retain settings details and update supported controls.",
      "component": "session"
    },
    {
      "name": "thread/tokenUsage/updated",
      "kind": "notification",
      "current": "Mapped",
      "shared": "usage; child surface.snapshot",
      "dom": ".ck-ctx; .ck-usage-panel; child .ck-surface",
      "rule": "Replace token snapshots.",
      "component": "account"
    },
    {
      "name": "turn/started",
      "kind": "notification",
      "current": "Mapped",
      "shared": "turn.start",
      "dom": ".ck-turn",
      "rule": "Bind thread and turn IDs.",
      "component": "status"
    },
    {
      "name": "hook/started",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"hook\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "hook"
    },
    {
      "name": "turn/completed",
      "kind": "notification",
      "current": "Mapped",
      "shared": "turn.end",
      "dom": ".ck-foot; .ck-status-text",
      "rule": "Finalize turn and settle active controls.",
      "component": "footer"
    },
    {
      "name": "hook/completed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"hook\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "hook"
    },
    {
      "name": "turn/diff/updated",
      "kind": "notification",
      "current": "Mapped",
      "shared": "turn.diff.snapshot",
      "dom": ".ck-turn-diff",
      "rule": "Replace aggregate diff for named turn; empty diff clears it.",
      "component": "turn-diff"
    },
    {
      "name": "turn/plan/updated",
      "kind": "notification",
      "current": "Mapped",
      "shared": "plan.snapshot",
      "dom": ".ck-surface[data-surface=\"plan\"]; .ck-tasks",
      "rule": "Replace steps; retain turn plan and update current task board.",
      "component": "plan"
    },
    {
      "name": "item/started",
      "kind": "notification",
      "current": "Mapped",
      "shared": "content/tool lifecycle or surface.snapshot",
      "dom": ".ck-text; .ck-think; .ck-row; .ck-surface",
      "rule": "Upsert item by thread, turn and item ID.",
      "component": "inspector"
    },
    {
      "name": "item/autoApprovalReview/started",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"approval-review\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "approval-review"
    },
    {
      "name": "item/autoApprovalReview/completed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"approval-review\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "approval-review"
    },
    {
      "name": "autoApprovalReview/strictReviewRequired",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"approval-review\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "approval-review"
    },
    {
      "name": "item/completed",
      "kind": "notification",
      "current": "Mapped",
      "shared": "content/tool lifecycle or surface.snapshot",
      "dom": ".ck-text; .ck-think; .ck-row; .ck-surface",
      "rule": "Finalize the same item; retain detail panels.",
      "component": "inspector"
    },
    {
      "name": "item/agentMessage/delta",
      "kind": "notification",
      "current": "Mapped",
      "shared": "content.delta",
      "dom": ".ck-text.sk-doc",
      "rule": "Append to the owning message.",
      "component": "assistant"
    },
    {
      "name": "item/plan/delta",
      "kind": "notification",
      "current": "Mapped",
      "shared": "tool.input",
      "dom": ".ck-row; .ck-detail",
      "rule": "Append text to plan item.",
      "component": "plan"
    },
    {
      "name": "command/exec/outputDelta",
      "kind": "notification",
      "current": "Mapped",
      "shared": "tool.output.delta",
      "dom": ".ck-stream-output",
      "rule": "Incrementally decode UTF-8 bytes per stream.",
      "component": "process"
    },
    {
      "name": "process/outputDelta",
      "kind": "notification",
      "current": "Mapped",
      "shared": "tool.output.delta",
      "dom": ".ck-stream-output; .ck-process-input",
      "rule": "Incrementally decode bytes; show stdin for supplied process handle.",
      "component": "process"
    },
    {
      "name": "process/exited",
      "kind": "notification",
      "current": "Mapped",
      "shared": "tool.result",
      "dom": ".ck-row; .ck-detail",
      "rule": "Keep streamed output when final captures are empty.",
      "component": "process"
    },
    {
      "name": "item/commandExecution/outputDelta",
      "kind": "notification",
      "current": "Mapped",
      "shared": "tool.output.delta",
      "dom": ".ck-stream-output",
      "rule": "Append bounded command output.",
      "component": "command"
    },
    {
      "name": "item/commandExecution/terminalInteraction",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"process\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "process"
    },
    {
      "name": "item/fileChange/outputDelta",
      "kind": "notification",
      "current": "Mapped",
      "shared": "tool.output.delta",
      "dom": ".ck-stream-output",
      "rule": "Append bounded live output.",
      "component": "file"
    },
    {
      "name": "item/fileChange/patchUpdated",
      "kind": "notification",
      "current": "Mapped",
      "shared": "tool.input",
      "dom": ".ck-row; .ck-change",
      "rule": "Replace current file changes.",
      "component": "file"
    },
    {
      "name": "serverRequest/resolved",
      "kind": "notification",
      "current": "Mapped",
      "shared": "approval.cancel",
      "dom": ".ck-card; .ck-status-text",
      "rule": "Resolve the matching typed native request.",
      "component": "approval"
    },
    {
      "name": "item/mcpToolCall/progress",
      "kind": "notification",
      "current": "Mapped",
      "shared": "tool.progress",
      "dom": ".ck-row-meta",
      "rule": "Replace progress message.",
      "component": "integrations"
    },
    {
      "name": "mcpServer/oauthLogin/completed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"integrations\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "integrations"
    },
    {
      "name": "mcpServer/startupStatus/updated",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"integrations\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "integrations"
    },
    {
      "name": "mcpServer/event/stream/notification",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"integrations\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "integrations"
    },
    {
      "name": "account/updated",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"account\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "account"
    },
    {
      "name": "account/gatewayOAuth/changed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"account\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "account"
    },
    {
      "name": "account/rateLimits/updated",
      "kind": "notification",
      "current": "Mapped",
      "shared": "usage",
      "dom": ".ck-usage-panel",
      "rule": "Replace rate limit windows.",
      "component": "account"
    },
    {
      "name": "app/list/updated",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"integrations\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "integrations"
    },
    {
      "name": "remoteControl/status/changed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"environment\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "environment"
    },
    {
      "name": "externalAgentConfig/import/progress",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"integrations\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "integrations"
    },
    {
      "name": "externalAgentConfig/import/completed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"integrations\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "integrations"
    },
    {
      "name": "fs/changed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"session\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "session"
    },
    {
      "name": "item/reasoning/summaryTextDelta",
      "kind": "notification",
      "current": "Mapped",
      "shared": "content.snapshot",
      "dom": ".ck-think",
      "rule": "Append per summary index and replace the assembled summary.",
      "component": "thinking"
    },
    {
      "name": "item/reasoning/summaryPartAdded",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"thinking\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "thinking"
    },
    {
      "name": "item/reasoning/textDelta",
      "kind": "notification",
      "current": "Mapped",
      "shared": "surface.snapshot",
      "dom": ".ck-surface",
      "rule": "Show stream metadata; omit raw reasoning text.",
      "component": "thinking"
    },
    {
      "name": "thread/compacted",
      "kind": "notification",
      "current": "Mapped",
      "shared": "notice",
      "dom": ".ck-notice",
      "rule": "Show context compaction notice.",
      "component": "status"
    },
    {
      "name": "model/rerouted",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"notice\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "notice"
    },
    {
      "name": "model/verification",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"notice\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "notice"
    },
    {
      "name": "modelProvider/authRecoveryStarted",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"notice\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "notice"
    },
    {
      "name": "modelProvider/authRecoveryCompleted",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"notice\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "notice"
    },
    {
      "name": "turn/moderationMetadata",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"footer\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "footer"
    },
    {
      "name": "model/safetyBuffering/updated",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"status\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "status"
    },
    {
      "name": "warning",
      "kind": "notification",
      "current": "Mapped",
      "shared": "notice",
      "dom": ".ck-notice",
      "rule": "Display supplied warning.",
      "component": "notice"
    },
    {
      "name": "guardianWarning",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"notice\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "notice"
    },
    {
      "name": "deprecationNotice",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"notice\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "notice"
    },
    {
      "name": "configWarning",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"notice\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "notice"
    },
    {
      "name": "fuzzyFileSearch/sessionUpdated",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"search\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "search"
    },
    {
      "name": "fuzzyFileSearch/sessionCompleted",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"search\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "search"
    },
    {
      "name": "thread/realtime/started",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"realtime\"]",
      "rule": "Native WebSocket voice captures and plays PCM16; DOM receives session/transcript state and audio metadata. WebRTC SDP is not used.",
      "component": "realtime"
    },
    {
      "name": "thread/realtime/itemAdded",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"realtime\"]",
      "rule": "Native WebSocket voice captures and plays PCM16; DOM receives session/transcript state and audio metadata. WebRTC SDP is not used.",
      "component": "realtime"
    },
    {
      "name": "thread/realtime/item/started",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"realtime\"]",
      "rule": "Native WebSocket voice captures and plays PCM16; DOM receives session/transcript state and audio metadata. WebRTC SDP is not used.",
      "component": "realtime"
    },
    {
      "name": "thread/realtime/item/transcript/delta",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"realtime\"]",
      "rule": "Native WebSocket voice captures and plays PCM16; DOM receives session/transcript state and audio metadata. WebRTC SDP is not used.",
      "component": "realtime"
    },
    {
      "name": "thread/realtime/item/completed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"realtime\"]",
      "rule": "Native WebSocket voice captures and plays PCM16; DOM receives session/transcript state and audio metadata. WebRTC SDP is not used.",
      "component": "realtime"
    },
    {
      "name": "thread/realtime/transcript/delta",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"realtime\"]",
      "rule": "Native WebSocket voice captures and plays PCM16; DOM receives session/transcript state and audio metadata. WebRTC SDP is not used.",
      "component": "realtime"
    },
    {
      "name": "thread/realtime/transcript/done",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"realtime\"]",
      "rule": "Native WebSocket voice captures and plays PCM16; DOM receives session/transcript state and audio metadata. WebRTC SDP is not used.",
      "component": "realtime"
    },
    {
      "name": "thread/realtime/outputAudio/delta",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"realtime\"]",
      "rule": "Native WebSocket voice captures and plays PCM16; DOM receives session/transcript state and audio metadata. WebRTC SDP is not used.",
      "component": "realtime"
    },
    {
      "name": "thread/realtime/sdp",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"realtime\"]",
      "rule": "Native WebSocket voice captures and plays PCM16; DOM receives session/transcript state and audio metadata. WebRTC SDP is not used.",
      "component": "realtime"
    },
    {
      "name": "thread/realtime/error",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"realtime\"]",
      "rule": "Native WebSocket voice captures and plays PCM16; DOM receives session/transcript state and audio metadata. WebRTC SDP is not used.",
      "component": "realtime"
    },
    {
      "name": "thread/realtime/closed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"realtime\"]",
      "rule": "Native WebSocket voice captures and plays PCM16; DOM receives session/transcript state and audio metadata. WebRTC SDP is not used.",
      "component": "realtime"
    },
    {
      "name": "windows/worldWritableWarning",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"environment\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "environment"
    },
    {
      "name": "windowsSandbox/setupCompleted",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"environment\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "environment"
    },
    {
      "name": "account/login/completed",
      "kind": "notification",
      "current": "Named details",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"account\"]",
      "rule": "Replace named detail state; preserve expansion.",
      "component": "account"
    },
    {
      "name": "item/commandExecution/requestApproval",
      "kind": "request",
      "current": "Interactive",
      "shared": "approval.request / approval.cancel",
      "dom": ".ck-native-card[data-kind=\"approval\"]",
      "rule": "Validate native response shape and offered decisions; respond exactly once.",
      "component": "approval"
    },
    {
      "name": "item/fileChange/requestApproval",
      "kind": "request",
      "current": "Interactive",
      "shared": "approval.request / approval.cancel",
      "dom": ".ck-native-card[data-kind=\"approval\"]",
      "rule": "Validate native response shape and offered decisions; respond exactly once.",
      "component": "approval"
    },
    {
      "name": "item/tool/requestUserInput",
      "kind": "request",
      "current": "Interactive",
      "shared": "approval.request / approval.cancel",
      "dom": ".ck-native-card[data-kind=\"questions\"]",
      "rule": "Validate native response shape and offered decisions; respond exactly once.",
      "component": "questions"
    },
    {
      "name": "mcpServer/elicitation/request",
      "kind": "request",
      "current": "Interactive",
      "shared": "approval.request / approval.cancel",
      "dom": ".ck-native-card[data-kind=\"elicitation\"]",
      "rule": "Validate native response shape and offered decisions; respond exactly once.",
      "component": "elicitation"
    },
    {
      "name": "item/permissions/requestApproval",
      "kind": "request",
      "current": "Interactive",
      "shared": "approval.request / approval.cancel",
      "dom": ".ck-native-card[data-kind=\"permissions\"]",
      "rule": "Validate native response shape and offered decisions; respond exactly once.",
      "component": "permissions"
    },
    {
      "name": "item/tool/call",
      "kind": "request",
      "current": "Native host tools",
      "shared": "tool.start / tool.result",
      "dom": ".ck-row; .ck-detail",
      "rule": "Validate arguments; execute registered native host action; respond once or fail with timeout/cancellation.",
      "component": "integrations"
    },
    {
      "name": "account/chatgptAuthTokens/refresh",
      "kind": "request",
      "current": "Managed refresh / sign-in",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"account\"]",
      "rule": "Refresh managed credentials with account/read; external-token callback returns explicit error and offers managed sign-in.",
      "component": "account"
    },
    {
      "name": "attestation/generate",
      "kind": "request",
      "current": "Unavailable callback",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"environment\"]",
      "rule": "Explicit JSON-RPC error; no credentials or attestation fabricated.",
      "component": "environment"
    },
    {
      "name": "currentTime/read",
      "kind": "request",
      "current": "Host response",
      "shared": "surface.snapshot",
      "dom": ".ck-surface[data-surface=\"inspector\"]",
      "rule": "Return host time and record completion.",
      "component": "inspector"
    },
    {
      "name": "applyPatchApproval",
      "kind": "request",
      "current": "Interactive",
      "shared": "approval.request / approval.cancel",
      "dom": ".ck-native-card[data-kind=\"approval\"]",
      "rule": "Validate native response shape and offered decisions; respond exactly once.",
      "component": "approval"
    },
    {
      "name": "execCommandApproval",
      "kind": "request",
      "current": "Interactive",
      "shared": "approval.request / approval.cancel",
      "dom": ".ck-native-card[data-kind=\"approval\"]",
      "rule": "Validate native response shape and offered decisions; respond exactly once.",
      "component": "approval"
    },
    {
      "name": "userMessage",
      "kind": "item",
      "current": "Existing prompt",
      "shared": "optimistic prompt",
      "dom": ".ck-user",
      "rule": "Local sent prompt owns the user message; replay reads recorded prompts.",
      "component": "assistant"
    },
    {
      "name": "hookPrompt",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle / surface.snapshot",
      "dom": ".ck-row; .ck-surface[data-surface=\"hook\"]",
      "rule": "Keep native item details in a named panel; completed tools retain results.",
      "component": "hook"
    },
    {
      "name": "agentMessage",
      "kind": "item",
      "current": "Mapped",
      "shared": "content lifecycle + surface.snapshot",
      "dom": ".ck-text; .ck-surface[data-surface=\"assistant\"]",
      "rule": "Final snapshot replaces text; show citations/questions/phase details.",
      "component": "assistant"
    },
    {
      "name": "functionCallOutput",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle / surface.snapshot",
      "dom": ".ck-row; .ck-surface[data-surface=\"command\"]",
      "rule": "Keep native item details in a named panel; completed tools retain results.",
      "component": "command"
    },
    {
      "name": "plan",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle / surface.snapshot",
      "dom": ".ck-row; .ck-surface[data-surface=\"plan\"]",
      "rule": "Keep native item details in a named panel; completed tools retain results.",
      "component": "plan"
    },
    {
      "name": "reasoning",
      "kind": "item",
      "current": "Summary only",
      "shared": "content lifecycle",
      "dom": ".ck-think",
      "rule": "Show indexed summary text; omit raw reasoning.",
      "component": "thinking"
    },
    {
      "name": "commandExecution",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle / surface.snapshot",
      "dom": ".ck-row; .ck-surface[data-surface=\"command\"]",
      "rule": "Keep native item details in a named panel; completed tools retain results.",
      "component": "command"
    },
    {
      "name": "fileChange",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle / surface.snapshot",
      "dom": ".ck-row; .ck-surface[data-surface=\"file\"]",
      "rule": "Keep native item details in a named panel; completed tools retain results.",
      "component": "file"
    },
    {
      "name": "mcpToolCall",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle / surface.snapshot",
      "dom": ".ck-row; .ck-surface[data-surface=\"integrations\"]",
      "rule": "Keep native item details in a named panel; completed tools retain results.",
      "component": "integrations"
    },
    {
      "name": "dynamicToolCall",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle / surface.snapshot",
      "dom": ".ck-row; .ck-surface[data-surface=\"integrations\"]",
      "rule": "Keep native item details in a named panel; completed tools retain results.",
      "component": "integrations"
    },
    {
      "name": "collabAgentToolCall",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle / surface.snapshot",
      "dom": ".ck-row; .ck-surface[data-surface=\"agent\"]",
      "rule": "Keep native item details in a named panel; completed tools retain results.",
      "component": "agent"
    },
    {
      "name": "subAgentActivity",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle / surface.snapshot",
      "dom": ".ck-row; .ck-surface[data-surface=\"agent\"]",
      "rule": "Keep native item details in a named panel; completed tools retain results.",
      "component": "agent"
    },
    {
      "name": "webSearch",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle / surface.snapshot",
      "dom": ".ck-row; .ck-surface[data-surface=\"search\"]",
      "rule": "Keep native item details in a named panel; completed tools retain results.",
      "component": "search"
    },
    {
      "name": "imageView",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle + media.snapshot",
      "dom": ".ck-row; .ck-media",
      "rule": "Load supported local images up to 4 MiB; otherwise show unavailable preview.",
      "component": "image"
    },
    {
      "name": "sleep",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle / surface.snapshot",
      "dom": ".ck-row; .ck-surface[data-surface=\"status\"]",
      "rule": "Keep native item details in a named panel; completed tools retain results.",
      "component": "status"
    },
    {
      "name": "imageGeneration",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle + media.snapshot",
      "dom": ".ck-row; .ck-media",
      "rule": "Load supported local images up to 4 MiB; otherwise show unavailable preview.",
      "component": "image"
    },
    {
      "name": "enteredReviewMode",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle / surface.snapshot",
      "dom": ".ck-row; .ck-surface[data-surface=\"review\"]",
      "rule": "Keep native item details in a named panel; completed tools retain results.",
      "component": "review"
    },
    {
      "name": "exitedReviewMode",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle / surface.snapshot",
      "dom": ".ck-row; .ck-surface[data-surface=\"review\"]",
      "rule": "Keep native item details in a named panel; completed tools retain results.",
      "component": "review"
    },
    {
      "name": "contextCompaction",
      "kind": "item",
      "current": "Mapped",
      "shared": "tool lifecycle / surface.snapshot",
      "dom": ".ck-row; .ck-surface[data-surface=\"status\"]",
      "rule": "Keep native item details in a named panel; completed tools retain results.",
      "component": "status"
    }
  ]
};
