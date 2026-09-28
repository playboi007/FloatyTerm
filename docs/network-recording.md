# Network recording & export

Record **every** request a Dart app makes, then export it as JSON, HAR or
Markdown — complete enough to replay the request with `curl`.

This is the capture-everything sibling of [devtools-awareness.md](devtools-awareness.md).
That feature answers *what broke*; this one answers *what happened*, in full.

```bash
floaty net start --label admin-app --vm "http://127.0.0.1:50123/TOKEN=/"   # a Dart app
floaty net start --label shop --chrome shop.example.com                    # a tab in your live Chrome
# … drive the app / page …
floaty net stop
floaty net export --format md
```

## On-screen controls

A recording is visible while it runs, however it was started:

- **The REC pill.** It fades in at the bottom centre of the screen when a
  session starts. A red dot breathes and ripples, so you can see it from the
  corner of your eye while you work in another app. It shows the elapsed time,
  the request count, and the failure count (orange when there is at least one).
  - **Stop** — ends the session through the same path as `floaty net stop`,
    so the collectors flush before the file closes.
  - **Save…** — stops if needed, then opens a save panel with a Markdown /
    JSON / HAR choice. The choice is remembered, and the file is written `0600`.
    After saving, **Show** reveals it in Finder.
  - Drag it anywhere. It remembers the spot.
  - Stopped from the terminal, it offers Save for 10 seconds, then leaves.
    Stopped from the pill, it waits for you.
  - With **Reduce Motion** on, the dot only breathes — no ripple, no slide-in.
- **The menu bar.** A red **● REC** sits beside the FloatyTerm icon while
  anything records. The menu has **Stop Recording** and **Stop and Save…**.
  This still works if the pill was dragged away or dismissed.

## If every `floaty net` command prints a status list

Your installed `floaty` is older than `net`. The installer copies the script,
so an old copy stays old. It drops the word after `net`, and the relay used to
treat a missing action as `status`. The relay now answers with an error and
the fix. Link the installed copy to the repo script, so it can never go stale:

```bash
ln -sf "$PWD/scripts/floaty" ~/.local/bin/floaty
```

---

## 1. Why it is a separate path

The devtools pipeline is a **triage** pipeline, and every stage of it is hostile
to a recording:

| Stage | Diagnosis behaviour | Effect on a recording |
|---|---|---|
| `EventAggregator.severity` | a 2xx network event scores 0 | successful calls never reach disk |
| `EventAggregator.ingest` | dedupes, samples repeats | a polling loop becomes 3 lines |
| `ndjsonLine` | key whitelist, 16 KB strings, one-level dicts | bodies truncated, unknown fields dropped |

So `floaty net` writes its **own** file, with its own encoder: no severity
filter, no dedupe, no whitelist, no redaction. Recordings live in
`~/Library/Application Support/FloatyTerm/Devtools/records/<label>-<stamp>.ndjson`,
created `0600`, swept by `StorageJanitor` like any other devtools artifact.

> **These files hold live credentials.** `Authorization` headers, cookies and
> full bodies are kept verbatim — that is the point, and it is also the risk.
> Exports inherit the same `0600` mode. Do not attach one to a ticket without
> reading it first.

## 2. Three collectors

### a. VM Service — no code in the app (`DartVMNetwork.swift`)

Attaches to the URI `flutter run` prints and reads the same source as the
DevTools Network tab:

```
ext.dart.io.httpEnableTimelineLogging  {isolateId, enabled:true}
ext.dart.io.getHttpProfile             {isolateId, updatedSince} → refs
ext.dart.io.getHttpProfileRequest      {isolateId, id}           → bodies
```

Notes that matter in practice:

- **Debug/profile builds only.** A release build has no profiler; the attach
  fails with that reason instead of recording nothing.
- **It back-fills.** The first poll uses `updatedSince: 0`, so requests the app
  made *before* you hit record are captured too, as long as the VM still holds
  them.
- **Entries mutate.** A request appears while in flight and is updated on
  completion, so an entry is emitted only once both halves are done — emitting
  on first sight would record half of every call.
