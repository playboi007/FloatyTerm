const test = require('node:test');
const assert = require('node:assert/strict');
const Events = require('../agent-events.js');
require('../agent-codex.js');

const wrap = (event, turnId = 'turn-a', t = 10) => ({ type: 'native', agent: 'codex', event, turnId, t });
const run = (normalizer, state, event, turnId) => {
  const emitted = normalizer.normalize(wrap(event, turnId));
  emitted.forEach(e => Events.reduce(state, e));
  return emitted;
};

test('officially documented thread, turn, command and message event shapes reduce', () => {
  const n = Events.createNormalizer('codex');
  const s = Events.createState();
  assert.equal(run(n, s, { type: 'thread.started', thread_id: 'thread-1' })[0].sessionId, 'thread-1');
  run(n, s, { type: 'turn.started' });
  run(n, s, { type: 'item.started', item: { id: 'item_1', type: 'command_execution', command: 'bash -lc ls', status: 'in_progress' } });
  run(n, s, { type: 'item.completed', item: { id: 'item_1', type: 'command_execution', command: 'bash -lc ls', aggregated_output: 'README.md\n', exit_code: 0 } });
  run(n, s, { type: 'item.completed', item: { id: 'item_3', type: 'agent_message', text: 'Repo contains docs.' } });
  const end = run(n, s, { type: 'turn.completed', usage: { input_tokens: 24, output_tokens: 5 } });
  assert.equal(s.sessionId, 'thread-1');
  assert.equal(s.status, 'success');
  assert.equal(s.busy, false);
  assert.equal([...s.tools.values()][0].input.command, 'bash -lc ls');
  assert.equal([...s.tools.values()][0].output, 'README.md\n');
  assert.equal([...s.blocks.values()][0].text, 'Repo contains docs.');
  assert.deepEqual(end[0].usage, { input_tokens: 24, output_tokens: 5 });
  assert.equal(end[0].raw.event.type, 'turn.completed');
  assert.equal(end[0].v, 1);
  assert.equal(end[0].agent, 'codex');
});

test('item updates replace snapshots and completed item reconciliation is idempotent', () => {
  const n = Events.createNormalizer('codex');
  const s = Events.createState();
  run(n, s, { type: 'turn.started' });
  const item = text => ({ type: 'agent_message', id: 'item_0', text });
  run(n, s, { type: 'item.started', item: item('Hel') });
  const update = run(n, s, { type: 'item.updated', item: item('Hello') });
  assert.equal(update[0].type, 'content.snapshot');
  assert.equal([...s.blocks.values()][0].text, 'Hello');
  const final = run(n, s, { type: 'item.completed', item: item('Hello') });
  assert.deepEqual(final.map(e => e.type), ['content.end']);
  assert.deepEqual(run(n, s, { type: 'item.completed', item: item('Hello') }), []);
  assert.equal([...s.blocks.values()][0].text, 'Hello');
});

test('reused native IDs remain separate across exec turns and reset', () => {
  const n = Events.createNormalizer('codex');
  const s = Events.createState();
  run(n, s, { type: 'turn.started' }, 'exec-a');
  run(n, s, { type: 'item.completed', item: { type: 'agent_message', id: 'item_0', text: 'First' } }, 'exec-a');
  run(n, s, { type: 'turn.completed' }, 'exec-a');
  run(n, s, { type: 'turn.started' }, 'exec-b');
  run(n, s, { type: 'item.completed', item: { type: 'agent_message', id: 'item_0', text: 'Second' } }, 'exec-b');
  assert.deepEqual([...s.blocks.values()].map(x => x.text), ['First', 'Second']);
  n.reset();
  const first = run(n, Events.createState(), { type: 'item.completed', item: { type: 'agent_message', id: 'item_0', text: 'After reset' } }, 'exec-a');
  assert.equal(first[0].type, 'content.start');
});

