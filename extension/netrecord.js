// FloatyTerm CDP Bridge — network recording assembler.
//
// Pure: turns one tab's Network.* CDP event stream into complete, replayable
// request records. No chrome.* calls live here — fetching bodies and shipping
// records are background.js's job — so this file loads in the service worker
// via importScripts() AND under node for tests.
//
// Why assembly happens in the extension and not in FloatyTerm: one request is
// five-plus events that arrive out of order (the ExtraInfo pair can land
// before OR after the event it belongs to), and its response body can only be
// fetched while Chrome still holds it. Shipping raw events over the bridge
// would move the correlation away from the one place that can fetch the body
// in time.
//
// UNREDACTED by design. Cookies come from the ExtraInfo raw headers — the
// plain Network events leave them out — and bodies are kept verbatim, because
// the point of a record is a request you can replay.
"use strict";

// Not network traffic: inline data, in-memory blobs, extension internals.
const IGNORED_SCHEMES = /^(data|blob|chrome-extension|devtools|about):/i;

/// CDP header objects are {Name: value}, and the raw ExtraInfo form joins a
/// repeated header (Set-Cookie) with "\n". The recorder schema is
/// {name: [values]}, lower-cased: HTTP names are case-insensitive and h2
/// already sends them lower-case, so this makes both forms look the same.
function headerLists(obj) {
  const out = {};
  for (const [k, v] of Object.entries(obj || {})) {
    const key = k.toLowerCase();
    out[key] = (out[key] || []).concat(String(v).split("\n"));
  }
  return out;
}

function utf8Length(s) { return new TextEncoder().encode(s).length; }

function base64Length(s) {
  const pad = s.endsWith("==") ? 2 : s.endsWith("=") ? 1 : 0;
  return Math.floor(s.length * 3 / 4) - pad;
}

function attachBody(ev, prefix, text, isBase64, maxBody) {
  if (text == null || text === "") return;
  const bytes = isBase64 ? base64Length(text) : utf8Length(text);
  ev[`${prefix}_body_bytes`] = bytes;
  if (maxBody > 0 && bytes > maxBody) {
    // base64 must be cut on a 4-char boundary or the tail stops decoding.
    text = text.slice(0, isBase64 ? Math.floor(maxBody / 3) * 4 : maxBody);
    ev[`${prefix}_body_truncated`] = true;
  }
  ev[`${prefix}_body`] = text;
  if (isBase64) ev[`${prefix}_body_base64`] = true;
}

/// postDataEntries arrive as base64 chunks. Chunks are not guaranteed to be
/// 3-byte aligned, so they are decoded and joined as bytes, never as strings.
function joinEntries(entries) {
  let binary = "";
  for (const e of entries) if (e && e.bytes) binary += atob(e.bytes);
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
  try {
    return { text: new TextDecoder("utf-8", { fatal: true }).decode(bytes), base64: false };
  } catch (_) {
    return { text: btoa(binary), base64: true };
  }
}

/// Who asked for this request. The full stack stays in the receipt; the
/// summary is the one line a reader needs ("script app.js:120").
function initiatorSummary(init) {
  if (!init) return undefined;
  const out = { type: init.type };
  if (init.url) out.url = init.url;
  if (init.lineNumber != null) out.line = init.lineNumber + 1;
  const frame = init.stack && init.stack.callFrames && init.stack.callFrames[0];
  if (frame) out.frame = `${frame.functionName || "(anonymous)"} ${frame.url}:${frame.lineNumber + 1}`;
  return out;
}

class NetAssembler {
  constructor({ maxBody = 5000000, onEvent }) {
    this.maxBody = maxBody;
    this.onEvent = onEvent;
    this.pending = new Map();   // key → entry being assembled
    this.ignored = new Set();   // keys of data:/blob: requests
    this.sockets = new Map();   // key → WebSocket url
  }

  /// requestIds are unique per TARGET, not per tab — an out-of-process
  /// iframe can reuse an id the main frame used. The session is part of the key.
  static key(sessionId, requestId) { return `${sessionId || "main"}:${requestId}`; }

  entry(key, sessionId) {
    let e = this.pending.get(key);
    if (!e) { e = { extra: {}, sessionId }; this.pending.set(key, e); }
    return e;
  }

