const test = require('node:test');
const assert = require('node:assert/strict');
const Events = require('../agent-events.js');
require('../agent-pi.js');

const wrap = event => ({ type: 'native', agent: 'pi', event, t: 10 });
const run = (normalizer, state, event) => {
  const emitted = normalizer.normalize(wrap(event));
  emitted.forEach(e => Events.reduce(state, e));
  return emitted;
};
const types = emitted => emitted.map(e => e.type);

test('a documented streaming turn reduces to text, a tool call and one page turn', () => {
  const n = Events.createNormalizer('pi');
  const s = Events.createState();
  assert.equal(run(n, s, { type: 'session', version: 3, id: 'sess-1', cwd: '/tmp' })[0].sessionId, 'sess-1');
  const start = run(n, s, { type: 'agent_start' });
  assert.deepEqual(types(start), ['turn.start']);
  assert.equal(start[0].turnId, 'turn-1');
  run(n, s, { type: 'turn_start' });
  run(n, s, { type: 'message_start', message: { role: 'assistant', id: 'm1', content: [] } });
  assert.deepEqual(types(run(n, s, { type: 'message_update', assistantMessageEvent: { type: 'text_start', contentIndex: 0 } })), ['content.start']);
  run(n, s, { type: 'message_update', assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta: 'Hel' } });
  run(n, s, { type: 'message_update', assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta: 'lo' } });
  run(n, s, { type: 'message_update', assistantMessageEvent: { type: 'text_end', contentIndex: 0, content: 'Hello' } });
  run(n, s, { type: 'message_update', assistantMessageEvent: { type: 'toolcall_start', contentIndex: 1, id: 'call_1', toolName: 'bash' } });
  run(n, s, { type: 'message_update', assistantMessageEvent: { type: 'toolcall_end', contentIndex: 1, toolCall: { id: 'call_1', name: 'bash', arguments: { command: 'ls' } } } });
  run(n, s, { type: 'message_end', message: { role: 'assistant', id: 'm1', content: [{ type: 'text', text: 'Hello' }, { type: 'toolCall', id: 'call_1', name: 'bash', arguments: { command: 'ls' } }] } });
  run(n, s, { type: 'tool_execution_start', toolCallId: 'call_1', toolName: 'bash', args: { command: 'ls' } });
  run(n, s, { type: 'tool_execution_update', toolCallId: 'call_1', partialResult: { content: [{ type: 'text', text: 'README.md\n' }] } });
  run(n, s, { type: 'tool_execution_end', toolCallId: 'call_1', toolName: 'bash', result: { content: [{ type: 'text', text: 'README.md\n' }] }, isError: false });
  run(n, s, { type: 'turn_end', message: { usage: { input: 10, output: 2 } }, toolResults: [{ toolCallId: 'call_1', toolName: 'bash', content: [{ type: 'text', text: 'README.md\n' }] }] });
  const end = run(n, s, { type: 'agent_end', messages: [] });
  assert.deepEqual(types(end), ['turn.end']);
  assert.equal(end[0].status, 'success');
  assert.equal(end[0].usage.input, 10);
  assert.equal(end[0].cwd, undefined);
  assert.equal(s.sessionId, 'sess-1');
  assert.equal(s.busy, false);
  assert.equal([...s.blocks.values()][0].text, 'Hello');
  const tool = [...s.tools.values()][0];
  assert.equal(tool.name, 'bash');
  assert.deepEqual(tool.input, { command: 'ls' });
  assert.equal(tool.output, 'README.md\n');
  assert.equal(tool.state, 'done');
  assert.equal(end[0].raw.event.type, 'agent_end');
  assert.equal(end[0].agent, 'pi');
  assert.equal(end[0].v, 1);
});

test('tool output comes from the end event only, and one call opens one row', () => {
  const n = Events.createNormalizer('pi');
  const s = Events.createState();
  run(n, s, { type: 'agent_start' });
  const events = [
    ...run(n, s, { type: 'message_update', assistantMessageEvent: { type: 'toolcall_start', contentIndex: 0, partial: { content: [{ type: 'toolCall', id: 'c', name: 'bash' }] } } }),
    ...run(n, s, { type: 'message_update', assistantMessageEvent: { type: 'toolcall_end', contentIndex: 0, toolCall: { id: 'c', name: 'bash', arguments: { command: 'sleep' } } } }),
    ...run(n, s, { type: 'message_end', message: { role: 'assistant', id: 'm', content: [{ type: 'toolCall', id: 'c', name: 'bash', arguments: { command: 'sleep' } }] } }),
    ...run(n, s, { type: 'tool_execution_start', toolCallId: 'c', toolName: 'bash', args: { command: 'sleep' } }),
    ...run(n, s, { type: 'tool_execution_update', toolCallId: 'c', partialResult: { content: [{ type: 'text', text: 'one\n' }] } }),
    ...run(n, s, { type: 'tool_execution_end', toolCallId: 'c', result: { content: [{ type: 'text', text: 'one\ntwo\n' }] } }),
  ];
  assert.equal(events.filter(e => e.type === 'tool.start').length, 1);
  assert.equal(events.filter(e => e.type === 'tool.output.delta').length, 0);
  assert.deepEqual([...s.tools.keys()], ['pi:c']);
  assert.equal(s.tools.get('pi:c').output, 'one\ntwo\n');
});

