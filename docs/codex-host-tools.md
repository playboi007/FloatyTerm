# Codex native host tools

New Codex conversations advertise three dynamic tools through `thread/start.dynamicTools`:

| Tool | Arguments | Native operation |
|---|---|---|
| `floatyterm_get_context` | `{}` | Conversation folder, channel/session, configured model, permission mode and view state. |
| `floatyterm_reveal_path` | `{ "path": "docs/events.md" }` | Request Finder selection of an existing workspace file/directory. |
| `floatyterm_open_file` | `{ "path": "docs/events.md" }` | Open a Markdown or image file in a FloatyTerm viewer tab, up to 16 MiB. |

Rebuild/relaunch FloatyTerm and start a **new Codex conversation** to advertise the tools. The installed 0.159.2 protocol has `dynamicTools` on thread/start, with no tool-registration field on resume/fork. Resuming or forking an older conversation does not send this catalog; start a new conversation to ensure registration. A standalone bridge exposes no tools unless its native host supplies `hostTools: true` in its start control.

## Dispatch

`item/tool/call → registry validation → tool.start → host.tool.request → native executor → hostToolResult → tool.result + DynamicToolCallResponse`

The controller intercepts native requests before forwarding events to the DOM. It uses the conversation's workspace, matches the originating session, and rejects expired requests. The sidecar correlates native RPC IDs with opaque UUIDs, ignores stale/duplicate replies, and returns failure on timeout (10 seconds), interruption, turn end, session change or shutdown. Server-resolved requests/disconnections settle local state without a second RPC response.

Paths must exist inside the conversation folder after symlink resolution. Opening files uses only FloatyTerm Markdown/image viewers; files are not executed or opened with arbitrary applications. Finder reveal reports that selection was requested, not that a separate Finder process has confirmed presentation.

## Extend

1. Add the tool name, description and JSON schema to `Resources/CodexSidecar/host-tools.mjs`; extend its argument validator.
2. Add the native implementation to `Sources/FloatyTerm/CodexHostTools.swift`.
3. Connect required app services through the controller/window callback, following the existing viewer callback.
4. Keep side effects within the tool's described scope. Broader tools need their own permission and cancellation behavior.

JavaScript syntax and the Swift debug build were checked. No live model invocation or GUI tool execution has been verified for this change.
