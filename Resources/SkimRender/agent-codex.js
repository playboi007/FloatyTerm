/* Codex exec --json adapter. Native item updates are complete snapshots. */
(function (root) {
  'use strict';
  const AgentEvents = root.AgentEvents || (typeof require === 'function' ? require('./agent-events.js') : null);
  if (!AgentEvents) throw new Error('Load agent-events.js before agent-codex.js');

  AgentEvents.register('codex', () => {
    let turnSequence = 0;
    let turnKey = 'turn-0';
    const items = new Map();
    const token = value => encodeURIComponent(String(value));
    const identity = (item, scope) => 'codex:' + token(scope) + ':' + token(item.id);
    const content = (type, id, kind, text, final) => ({ type, id, messageId: id, kind, text, ...(final ? { final: true } : {}) });
    const outputText = value => value == null ? undefined : typeof value === 'string' ? value : JSON.stringify(value, null, 2);
    const summary = item => {
      // exec --json maps the actual reasoning summary into item.text.
      if (typeof item.text === 'string') return item.text;
      if (typeof item.summary === 'string') return item.summary;
      if (Array.isArray(item.summary)) return item.summary.map(part => typeof part === 'string' ? part : part && typeof part.text === 'string' ? part.text : '').filter(Boolean).join('\n');
      return null;
    };
    const tool = item => {
      switch (item.type) {
        case 'command_execution': return { name: 'Bash', input: { command: item.command || '' }, output: item.aggregated_output, isError: (item.exit_code != null && item.exit_code !== 0) || item.status === 'failed' };
        case 'file_change': return { name: 'File changes', input: { changes: item.changes || [] }, output: item.status === 'failed' ? 'File changes failed' : item.status === 'completed' ? 'File changes completed' : undefined, isError: item.status === 'failed' };
        case 'mcp_tool_call': return { name: item.tool ? 'MCP: ' + item.tool : 'MCP tool', input: { server: item.server, arguments: item.arguments }, output: outputText(item.result ?? item.error), isError: !!item.error || item.status === 'failed' };
        case 'web_search': return { name: 'Web search', input: { query: item.query, action: item.action }, output: outputText(item.results ?? item.result), isError: item.status === 'failed' };
        case 'todo_list': return { name: 'Plan', input: { items: item.items }, output: outputText(item.items), isError: false };
        default: return null;
      }
    };
    function normalizeItem(phase, item, scope) {
      if (!item || typeof item !== 'object' || item.id == null) return [{ type: 'unknown', name: 'item.' + phase }];
      if (item.type === 'error') return [{ type: 'notice', kind: 'error', message: item.message || 'Codex item error', terminal: false }];
      const id = identity(item, scope);
      const previous = items.get(id);
      const first = !previous;
      const finished = phase === 'completed' || !!previous?.finished;
      const out = [];
      if (item.type === 'agent_message' || item.type === 'reasoning') {
        const kind = item.type === 'reasoning' ? 'thinking' : 'text';
        const text = kind === 'thinking' ? summary(item) : typeof item.text === 'string' ? item.text : null;
        if (first) out.push(content('content.start', id, kind));
        if (text !== null && (first || text !== previous.text)) out.push(content('content.snapshot', id, kind, text, finished));
        if (phase === 'completed' && (!previous || !previous.finished)) out.push(content('content.end', id, kind));
        items.set(id, { text: text === null ? previous?.text : text, finished });
        return out;
      }
      const detail = tool(item);
      if (!detail) return [{ type: 'unknown', name: 'item.' + phase + ':' + (item.type || 'unknown') }];
      if (first) out.push({ type: 'tool.start', id, name: detail.name, input: detail.input });
      else if (JSON.stringify(detail.input) !== JSON.stringify(previous.input)) out.push({ type: 'tool.input', id, name: detail.name, input: detail.input });
      if (phase === 'completed' && (!previous || !previous.finished)) out.push({ type: 'tool.result', id, name: detail.name, output: detail.output, isError: detail.isError });
      items.set(id, { input: detail.input, finished });
      return out;
    }
    return {
      reset() { turnSequence = 0; turnKey = 'turn-0'; items.clear(); },
      normalize(raw) {
        if (raw.type !== 'native' || !raw.event || typeof raw.event !== 'object') return [{ type: 'unknown', name: raw.type || 'invalid' }];
        const e = raw.event;
        switch (e.type) {
          case 'thread.started': return [{ type: 'session', sessionId: e.thread_id }];
          case 'turn.started':
            turnSequence += 1;
            turnKey = raw.turnId != null ? String(raw.turnId) : 'turn-' + turnSequence;
            return [{ type: 'turn.start' }];
          case 'turn.completed': return [{ type: 'turn.end', status: 'success', usage: e.usage }];
          case 'turn.failed': return [{ type: 'turn.end', status: 'error', message: e.error?.message || e.message || 'Codex turn failed', usage: e.usage }];
          case 'error': return [{ type: 'notice', kind: 'error', message: e.message || e.error?.message || 'Codex error', terminal: false }];
          case 'item.started': case 'item.updated': case 'item.completed':
            return normalizeItem(e.type.slice(5), e.item, raw.turnId != null ? String(raw.turnId) : turnKey);
          default: return [{ type: 'unknown', name: e.type || 'unnamed' }];
        }
      }
    };
  });
})(typeof globalThis !== 'undefined' ? globalThis : this);