  /// Feeds one CDP event. When a response has finished, returns a body-fetch
  /// request — {key, requestId, sessionId, response, post} — that the caller
  /// resolves and hands back to complete(). Otherwise returns null.
  handle(sessionId, method, p) {
    p = p || {};
    const key = NetAssembler.key(sessionId, p.requestId);
    if (this.ignored.has(key)) {
      if (method === "Network.loadingFinished" || method === "Network.loadingFailed") this.ignored.delete(key);
      return null;
    }
    switch (method) {
      case "Network.requestWillBeSent":
        return this.onRequest(key, sessionId, p);

      case "Network.requestWillBeSentExtraInfo":
        this.entry(key, sessionId).extra.request = { headers: p.headers, cookies: p.associatedCookies };
        return null;

      case "Network.responseReceivedExtraInfo":
        this.entry(key, sessionId).extra.response =
          { headers: p.headers, status: p.statusCode, headersText: p.headersText };
        return null;

      case "Network.requestServedFromCache":
        this.entry(key, sessionId).fromMemoryCache = true;
        return null;

      case "Network.responseReceived": {
        const e = this.entry(key, sessionId);
        e.response = p.response;
        e.resourceType = p.type || e.resourceType;
        return null;
      }

      case "Network.loadingFinished":
      case "Network.loadingFailed": {
        const e = this.pending.get(key);
        if (!e || !e.request) return null;
        e.tsEnd = p.timestamp;
        if (method === "Network.loadingFinished") {
          e.encoded = p.encodedDataLength;
        } else {
          e.error = p.errorText
            + (p.canceled ? " (canceled)" : "")
            + (p.blockedReason ? ` [blocked: ${p.blockedReason}]` : "")
            + (p.corsErrorStatus ? ` [cors: ${p.corsErrorStatus.corsError}]` : "");
        }
        const r = e.request;
        return {
          key, requestId: p.requestId, sessionId,
          response: method === "Network.loadingFinished",
          post: !!(r.hasPostData && r.postData == null && !r.postDataEntries),
        };
      }

      case "Network.webSocketCreated":
        this.sockets.set(key, p.url);
        this.emitSocket(key, sessionId, "open", { initiator: initiatorSummary(p.initiator) });
        return null;

      case "Network.webSocketHandshakeResponseReceived": {
        const r = p.response || {};
        this.emitSocket(key, sessionId, "handshake", {
          status: r.status, status_text: r.statusText,
          req_headers: headerLists(r.requestHeaders), res_headers: headerLists(r.headers),
        });
        return null;
      }

      case "Network.webSocketFrameSent":
      case "Network.webSocketFrameReceived": {
        const f = p.response || {};
        const sent = method === "Network.webSocketFrameSent";
        const ev = { opcode: f.opcode };
        // opcode 2 = binary; CDP already hands those over base64.
        attachBody(ev, sent ? "req" : "res", f.payloadData, f.opcode === 2, this.maxBody);
        this.emitSocket(key, sessionId, sent ? "send" : "receive", ev);
        return null;
      }

      case "Network.webSocketFrameError":
        this.emitSocket(key, sessionId, "error", { error: p.errorMessage });
        return null;

      case "Network.webSocketClosed":
        this.emitSocket(key, sessionId, "close", {});
        this.sockets.delete(key);
        return null;

      case "Network.eventSourceMessageReceived": {
        const e = this.pending.get(key);
        const ev = {
          kind: "network", protocol: "sse", method: "SSE",
          url: e && e.request ? e.request.url : "",
          event_name: p.eventName, event_id: p.eventId, target: sessionId || "main",
        };
        attachBody(ev, "res", p.data, false, this.maxBody);
        this.onEvent(ev);
        return null;
      }

      default:
        return null;
    }
  }

  onRequest(key, sessionId, p) {
    const url = p.request.url + (p.request.urlFragment || "");
    if (IGNORED_SCHEMES.test(url)) {
      this.ignored.add(key);
      this.pending.delete(key);
      return null;
    }

    let redirectedFrom;
    const prev = this.pending.get(key);
    if (p.redirectResponse && prev && prev.request) {
      // Same requestId, next hop. The previous hop is finished and its
      // response IS the redirect — emit it as its own record, because a replay
      // of the chain needs every hop, not only the last one.
      prev.response = p.redirectResponse;
      prev.tsEnd = p.timestamp;
      this.emit(prev, {});
      redirectedFrom = prev.request.url + (prev.request.urlFragment || "");
      this.pending.delete(key);
    }

    const e = this.entry(key, sessionId);   // keeps any ExtraInfo that arrived first
    e.request = p.request;
    e.ts0 = p.timestamp;
    e.wallTime = p.wallTime;
    e.resourceType = p.type;
    e.initiator = p.initiator;
    e.documentURL = p.documentURL;
    e.redirectedFrom = redirectedFrom;
    return null;
  }

