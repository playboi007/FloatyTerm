/* pi adapter. pi streams JsonAgentSessionEvent records (--mode json, --mode rpc). */
(function (root) {
  'use strict';
  const AgentEvents = root.AgentEvents || (typeof require === 'function' ? require('./agent-events.js') : null);
  if (!AgentEvents) throw new Error('Load agent-events.js before agent-pi.js');

  AgentEvents.register('pi', () => {
    let turnSequence = 0;
    let turnId = null;
    let sessionId = null;
    let ended = true;
    let messageId = null;
    let usage = null;
    let sessionCost = 0;        // the page shows one running cost for the conversation; usage is per run
    const counted = new Set();  // assistant message ids already folded into `usage`
    const calls = new Map();      // toolCallId -> { name, input }
    const results = new Set();    // toolCallIds that already ended
    const started = new Set();    // toolCallIds whose row was already opened
    // Streaming indexes content by position in the partial message, the final message by its
    // own array. Blocks are keyed by kind and ordinal so both name the same block.
    const slots = new Map();      // contentIndex -> block id, for the message in flight
    const ordinals = {};          // kind -> blocks opened so far in the message in flight

    const id = value => encodeURIComponent(String(value ?? 'unknown'));
    const toolId = value => 'pi:' + id(value);
    const messageKey = value => 'pi:' + id(value);
    const blockId = (mid, index, kind) => messageKey(mid) + ':' + index + ':' + kind;
    const turn = () => ({ threadId: sessionId, turnId });
    const call = callId => calls.get(callId) || { name: 'Tool', input: {} };
    const slot = (a, kind) => {
      if (!slots.has(a.contentIndex)) slots.set(a.contentIndex, blockId(messageId, ordinals[kind] = (ordinals[kind] ?? -1) + 1, kind));
      return slots.get(a.contentIndex);
    };
    const newMessage = () => { slots.clear(); for (const k of Object.keys(ordinals)) delete ordinals[k]; };
    // pi puts the call id on the finished toolCall, or on the partial message's block; never on the event itself.
    const callIdOf = a => a.toolCall?.id ?? a.id ?? a.partial?.content?.[a.contentIndex]?.id;
    /** The first sight of a call opens its row; later sights only refine its input. */
    const openCall = (callId, entry) => {
      calls.set(callId, entry);
      const first = !started.has(callId);
      started.add(callId);
      return [{ type: first ? 'tool.start' : 'tool.input', id: toolId(callId), name: entry.name, input: entry.input }];
    };

    // pi tool output is an array of content blocks; everything folds down to text.
    const text = value => {
      if (value == null) return '';
      if (typeof value === 'string') return value;
      if (Array.isArray(value)) return value.map(text).filter(Boolean).join('\n');
      if (typeof value === 'object') {
        if (typeof value.text === 'string') return value.text;
        if (typeof value.content !== 'undefined') return text(value.content);
        try { return JSON.stringify(value, null, 2); } catch { return String(value); }
      }
      return String(value);
    };

    /** Ends the page turn once; usage rides along for the footer and the token gauge. */
    function endTurn(status, e) {
      ended = true;
      return [{ type: 'turn.end', status, ...turn(), usage, cost: sessionCost || undefined, ...(e?.errorMessage ? { message: e.errorMessage } : {}) }];
    }
    const num = value => typeof value === 'number' && Number.isFinite(value) ? value : 0;
    function addUsage(u, key) {
      if (!u || (key != null && counted.has(key))) return;
      if (key != null) counted.add(key);
      usage ||= { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { total: 0 } };
      for (const field of ['input', 'output', 'cacheRead', 'cacheWrite', 'totalTokens']) usage[field] += num(u[field]);
      usage.cost.total += num(u.cost?.total);
      sessionCost += num(u.cost?.total);
    }

    return {
      reset() {
        turnSequence = 0; turnId = null; sessionId = null; ended = true; messageId = null; usage = null; sessionCost = 0;
        counted.clear(); calls.clear(); results.clear(); started.clear(); newMessage();
      },

      normalize(raw) {
        if (raw.type !== 'native' || !raw.event || typeof raw.event !== 'object') return [{ type: 'unknown', name: raw.type || 'invalid' }];
        const e = raw.event;
        switch (e.type) {
          case 'session':
            sessionId = e.id || e.sessionId || sessionId;
            return [{ type: 'session', sessionId, cwd: e.cwd, info: { provider: 'pi', version: e.version != null ? String(e.version) : null } }];

          // One pi agent run is one page turn: an assistant response plus its tool loop.
          case 'agent_start':
            turnSequence += 1;
            turnId = 'turn-' + turnSequence;
            ended = false;
            usage = null;
            return [{ type: 'turn.start', ...turn() }];
          case 'turn_start':
            if (ended) { turnSequence += 1; turnId = 'turn-' + turnSequence; ended = false; }
            return [{ type: 'turn.start', ...turn() }];

          case 'message_start': {
            const m = e.message;
            if (m && m.role === 'assistant') { newMessage(); if (m.id != null) messageId = m.id; }
            return [];
          }

          case 'message_update': {
            const a = e.assistantMessageEvent;
            if (!a || typeof a !== 'object') return [{ type: 'unknown', name: 'message_update' }];
            const kind = a.type.startsWith('thinking') ? 'thinking' : 'text';
            if (a.type === 'text_start' || a.type === 'thinking_start') {
              return [{ type: 'content.start', id: slot(a, kind), messageId: messageKey(messageId), kind }];
            }
            if (a.type === 'text_delta' || a.type === 'thinking_delta') {
              return [{ type: 'content.delta', id: slot(a, kind), messageId: messageKey(messageId), kind, text: a.delta || '' }];
            }
            if (a.type === 'text_end' || a.type === 'thinking_end') {
              return [{ type: 'content.end', id: slot(a, kind), messageId: messageKey(messageId), kind, text: text(a.content ?? a.text), final: true }];
            }
            if (a.type === 'toolcall_start') {
              const callId = callIdOf(a);
              return callId == null ? [] : openCall(callId, { name: a.toolName || a.partial?.content?.[a.contentIndex]?.name || 'Tool', input: {} });
            }
            if (a.type === 'toolcall_delta') return [];   // arguments arrive whole in toolcall_end
            if (a.type === 'toolcall_end') {
              const callId = callIdOf(a);
              if (callId == null) return [];
              const final = a.toolCall || {};
              return openCall(callId, { name: final.name || call(callId).name, input: final.arguments ?? {} });
            }
            return [{ type: 'unknown', name: 'message_update:' + a.type }];
          }

          // The authoritative final message: declare every block, so a dropped delta can't lose text.
          case 'message_end': {
            const m = e.message;
            if (!m || m.role !== 'assistant') return [];
            const out = [];
            const seen = {};
            (Array.isArray(m.content) ? m.content : []).forEach(part => {
              if (part?.type === 'text' || part?.type === 'thinking') {
                const ordinal = seen[part.type] = (seen[part.type] ?? -1) + 1;
                out.push({ type: 'content.snapshot', id: blockId(m.id, ordinal, part.type), messageId: messageKey(m.id), kind: part.type, text: text(part.text ?? part.thinking), final: true });
              } else if (part?.type === 'toolCall') {
                out.push(...openCall(part.id, { name: part.name || 'Tool', input: part.arguments ?? {} }));
              }
            });
            messageId = null;
            newMessage();
            addUsage(m?.usage, m?.id);
            return out;
          }

          case 'tool_execution_start': {
            const previous = call(e.toolCallId);
            results.delete(e.toolCallId);
            return openCall(e.toolCallId, { name: e.toolName || previous.name, input: e.args ?? previous.input });
          }
          // The end event carries the whole result and is its only authority; partial output would show twice.
          case 'tool_execution_update':
            return [];
          case 'tool_execution_end': {
            results.add(e.toolCallId);
            return [{ type: 'tool.result', id: toolId(e.toolCallId), name: call(e.toolCallId).name, output: text(e.result?.content ?? e.result), isError: !!e.isError }];
          }

          case 'turn_end': {
            addUsage(e.message?.usage, e.message?.id);
            // Reconcile tool results the run recorded but never streamed an end for.
            const out = [];
            for (const result of Array.isArray(e.toolResults) ? e.toolResults : []) {
              if (!result?.toolCallId || results.has(result.toolCallId)) continue;
              results.add(result.toolCallId);
              out.push({ type: 'tool.result', id: toolId(result.toolCallId), name: result.toolName || call(result.toolCallId).name, output: text(result.content), isError: !!result.isError });
            }
            return out;
          }

          // pi's turn_end is per LLM call; the page turn ends when the whole run settles.
          case 'agent_end':
            if (e.willRetry) return [{ type: 'notice', kind: 'warn', message: e.errorMessage || 'Retrying…', terminal: false }];
            return ended ? [] : endTurn('success', e);
          case 'agent_settled':
            return ended ? [] : endTurn('success', e);

          case 'error':
            return [{ type: 'notice', kind: 'error', message: e.message || e.error?.message || 'pi error', terminal: false }];
          case 'extension_error':
            return [{ type: 'notice', kind: 'error', message: e.error || 'An extension threw an error.', terminal: false }];

          case 'bash_execution_update':
            return [{ type: 'local.output', content: e.delta || '' }];

          case 'queue_update': {
            const queued = [...(e.steering || []), ...(e.followUp || [])];
            return queued.length ? [{ type: 'notice', kind: 'info', message: 'Queued: ' + queued.join(' · '), terminal: false }] : [];
          }

          case 'auto_retry_start':
            return [{ type: 'retry', attempt: e.attempt, maxRetries: e.maxAttempts, delayMs: e.delayMs, errorStatus: e.errorMessage }];
          case 'auto_retry_end':
            return e.success ? [] : [{ type: 'notice', kind: 'error', message: e.finalError || 'Retries exhausted.', terminal: false }];
          case 'summarization_retry_scheduled':
            return [{ type: 'notice', kind: 'warn', message: `Retrying summarization (attempt ${e.attempt || 1})…`, terminal: false }];

          case 'compaction_start':
            return [{ type: 'notice', kind: 'info', message: 'Compacting the conversation…', terminal: false }];
          case 'compaction_end': {
            if (e.aborted) return [{ type: 'notice', kind: 'warn', message: 'Compaction was cancelled.', terminal: false }];
            if (e.errorMessage) return [{ type: 'notice', kind: 'error', message: e.errorMessage, terminal: false }];
            const tokens = e.result?.estimatedTokensAfter;
            return [{ type: 'notice', kind: 'info', message: 'Conversation compacted' + (tokens ? ` · ~${tokens} tokens` : '') + '.', terminal: false }];
          }

          // Retry bookkeeping and status-only traffic that has no place in the transcript.
          case 'summarization_retry_attempt_start': case 'summarization_retry_finished':
            return [];

          default:
            return [{ type: 'unknown', name: e.type || 'unnamed' }];
        }
      }
    };
  });
})(typeof globalThis !== 'undefined' ? globalThis : this);