- **Hot restart is handled.** The poll re-scans isolates every ~10 cycles and
  re-enables logging on the new one.
- **`dart:io` only.** Not Flutter web, not native platform-channel traffic.

### b. `floaty_net_recorder` — the Dart package (`dart/floaty_net_recorder/`)

A dependency-free dev package that installs an `HttpOverrides`, tees request
and response bytes as they flow, and POSTs them to the relay.

```dart
void main() {
  assert(() { FloatyNet.start(label: 'admin-app'); return true; }());
  runApp(const MyApp());
}
```

The `assert` body is stripped from release builds, so it cannot ship by
accident. Use it for the three things the VM profiler cannot do:

- a **release/profile build on a real device**, where no VM Service is attached;
- **user-action context** — `FloatyNet.tag('screen', 'checkout')` attaches to
  every request that follows, so the export says what caused the call;
- **manual records** — `FloatyNet.record({...})` for a gRPC call, a WebSocket
  frame, or anything no `HttpClient` owns.

### c. Chrome — your live profile (`ChromeNetwork.swift` + `extension/netrecord.js`)

Records one tab in the Chrome you already use — real profile, logged in —
through the FloatyTerm CDP extension. No debug port, no relaunch.

```bash
floaty net start --label shop --chrome shop.example.com   # tab whose url/title contains it
floaty net start --label shop --chrome                    # the active tab
floaty net attach --chrome dashboard                      # add a tab to a live session
```

**Assembly happens in the extension, not in FloatyTerm.** One request is five
or more `Network.*` events, and they arrive out of order: the `ExtraInfo` pair
can land before or after the event it belongs to. The response body can only
be fetched while Chrome still holds it. So `netrecord.js` builds complete
records right next to the one API that can fetch bodies in time, then
`background.js` POSTs them to `/net` in ~8 MiB batches. `netrecord.js` is pure
(no `chrome.*`), so it is tested under node.

What it captures:

- **Cookies and every raw header.** They come from `requestWillBeSentExtraInfo`
  / `responseReceivedExtraInfo`. The plain Network events leave the `Cookie`
  header out, so without these a replay would be logged out.
- **Request and response bodies**, fetched with `Network.getRequestPostData` /
  `Network.getResponseBody`. When Chrome cannot return a body, the record says
  why (`res_body_error`), so an empty body is never mistaken for a real one.
- **Every redirect hop.** Each hop is its own record, linked by `redirected_from`.
- **Out-of-process iframes and workers**, via `Target.setAutoAttach` (Chrome 125+).
- **WebSocket frames and SSE messages**, as `protocol: websocket` / `sse` records.
- **Requests still in flight at stop**, emitted with an `error` that says so.
  A recording that drops unfinished calls hides the one hung request you were
  looking for.
- The `initiator` (for example `addToCart app.js:42`) and the `resource_type`.

Behaviour to know:

- **The debugging banner.** Chrome shows "…is debugging this browser" for the
  whole recording. If you **dismiss it, the recording ends**. The requests in
  flight are saved, and `net stop` reports `ended_early` with the reason.
- **The tab stays attached.** The extension normally detaches after 8 s idle.
  A recording tab is exempt, because that timer would end every recording
  silently.
- **Stop waits for the flush.** The extension replies to `Floaty.netStop` only
  after its last batch has landed, so the file closes after the last request.
- **Worker restarts.** Chrome can restart the MV3 worker. Live recordings are
  saved in `chrome.storage.session` and re-armed. Only the requests in flight at
  that moment are lost.
- **Child frames are not paused.** `waitForDebuggerOnStart` stays `false`.
  Pausing would catch a child frame's first request. But on a Chrome too old
  for child sessions, the frame would then hang forever. Missing one request is
  better than freezing the page.
- **One Chrome profile at a time.** The bridge keeps the latest connection. To
  record a tab in a different Chrome profile, load the extension in that
  profile. Only one profile can hold the bridge at a time.
- **After updating the extension files**, reload it once in
  `chrome://extensions`. An old build forwards `Floaty.netStart` to Chrome as a
  CDP method. FloatyTerm detects that error and tells you to reload.

