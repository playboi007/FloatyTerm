# DevTools awareness & Flutter diagnosis

FloatyTerm can give a terminal agent **DevTools-grade awareness of a web/Flutter
app running in an external browser** — console, network, and structured error
diagnoses — without that app ever living inside a FloatyTerm tab. The agent just
tails a log file.

This doc covers the moving parts: the relay, the two capture paths (injected JS
vs. an optional Dart hook), the diagnosis envelope, HTTP-status coverage, and
the on-disk NDJSON schema.

---

## 1. The relay (`DevtoolsRelay.swift`)

A loopback-only HTTP server on **`127.0.0.1:7777`**, started at launch
(`AppDelegate.applicationDidFinishLaunching`). Loopback by construction — page
telemetry must never be reachable off-box.

Routes (matched on the **path only**, so query params on the script tag don't
404 the request):

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/floaty.js` | Serves the capture script (mode/label from `?mode=&label=`) |
| `POST` | `/log` | Receives a batch of events |
| `OPTIONS` | * | CORS preflight (`Access-Control-Allow-Origin: *`) |

Events land under
`~/Library/Application Support/FloatyTerm/Devtools/`, one stable NDJSON file per
provenance:

- `remote/<label-or-host>.ndjson` — external pages (Chrome, an IDE preview).
- `tabs/<host>-<id>.ndjson` — FloatyTerm's own in-app browser tabs.

A session right-clicks the terminal → **Tail DevTools Log** to stage
`tail -f "<path>"` at the prompt (progressive-disclosure submenu when several
logs exist; "Latest" on top).

### Ingestion pipeline

`POST /log` → per-provenance `EventAggregator` (dedupe by fingerprint, rank by
severity, sample high-volume repeats) → mode formatter (`flutter` /
`react-native` / `browser`) → `ndjsonLine` (key whitelist + size caps) → append.

The write handle is resolved **at write time on the relay queue**, so a handle
closed by the idle-cleanup or by `StorageJanitor.dropHandles()` between batches
can't silently swallow events into a deleted inode.

---

## 2. Two capture paths

Both write the same event shapes into the same log. They're **complementary**:

### a. Injected JS (`remoteCaptureJS`, served at `/floaty.js`)

Add one tag to the page (dev only):

```html
<script src="http://127.0.0.1:7777/floaty.js?mode=flutter&label=admin-app"></script>
```

Captures **broadly, from outside**: `console.*`, `window.onerror`,
`unhandledrejection`, `fetch`/`XHR` (method/url/status/ms), a page-load marker
with **viewport** (w/h/dpr), and the **`triggered_by` causal chain** (the last
user action — "clicked Submit" → POST → 500 — captured in the DOM capture phase;
input *values* are never read).

For Flutter it also runs `flutterSift`: Flutter prints framework errors as dozens
of `console.log` lines (`══╡ EXCEPTION CAUGHT BY …`) that a severity filter would
drop as noise; flutterSift assembles them into **one** `kind:"error"` event with
`message`, `constraints`, `widget_chain`, and app-only `user_frames`.

### b. Dart hook (`floaty_devtools.dart`, lives in the Flutter app — dev only)

Runs *inside* the Dart VM, so it sees structured detail the JS path can't:

- `FlutterError.onError` + `PlatformDispatcher.onError` → real Dart stacks; on a
  `RenderFlex` overflow it walks the live render tree and enumerates **every
  sibling with its laid-out size**, posting them as `diagnosis.candidates` with
  `candidates_complete: true`.
- A Dio `Interceptor` → `kind:"network"` with **request/response bodies, query,
  and redacted headers** (the outside XHR wrapper only sees status/url/ms).

It posts to the same `127.0.0.1:7777/log` with `mode:"flutter"` and the same
`label`, so both feeds merge into one file. Remove the `index.html` script tag
(and never ship the Dart hook un-guarded) before a production deploy.

---

## 3. The diagnosis envelope (`FlutterDiagnosis.swift`)

Every flutter-mode error gets a uniform `diagnosis` object. The design goal is to
stop an agent **satisficing** — reading a one-line prose hint, fixing the first
plausible cause, and missing a second offender. So each diagnosis carries a
claim, the load-bearing numbers, and an **audit protocol with an explicit stop
condition** — or an honest admission that the candidate set isn't enumerable from
a banner.

```json
"diagnosis": {
  "category": "layout/overflow",
  "what":     "A RenderFlex overflowed by 291 pixels on the bottom.",
  "where":    "admin_screen.dart:96",
  "evidence": { "overflow_px": 291, "edge": "bottom", "axis": "vertical" },
  "candidates_complete": false,
  "protocol": "Enumerate EVERY child of the flex parent … do not stop at the first one found."
}
```

`candidates_complete` is the keystone: banner parsing can never see sibling sizes,
so it stays `false` and the protocol says how to finish the enumeration. The Dart
hook supplies the real `candidates` table and flips it `true`; the relay **merges**
— server keeps `category`/`protocol`, client wins on `candidates` /
`candidates_complete` / extra `evidence`.

### Classifier table

One ordered list of rules (regex → category → evidence extractor → protocol).
First match wins; a new failure mode = one new row. Categories:

- **layout** — `overflow`, `negative-constraints`, `unbounded`, `parentdata`
- **lifecycle** — `setstate-after-dispose`, `build-phase`, `deactivated-context`, `duplicate-globalkey`
- **type** — `null`, `cast`, `method-or-range`
- **network** — `timeout`, `http-response`, `data/parse`
- **async** — `unhandled`
- **generic** — fallback so *every* error carries the envelope

Classification runs on `kind:"error"` **and** `kind:"console"` level `"error"`
(where Dart runtime dumps like an uncaught `DioException` land).

### HTTP-status coverage

`network/http-response` extracts the status (Dio's `status code of N`, plus
`status: N` / `HTTP/1.1 N`) and attaches `evidence.status_meaning` — a precise
reading per code: every standard 4xx (400–451) and 5xx (500–511), 3xx redirects,
and a class fallback (`Client error (NNN) …` / `Server error (NNN) …`) so an
unenumerated code still gets an actionable line. The protocol points the agent at
the correlated `kind:"network"` event and tells it to fix the request or server —
never to widen `validateStatus`.

---

## 4. NDJSON event schema

One JSON object per line. Keys are whitelisted in `ndjsonLine`; strings capped,
arrays ≤12 items, dicts one level deep.

| Field | Kinds | Notes |
|---|---|---|
| `ts` | all | server-stamped ISO8601 |
| `kind` | all | `console` / `error` / `network` / `loaded` |
| `severity` | all | 1000 error · 900/500 net · 800/200 console · … |
| `level`, `text` | console | |
| `message`, `source`, `line`, `stack` | error | |
| `constraints`, `widget_chain`, `user_frames` | error (flutter) | from flutterSift / Dart hook |
| `diagnosis` | error (flutter) | the envelope above |
| `method`, `url`, `status`, `ms`, `error` | network | |
| `req_body`, `res_body`, `req_query`, `req_headers`, `res_headers` | network | Dart Dio interceptor only |
| `viewport` | loaded | `{w,h,dpr}` |
| `triggered_by` | any | causal chain `{type,element,id,text,ts}` — JS path |

---

## 5. Storage

Logs are managed by `StorageJanitor` (hourly + launch sweep): a retention pass
(`Settings.storageRetentionDays`, 0 = keep forever) then an oldest-first size cap
(`Settings.storageCapMB`; Devtools gets the full budget, Browser Context and
Snaps a quarter each). Files modified in the last 10 minutes are never touched;
after any Devtools deletion the relay's open handles are dropped so the next event
recreates a fresh file. Tune both knobs (and clear per-category) in
**Preferences → Storage**. Transcripts are excluded — they manage their own
lifecycle.
