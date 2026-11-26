import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import path from 'node:path';

const require = createRequire(import.meta.url);
const Events = require('../../SkimRender/agent-events.js');
require('../../SkimRender/agent-pi.js');

const here = path.dirname(fileURLToPath(import.meta.url));
const sidecar = path.join(here, '..', 'sidecar.mjs');
const fakePi = path.join(here, 'fake-pi.mjs');

/** Starts the bridge against the fake pi and collects its canonical lines. */
function boot({ cwd = here } = {}) {
  const proc = spawn(process.execPath, [sidecar], { cwd, stdio: ['pipe', 'pipe', 'pipe'] });
  const lines = [];
  let buffer = '';
  const waiters = [];
  proc.stdout.on('data', chunk => {
    buffer += chunk;
    let index;
    while ((index = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, index);
      buffer = buffer.slice(index + 1);
      if (!line) continue;
      const record = JSON.parse(line);
      lines.push(record);
      for (const wake of [...waiters]) if (wake.predicate(record)) { waiters.splice(waiters.indexOf(wake), 1); wake.resolve(record); }
    }
  });
  proc.stderr.on('data', chunk => process.stderr.write('[bridge] ' + chunk));
  const send = message => proc.stdin.write(JSON.stringify(message) + '\n');
  const waitFor = (predicate, timeoutMs = 5000) => {
    const found = lines.find(predicate);
    if (found) return Promise.resolve(found);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('timed out waiting for the bridge; saw ' + lines.map(r => r.type).join(', '))), timeoutMs);
      waiters.push({ predicate, resolve: value => { clearTimeout(timer); resolve(value); } });
    });
  };
  const start = (extra = {}) => { send({ type: 'start', cwd, piPath: fakePi, ...extra }); return waitFor(r => r.type === 'capabilities'); };
  return { proc, lines, send, waitFor, start, stop: () => proc.kill('SIGKILL') };
}

test('the bridge announces pi as an agent with models, levels and commands', async () => {
  const bridge = boot();
  try {
    const capabilities = await bridge.start();
    assert.equal(capabilities.v, 1);
    assert.equal(capabilities.agent, 'pi');
    assert.equal(capabilities.models.length, 2);
    assert.deepEqual(capabilities.models.map(m => m.value), ['fake/model-a', 'fake/model-b']);
    assert.deepEqual(capabilities.models[0].supportedEffortLevels, ['off', 'low', 'medium', 'high']);
    assert.equal(capabilities.models[0].supportsEffort, true);
    assert.deepEqual(capabilities.commands.map(c => c.name).slice(0, 2), ['demo', 'model']);
    // The renderer answers for pi's own surfaces; the bridge must not claim what pi lacks.
    assert.equal(capabilities.features.approvals, undefined);
    assert.equal(capabilities.features.midTurnInput, true);
    const session = await bridge.waitFor(r => r.type === 'session');
    assert.equal(session.sessionId, 'fake-session-1');
    assert.equal(session.model, 'fake/model-a');
    assert.equal(session.cwd, here);
    const usage = await bridge.waitFor(r => r.type === 'usage');
    assert.equal(usage.context.totalTokens, 160);
    assert.equal(usage.context.maxTokens, 1000);
    assert.equal(usage.modelUsage['fake/model-a'].inputTokens, 120);
    assert.equal(usage.modelUsage['fake/model-a'].costUSD, 0.012);
    assert.equal((await bridge.waitFor(r => r.type === 'title')).title, 'Fake work');
    assert.equal((await bridge.waitFor(r => r.type === 'effort')).effort, 'medium');
  } finally { bridge.stop(); }
});

test('a prompt streams pi events through untouched and ends one page turn', async () => {
  const bridge = boot();
  try {
    await bridge.start();
    bridge.send({ type: 'send', text: 'hello' });
    await bridge.waitFor(r => r.type === 'native' && r.event.type === 'agent_settled', 8000);
    // The bridge must not draw: it hands pi's shapes to the renderer adapter, which
    // turns this exact stream into the canonical events the page already draws.
    assert.ok(!bridge.lines.some(r => r.type === 'content.delta'));
    assert.ok(bridge.lines.some(r => r.type === 'native' && r.event.assistantMessageEvent?.type === 'text_delta'));
    // Relayed events are raw, so the page's normalizer runs: a versioned envelope
    // would be passed straight through and drawn as "Unrecognized event: native".
    const relayed = bridge.lines.filter(r => r.type === 'native');
    assert.ok(relayed.length > 0 && relayed.every(r => r.v === undefined), relayed[0]);
    assert.ok(bridge.lines.some(r => r.type === 'capabilities' && r.v === 1));
    const normalizer = Events.createNormalizer('pi');
    const state = Events.createState();
    const canonical = [];
    for (const record of relayed) {
      for (const event of normalizer.normalize({ type: 'native', agent: 'pi', event: record.event })) {
        canonical.push(event);
        Events.reduce(state, event);
      }
    }
    const end = canonical.find(e => e.type === 'turn.end');
    assert.equal(end.status, 'success');
    assert.equal(end.usage.input, 120);
    assert.equal(end.cost, 0.012);
    assert.deepEqual([...state.blocks.values()].map(b => b.text), ['why', 'Hello']);
    assert.equal([...state.tools.values()][0].output, 'a.txt\n');
    assert.equal(state.busy, false);
  } finally { bridge.stop(); }
});

