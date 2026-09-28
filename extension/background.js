// FloatyTerm CDP Bridge — MV3 background service worker.
//
// The extension can't be a server, so it dials FloatyTerm's loopback relay and
// becomes a long-lived CDP executor. FloatyTerm sends {id, method, params, match}
// frames; we resolve `match` to one of the user's LIVE tabs, chrome.debugger it,
// run sendCommand, and reply {id, result} — the exact JSON-RPC shape AgentDOM
// already speaks. No --remote-debugging-port, no relaunch, session intact.

const RELAY_URL = "ws://127.0.0.1:7777/cdp-bridge";
const CDP_VERSION = "1.3";
const DETACH_IDLE_MS = 8000;   // drop the "started debugging" banner once idle
const KEEPALIVE_MS = 20000;    // app-level ping so the MV3 SW isn't killed at ~30s

let ws = null;
let reconnectTimer = null;
let keepaliveTimer = null;
const attached = new Set();        // tabIds we currently hold a debugger on
const detachTimers = new Map();    // tabId -> setTimeout handle

function log(...a) { console.log("[floaty-cdp]", ...a); }

// NetAssembler — pure CDP Network event assembly for `floaty net --chrome`.
importScripts("netrecord.js");

// ── Relay connection ──────────────────────────────────────────────────────

function connect() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;
  try {
    ws = new WebSocket(RELAY_URL);
  } catch (e) {
    scheduleReconnect();
    return;
  }
  ws.onopen = async () => {
    log("connected to relay");
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
    // Optional shared-secret handshake (FloatyTerm enforces it only if a token
    // file exists on its side; otherwise this is ignored).
    const { floatyToken, floatyInstance, floatyProfileLabel } =
      await chrome.storage.local.get(["floatyToken", "floatyInstance", "floatyProfileLabel"]);
    // A stable id for THIS profile's copy of the extension (storage.local is
    // per profile). FloatyTerm uses it to tell "my worker reconnected" (replace
    // the old socket) from "another profile connected" (keep both). Without it,
    // two profiles evicted each other every ~2s and requests died mid-flight.
    let instance = floatyInstance;
    if (!instance) {
      instance = crypto.randomUUID();
      await chrome.storage.local.set({ floatyInstance: instance });
    }
    send({ hello: "floaty-cdp", token: floatyToken || "", instance, profile: floatyProfileLabel || "" });
    startKeepalive();
  };
  ws.onclose = () => { log("relay closed"); ws = null; stopKeepalive(); scheduleReconnect(); };
  ws.onerror = () => { try { ws.close(); } catch (e) {} };
  ws.onmessage = (ev) => handleCommand(ev.data);
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => { reconnectTimer = null; connect(); }, 2000);
}

function startKeepalive() {
  stopKeepalive();
  keepaliveTimer = setInterval(() => {
    if (ws && ws.readyState === WebSocket.OPEN) send({ ping: Date.now() });
  }, KEEPALIVE_MS);
}
function stopKeepalive() {
  if (keepaliveTimer) { clearInterval(keepaliveTimer); keepaliveTimer = null; }
}

function send(obj) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    try { ws.send(JSON.stringify(obj)); } catch (e) {}
  }
}
function reply(id, result, error, tabId) {
  const msg = error ? { id, error: String(error) } : { id, result: result || {} };
  if (tabId != null) msg.tabId = tabId;   // lets FloatyTerm pin a session to one tab
  send(msg);
}

// ── Tab resolution + attach lifecycle ─────────────────────────────────────

async function resolveTab(match) {
  const tabs = await chrome.tabs.query({});
  const usable = tabs.filter(t => t.id != null && /^(https?|file):/.test(t.url || ""));
  if (match) {
    const m = String(match).toLowerCase();
    const hit = usable.find(t =>
      (t.url || "").toLowerCase().includes(m) || (t.title || "").toLowerCase().includes(m));
    if (!hit) throw new Error(`no tab matches "${match}"`);
    return hit;
  }
  const active = usable.find(t => t.active);
  if (active) return active;
  if (usable[0]) return usable[0];
  throw new Error("no attachable http/https/file tab open");
}

async function ensureAttached(tabId) {
  if (attached.has(tabId)) return;
  try {
    await chrome.debugger.attach({ tabId }, CDP_VERSION);
  } catch (e) {
    if (!/already attached/i.test((e && e.message) || "")) throw e;
    // "Already attached" means one of two things. After a worker restart our
    // attached-set is empty but Chrome still holds OUR session — adopt it.
    // Or someone else holds the tab (DevTools open on it, another extension).
    // Only our own session answers a command, so probe with a harmless one.
    // On failure keep the ORIGINAL error — it names the real cause — and do
    // not mark the tab attached, so a retry after DevTools closes still works.
    try {
      await chrome.debugger.sendCommand({ tabId }, "Runtime.evaluate",
                                        { expression: "0", returnByValue: true });
    } catch (_) {
      throw e;
    }
  }
  attached.add(tabId);
}