test('streamed and final text share one block even when content indexes differ', () => {
  const n = Events.createNormalizer('pi');
  const s = Events.createState();
  run(n, s, { type: 'agent_start' });
  run(n, s, { type: 'message_start', message: { role: 'assistant', id: 'm' } });
  run(n, s, { type: 'message_update', assistantMessageEvent: { type: 'text_start', contentIndex: 1 } });
  run(n, s, { type: 'message_update', assistantMessageEvent: { type: 'text_delta', contentIndex: 1, delta: 'Hi' } });
  run(n, s, { type: 'message_update', assistantMessageEvent: { type: 'text_end', contentIndex: 1, content: 'Hi' } });
  run(n, s, { type: 'message_end', message: { role: 'assistant', id: 'm', content: [{ type: 'text', text: 'Hi' }] } });
  assert.equal(s.blocks.size, 1);
});

test('an assistant run that will retry does not end the page turn', () => {
  const n = Events.createNormalizer('pi');
  const s = Events.createState();
  run(n, s, { type: 'agent_start' });
  const retry = run(n, s, { type: 'agent_end', willRetry: true, errorMessage: 'overloaded' });
  assert.equal(retry[0].type, 'notice');
  assert.equal(s.busy, true);
  assert.deepEqual(run(n, s, { type: 'agent_settled' }).map(e => e.type), ['turn.end']);
  assert.deepEqual(run(n, s, { type: 'agent_settled' }), []);   // settled only once
  assert.equal(s.busy, false);
});

test('thinking blocks and a later turn stay separate and ordered', () => {
  const n = Events.createNormalizer('pi');
  const s = Events.createState();
  run(n, s, { type: 'agent_start' });
  run(n, s, { type: 'message_start', message: { role: 'assistant', id: 'm1', content: [] } });
  run(n, s, { type: 'message_update', assistantMessageEvent: { type: 'thinking_start', contentIndex: 0 } });
  run(n, s, { type: 'message_update', assistantMessageEvent: { type: 'thinking_delta', contentIndex: 0, delta: 'hmm' } });
  run(n, s, { type: 'message_update', assistantMessageEvent: { type: 'thinking_end', contentIndex: 0, content: 'hmm' } });
  run(n, s, { type: 'message_end', message: { role: 'assistant', id: 'm1', content: [{ type: 'thinking', thinking: 'hmm' }, { type: 'text', text: 'Done' }] } });
  const blocks = [...s.blocks.values()];
  assert.deepEqual(blocks.map(b => b.kind), ['thinking', 'text']);
  assert.deepEqual(blocks.map(b => b.text), ['hmm', 'Done']);
  assert.equal(blocks.every(b => b.final), true);
});

test('bash, queue, compaction and retry events land as their own page surfaces', () => {
  const n = Events.createNormalizer('pi');
  const s = Events.createState();
  run(n, s, { type: 'agent_start' });
  assert.deepEqual(types(run(n, s, { type: 'bash_execution_update', id: 'req-1', delta: 'total 48\n' })), ['local.output']);
  assert.equal(run(n, s, { type: 'queue_update', steering: ['Focus'], followUp: [] })[0].kind, 'info');
  assert.deepEqual(run(n, s, { type: 'queue_update', steering: [], followUp: [] }), []);
  assert.equal(run(n, s, { type: 'compaction_start', reason: 'threshold' })[0].message, 'Compacting the conversation…');
  assert.match(run(n, s, { type: 'compaction_end', reason: 'threshold', aborted: false, result: { estimatedTokensAfter: 32000 } })[0].message, /~32000 tokens/);
  assert.equal(run(n, s, { type: 'compaction_end', reason: 'overflow', aborted: false, errorMessage: 'quota' })[0].kind, 'error');
  const retry = run(n, s, { type: 'auto_retry_start', attempt: 1, maxAttempts: 3, delayMs: 2000, errorMessage: '529' });
  assert.deepEqual([retry[0].type, retry[0].attempt, retry[0].maxRetries], ['retry', 1, 3]);
  assert.equal(run(n, s, { type: 'extension_error', event: 'tool_call', error: 'boom' })[0].kind, 'error');
});

test('unknown pi events stay inspectable and reset drops the previous run\'s tool bookkeeping', () => {
  const n = Events.createNormalizer('pi');
  const s = Events.createState();
  const unknown = run(n, s, { type: 'something_new', detail: 1 });
  assert.equal(unknown[0].type, 'unknown');
  assert.equal(unknown[0].name, 'something_new');
  run(n, s, { type: 'agent_start' });
  run(n, s, { type: 'tool_execution_start', toolCallId: 'call_1', toolName: 'bash', args: { command: 'ls' } });
  n.reset();
  // A reused call id must not inherit the previous run's name, and the previous run cannot end the new turn.
  assert.deepEqual(run(n, s, { type: 'agent_settled' }), []);
  const end = run(n, s, { type: 'tool_execution_end', toolCallId: 'call_1', result: { content: [{ type: 'text', text: 'ok' }] } });
  assert.equal(end[0].name, 'Tool');
});
