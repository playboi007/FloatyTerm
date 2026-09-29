/* Transport-independent conversation events. No DOM, processes, or provider SDKs. */
(function (root) {
  'use strict';
  const VERSION = 1;
  const factories = new Map();
  const controls = new Set(['capabilities', 'model', 'mode', 'effort', 'git', 'sessions', 'history', 'thinking', 'usage']);
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
    return { sessionId: null, busy: false, status: 'idle', blocks: new Map(), tools: new Map(), approvals: new Map(), unknown: [] };
  }
  function reduce(state, e) {
    if (e.v !== VERSION) throw new Error('Unsupported agent event version: ' + e.v);
    switch (e.type) {
      case 'session': state.sessionId = e.sessionId || state.sessionId; break;
      case 'turn.start': state.busy = true; state.status = 'running'; break;
      case 'content.start': case 'content.delta': case 'content.snapshot': case 'content.end': {
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
        break;
      }
      case 'tool.start': case 'tool.input': case 'tool.result': {
        const tool = state.tools.get(e.id) || { id: e.id, name: e.name || 'Tool', parentId: e.parentId || null, state: 'running' };
        if (e.name) tool.name = e.name;
        if (e.input !== undefined) tool.input = e.input;
        if (e.type === 'tool.result') {
          tool.output = e.output; tool.state = e.isError ? 'error' : 'done';
          for (const [id, request] of state.approvals) if (request.toolUseID === e.id) state.approvals.delete(id);
        }
        else state.busy = true;
        state.tools.set(e.id, tool);
        break;
      }
      case 'approval.request': state.approvals.set(e.request.id, e.request); break;
      case 'approval.cancel': state.approvals.delete(e.id); break;
      case 'turn.end':
        state.busy = false; state.status = e.status;
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
  const api = { VERSION, envelope, createNormalizer, createState, reduce, register: (name, factory) => factories.set(name, factory) };
  root.AgentEvents = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