function cancelDetach(tabId) {
  const t = detachTimers.get(tabId);
  if (t) { clearTimeout(t); detachTimers.delete(tabId); }
}

function scheduleDetach(tabId) {
  // A recording tab holds its debugger for the whole session. The idle
  // detach would otherwise end every recording 8s in, silently.
  if (recordings.has(tabId)) return;
  const prev = detachTimers.get(tabId);
  if (prev) clearTimeout(prev);
  detachTimers.set(tabId, setTimeout(async () => {
    detachTimers.delete(tabId);
    if (attached.has(tabId) && !recordings.has(tabId)) {
      try { await chrome.debugger.detach({ tabId }); } catch (e) {}
      attached.delete(tabId);
    }
  }, DETACH_IDLE_MS));
}

// ── Command dispatch ───────────────────────────────────────────────────────

async function handleCommand(raw) {
  let cmd;
  try { cmd = JSON.parse(raw); } catch (e) { return; }
  const { id, method, params, match, tabId: pinned } = cmd;
  if (id == null || !method) return;   // pings / non-commands: ignore

  try {
    // Synthetic namespace the extension answers itself (no CDP attach needed).
    if (method === "Floaty.listTabs") {
      // active + windowFocused let FloatyTerm pick the right PROFILE when
      // several are connected and a command names no tab: the one whose
      // window the user is actually looking at.
      const [tabs, focusedWin] = await Promise.all([
        chrome.tabs.query({}),
        chrome.windows.getLastFocused().catch(() => null),
      ]);
      reply(id, {
        tabs: tabs
          .filter(t => /^(https?|file):/.test(t.url || ""))
          .map(t => ({
            id: String(t.id), title: t.title || "", url: t.url || "",
            active: !!t.active,
            windowFocused: !!(focusedWin && focusedWin.focused && t.windowId === focusedWin.id),
          }))
      });
      return;
    }

    // Network recording — answered here, not forwarded as raw CDP.
    if (method === "Floaty.netStatus") { reply(id, netStatus()); return; }
    if (method === "Floaty.netStop") {
      if (pinned == null) throw new Error("netStop needs a tabId");
      reply(id, await netStop(pinned), null, pinned);
      return;
    }
    if (method === "Floaty.netStart") {
      const tab = pinned != null ? await chrome.tabs.get(pinned) : await resolveTab(match);
      reply(id, await netStart(tab, params), null, tab.id);
      return;
    }

    // A pinned tabId (from an earlier reply in the same FloatyTerm session)
    // beats match-resolution: a multi-command op must stay on ONE tab even if
    // the user switches tabs mid-flight. chrome.tabs.get rejects if it closed —
    // the error reply is the honest answer ("re-run", not silent drift).
    const tab = pinned != null ? await chrome.tabs.get(pinned) : await resolveTab(match);
    await ensureAttached(tab.id);
    const result = await chrome.debugger.sendCommand({ tabId: tab.id }, method, params || {});
    reply(id, result || {}, null, tab.id);
    scheduleDetach(tab.id);   // auto-detach when idle → banner clears
  } catch (e) {
    reply(id, null, (e && e.message) ? e.message : e);
  }
}

// ── Network recording ─────────────────────────────────────────────────────
//
// `floaty net start --chrome` arrives as Floaty.netStart. The tab stays
// attached for the whole session, Network.* events are assembled into
// complete request records by NetAssembler (netrecord.js), and finished
// records are POSTed to FloatyTerm's /net ingress in batches.

const NET_BATCH_BYTES = 8 * 1024 * 1024;   // one POST, well under the relay's cap
const NET_FLUSH_MS = 500;
const NET_STORE_KEY = "floatyNetRecordings";
// Chrome evicts response bodies it no longer needs; generous buffers keep
// them fetchable until loadingFinished gets to them.
const NETWORK_ENABLE = {
  maxTotalBufferSize: 200 * 1024 * 1024,
  maxResourceBufferSize: 50 * 1024 * 1024,
  maxPostDataSize: 20 * 1024 * 1024,
};
// waitForDebuggerOnStart stays FALSE on purpose. TRUE would catch a child
// frame's very first request, but it pauses that frame until we release it —
// and on a Chrome too old for child sessions the release call fails and the
// frame hangs forever. Missing a first request beats freezing the page.
const AUTO_ATTACH = { autoAttach: true, waitForDebuggerOnStart: false, flatten: true };

const recordings = new Map();   // tabId → recording
const endedEarly = new Map();   // tabId → why it ended before netStop