  /// Emits a finished request with the bodies the caller fetched.
  complete(key, bodies) {
    const e = this.pending.get(key);
    if (!e) return;
    this.pending.delete(key);
    this.emit(e, bodies || {});
  }

  /// Emits every request still in flight, marked with `reason`. A recording
  /// that drops the calls that never finished hides exactly the hung request
  /// someone was trying to find.
  flushAll(reason) {
    for (const e of this.pending.values()) {
      if (!e.request) continue;
      if (!e.error) e.error = reason;
      this.emit(e, {});
    }
    this.pending.clear();
  }

  emit(e, b) {
    const req = e.request || {};
    const res = e.response;
    const reqExtra = e.extra.request;
    const resExtra = e.extra.response;

    const ev = {
      kind: "network",
      protocol: "http",
      method: req.method || "",
      url: (req.url || "") + (req.urlFragment || ""),
      // Raw headers win: the plain Network.requestWillBeSent headers omit
      // Cookie and the h2 pseudo-headers, and a replay needs the cookie.
      req_headers: headerLists((reqExtra && reqExtra.headers) || req.headers),
      resource_type: e.resourceType,
      target: e.sessionId || "main",
    };
    if (e.wallTime) ev.started_at = new Date(e.wallTime * 1000).toISOString();
    if (e.ts0 != null && e.tsEnd != null) ev.ms = Math.round((e.tsEnd - e.ts0) * 1e6) / 1000;
    if (e.documentURL) ev.document_url = e.documentURL;
    if (e.redirectedFrom) ev.redirected_from = e.redirectedFrom;
    const init = initiatorSummary(e.initiator);
    if (init) ev.initiator = init;
    if (reqExtra && reqExtra.cookies && reqExtra.cookies.length) {
      ev.req_cookies = reqExtra.cookies.map((c) => ({
        name: c.cookie.name, value: c.cookie.value, domain: c.cookie.domain, path: c.cookie.path,
        blocked: (c.blockedReasons || []).length ? c.blockedReasons : undefined,
      }));
    }

    // Request body: inline postData, else the chunked entries, else what the
    // caller fetched with Network.getRequestPostData.
    let post = req.postData;
    let postBase64 = false;
    if (post == null && req.postDataEntries) {
      const joined = joinEntries(req.postDataEntries);
      post = joined.text;
      postBase64 = joined.base64;
    }
    if (post == null && b.postData != null) {
      post = b.postData;
      postBase64 = !!b.postBase64;
    }
    attachBody(ev, "req", post, postBase64, this.maxBody);

    if (res) {
      ev.status = (resExtra && resExtra.status) || res.status;
      ev.status_text = res.statusText;
      ev.res_headers = headerLists((resExtra && resExtra.headers) || res.headers);
      ev.http_version = res.protocol;
      ev.mime_type = res.mimeType;
      if (res.remoteIPAddress) {
        ev.remote_address = res.remoteIPAddress;
        ev.remote_port = res.remotePort;
      }
      if (res.fromDiskCache) ev.from_cache = "disk";
      else if (e.fromMemoryCache) ev.from_cache = "memory";
      if (res.fromServiceWorker) ev.from_service_worker = true;
      if (res.securityDetails) {
        const s = res.securityDetails;
        ev.tls = { protocol: s.protocol, cipher: s.cipher, subject: s.subjectName, issuer: s.issuer, valid_to: s.validTo };
      }
      if (e.encoded != null) ev.res_encoded_bytes = e.encoded;
      if (resExtra && resExtra.headersText) ev.res_headers_text = resExtra.headersText;
    }

    if (b.resBody != null) {
      attachBody(ev, "res", b.resBody, !!b.resBase64, this.maxBody);
    } else if (b.resError && res && res.status !== 204 && !(res.status >= 300 && res.status < 400)) {
      // Say WHY there is no body, so an empty body is never mistaken for one.
      ev.res_body_error = b.resError;
    }
    if (e.error) ev.error = e.error;

    // The receipt: what CDP said, minus the body copies already above.
    ev.cdp = {
      request: Object.assign({}, req, { postData: undefined, postDataEntries: undefined }),
      response: res,
      request_extra: reqExtra,
      response_extra: resExtra,
    };
    this.onEvent(ev);
  }

  emitSocket(key, sessionId, event, extra) {
    this.onEvent(Object.assign({
      kind: "network", protocol: "websocket",
      method: `WS ${event}`, url: this.sockets.get(key) || "",
      ws_event: event, socket_id: key, target: sessionId || "main",
    }, extra));
  }
}

if (typeof module !== "undefined") module.exports = { NetAssembler, headerLists };
