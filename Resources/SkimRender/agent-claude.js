/* Claude SDK -> FloatyTerm event contract. One instance per conversation. */
(function (root) {
  'use strict';
  const A = root.AgentEvents || require('./agent-events.js');
  function factory() {
    let current = null, serial = 0;
    let stopSeen = false;   // "[Request interrupted by user]" came before the result: the user stopped this turn
    const blocks = new Map();
    const messageBlocks = new Map(), confirmations = new Map();
    const stringify = value => typeof value === 'string' ? value : JSON.stringify(value == null ? '' : value);
    const resultText = value => typeof value === 'string' ? value : Array.isArray(value)
      ? value.map(c => c.text || stringify(c)).join('\n') : stringify(value);
    const notice = (kind, message) => message ? [{ type: 'notice', kind, message: String(message) }] : [];
    const identity = (messageId, index, kind, redacted = false) => ({ id: messageId + ':' + index, messageId, kind, redacted });
    const unknown = raw => [{ type: 'unknown', name: raw.msg?.event?.type || raw.msg?.subtype || raw.msg?.type || raw.type }];
    function remember(block) {
      if (!messageBlocks.has(block.messageId)) messageBlocks.set(block.messageId, []);
      messageBlocks.get(block.messageId).push(block);
      return block;
    }
    function reset() { current = null; serial = 0; stopSeen = false; blocks.clear(); messageBlocks.clear(); confirmations.clear(); }
    const STOP_TEXT = /^\[Request interrupted by user/;
    // Claude Code's own trace lines in a result's errors ("[ede_diagnostic] result_type=user …"): for logs, not for people.
    const DIAGNOSTIC = /^\[[a-z_]+_diagnostic\]/;
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
          if (msg.parent_tool_use_id && ['text', 'thinking', 'redacted_thinking'].includes(c.type)) {
            // A subagent's words: its own transcript (a panel), never this conversation's blocks.
            // Envelopes of one message each hold one block at index 0, so the envelope's uuid keys it.
            out.push({ type: 'content.snapshot', id: 'sub:' + (msg.uuid || messageId) + ':' + index, messageId, kind: c.type === 'text' ? 'text' : 'thinking',
              redacted: c.type === 'redacted_thinking', text: c.text || c.thinking || '', final: true, parentId: msg.parent_tool_use_id });
          } else if (['text', 'thinking', 'redacted_thinking'].includes(c.type)) {
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
      if (msg.type === 'user') {
        const content = msg.message?.content;
        const texts = typeof content === 'string' ? [content] : Array.isArray(content) ? content.filter(c => c.type === 'text').map(c => c.text || '') : [];
        if (!msg.parent_tool_use_id && texts.some(t => STOP_TEXT.test(t))) stopSeen = true;
      }
      if (msg.type === 'user') return (Array.isArray(msg.message?.content) ? msg.message.content : [])
        .filter(c => c.type === 'tool_result').map(c => ({ type: 'tool.result', id: c.tool_use_id,
          output: resultText(c.content), isError: !!c.is_error, parentId: msg.parent_tool_use_id || null }));
      if (msg.type === 'result') {
        // A stop is not an error: Claude Code reports it as error_during_execution, with an "aborted_…" terminal reason.
        const stopped = /^aborted/.test(msg.terminal_reason || '') || (stopSeen && msg.subtype === 'error_during_execution');
        stopSeen = false;
        const errors = (msg.errors || []).filter(x => !DIAGNOSTIC.test(String(x)));
        const status = stopped ? 'interrupted' : msg.subtype === 'success' && !msg.is_error ? 'success' : 'error';
        return [{ type: 'turn.end', status,
          message: status === 'error' ? (msg.result || errors.join('\n')) || undefined : undefined,
        label: msg.subtype, durationMs: msg.duration_ms, apiMs: msg.duration_api_ms, steps: msg.num_turns,
        cost: msg.total_cost_usd, modelUsage: msg.modelUsage, usage: msg.usage }];
      }
      if (msg.type === 'system') {
        if (msg.subtype === 'init') return [{ type: 'session', sessionId: msg.session_id, model: msg.model,
          mode: msg.permissionMode, cwd: msg.cwd, terminalCommands: msg.terminal_slash_commands || [],
          info: { version: msg.claude_code_version, mcp: (msg.mcp_servers || []).map(x => ({ name: x.name, status: x.status })), outputStyle: msg.output_style } }];
        if (msg.subtype === 'status') return msg.permissionMode ? [{ type: 'mode', mode: msg.permissionMode }] : [];
        if (msg.subtype === 'commands_changed') return [{ type: 'commands', commands: msg.commands || [] }];
        if (msg.subtype === 'local_command_output') return [{ type: 'local.output', text: msg.content }];
        if (msg.subtype === 'compact_boundary') return [{ type: 'notice', kind: 'info', message: 'Conversation compacted' }];
        if (msg.subtype === 'api_retry') return [{ type: 'retry', attempt: msg.attempt, maxRetries: msg.max_retries,
          delayMs: msg.retry_delay_ms, errorStatus: msg.error_status ?? null }];
        if (msg.subtype === 'hook_started' || msg.subtype === 'hook_progress') return [];
        if (msg.subtype === 'hook_response') return [{ type: 'hook', name: msg.hook_name, event: msg.hook_event, outcome: msg.outcome,
          exitCode: msg.exit_code ?? null, output: String(msg.stderr || msg.stdout || msg.output || '').trim() }];
        if (msg.subtype === 'permission_denied') return notice('warn', 'Blocked ' + (msg.tool_name || 'a tool') + (msg.message ? ': ' + msg.message : ''));
        if (msg.subtype === 'notification') return notice(['high', 'immediate'].includes(msg.priority) ? 'warn' : 'info', msg.text);
        if (msg.subtype === 'informational') return notice(msg.level === 'warning' ? 'warn' : 'info', msg.content);
        if (msg.subtype === 'model_refusal_fallback') return notice('info', msg.content ||
          `${msg.original_model || 'The model'} declined; retried with ${msg.fallback_model || 'another model'}`);
        if (msg.subtype === 'model_refusal_no_fallback') return notice('warn', msg.content || `${msg.original_model || 'The model'} declined to answer`);
        // Subagents and background commands: bookends and progress, joined to their tool row by tool_use_id.
        if (msg.subtype === 'task_started') return [{ type: 'task.start', taskId: msg.task_id, toolId: msg.tool_use_id || null,
          description: msg.description || '', taskType: msg.task_type || null, subagentType: msg.subagent_type || null,
          background: !!msg.is_backgrounded, ambient: !!(msg.ambient || msg.skip_transcript) }];
        if (msg.subtype === 'task_progress') return [{ type: 'task.progress', taskId: msg.task_id, toolId: msg.tool_use_id || null,
          description: msg.description || '', summary: msg.summary || '', lastTool: msg.last_tool_name || null, usage: msg.usage || null }];
        if (msg.subtype === 'task_updated') return [{ type: 'task.update', taskId: msg.task_id, patch: msg.patch || {} }];
        if (msg.subtype === 'task_notification') return [{ type: 'task.end', taskId: msg.task_id, toolId: msg.tool_use_id || null,
          status: msg.status, summary: msg.summary || '', usage: msg.usage || null, outputFile: msg.output_file || null,
          ambient: !!(msg.ambient || msg.skip_transcript) }];
        if (msg.subtype === 'background_tasks_changed') return [{ type: 'tasks.background',
          tasks: (msg.tasks || []).filter(t => !t.ambient).map(t => ({ id: t.task_id, taskType: t.task_type, description: t.description || '' })) }];
        // A running estimate while thinking arrives without text (display "omitted").
        if (msg.subtype === 'thinking_tokens') return [{ type: 'thinking.tokens', tokens: msg.estimated_tokens || 0 }];
        if (msg.subtype === 'memory_recall') {
          const n = (msg.memories || []).length;
          return n ? notice('info', msg.mode === 'synthesize' ? 'Recalled from memory' : `Recalled ${n} ${n === 1 ? 'memory' : 'memories'}`) : [];
        }
        if (msg.subtype === 'mirror_error') return notice('warn', 'Transcript not saved: ' + (msg.error || 'unknown error'));
        if (msg.subtype === 'worker_shutting_down') return notice('info', 'Session shutting down' + (msg.reason ? ' (' + msg.reason.replace(/_/g, ' ') + ')' : ''));
        if (msg.subtype === 'plugin_install') return msg.status === 'failed' ? notice('warn', `Plugin ${msg.name || ''} failed to install` + (msg.error ? ': ' + msg.error : '')) : [];
        // What the TUI shows as a banner or a line: a notice here.
        if (msg.subtype === 'api_error') return notice('error', msg.formatted || msg.message || (msg.error && msg.error.message) || 'API error');
        if (msg.subtype === 'agents_killed') return notice('info', msg.content || 'Background agents stopped');
        if (msg.subtype === 'away_summary') return notice('info', msg.content);
        if (msg.subtype === 'memory_saved') {
          const n = (msg.written_paths || []).length;
          return notice('info', msg.content || `${msg.verb || 'Saved'} ${n} ${n === 1 ? 'memory' : 'memories'}`);
        }
        if (msg.subtype === 'model_fallback' || msg.subtype === 'model_consent_fallback') return notice('info', msg.content ||
          `Switched from ${msg.original_model_name || msg.original_model || 'the model'} to ${msg.fallback_model || 'another model'}`);
        if (msg.subtype === 'permission_retry') return notice('info', msg.content || 'Retrying with the new permissions');
        if (msg.subtype === 'scheduled_task_fire') return notice('info', msg.content || 'A scheduled task started');
        if (msg.subtype === 'stop_hook_summary') return (msg.hook_errors || []).length || msg.prevented_continuation
          ? notice('warn', 'Stop hook' + ((msg.hook_errors || []).length ? ': ' + msg.hook_errors.join(' · ') : ' kept the turn going')) : [];
        if (msg.subtype === 'code_change_published') return notice('info', `Change ${msg.action || 'published'}` + (msg.url ? ': ' + msg.url : ''));
        if (msg.subtype === 'feedback_draft_queued') return notice('info', 'Feedback draft saved' + (msg.title ? ': ' + msg.title : ''));
        // Signals for the page: the repository changed (re-read git); a live phrase for the status line.
        if (msg.subtype === 'vcs_state_changed') return [{ type: 'vcs', kind: msg.kind || null, branch: msg.branch || null }];
        if (msg.subtype === 'task_summary') return [{ type: 'progress.summary', text: msg.detail || null }];
        // Signals this page does not draw: the turn state (turn.end covers it), heartbeats, housekeeping, cloud-session frames.
        if (['session_state_changed', 'files_persisted', 'elicitation_complete', 'control_request_progress', 'turn_duration', 'post_turn_summary',
          'file_snapshot', 'per_turn_effort_changed', 'cloud_session_delta', 'session_metadata', 'turn_handoff_available', 'upgrade_relay_marker',
          'dev_intent', 'peer_message_hold', 'turn_preempted'].includes(msg.subtype)) return [];
      }
      if (msg.type === 'conversation_reset') return notice('info', msg.trigger === 'plan_mode_exit' ? 'Context cleared for the plan' : 'New conversation');
      if (msg.type === 'auth_status') return msg.error ? notice('error', 'Sign-in: ' + msg.error) : [];
      // The fate of a prompt sent with an ID: queued, started, then completed, cancelled, discarded or refused.
      if (msg.type === 'command_lifecycle') return msg.command_uuid ? [{ type: 'prompt.state', id: msg.command_uuid, state: msg.state }] : [];
      if (msg.type === 'session_notice') return notice('info', (msg.notice_class === 'peer_notice' ? 'From another session: ' : '') + (msg.content || ''));
      if (['tool_progress', 'tool_use_summary', 'prompt_suggestion', 'active_goal', 'keep_alive', 'transcript_mirror', 'autocompact_state'].includes(msg.type)) return [];
      if (msg.type === 'rate_limit_event') {
        const i = msg.rate_limit_info || {};
        return [{ type: 'limit', status: i.status, resetsAt: i.resetsAt, limitType: i.rateLimitType, utilization: i.utilization }];
      }
      return unknown(raw);
    }
    return { normalize, reset };
  }
  A.register('claude', factory);
})(typeof globalThis !== 'undefined' ? globalThis : this);