All collectors can run at once — `--vm` and `--chrome` in one session is fine.
Each event carries its `source` (`vm-service` / `dart-hook` / `chrome-cdp` /
`js`), so the export keeps them apart.

## 3. Relay surface

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/agent/net` | `action`: `start` · `stop` · `status` · `attach` · `detach` · `export` |
| `POST` | `/net` | the recorder's ingress — verbatim, no whitelist, drops everything when nothing is recording |

`/net` is separate from `/log` on purpose: `/log` sanitizes, and sanitizing is
what a recording must not do.

**Start and stop are one unit.** If the VM collector fails to attach, the
session is rolled back and its file deleted — an empty recording that looks
successful is worse than a clear failure.

The relay's whole-request cap is now 64 MiB (it was 2 MiB). At 2 MiB, one
large response body closed the connection and lost the entire batch around
it. Collectors keep each POST near 8 MiB, so the cap only stops a runaway
client.

The relay also de-chunks request bodies now. `dart:io` streams a body with no
`Content-Length`, and reading only `Content-Length` meant the relay answered
`200` to a POST it had read as zero bytes.

## 4. Export formats

```bash
floaty net export [--record <session|path>] [--format md|json|har] [--out FILE]
                  [--failed] [--url /v1/orders] [--full]
```

Writes into your current directory, newest recording by default.

- **`md`** — summary table, then a detail section per request: headers, bodies,
  the user-action context, and a runnable `curl` in a `<details>` block.
- **`json`** — every field of every event, plus `replay.curl`. The agent format.
- **`har`** — HAR 1.2. Opens directly in Chrome DevTools, Proxyman, Charles.

The `curl` line drops `Host`, `Content-Length`, `Transfer-Encoding`,
`Connection`, and Chrome's HTTP/2 pseudo-headers (`:authority`, `:path`, …) —
curl owns request framing, and a replayed `transfer-encoding:
chunked` makes client and server disagree about where the body ends. Everything
else, including the auth header, is kept, because the request will not
reproduce without it. When the recording has an `Accept-Encoding` header, the
line adds `--compressed`, so a gzip or br answer prints as text. WebSocket and
SSE records get no `curl` line — one would be a lie.

## 5. Event schema

Recording NDJSON. One JSON object per line, first line `record_start`, last
`record_stop`.

| Field | Notes |
|---|---|
| `seq` | recorder order — two collectors stamping the same call must not reorder |
| `source` | `vm-service` · `dart-hook` · `js` |
| `ts` | server-stamped ISO8601 |
| `method`, `url`, `status`, `status_text`, `ms` | |
| `req_headers`, `res_headers` | `Map<String, List<String>>`, unredacted; repeated headers kept as lists |
| `req_body`, `res_body` | UTF-8 text, or base64 with `*_base64: true` when the bytes are not valid UTF-8 |
| `*_body_bytes`, `*_body_truncated` | true size, and whether `--max-body` cut it |
| `http_version`, `remote_address`, `remote_port`, `redirects`, `is_redirect` | |
| `error` | connection failures — recorded, never silently dropped |
| `context` | the Dart package's tags (`screen`, `action`, …) |
| `resource_type`, `initiator` | Chrome: `Fetch`/`XHR`/`Document`…, and who sent it (`fn file:line`) |
| `req_cookies` | Chrome: the cookies sent, each with the reason Chrome blocked it, if any |
| `redirected_from` | the previous hop's URL |
| `from_cache`, `from_service_worker`, `tls` | Chrome: cache source, SW-served, TLS details |
| `res_body_error` | why a body is missing — never an empty body |
| `target` | `main`, or the child session id of an iframe/worker |
| `ws_event`, `socket_id`, `opcode` | WebSocket records (`open`/`handshake`/`send`/`receive`/`close`) |
| `cdp` | Chrome's own request/response/ExtraInfo objects, verbatim |
| `vm` | the VM Service's own record, verbatim — the receipt behind every normalized field |

That last field is the honesty bit: normalization is a best effort over a
protocol that changes between Dart SDKs, so the raw subtree is what settles a
disagreement between the export and reality.