test('models, effort and naming round-trip through pi commands', async () => {
  const bridge = boot();
  try {
    await bridge.start();
    bridge.send({ type: 'setModel', model: 'fake/model-b' });
    await bridge.waitFor(r => r.type === 'model' && r.model === 'fake/model-b');
    bridge.send({ type: 'setEffort', effort: 'low' });
    await bridge.waitFor(r => r.type === 'effort' && r.effort === 'low');
    bridge.send({ type: 'rename', title: 'Renamed' });
    assert.equal((await bridge.waitFor(r => r.type === 'title' && r.title === 'Renamed')).custom, true);
    // A model switch refreshes the thinking levels it now supports.
    const refreshed = bridge.lines.filter(r => r.type === 'capabilities');
    assert.equal(refreshed.length, 2);
  } finally { bridge.stop(); }
});

test('a bad thinking level is reported, never silently accepted', async () => {
  const bridge = boot();
  try {
    await bridge.start();
    bridge.send({ type: 'setEffort', effort: 'nope' });
    const notice = await bridge.waitFor(r => r.type === 'notice' && r.kind === 'error');
    assert.match(notice.message, /thinking level/);
  } finally { bridge.stop(); }
});

test('a direct shell command draws as a shell card, not as conversation text', async () => {
  const bridge = boot();
  try {
    await bridge.start();
    bridge.send({ type: 'shell', id: 'ui-1', command: 'ls' });
    const done = await bridge.waitFor(r => r.type === 'shell' && r.done);
    assert.equal(done.code, 0);
    const chunks = bridge.lines.filter(r => r.type === 'shell' && r.chunk).map(r => r.chunk);
    assert.deepEqual(chunks, ['total 0\n', 'ok\n']);
    assert.ok(!bridge.lines.some(r => r.type === 'native' && r.event.type === 'bash_execution_update'));
  } finally { bridge.stop(); }
});

test('unsupported controls answer with a notice instead of failing the session', async () => {
  const bridge = boot();
  try {
    await bridge.start();
    bridge.send({ type: 'setPermissionMode', mode: 'read-only' });
    assert.match((await bridge.waitFor(r => r.type === 'notice' && /permission modes/.test(r.message))).message, /permission modes/);
    bridge.send({ type: 'nonsense' });
    assert.match((await bridge.waitFor(r => r.type === 'notice' && /Unsupported pi control/.test(r.message))).message, /nonsense/);
  } finally { bridge.stop(); }
});

test('extension dialogs become approval cards and their answers go back to pi', async () => {
  const bridge = boot();
  try {
    await bridge.start();
    bridge.send({ type: 'send', text: 'dialog' });
    const card = await bridge.waitFor(r => r.type === 'approval.request');
    assert.equal(card.request.id, 'ui-7');
    assert.equal(card.request.toolName, 'Allow dangerous command?');
    assert.deepEqual(card.request.input.availableDecisions, ['Allow', 'Block']);
    assert.equal(card.request.timeout, 10000);
    // The card's answer comes back as a permission control and is translated for pi.
    bridge.send({ type: 'permission', id: 'ui-7', decision: 'allow', response: { decision: 'Allow' } });
    const echoed = await bridge.waitFor(r => r.type === 'native' && r.event.type === 'message_end');
    assert.equal(echoed.event.message.content[0].text, 'dialog answer: Allow');
    // A second control for the same dialog is stale, not a second answer.
    bridge.send({ type: 'permission', id: 'ui-7', decision: 'deny' });
    assert.match((await bridge.waitFor(r => r.type === 'notice' && /no longer waiting/.test(r.message))).message, /no longer waiting/);
  } finally { bridge.stop(); }
});
