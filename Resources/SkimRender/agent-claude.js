/* Claude SDK -> FloatyTerm event contract. One instance per conversation. */
(function (root) {
  'use strict';
  const A = root.AgentEvents || require('./agent-events.js');
  function factory() {
    let current = null, serial = 0;
    const blocks = new Map();
    const messageBlocks = new Map(), confirmations = new Map();
    const stringify = value => typeof value === 'string' ? value : JSON.stringify(value == null ? '' : value);
    const resultText = value => typeof value === 'string' ? value : Array.isArray(value)
      ? value.map(c => c.text || stringify(c)).join('\n') : stringify(value);
    const identity = (messageId, index, kind, redacted = false) => ({ id: messageId + ':' + index, messageId, kind, redacted });
    const unknown = raw => [{ type: 'unknown', name: raw.msg?.event?.type || raw.msg?.subtype || raw.msg?.type || raw.type }];
    function remember(block) {
      if (!messageBlocks.has(block.messageId)) messageBlocks.set(block.messageId, []);
      messageBlocks.get(block.messageId).push(block);
      return block;
    }
    function reset() { current = null; serial = 0; blocks.clear(); messageBlocks.clear(); confirmations.clear(); }
    function normalize(raw) {
      if (raw.type === 'permission_request') return [{ type: 'approval.request', request: raw }];
      if (raw.type === 'permission_cancelled') return [{ type: 'approval.cancel', id: raw.id }];
      if (raw.type !== 'sdk' || !raw.msg) return unknown(raw);
      const msg = raw.msg;
      if (msg.type === 'stream_event') {
        if (msg.parent_tool_use_id) return []; // Subagent tools arrive in full messages.
        const e = msg.event || {};
        if (e.type === 'message_start') {
          current = e.message?.id || 'anonymous-' + ++serial;
          return [{ type: 'turn.start' }];
        }
        if (e.type === 'message_stop' || e.type === 'message_delta') return [];
        if (e.type === 'content_block_start') {
          if (!current) current = 'anonymous-' + ++serial;
          const b = e.content_block || {};
          const key = current + ':' + e.index;
          if (b.type === 'tool_use') {
            blocks.set(key, { toolId: b.id, input: '' });
            return [{ type: 'tool.start', id: b.id, name: b.name }];
          }
          const kind = b.type === 'text' ? 'text' : ['thinking', 'redacted_thinking'].includes(b.type) ? 'thinking' : null;
          if (!kind) return unknown(raw);
          const id = remember(identity(current, e.index, kind, b.type === 'redacted_thinking'));
          blocks.set(key, id);
          return [{ type: 'content.start', ...id, text: b.text || b.thinking || '' }];
        }
        const block = blocks.get(current + ':' + e.index);
        if (e.type === 'content_block_delta') {
          const d = e.delta || {};
          if (d.type === 'signature_delta') return [];
          if (d.type === 'input_json_delta' && block?.toolId) {
            block.input += d.partial_json || '';
            return []; // Parse only when complete; the full tool block is authoritative.
          }
          if (!block || !block.id) return unknown(raw);
          if (d.type === 'text_delta' || d.type === 'thinking_delta') return [{
            type: 'content.delta', ...block, text: d.text || d.thinking || ''
          }];
        }
        if (e.type === 'content_block_stop' && block) {
          if (block.toolId) {
            if (!block.input) return [];
            try { return [{ type: 'tool.input', id: block.toolId, input: JSON.parse(block.input) }]; }
            catch { return unknown(raw); }
          }
          return [{ type: 'content.end', ...block }];
        }
        return unknown(raw);
      }
      if (msg.type === 'assistant') {
        const m = msg.message || {}, out = [];
        const messageId = m.id || 'anonymous-' + ++serial;
        for (const [index, c] of (m.content || []).entries()) {
          if (!msg.parent_tool_use_id && ['text', 'thinking', 'redacted_thinking'].includes(c.type)) {
            const kind = c.type === 'text' ? 'text' : 'thinking';
            const text = c.text || c.thinking || '';
            // SDK assistant envelopes can contain ONE completed block even when
            // the native message had thinking, text, and tools at other indices.
            // Match by kind/order, not the envelope's local content-array index.
            const confirmation = msg.uuid ? msg.uuid + ':' + index : null;
            const candidates = (messageBlocks.get(messageId) || []).filter(b => b.kind === kind);
            let block = confirmation && confirmations.get(confirmation);
            block ||= candidates.find(b => !b.confirmed) || candidates.find(b => b.snapshot === text);
            if (!block) {
              const key = messageId + ':' + index;
              block = remember(identity(messageId, blocks.has(key) ? 'full-' + ++serial : index, kind, c.type === 'redacted_thinking'));
              blocks.set(block.id, block);
            }
            block.confirmed = true; block.snapshot = text;
            if (confirmation) confirmations.set(confirmation, block);
            out.push({ type: 'content.snapshot', id: block.id, messageId, kind, redacted: block.redacted, text, final: true });
          } else if (c.type === 'tool_use') {
            out.push({ type: 'tool.start', id: c.id, name: c.name, parentId: msg.parent_tool_use_id || null, input: c.input });
          } else if (!msg.parent_tool_use_id) out.push({ type: 'unknown', name: c.type });
        }
        return out;
      }
      if (msg.type === 'user') return (Array.isArray(msg.message?.content) ? msg.message.content : [])
        .filter(c => c.type === 'tool_result').map(c => ({ type: 'tool.result', id: c.tool_use_id,
          output: resultText(c.content), isError: !!c.is_error }));
      if (msg.type === 'result') return [{ type: 'turn.end', status: msg.subtype === 'success' && !msg.is_error ? 'success' : 'error',
        message: msg.is_error ? (msg.result || (msg.errors || []).join('\n')) : undefined,
        label: msg.subtype, durationMs: msg.duration_ms, apiMs: msg.duration_api_ms, steps: msg.num_turns,
        cost: msg.total_cost_usd, modelUsage: msg.modelUsage, usage: msg.usage }];
      if (msg.type === 'system') {
        if (msg.subtype === 'init') return [{ type: 'session', sessionId: msg.session_id, model: msg.model,
          mode: msg.permissionMode, cwd: msg.cwd, terminalCommands: msg.terminal_slash_commands || [],
          info: { version: msg.claude_code_version, mcp: (msg.mcp_servers || []).map(x => ({ name: x.name, status: x.status })), outputStyle: msg.output_style } }];
        if (msg.subtype === 'status') return msg.permissionMode ? [{ type: 'mode', mode: msg.permissionMode }] : [];
        if (msg.subtype === 'commands_changed') return [{ type: 'commands', commands: msg.commands || [] }];
        if (msg.subtype === 'local_command_output') return [{ type: 'local.output', text: msg.content }];
        if (msg.subtype === 'compact_boundary') return [{ type: 'notice', kind: 'info', message: 'Conversation compacted' }];
      }
      return unknown(raw);
    }
    return { normalize, reset };
  }
  A.register('claude', factory);
})(typeof globalThis !== 'undefined' ? globalThis : this);
