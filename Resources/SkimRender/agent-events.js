/* Transport-independent conversation events. No DOM, processes, or provider SDKs. */
(function (root) {
  'use strict';
  const VERSION = 1;
  // Memory is the reducer's job, not the producer's: cap what a single conversation may retain.
  const TOOL_OUTPUT_MAX = 256 * 1024;   // the streamed-delta window, applied to final results too
  // Finished blocks and tools are already drawn; the reducer keeps only the newest of them.
  const BLOCKS_MAX = 400;
  const TOOLS_MAX = 200;
  const DETAIL_STRING_MAX = 16000;
  const DETAIL_ITEMS_MAX = 100;
  const DETAIL_DEPTH_MAX = 8;
  const SECRET_KEY = /^(accessToken|refreshToken|idToken|apiKey|clientSecret|password|secret|token|authorization|challenge|sdp|deltaBase64)$/i;
  const SCHEMA_TYPES = ['string', 'number', 'integer', 'boolean', 'array'];
  const capped = (text, max = TOOL_OUTPUT_MAX) => typeof text === 'string' && text.length > max
    ? '… (' + (text.length - max) + ' more characters)\n' + text.slice(-max) : text;
  /** Bounded deep copy for folded payloads, matching the Codex producer's safePayload: surfaces and media may outlive their turn. */
  function bound(value, depth = 0) {
    if (depth > DETAIL_DEPTH_MAX) return '[nested details omitted]';
    if (typeof value === 'string') return value.length > DETAIL_STRING_MAX ? value.slice(0, DETAIL_STRING_MAX) + '\n[Details truncated]' : value;
    if (Array.isArray(value)) return value.slice(0, DETAIL_ITEMS_MAX).map(v => bound(v, depth + 1));
    if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).slice(0, DETAIL_ITEMS_MAX).map(([k, v]) => [k,
      SECRET_KEY.test(k) && !(v && typeof v === 'object' && SCHEMA_TYPES.includes(v.type)) ? '[not displayed]' : bound(v, depth + 1)]));
    return value;
  }
  const factories = new Map();
  const controls = new Set(['capabilities', 'model', 'mode', 'effort', 'git', 'sessions', 'history', 'thinking', 'usage', 'files', 'title', 'rewind', 'btw', 'shell', 'promptHistory', 'catalog', 'permissionProfiles', 'usageHistory', 'import', 'guardian']);
  function envelope(agent, raw, event) {
    return { ...event, v: VERSION, agent, t: raw.t || 0, raw };
  }
  function control(agent, raw) {
    if (controls.has(raw.type)) return [envelope(agent, raw, raw)];
    if (raw.type === 'host' || raw.type === 'error' || raw.type === 'end') return [envelope(agent, raw, {
      type: 'notice', kind: raw.kind || (raw.type === 'error' ? 'error' : 'info'),
      message: raw.message || 'Session ended', terminal: raw.type !== 'host' || raw.kind === 'error'
    })];
    return null;
  }
  function createNormalizer(agent = 'claude') {
    const factory = factories.get(agent);
    if (!factory) throw new Error('Unsupported agent: ' + agent);
    const normalizer = factory();
    return {
      reset: () => normalizer.reset(),
      normalize(raw) {
        if (!raw || typeof raw !== 'object') throw new Error('Agent event must be an object');
        if (raw.v !== undefined) {
          if (raw.v !== VERSION) throw new Error('Unsupported agent event version: ' + raw.v);
          return [raw];
        }
        return control(agent, raw) || normalizer.normalize(raw).map(e => envelope(agent, raw, e));
      }
    };
  }
  function createState() {
    return { sessionId: null, busy: false, status: 'idle', blocks: new Map(), tools: new Map(), approvals: new Map(), turnDiffs: new Map(), plans: new Map(), surfaces: new Map(), media: new Map(), unknown: [] };
  }
  const turnKey = (threadId, turnId) => threadId != null && turnId != null ? JSON.stringify([String(threadId), String(turnId)]) : null;
  /** A finished turn's folded payloads are already drawn: drop them, except surfaces that span the session. */
  function pruneTurn(state, threadId, turnId) {
    if (threadId == null || turnId == null) return;
    state.turnDiffs.delete(turnKey(threadId, turnId));
    state.plans.delete(turnKey(threadId, turnId));
    for (const [id, surface] of state.surfaces) if (surface.placement !== 'session' && surface.threadId === threadId && surface.turnId === turnId) state.surfaces.delete(id);
    for (const [id, media] of state.media) if (media.threadId === threadId && media.turnId === turnId) state.media.delete(id);
  }
  /** Drops the oldest settled entries once a map outgrows its cap; running tools and open blocks always stay. */
  function evict(map, max, settled) {
    if (map.size <= max) return;
    const target = Math.floor(max * 0.8);   // trim below the cap so the scan is not repeated every event
    for (const [id, item] of map) {
      if (map.size <= target) break;
      if (settled(item)) map.delete(id);
    }
  }
  /** Drops the oldest entries of an insertion-ordered map once it outgrows `max`; normalizers keep state for in-flight items only. */
  function trimOldest(map, max) {
    for (const key of map.keys()) { if (map.size <= max) break; map.delete(key); }
  }
  function reduce(state, e) {
    if (e.v !== VERSION) throw new Error('Unsupported agent event version: ' + e.v);
    switch (e.type) {
      case 'session': state.sessionId = e.sessionId || state.sessionId; break;
      case 'turn.start': state.busy = true; state.status = 'running'; break;
      case 'plan.snapshot': { const key = turnKey(e.threadId, e.turnId); if (key) state.plans.set(key, e); break; }
      case 'surface.snapshot': {
        if (e.clear) {
          for (const [key, value] of state.surfaces) if (value.surface === e.surface && value.threadId === e.threadId) state.surfaces.delete(key);
        } else {
          const previous = state.surfaces.get(e.id);
          const data = bound(e.data);
          state.surfaces.set(e.id, { ...e, data: previous?.method === e.method ? data : { ...bound(previous?.data), ...data } });
        }
        break;
      }
      case 'media.snapshot': state.media.set(e.id, { ...e, url: bound(e.url) }); break;
      case 'tool.output.delta': case 'tool.progress': {
        const tool = state.tools.get(e.id) || { id: e.id, name: e.name || 'Tool', state: 'running' };
        if (e.type === 'tool.output.delta') {
          const stream = e.stream || 'stdout';
          tool.streams ||= {};
          const appended = (tool.streams[stream] || '') + (e.text || '');
          tool.capped = tool.capped || appended.length > TOOL_OUTPUT_MAX;
          tool.streams[stream] = appended.slice(-TOOL_OUTPUT_MAX);
          tool.output = Object.entries(tool.streams).map(([name, text]) => name === 'stdout' ? text : '[' + name + ']\n' + text).join('\n');
          tool.capped = tool.capped || !!e.capped;
          if (e.processHandle) tool.processHandle = e.processHandle;
        } else tool.progress = e.message || '';
        state.tools.set(e.id, tool); break;
      }
      case 'turn.diff.snapshot': {
        const key = turnKey(e.threadId, e.turnId);
        if (key) state.turnDiffs.set(key, { threadId: e.threadId, turnId: e.turnId, diff: typeof e.diff === 'string' ? e.diff : '' });
        break;
      }
      case 'content.start': case 'content.delta': case 'content.snapshot': case 'content.end': {
        if (e.parentId) break;   // a subagent's words belong to its own transcript
        let block = state.blocks.get(e.id);
        if (!block) {
          block = { id: e.id, messageId: e.messageId, kind: e.kind || 'text', text: '', final: false, redacted: !!e.redacted };
          state.blocks.set(e.id, block);
        }
        if (e.type === 'content.delta') block.text += e.text || '';
        if (e.type === 'content.snapshot') block.text = e.text || '';
        if (e.type === 'content.start' && e.text && !block.text) block.text = e.text;
        if (e.type === 'content.end' || e.final) block.final = true;
        if (!block.final) state.busy = true;
        evict(state.blocks, BLOCKS_MAX, item => item.final && item !== block);
        break;
      }
      case 'tool.start': case 'tool.input': case 'tool.result': {
        const tool = state.tools.get(e.id) || { id: e.id, name: e.name || 'Tool', parentId: e.parentId || null, state: 'running' };
        if (e.name) tool.name = e.name;
        if (e.input !== undefined) tool.input = e.input;
        if (e.type === 'tool.result') {
          if (e.output !== undefined) tool.output = capped(e.output);
          tool.state = e.isError ? 'error' : 'done';
          for (const [id, request] of state.approvals) if (request.toolUseID === e.id) state.approvals.delete(id);
        }
        else state.busy = true;
        state.tools.set(e.id, tool);
        evict(state.tools, TOOLS_MAX, item => item.state !== 'running' && item !== tool);
        break;
      }
      case 'approval.request': state.approvals.set(e.request.id, e.request); break;
      case 'approval.cancel': state.approvals.delete(e.id); break;
      case 'turn.end':
        state.busy = false; state.status = e.status;
        pruneTurn(state, e.threadId, e.turnId);
        for (const block of state.blocks.values()) block.final = true;
        for (const tool of state.tools.values()) if (tool.state === 'running') tool.state = e.status === 'success' ? 'interrupted' : e.status;
        state.approvals.clear();
        break;
      case 'notice': if (e.terminal) {
        state.busy = false; state.status = e.kind === 'error' ? 'error' : 'ended';
        for (const block of state.blocks.values()) block.final = true;
        for (const tool of state.tools.values()) if (tool.state === 'running') tool.state = 'interrupted';
        state.approvals.clear();
      } break;
      case 'unknown':
        state.unknown.push(e);
        if (state.unknown.length > 100) state.unknown.shift();
        break;
    }
    return state;
  }
  const api = {
    trimOldest, VERSION, envelope, createNormalizer, createState, reduce, turnKey, register: (name, factory) => factories.set(name, factory) };
  root.AgentEvents = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