function newRecording(tabId, cfg) {
  const rec = {
    tabId, label: cfg.label, relay: cfg.relay, maxBody: cfg.maxBody,
    queue: [], queueBytes: 0, timer: null, chain: Promise.resolve(),
    fetches: new Set(), events: 0, sent: 0, sendErrors: 0, lastError: null,
  };
  rec.assembler = new NetAssembler({ maxBody: cfg.maxBody, onEvent: (ev) => enqueue(rec, ev) });
  return rec;
}

async function armNetwork(tabId) {
  await chrome.debugger.sendCommand({ tabId }, "Network.enable", NETWORK_ENABLE);
  // Out-of-process iframes and workers are separate targets; without
  // auto-attach their traffic never reaches this tab's event stream.
  try { await chrome.debugger.sendCommand({ tabId }, "Target.setAutoAttach", AUTO_ATTACH); }
  catch (e) { log("auto-attach unavailable:", e && e.message); }
}

async function armChild(tabId, params) {
  const target = { tabId, sessionId: params.sessionId };
  try { await chrome.debugger.sendCommand(target, "Network.enable", NETWORK_ENABLE); } catch (e) {}
  try { await chrome.debugger.sendCommand(target, "Target.setAutoAttach", AUTO_ATTACH); } catch (e) {}
  if (params.waitingForDebugger) {
    try { await chrome.debugger.sendCommand(target, "Runtime.runIfWaitingForDebugger"); } catch (e) {}
  }
}

async function netStart(tab, params) {
  if (recordings.has(tab.id)) {
    throw new Error(`tab ${tab.id} is already recording (label "${recordings.get(tab.id).label}")`);
  }
  if (!params || !params.label || !params.relay) throw new Error("netStart needs label and relay");
  const cfg = { label: params.label, relay: params.relay, maxBody: params.maxBody || 5000000 };
  await ensureAttached(tab.id);
  cancelDetach(tab.id);
  const rec = newRecording(tab.id, cfg);
  recordings.set(tab.id, rec);   // BEFORE enable: events start arriving at once
  endedEarly.delete(tab.id);
  try { await armNetwork(tab.id); }
  catch (e) { recordings.delete(tab.id); throw e; }
  await persistRecordings();
  return { recording: true, tabId: tab.id, url: tab.url || "", title: tab.title || "", label: cfg.label };
}

async function netStop(tabId) {
  const rec = recordings.get(tabId);
  if (!rec) {
    const reason = endedEarly.get(tabId);
    endedEarly.delete(tabId);
    if (reason) return { stopped: true, tabId, ended_early: reason };
    throw new Error(`tab ${tabId} is not recording`);
  }
  await finishRecording(rec, "recording stopped before this request completed");
  try { await chrome.debugger.sendCommand({ tabId }, "Network.disable"); } catch (e) {}
  scheduleDetach(tabId);
  return {
    stopped: true, tabId, events: rec.events, sent: rec.sent,
    send_errors: rec.sendErrors, last_error: rec.lastError || undefined,
  };
}

function netStatus() {
  return {
    recordings: [...recordings.values()].map((r) => ({
      tabId: r.tabId, label: r.label, events: r.events, sent: r.sent,
      send_errors: r.sendErrors, in_flight: r.assembler.pending.size,
    })),
  };
}

// Shared by stop, tab close and detach: wait for body fetches, emit what is
// still in flight as incomplete, flush — and only THEN reply, so FloatyTerm
// closes the file after the last batch has landed.
async function finishRecording(rec, reason) {
  recordings.delete(rec.tabId);
  await Promise.allSettled([...rec.fetches]);
  rec.assembler.flushAll(reason);
  if (rec.timer) { clearTimeout(rec.timer); rec.timer = null; }
  await flushRecording(rec);
  await persistRecordings();
}

function endRecordingEarly(tabId, reason) {
  const rec = recordings.get(tabId);
  if (!rec) return;
  endedEarly.set(tabId, reason);
  finishRecording(rec, reason);
}

function approxSize(ev) {
  return 2048 + (typeof ev.req_body === "string" ? ev.req_body.length : 0)
              + (typeof ev.res_body === "string" ? ev.res_body.length : 0);
}

function enqueue(rec, ev) {
  rec.events++;
  rec.queue.push(ev);
  rec.queueBytes += approxSize(ev);
  if (rec.queueBytes >= NET_BATCH_BYTES) { flushRecording(rec); return; }
  if (!rec.timer) rec.timer = setTimeout(() => { rec.timer = null; flushRecording(rec); }, NET_FLUSH_MS);
}

