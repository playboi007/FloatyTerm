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
    const { floatyToken } = await chrome.storage.local.get("floatyToken");
    send({ hello: "floaty-cdp", token: floatyToken || "" });
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
  await chrome.debugger.attach({ tabId }, CDP_VERSION);
  attached.add(tabId);
}

function scheduleDetach(tabId) {
  const prev = detachTimers.get(tabId);
  if (prev) clearTimeout(prev);
  detachTimers.set(tabId, setTimeout(async () => {
    detachTimers.delete(tabId);
    if (attached.has(tabId)) {
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
      const tabs = await chrome.tabs.query({});
      reply(id, {
        tabs: tabs
          .filter(t => /^(https?|file):/.test(t.url || ""))
          .map(t => ({ id: String(t.id), title: t.title || "", url: t.url || "" }))
      });
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
chrome.debugger.onDetach.addListener((source) => {
  if (source.tabId != null) attached.delete(source.tabId);
});
chrome.tabs.onRemoved.addListener((tabId) => { attached.delete(tabId); });

// (Re)connect on every SW spin-up. The alarm is the backstop: MV3 kills an idle
// SW at ~30s, and a 30s alarm respawns it so the bridge self-heals.
chrome.runtime.onStartup.addListener(connect);
chrome.runtime.onInstalled.addListener(connect);
chrome.alarms.create("floaty-reconnect", { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(() => connect());

connect();
