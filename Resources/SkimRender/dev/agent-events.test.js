const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const A = require('../agent-events.js');
require('../agent-claude.js');

const sdk = msg => ({ type: 'sdk', msg });
const stream = event => sdk({ type: 'stream_event', event });
function conversation() {
  const n = A.createNormalizer('claude'), state = A.createState();
  return { n, state, feed: raw => { const events = n.normalize(raw); events.forEach(e => A.reduce(state, e)); return events; } };
}
function fixture(name, key) {
  const context = { window: {} };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, name), 'utf8'), context);
  return JSON.parse(JSON.stringify(context.window[key]));
}

test('Claude stream and authoritative snapshot reconcile by block identity', () => {
  const c = conversation();
  c.feed(stream({ type: 'message_start', message: { id: 'm1' } }));
  c.feed(stream({ type: 'content_block_start', index: 0, content_block: { type: 'thinking' } }));
  c.feed(stream({ type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: 'Summary' } }));
  c.feed(stream({ type: 'content_block_start', index: 1, content_block: { type: 'text' } }));
  c.feed(stream({ type: 'content_block_delta', index: 1, delta: { type: 'text_delta', text: 'Hello' } }));
  const full = sdk({ type: 'assistant', message: { id: 'm1', content: [{ type: 'thinking', thinking: 'Summary' }, { type: 'text', text: 'Hello world' }] } });
  c.feed(full); c.feed(full);
  assert.equal(c.state.blocks.size, 2);
  assert.equal(c.state.blocks.get('m1:1').text, 'Hello world');
  assert.equal(c.state.blocks.get('m1:1').final, true);
});

test('recorded Claude session preserves final text, tool inputs/results, and failures', () => {
  const c = conversation(), events = fixture('session-sample.js', 'SESSION_SAMPLE');
  for (const e of events) c.feed(e);
  const expected = events.filter(e => e.msg?.type === 'assistant' && !e.msg.parent_tool_use_id)
    .flatMap(e => e.msg.message.content.filter(b => b.type === 'text').map(b => b.text));
  assert.deepEqual([...c.state.blocks.values()].filter(b => b.kind === 'text').map(b => b.text), expected);
  const thinking = events.filter(e => e.msg?.type === 'assistant' && !e.msg.parent_tool_use_id)
    .flatMap(e => e.msg.message.content.filter(b => b.type === 'thinking').map(b => b.thinking));
  assert.deepEqual([...c.state.blocks.values()].filter(b => b.kind === 'thinking').map(b => b.text), thinking);
  assert.ok(c.state.tools.size >= 3);
  assert.ok([...c.state.tools.values()].some(t => t.state === 'error'));
  assert.ok([...c.state.tools.values()].every(t => t.input !== undefined && t.output !== undefined));
  assert.equal(c.state.busy, false);
  assert.equal(c.state.approvals.size, 0);
});

test('single-block Claude assistant envelopes reconcile against native stream indices', () => {
  const c = conversation();
  c.feed(stream({ type: 'message_start', message: { id: 'm' } }));
  c.feed(stream({ type: 'content_block_start', index: 0, content_block: { type: 'thinking' } }));
  c.feed(stream({ type: 'content_block_start', index: 1, content_block: { type: 'text' } }));
  c.feed(sdk({ type: 'assistant', uuid: 'thinking-envelope', message: { id: 'm', content: [{ type: 'thinking', thinking: 'Thought summary' }] } }));
  const text = sdk({ type: 'assistant', uuid: 'text-envelope', message: { id: 'm', content: [{ type: 'text', text: 'Answer' }] } });
  c.feed(text); c.feed(text);
  assert.equal(c.state.blocks.size, 2);
  assert.equal(c.state.blocks.get('m:0').text, 'Thought summary');
  assert.equal(c.state.blocks.get('m:1').text, 'Answer');
});

test('tool JSON fragments and final input agree; subagent text does not leak', () => {
  const c = conversation();
  c.feed(stream({ type: 'message_start', message: { id: 'm' } }));
  c.feed(stream({ type: 'content_block_start', index: 0, content_block: { type: 'tool_use', id: 't', name: 'Bash' } }));
  for (const part of ['{"command":', '"ls"}']) c.feed(stream({ type: 'content_block_delta', index: 0, delta: { type: 'input_json_delta', partial_json: part } }));
  c.feed(stream({ type: 'content_block_stop', index: 0 }));
  assert.deepEqual(c.state.tools.get('t').input, { command: 'ls' });
  c.feed(sdk({ type: 'assistant', parent_tool_use_id: 'parent', message: { id: 'sub', content: [{ type: 'text', text: 'private subagent chatter' }, { type: 'tool_use', id: 'subtool', name: 'Read', input: {} }] } }));
  assert.equal(c.state.blocks.size, 0);
  assert.equal(c.state.tools.get('subtool').parentId, 'parent');
});

test('isolated normalizers do not mix interleaved conversations', () => {
  const a = conversation(), b = conversation();
  for (const [c, id] of [[a, 'a'], [b, 'b']]) {
    c.feed(stream({ type: 'message_start', message: { id } }));
    c.feed(stream({ type: 'content_block_start', index: 0, content_block: { type: 'text' } }));
  }
  a.feed(stream({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'A' } }));
  b.feed(stream({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'B' } }));
  assert.equal(a.state.blocks.get('a:0').text, 'A');
  assert.equal(b.state.blocks.get('b:0').text, 'B');
});

test('terminal failures settle open blocks/tools/approvals; unknown payload retained', () => {
  const c = conversation();
  c.feed(sdk({ type: 'assistant', message: { id: 'm', content: [{ type: 'tool_use', id: 't', name: 'Read', input: {} }] } }));
  c.feed({ type: 'permission_request', id: 'approval', toolUseID: 't' });
  c.feed({ type: 'host', kind: 'error', message: 'Runner exited' });
  assert.equal(c.state.busy, false);
  assert.equal(c.state.tools.get('t').state, 'interrupted');
  assert.equal(c.state.approvals.size, 0);
  const raw = sdk({ type: 'future.event', payload: '<script>unsafe()</script>' });
  const [unknown] = c.feed(raw);
  assert.equal(unknown.type, 'unknown'); assert.equal(unknown.raw, raw);
  assert.throws(() => c.n.normalize({ v: 999, type: 'turn.start' }), /version/);
});
