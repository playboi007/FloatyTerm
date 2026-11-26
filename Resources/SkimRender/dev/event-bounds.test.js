const test = require('node:test');
const assert = require('node:assert/strict');
const A = require('../agent-events.js');

const at = (type, fields) => ({ v: 1, agent: 'codex', t: 0, type, ...fields });
const feed = (state, ...events) => { for (const e of events) A.reduce(state, e); return state; };

test('a final tool output is capped like the streamed-delta window', () => {
  const state = feed(A.createState(), at('tool.start', { id: 't', name: 'Bash' }));
  const big = 'A'.repeat(400 * 1024);
  feed(state, at('tool.result', { id: 't', output: big, isError: false }));
  const output = state.tools.get('t').output;
  assert.ok(output.length < big.length);
  assert.match(output, /more characters\)/);
  // The tail is what a long command's reader wants, as with tool.output.delta.
  assert.ok(output.endsWith('A'.repeat(1024)));
  assert.ok(output.length <= 256 * 1024 + 64);
});

test('streamed deltas and final results share one output budget', () => {
  const state = feed(A.createState(), at('tool.start', { id: 't', name: 'Bash' }));
  for (let i = 0; i < 40; i++) feed(state, at('tool.output.delta', { id: 't', text: 'x'.repeat(16 * 1024) }));
  assert.ok(state.tools.get('t').output.length <= 256 * 1024);
  assert.equal(state.tools.get('t').capped, true);
  feed(state, at('tool.result', { id: 't', output: 'y'.repeat(300 * 1024), isError: false }));
  assert.ok(state.tools.get('t').output.length <= 256 * 1024 + 64);
});

test('turn.end drops the finished turn’s folded payloads, keeping session surfaces', () => {
  const state = A.createState();
  feed(state,
    at('turn.start', { threadId: 'th', turnId: 't1' }),
    at('surface.snapshot', { id: 'turn-surf', surface: 'mcp', placement: 'turn', threadId: 'th', turnId: 't1', data: { item: { status: 'completed' } } }),
    at('surface.snapshot', { id: 'sess-surf', surface: 'account', placement: 'session', threadId: 'th', turnId: 't1', data: { status: 'signedIn' } }),
    at('surface.snapshot', { id: 'other-turn', surface: 'mcp', placement: 'turn', threadId: 'th', turnId: 't2', data: {} }),
    at('turn.diff.snapshot', { threadId: 'th', turnId: 't1', diff: 'diff --git a/x b/x\n' }),
    at('plan.snapshot', { id: 'p', threadId: 'th', turnId: 't1', steps: [] }),
    at('media.snapshot', { id: 'm', threadId: 'th', turnId: 't1', url: 'blob:shot' }));
  assert.equal(state.surfaces.size, 3);
  assert.equal(state.media.size, 1);
  feed(state, at('turn.end', { threadId: 'th', turnId: 't1', status: 'success' }));
  assert.deepEqual([...state.surfaces.keys()].sort(), ['other-turn', 'sess-surf']);
  assert.equal(state.turnDiffs.size, 0);
  assert.equal(state.plans.size, 0);
  assert.equal(state.media.size, 0);
});

test('a turn.end without a turn identity prunes nothing', () => {
  const state = A.createState();
  feed(state, at('surface.snapshot', { id: 's', surface: 'mcp', placement: 'turn', threadId: 'th', turnId: 't1', data: {} }));
  feed(state, at('turn.end', { status: 'success' }));
  assert.equal(state.surfaces.size, 1);
});

test('surface data and media URLs are bounded and secrets are redacted', () => {
  const state = A.createState();
  feed(state,
    at('surface.snapshot', { id: 's', surface: 'account', placement: 'session', data: {
      token: 'do-not-retain', note: 'n'.repeat(40000), list: Array.from({ length: 1000 }, (_, i) => ({ i, blob: 'b'.repeat(100) })) } }),
    at('media.snapshot', { id: 'm', threadId: 'th', turnId: 't1', url: 'data:image/png;base64,' + 'A'.repeat(40000), caption: 'shot' }));
  const data = state.surfaces.get('s').data;
  assert.equal(data.token, '[not displayed]');
  assert.ok(data.note.length < 40000 && data.note.endsWith('[Details truncated]'));
  assert.equal(data.list.length, 100);
  assert.ok(state.media.get('m').url.length < 40000 && state.media.get('m').url.endsWith('[Details truncated]'));
});

test('a schema descriptor named like a secret survives the projection', () => {
  const state = A.createState();
  feed(state, at('surface.snapshot', { id: 's', surface: 'mcp', placement: 'turn', threadId: 'th', turnId: 't1', data: {
    inputSchema: { token: { type: 'string', description: 'auth token' }, password: 'hunter2' } } }));
  const schema = state.surfaces.get('s').data.inputSchema;
  assert.deepEqual(schema.token, { type: 'string', description: 'auth token' });
  assert.equal(schema.password, '[not displayed]');
});

test('empty and unidentified snapshots are ignored, not retained under a null key', () => {
  const state = A.createState();
  feed(state,
    at('plan.snapshot', { id: 'p', threadId: null, turnId: null, steps: [] }),
    at('turn.diff.snapshot', { threadId: 'th', turnId: null, diff: 'x' }));
  assert.equal(state.plans.size, 0);
  assert.equal(state.turnDiffs.size, 0);
});

test('finished tools and blocks are evicted oldest-first; running and open ones stay', () => {
  const state = A.createState();
  feed(state, at('tool.start', { id: 'running', name: 'Bash' }), at('content.delta', { id: 'open', messageId: 'm', kind: 'text', text: 'x' }));
  for (let i = 0; i < 1000; i++) {
    feed(state,
      at('tool.start', { id: 't' + i, name: 'Bash', input: { command: 'x' } }), at('tool.result', { id: 't' + i, output: 'ok' }),
      at('content.snapshot', { id: 'b' + i, messageId: 'm' + i, kind: 'text', text: 'hi', final: true }));
  }
  assert.ok(state.tools.size <= 200);
  assert.ok(state.blocks.size <= 400);
  assert.ok(state.tools.has('running') && state.tools.get('running').state === 'running');
  assert.ok(state.blocks.has('open') && !state.blocks.get('open').final);
  assert.ok(state.tools.has('t999') && state.blocks.has('b999'));   // the newest survive
  assert.ok(!state.tools.has('t0') && !state.blocks.has('b0'));
});