// Serialized through rec.chain: two overlapping flushes would race their
// POSTs and could reorder a session. The returned promise settles once
// everything queued up to this call has been sent.
function flushRecording(rec) {
  rec.chain = rec.chain.then(async () => {
    while (rec.queue.length) {
      const batch = [];
      let bytes = 0;
      while (rec.queue.length && (batch.length === 0 || bytes + approxSize(rec.queue[0]) <= NET_BATCH_BYTES)) {
        const ev = rec.queue.shift();
        bytes += approxSize(ev);
        batch.push(ev);
      }
      rec.queueBytes = Math.max(0, rec.queueBytes - bytes);
      try {
        const res = await fetch(rec.relay, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ label: rec.label, source: "chrome-cdp", events: batch }),
        });
        if (!res.ok) throw new Error(`relay answered ${res.status}`);
        rec.sent += batch.length;
      } catch (e) {
        rec.sendErrors += batch.length;
        rec.lastError = (e && e.message) || String(e);
        log("net batch failed:", rec.lastError);
      }
    }
  });
  return rec.chain;
}

function fetchBodies(tabId, rec, need) {
  const target = need.sessionId ? { tabId, sessionId: need.sessionId } : { tabId };
  const job = (async () => {
    const bodies = {};
    if (need.response) {
      try {
        const r = await chrome.debugger.sendCommand(target, "Network.getResponseBody", { requestId: need.requestId });
        bodies.resBody = r.body;
        bodies.resBase64 = !!r.base64Encoded;
      } catch (e) { bodies.resError = (e && e.message) || String(e); }
    }
    if (need.post) {
      try {
        const r = await chrome.debugger.sendCommand(target, "Network.getRequestPostData", { requestId: need.requestId });
        bodies.postData = r.postData;
        bodies.postBase64 = !!r.base64Encoded;
      } catch (e) {}
    }
    rec.assembler.complete(need.key, bodies);
  })();
  rec.fetches.add(job);
  job.finally(() => rec.fetches.delete(job));
}

async function persistRecordings() {
  const cfg = {};
  for (const [tabId, r] of recordings) cfg[tabId] = { label: r.label, relay: r.relay, maxBody: r.maxBody };
  try { await chrome.storage.session.set({ [NET_STORE_KEY]: cfg }); } catch (e) {}
}

// Chrome can still restart an MV3 worker. The debugger session and the tab
// survive that; our in-memory state does not. Re-arm every recording that was
// live, so a restart costs the requests in flight at that moment — not the
// rest of the session.
async function rearmRecordings() {
  let saved = {};
  try { saved = (await chrome.storage.session.get(NET_STORE_KEY))[NET_STORE_KEY] || {}; }
  catch (e) { return; }
  for (const [id, cfg] of Object.entries(saved)) {
    const tabId = Number(id);
    if (recordings.has(tabId)) continue;
    try {
      await chrome.tabs.get(tabId);
      await ensureAttached(tabId);
      cancelDetach(tabId);
      recordings.set(tabId, newRecording(tabId, cfg));
      await armNetwork(tabId);
      log("re-armed recording on tab", tabId);
    } catch (e) {
      recordings.delete(tabId);
      endedEarly.set(tabId, "extension restarted and could not re-attach: " + ((e && e.message) || e));
    }
  }
  await persistRecordings();
}

// Top level, so Chrome can wake the worker for these events.
chrome.debugger.onEvent.addListener((source, method, params) => {
  const rec = recordings.get(source.tabId);
  if (!rec) return;
  if (method === "Target.attachedToTarget") { armChild(source.tabId, params); return; }
  if (!method.startsWith("Network.")) return;
  let need = null;
  try { need = rec.assembler.handle(source.sessionId, method, params); }
  catch (e) { log("assembler error on", method, e && e.message); }
  if (need) fetchBodies(source.tabId, rec, need);
});

// Options page pokes: "reconnect" tears down and redials (also how a token
// change takes effect). Merely receiving this message wakes the SW if it was
// idle-killed, which alone re-triggers connect() at top level.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "reconnect") {
    try { if (ws) ws.close(); } catch (e) {}
    ws = null;
    connect();
    sendResponse({ ok: true });
  }
  return false;
});

// Keep our attached-set honest if a tab closes or the user detaches manually.
chrome.debugger.onDetach.addListener((source, reason) => {
  if (source.tabId == null || source.sessionId) return;   // a child frame leaving is not the tab leaving
  attached.delete(source.tabId);
  endRecordingEarly(source.tabId, `debugger detached (${reason})` +
    (reason === "canceled_by_user" ? " — the \"is debugging this browser\" banner was dismissed" : ""));
});
chrome.tabs.onRemoved.addListener((tabId) => {
  attached.delete(tabId);
  endRecordingEarly(tabId, "tab closed");
});

// (Re)connect on every SW spin-up. The alarm is the backstop: MV3 kills an idle
// SW at ~30s, and a 30s alarm respawns it so the bridge self-heals.
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.alarms.create("floaty-reconnect", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => connect());

connect();
rearmRecordings();