test('reasoning renders exec summary text; tools retain actual available fields', () => {
  const n = Events.createNormalizer('codex');
  const s = Events.createState();
  run(n, s, { type: 'turn.started' });
  run(n, s, { type: 'item.completed', item: { type: 'reasoning', id: 'r1', text: 'Public reasoning summary' } });
  run(n, s, { type: 'item.completed', item: { type: 'reasoning', id: 'r2', summary: ['Checked files', 'Found result'] } });
  assert.deepEqual([...s.blocks.values()].map(x => x.text), ['Public reasoning summary', 'Checked files\nFound result']);
  const changes = [{ path: 'README.md', kind: 'update' }];
  run(n, s, { type: 'item.completed', item: { type: 'file_change', id: 'f1', changes, status: 'completed' } });
  const file = [...s.tools.values()][0];
  assert.deepEqual(file.input.changes, changes);
  assert.equal(file.input.content, undefined);
  run(n, s, { type: 'item.completed', item: { type: 'mcp_tool_call', id: 'm1', server: 'catalog', tool: 'find', arguments: { q: 'x' }, result: { found: true } } });
  run(n, s, { type: 'item.completed', item: { type: 'web_search', id: 'w1', query: 'x', results: [{ title: 'Result' }] } });
  run(n, s, { type: 'item.completed', item: { type: 'todo_list', id: 'p1', items: [{ text: 'Inspect', completed: true }] } });
  assert.equal(s.tools.size, 4);
  for (const entry of s.tools.values()) if (entry.output != null) assert.equal(typeof entry.output, 'string');
});

test('explicit turn IDs scope items even without a turn.started event', () => {
  const n = Events.createNormalizer('codex');
  const a = n.normalize(wrap({ type: 'item.completed', item: { type: 'agent_message', id: 'item_0', text: 'A' } }, 'exec-a'));
  const b = n.normalize(wrap({ type: 'item.completed', item: { type: 'agent_message', id: 'item_0', text: 'B' } }, 'exec-b'));
  assert.notEqual(a[0].id, b[0].id);
  assert.deepEqual(a.map(x => x.type), ['content.start', 'content.snapshot', 'content.end']);
  assert.deepEqual(b.map(x => x.type), ['content.start', 'content.snapshot', 'content.end']);
});

test('failed command status marks error without an exit code', () => {
  const n = Events.createNormalizer('codex');
  const result = n.normalize(wrap({ type: 'item.completed', item: { type: 'command_execution', id: 'item_2', command: 'false', status: 'failed', exit_code: null } }));
  assert.equal(result.find(x => x.type === 'tool.result').isError, true);
});

test('recoverable error stays active, failed turn ends; unknown native payload is inspectable', () => {
  const n = Events.createNormalizer('codex');
  const s = Events.createState();
  run(n, s, { type: 'turn.started' });
  const error = run(n, s, { type: 'error', message: 'Temporary retry' });
  assert.equal(error[0].terminal, false);
  assert.equal(s.busy, true);
  const unknown = run(n, s, { type: 'future.event', payload: { x: 1 } });
  assert.equal(unknown[0].name, 'future.event');
  assert.deepEqual(unknown[0].raw.event.payload, { x: 1 });
  run(n, s, { type: 'turn.failed', error: { message: 'Exhausted retries' } });
  assert.equal(s.status, 'error');
  assert.equal(s.busy, false);
});

test('separate normalizers do not share item identity or completion state', () => {
  const a = Events.createNormalizer('codex');
  const b = Events.createNormalizer('codex');
  const first = { type: 'item.completed', item: { type: 'agent_message', id: 'item_0', text: 'One' } };
  run(a, Events.createState(), { type: 'turn.started' });
  run(b, Events.createState(), { type: 'turn.started' });
  assert.equal(a.normalize(wrap(first))[0].type, 'content.start');
  assert.equal(b.normalize(wrap(first))[0].type, 'content.start');
});
