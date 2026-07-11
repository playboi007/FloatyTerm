# FloatyTerm CDP Bridge (extension)

Gives `floaty` full Chrome DevTools Protocol access to your **live, logged-in
Chrome tabs** — no `--remote-debugging-port`, no quit-and-relaunch, no lost
session. This is the answer to the whole "Bootstrapping the debug port" saga in
`docs/floaty-ui-control/ref/cdp.md`: a personal Chrome can't be made debuggable
non-destructively, but an extension with the `debugger` permission already has
CDP on every tab.

## How it works

```
floaty eval --via-extension     (CLI)
   └─ POST /agent/eval {via_extension:true}
        └─ DevtoolsRelay → AgentDOM.runJavaScript(viaExtension:true)
             └─ CDPBridge.call("Runtime.evaluate", …, match)   ← Swift, actor
                  └─ WebSocket frame → extension service worker
                       └─ chrome.debugger.sendCommand(tabId, "Runtime.evaluate")
                            └─ reply {id, result}  ─────────────────┘
```

The extension can't be a server, so its MV3 background service worker dials
FloatyTerm's loopback relay (`ws://127.0.0.1:7777/cdp-bridge`) and becomes a
long-lived CDP executor. FloatyTerm sends `{id, method, params, match}`; the
worker resolves `match` → a tab, attaches `chrome.debugger`, runs `sendCommand`,
and replies `{id, result}` — the exact JSON-RPC shape `AgentDOM` already speaks.
It's a transport swap, not new protocol work.

## Install (load unpacked — no Web Store)

1. Open `chrome://extensions`.
2. Toggle **Developer mode** (top-right).
3. **Load unpacked** → select this `extension/` folder.
4. Make sure FloatyTerm is running, then open any normal `http(s)` tab.
5. Click the extension's icon — it should say **"relay reachable ✓"**.

## Use

```sh
floaty tabs      --via-extension                          # list your live tabs
floaty eval      --via-extension --expression "document.title"
floaty eval      --via-extension --match youtube.com --expression "document.querySelector('video').paused"
floaty query-dom --via-extension --selector "textarea"    # → screen rects to click
floaty navigate  --via-extension --match gmail --url "https://mail.google.com"
floaty som       --via-extension --match console.cloud    # numbered marks over the live tab
```

`--match` picks a tab by url/title substring (same semantics as the port path);
omit it to drive the active tab.

## What to expect / limits

- **Yellow banner.** While a tab is attached Chrome shows *"FloatyTerm CDP Bridge
  started debugging this browser."* The worker auto-detaches ~8s after the last
  command, which clears it. Unavoidable while attached.
- **Chrome only.** Electron apps (Slack, VS Code, Cursor) can't load a Chrome
  extension — keep using `floaty enable-cdp --app …` for those.
- **No `chrome://`, Web Store, or other-extension pages** — `chrome.debugger`
  can't attach to them.
- **Service-worker lifetime.** MV3 kills an idle worker at ~30s; a 30s alarm plus
  a 20s keepalive ping respawn/hold it, and it auto-reconnects, so the bridge
  self-heals within ~30s of going cold.
- **DevTools open on a tab** blocks attaching to that same tab
  ("Another debugger is already attached").

## Security

The relay is loopback-only, but the bridge grants any local process that reaches
`127.0.0.1:7777` full CDP over your authenticated tabs. To gate it, create
`~/Library/Application Support/FloatyTerm/cdp-bridge-token.txt` with a secret
string, then paste the same string into the extension's options. FloatyTerm
enforces the token only when that file exists; otherwise the bridge is open (the
same trust model as the existing `/agent/*` input routes).
