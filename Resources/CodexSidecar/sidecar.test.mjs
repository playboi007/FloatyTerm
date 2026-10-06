import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

const sidecar = fileURLToPath(new URL('./sidecar.mjs', import.meta.url));

const fakeAppServer = `#!/usr/bin/env node
const fs = require('node:fs');
const readline = require('node:readline');
const logPath = process.env.FAKE_LOG;
if (process.env.FAKE_PID_FILE) fs.writeFileSync(process.env.FAKE_PID_FILE, String(process.pid));
const log = value => fs.appendFileSync(logPath, JSON.stringify(value) + '\\n');
const write = value => process.stdout.write(JSON.stringify(value) + '\\n');
const models = [
  { id: 'catalog-luna', model: 'gpt-6-luna', displayName: 'GPT-6 Luna', description: 'Fast model', hidden: false,
    supportedReasoningEfforts: [{ reasoningEffort: 'low', description: 'Low' }, { reasoningEffort: 'medium', description: 'Medium' }, { reasoningEffort: 'high', description: 'High' }],
    defaultReasoningEffort: 'medium', inputModalities: ['text'], supportsPersonality: false, multiAgentVersion: null,
    additionalSpeedTiers: [], serviceTiers: [], defaultServiceTier: null, availableAccessPrograms: null, isDefault: true },
  { id: 'catalog-sage', model: 'gpt-6-sage', displayName: 'GPT-6 Sage', description: 'Reasoning model', hidden: false,
    supportedReasoningEfforts: [{ reasoningEffort: 'medium', description: 'Medium' }, { reasoningEffort: 'xhigh', description: 'Extra high' }],
    defaultReasoningEffort: 'medium', inputModalities: ['text'], supportsPersonality: false, multiAgentVersion: null,
    additionalSpeedTiers: [], serviceTiers: [], defaultServiceTier: null, availableAccessPrograms: null, isDefault: false },
];
const quota = { limitId: 'codex', limitName: 'Codex', normalModelSlug: 'gpt-6-luna',
  primary: { usedPercent: 35, windowDurationMins: 300, resetsAt: 2000000000 },
  secondary: { usedPercent: 17, windowDurationMins: 10080, resetsAt: 2000000000 },
  credits: null, individualLimit: null, spendControlReached: null, planType: 'plus', rateLimitReachedType: null };
let threadNumber = 0;
let currentThread = 'thread-initial';
let turnNumber = 0;
let currentTurn = null;
let currentApproval = null;
let summary = '';
const thread = id => ({ id, sessionId: 'session-' + id, forkedFromId: null, parentThreadId: null, preview: 'fixture thread', ephemeral: false,
  section: null, sectionEnteredAt: null, projectId: null, historyMode: 'enabled', modelProvider: 'openai', model: 'gpt-6-luna',
  reasoningEffort: 'medium', createdAt: 1700000000, updatedAt: 1700000001, recencyAt: 1700000001, status: { type: 'idle' },
  path: null, cwd: process.cwd(), cliVersion: 'test', originator: 'codex app-server', source: { kind: 'appServer' },
  threadSource: null, agentNickname: null, agentRole: null, gitInfo: null, name: id, turns: [] });
const turn = (id, status = 'inProgress', items = []) => ({ id, items, itemsView: 'full', status, error: null,
  startedAt: 1700000002, completedAt: status === 'inProgress' ? null : 1700000003, durationMs: status === 'inProgress' ? null : 100 });
const respond = (request, result) => write({ jsonrpc: '2.0', id: request.id, result });
const notify = (method, params) => write({ jsonrpc: '2.0', method, params });
function userText(request) { return request.params?.input?.[0]?.text || ''; }
function doTurn(request) {
  currentTurn = 'turn-' + (++turnNumber);
  const text = userText(request);
  const started = turn(currentTurn);
  respond(request, { turn: started });
  notify('turn/started', { threadId: request.params.threadId, turn: started });
  notify('item/started', { threadId: request.params.threadId, turnId: currentTurn,
    item: { type: 'agentMessage', id: 'message-' + currentTurn, text: '' }, startedAtMs: Date.now() });
  if (text === 'spawn') {
    const call = status => ({ type: 'collabAgentToolCall', id: 'collab-1', tool: 'spawnAgent', status, senderThreadId: request.params.threadId,
      receiverThreadIds: ['child-1'], prompt: 'Review the diff', model: null, reasoningEffort: null,
      agentsStates: status === 'inProgress' ? { 'child-1': { status: 'running', message: null } } : { 'child-1': { status: 'completed', message: 'Looks fine' } } });
    notify('item/started', { threadId: request.params.threadId, turnId: currentTurn, item: call('inProgress'), startedAtMs: Date.now() });
    notify('item/completed', { threadId: request.params.threadId, turnId: currentTurn, item: call('completed'), completedAtMs: Date.now() });
  }
  if (text === 'reasoning') {
    notify('item/reasoning/textDelta', { threadId: request.params.threadId, turnId: currentTurn, itemId: 'reasoning-1', delta: 'PRIVATE_RAW_REASONING' });
    notify('item/reasoning/summaryTextDelta', { threadId: request.params.threadId, turnId: currentTurn, itemId: 'reasoning-1', summaryIndex: 0, delta: 'Public summary' });
  } else {
    summary = 'Answer for ' + text;
    notify('item/agentMessage/delta', { threadId: request.params.threadId, turnId: currentTurn, itemId: 'message-' + currentTurn, delta: summary });
  }
  const tokenUsage = {
    total: { totalTokens: 700, inputTokens: 500, cachedInputTokens: 20, cacheWriteInputTokens: 0, outputTokens: 200, reasoningOutputTokens: 80 },
    last: { totalTokens: 150, inputTokens: 100, cachedInputTokens: 10, cacheWriteInputTokens: 0, outputTokens: 50, reasoningOutputTokens: 40 },
    modelContextWindow: 1000,
  };
  notify('thread/tokenUsage/updated', { threadId: request.params.threadId, turnId: currentTurn, tokenUsage });
  if (text === 'approve') {
    currentApproval = { id: 71, method: 'item/commandExecution/requestApproval' };
    write({ jsonrpc: '2.0', id: currentApproval.id, method: currentApproval.method, params: {
      kind: 'command', threadId: request.params.threadId, turnId: currentTurn, itemId: 'shell-1', startedAtMs: Date.now(),
      environmentId: null, reason: 'Run the requested command', command: 'git status --short', cwd: process.cwd(), commandActions: [],
    } });
    return;
  }
  if (text === 'deny-note') {
    currentApproval = { id: 72, method: 'item/fileChange/requestApproval' };
    write({ jsonrpc: '2.0', id: currentApproval.id, method: currentApproval.method, params: {
      threadId: request.params.threadId, turnId: currentTurn, itemId: 'file-1', startedAtMs: Date.now(),
      reason: 'Write outside the workspace', grantRoot: '/tmp/fixture',
    } });
    return;
  }
  if (text === 'unsupported-request') {
    write({ jsonrpc: '2.0', id: 'unsupported-1', method: 'future/unsupportedRequest', params: { threadId: request.params.threadId, turnId: currentTurn } });
  }
  if (text === 'hang') return;
  if (text === 'diff') {
    notify('turn/diff/updated', { threadId: request.params.threadId, turnId: currentTurn, diff: 'first diff' });
    notify('turn/diff/updated', { threadId: request.params.threadId, turnId: currentTurn, diff: 'replacement diff' });
    notify('turn/diff/updated', { threadId: request.params.threadId, turnId: currentTurn, diff: '' });
  }
  finishTurn(request.params.threadId, text === 'fail' ? 'failed' : 'completed');
}
function finishTurn(threadId, status) {
  const messageItem = { type: 'agentMessage', id: 'message-' + currentTurn, text: summary };
  notify('item/completed', { threadId, turnId: currentTurn, item: messageItem, completedAtMs: Date.now() });
  notify('turn/completed', { threadId, turn: turn(currentTurn, status, [messageItem]) });
  currentApproval = null;
}
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', line => {
  let request;
  try { request = JSON.parse(line); } catch { return; }
  log(request);
  if (!request.method) {
    if (request.id === 71 || request.id === 72) {
      if (currentApproval && String(request.id) === String(currentApproval.id)) {
        const approval = currentApproval; currentApproval = null;
        respond(request, {});
        const decision = request.result?.decision;
        if (decision === 'accept' || decision === 'decline') finishTurn(currentThread, 'completed');
        else finishTurn(currentThread, 'failed');
      }
    }
    return;
  }
  if (!Object.hasOwn(request, 'id')) return; // initialize notification
  if (process.env.FAKE_EXIT_ON_METHOD === request.method) process.exit(17);
  switch (request.method) {
    case 'initialize': respond(request, { serverInfo: { name: 'codex', version: 'test' }, capabilities: {} }); return;
    case 'model/list': respond(request, { data: models, nextCursor: null }); return;
    case 'config/read': respond(request, { config: { model: null, model_reasoning_effort: null, model_reasoning_summary: 'auto' }, origins: {}, layers: null }); return;
    case 'account/rateLimits/read': respond(request, { ordinaryUsageAllowed: null, rateLimits: quota, rateLimitsByLimitId: { codex: quota }, rateLimitResetCredits: null, accountId: 'test-account', rateLimitUpsell: null }); return;
    case 'thread/start':
      threadNumber++;
      currentThread = 'thread-' + threadNumber;
      respond(request, { thread: thread(currentThread), model: request.params.model || 'gpt-6-luna', modelProvider: 'openai', serviceTier: null,
        disabledPluginIds: [], cwd: process.cwd(), instructionSources: [], approvalPolicy: request.params.approvalPolicy || 'on-request',
        approvalsReviewer: 'user', sandbox: { type: request.params.sandbox || 'workspace-write' }, reasoningEffort: 'medium' });
      if (process.env.FAKE_CRASH_AFTER_START === '1') setTimeout(() => process.exit(23), 25);
      if (process.env.FAKE_OVERSIZED_AFTER_START === '1') setTimeout(() => process.stdout.write('x'.repeat(1100000) + '\\n'), 25);
      return;
    case 'thread/resume': currentThread = request.params.threadId; respond(request, { thread: thread(currentThread), model: 'gpt-6-luna', modelProvider: 'openai', serviceTier: null,
      disabledPluginIds: [], cwd: process.cwd(), instructionSources: [], approvalPolicy: 'on-request', approvalsReviewer: 'user',
      sandbox: { type: 'workspaceWrite', writableRoots: [], networkAccess: false, excludeTmpdirEnvVar: false, excludeSlashTmp: false }, reasoningEffort: 'medium' }); return;
    case 'thread/fork': currentThread = 'fork-' + (++threadNumber); respond(request, { thread: thread(currentThread), model: request.params.model || 'gpt-6-luna', modelProvider: 'openai', serviceTier: null,
      disabledPluginIds: [], cwd: process.cwd(), instructionSources: [], approvalPolicy: 'on-request', approvalsReviewer: 'user',
      sandbox: { type: 'workspaceWrite', writableRoots: [], networkAccess: false, excludeTmpdirEnvVar: false, excludeSlashTmp: false }, reasoningEffort: 'medium' }); return;
    case 'turn/start': doTurn(request); return;
    case 'turn/interrupt': respond(request, {}); if (currentTurn) finishTurn(request.params.threadId, 'interrupted'); return;
    case 'thread/list': respond(request, { data: [thread('thread-listed')], nextCursor: null, backwardsCursor: 'thread-listed' }); return;
    case 'thread/turns/list': respond(request, { data: [
      { id: 'history-new', items: [
        { type: 'userMessage', id: 'u2', clientId: null, content: [{ type: 'text', text: 'newer prompt', text_elements: [] }] },
        { type: 'reasoning', id: 'r2', summary: ['Visible reasoning summary'], content: ['private text must not replay'] },
        { type: 'agentMessage', id: 'a2', text: 'newer answer', phase: 'final', memoryCitation: null, delivery: null, questions: null },
        { type: 'enteredReviewMode', id: 'review-1', review: 'review fixture' },
      ], itemsView: 'full', status: 'failed', error: { message: 'history failure' }, startedAt: 1700000100, completedAt: 1700000102, durationMs: 200 },
      { id: 'history-old', items: [
        { type: 'userMessage', id: 'u1', clientId: null, content: [{ type: 'text', text: 'older prompt', text_elements: [] }] },
        { type: 'commandExecution', id: 'c1', command: 'false', cwd: process.cwd(), processId: null, source: { type: 'exec' }, status: 'failed',
          commandActions: [], aggregatedOutput: 'command failed', exitCode: 1, durationMs: 2 },
        { type: 'agentMessage', id: 'a1', text: 'older answer', phase: 'final', memoryCitation: null, delivery: null, questions: null },
      ], itemsView: 'full', status: 'completed', error: null, startedAt: 1700000000, completedAt: 1700000002, durationMs: 200 },
    ], nextCursor: null, backwardsCursor: 'history-new' }); return;
    case 'thread/items/list': respond(request, { data: [], nextCursor: null, backwardsCursor: null }); return;
    case 'thread/compact/start': respond(request, {}); notify('thread/compacted', { threadId: request.params.threadId, turnId: 'compact-turn' }); return;
    case 'fuzzyFileSearch': respond(request, { files: [{ file_name: 'a.dart', path: 'lib/a.dart', root: process.cwd(), match_type: 'file', score: 5, indices: null }, { file_name: 'b.dart', path: 'lib/b.dart', root: process.cwd(), match_type: 'file', score: 9, indices: null }] }); return;
    case 'thread/name/set': respond(request, {}); return;
    case 'skills/list': respond(request, { data: [{ cwd: process.cwd(), errors: [], skills: [
      { name: 'imagegen', description: 'Make images', enabled: true, path: '/skills/imagegen/SKILL.md', scope: 'user', interface: { shortDescription: 'Generate images' } },
      { name: 'off', description: 'Disabled', enabled: false, path: '/skills/off/SKILL.md', scope: 'user' }] }] }); return;
    case 'app/list': respond(request, { data: [{ id: 'connector_1', name: 'Google Drive', description: 'Files', isEnabled: true, isAccessible: true }], nextCursor: null }); return;
    case 'plugin/installed': respond(request, { marketplaces: [{ name: 'official', plugins: [
      { id: 'github@official', name: 'github', installed: true, enabled: true, interface: { displayName: 'GitHub', shortDescription: 'Repos' } },
      { id: 'idle@official', name: 'idle', installed: true, enabled: false }] }] }); return;
    case 'mcpServerStatus/list': respond(request, { data: [{ name: 'docs', authStatus: 'oAuth', runtimeStatus: 'connected', tools: { search: {} }, resources: [], resourceTemplates: [] }], nextCursor: null }); return;
    default: respond(request, {}); return;
  }
});
`;

async function harness(run, env = {}) {
  const dir = await mkdtemp(join(tmpdir(), 'floaty-codex-appserver-'));
  const codex = join(dir, 'fake-codex');
  const log = join(dir, 'rpc.jsonl');
  const pidFile = join(dir, 'fake.pid');
  await writeFile(codex, fakeAppServer, { mode: 0o755 });
  const child = spawn(process.execPath, [sidecar], {
    env: { ...process.env, ...env, FAKE_LOG: log, FAKE_PID_FILE: pidFile }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  const lines = [];
  const stderr = [];
  createInterface({ input: child.stdout, crlfDelay: Infinity }).on('line', line => {
    try { lines.push(JSON.parse(line)); } catch { lines.push({ invalid: line }); }
  });
  createInterface({ input: child.stderr, crlfDelay: Infinity }).on('line', line => stderr.push(line));
  const send = value => child.stdin.write(JSON.stringify(value) + '\n');
  const until = async predicate => {
    for (let i = 0; i < 500; i++) {
      if (predicate(lines)) return;
      if (child.exitCode !== null) throw new Error(`sidecar exited ${child.exitCode}: ${stderr.join('\n')}\n${JSON.stringify(lines)}`);
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    throw new Error('Timed out: ' + JSON.stringify(lines));
  };
  const calls = async () => {
    try { return (await readFile(log, 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse); }
    catch { return []; }
  };
  try {
    send({ type: 'start', cwd: dir, codexPath: codex });
    await until(xs => xs.some(x => x.type === 'capabilities') && xs.some(x => x.type === 'session'));
    await run({ dir, log, pidFile, lines, send, until, calls, child });
  } finally {
    if (child.exitCode === null) {
      child.stdin.end();
      await Promise.race([new Promise(resolve => child.once('close', resolve)), new Promise(resolve => setTimeout(resolve, 2500))]);
      if (child.exitCode === null) child.kill('SIGKILL');
    }
    await rm(dir, { recursive: true, force: true });
  }
}

test('turn diff notifications preserve ownership, full replacements, empty clearing and provenance', async () => {
  await harness(async ({ lines, send, until }) => {
    send({ type: 'user', text: 'diff' });
    await until(xs => xs.some(event => event.type === 'turn.end'));
    const diffs = lines.filter(event => event.type === 'turn.diff.snapshot');
    assert.deepEqual(diffs.map(event => event.diff), ['first diff', 'replacement diff', '']);
    const start = lines.find(event => event.type === 'turn.start');
    for (const event of diffs) {
      assert.equal(event.threadId, start.sessionId);
      assert.equal(event.turnId, start.turnId);
      assert.equal(event.raw.method, 'turn/diff/updated');
    }
    assert.ok(!lines.some(event => event.type === 'unknown' && event.name === 'turn/diff/updated'));
  });
});

test('initializes persistent app-server, exposes model catalog by selectable slug, and starts safely', async () => {
  await harness(async ({ lines, calls }) => {
    const capabilityIndex = lines.findIndex(event => event.type === 'capabilities');
    const sessionIndex = lines.findIndex(event => event.type === 'session');
    assert.ok(capabilityIndex >= 0 && capabilityIndex < sessionIndex);
    const capabilities = lines[capabilityIndex];
    assert.equal(capabilities.agent, 'codex');
    assert.equal(capabilities.features.approvals, true);
    assert.equal(capabilities.features.history, true);
    assert.equal(capabilities.features.midTurnInput, false);
    assert.deepEqual(capabilities.permissionModes, ['default', 'plan']);
    const luna = capabilities.models.find(model => model.value === 'gpt-6-luna');
    assert.equal(luna.resolvedModel, 'gpt-6-luna');
    assert.equal(luna.supportsEffort, true);
    assert.deepEqual(luna.supportedEffortLevels, ['low', 'medium', 'high']);
    assert.equal(lines.find(event => event.type === 'session').sessionId, 'thread-1');
    assert.equal(lines.find(event => event.type === 'mode').mode, 'default');
    assert.ok(lines.some(event => event.type === 'usage' && event.plan?.limits?.length === 2));
    const requests = await calls();
    assert.ok(requests.some(request => request.method === 'initialize'));
    assert.ok(requests.some(request => request.method === 'model/list'));
    const threadStart = requests.find(request => request.method === 'thread/start');
    assert.equal(threadStart.params.approvalPolicy, 'on-request');
    assert.equal(threadStart.params.sandbox, 'workspace-write');
    assert.equal(Object.hasOwn(threadStart.params, 'model'), false);
  });
});

test('sends prompt with validated model slug, effort and complete read-only sandbox; reports usage and hides raw reasoning', async () => {
  await harness(async ({ lines, send, until, calls }) => {
    send({ type: 'setModel', model: 'gpt-6-sage' });
    send({ type: 'setEffort', effort: 'xhigh' });
    send({ type: 'setPermissionMode', mode: 'plan' });
    send({ type: 'user', text: 'reasoning' });
    await until(xs => xs.some(event => event.type === 'turn.end'));
    const turn = (await calls()).find(request => request.method === 'turn/start');
    assert.equal(turn.params.model, 'gpt-6-sage');
    assert.equal(turn.params.effort, 'xhigh');
    assert.deepEqual(turn.params.sandboxPolicy, { type: 'readOnly', networkAccess: false });
    assert.equal(turn.params.approvalPolicy, 'on-request');
    const usage = lines.filter(event => event.type === 'usage').at(-1);
    assert.equal(usage.tokens.totalTokens, 700);
    assert.equal(usage.context.totalTokens, 150);
    assert.equal(usage.context.maxTokens, 1000);
    assert.equal(usage.plan.available, true);
    assert.match(usage.plan.limits[0].label, /5h/i);
    assert.match(usage.plan.limits[1].label, /168h/i);
    assert.ok(lines.some(event => event.type === 'content.snapshot' && event.kind === 'thinking' && event.text === 'Public summary'));
    assert.equal(lines.some(event => JSON.stringify(event).includes('PRIVATE_RAW_REASONING')), false);
  });
});

test('workspace-write turn policy includes every required policy field', async () => {
  await harness(async ({ lines, send, until, calls }) => {
    send({ type: 'user', text: 'simple' });
    await until(xs => xs.some(event => event.type === 'turn.end'));
    const turn = (await calls()).find(request => request.method === 'turn/start');
    assert.deepEqual(turn.params.sandboxPolicy, {
      type: 'workspaceWrite', writableRoots: [], networkAccess: false,
      excludeTmpdirEnvVar: false, excludeSlashTmp: false,
    });
  });
});

test('command and file approval cards round-trip allow and deny exactly once', async () => {
  await harness(async ({ lines, send, until, calls }) => {
    send({ type: 'user', text: 'approve' });
    await until(xs => xs.some(event => event.type === 'approval.request'));
    const commandCard = lines.find(event => event.type === 'approval.request').request;
    assert.equal(commandCard.id, 'rpc:71');
    assert.equal(commandCard.toolName, 'Bash');
    assert.equal(commandCard.input.command, 'git status --short');
    assert.equal(commandCard.suppressAlwaysAllowRule, true);
    send({ type: 'permission', id: commandCard.id, decision: 'allow' });
    send({ type: 'permission', id: commandCard.id, decision: 'allow' });
    await until(xs => xs.some(event => event.type === 'turn.end'));
    let responses = (await calls()).filter(message => message.id === 71 && !message.method);
    assert.equal(responses.length, 1);
    assert.equal(responses[0].result.decision, 'accept');

    send({ type: 'user', text: 'deny-note' });
    await until(xs => xs.filter(event => event.type === 'approval.request').length === 2);
    const fileCard = lines.filter(event => event.type === 'approval.request')[1].request;
    assert.equal(fileCard.toolName, 'File changes');
    assert.equal(fileCard.input.grantRoot, '/tmp/fixture');
    send({ type: 'permission', id: fileCard.id, decision: 'deny', message: 'Not now' });
    await until(xs => xs.filter(event => event.type === 'turn.end').length === 2);
    responses = (await calls()).filter(message => message.id === 72 && !message.method);
    assert.equal(responses.length, 1);
    assert.equal(responses[0].result.decision, 'decline');
    assert.ok(lines.some(event => event.type === 'notice' && /approval feedback is not supported/i.test(event.message)));
  });
});

test('interrupt uses app-server and settles an in-progress turn once', async () => {
  await harness(async ({ lines, send, until, calls }) => {
    send({ type: 'user', text: 'hang' });
    await until(xs => xs.some(event => event.type === 'turn.start'));
    send({ type: 'interrupt' });
    await until(xs => xs.some(event => event.type === 'turn.end'));
    const requests = await calls();
    assert.ok(requests.some(request => request.method === 'turn/interrupt'));
    assert.equal(lines.filter(event => event.type === 'turn.end').length, 1);
    assert.equal(lines.find(event => event.type === 'turn.end').status, 'cancelled');
  });
});

test('unsupported app-server requests get an explicit JSON-RPC error and a visible notice', async () => {
  await harness(async ({ lines, send, until, calls }) => {
    send({ type: 'user', text: 'unsupported-request' });
    await until(xs => xs.some(event => event.type === 'notice' && /unsupported operation/i.test(event.message)));
    const response = (await calls()).find(message => message.id === 'unsupported-1' && !message.method);
    assert.equal(response.error.code, -32601);
    assert.match(response.error.message, /Unsupported operation/);
  });
});

test('session list, explicit canonical history replay, fork, new conversation, and compaction use app-server controls', async () => {
  await harness(async ({ lines, send, until, calls }) => {
    send({ type: 'sessions' });
    await until(xs => xs.some(event => event.type === 'sessions'));
    assert.equal(lines.find(event => event.type === 'sessions').list[0].id, 'thread-listed');
    const listRequest = (await calls()).find(request => request.method === 'thread/list');
    assert.deepEqual(listRequest.params.sourceKinds, ['cli', 'vscode', 'appServer', 'exec']);

    send({ type: 'history', sessionId: 'thread-history' });
    await until(xs => xs.some(event => event.type === 'history.replay'));
    const replay = lines.find(event => event.type === 'history.replay');
    assert.deepEqual(replay.turns.map(turn => turn.userText), ['older prompt', 'newer prompt']);
    for (const turn of replay.turns) {
      assert.ok(turn.events.every(event => event.v === 1 && event.agent === 'codex'));
      assert.equal(turn.events.at(-1).type, 'turn.end');
    }
    assert.equal(replay.turns[0].events.at(-1).status, 'success');
    assert.equal(replay.turns[1].events.at(-1).status, 'error');
    assert.ok(replay.turns[1].events.some(event => event.type === 'unknown' && event.name === 'history:enteredReviewMode'));
    const failedCommand = replay.turns[0].events.find(event => event.type === 'tool.result' && event.name === 'Bash');
    assert.equal(failedCommand.isError, true);
    assert.equal(JSON.stringify(replay).includes('private text must not replay'), false);

    send({ type: 'fork' });
    await until(xs => xs.some(event => event.type === 'session' && event.sessionId.startsWith('fork-')));
    send({ type: 'newConversation' });
    await until(xs => xs.filter(event => event.type === 'session').length >= 3);
    send({ type: 'compact' });
    await until(xs => xs.some(event => event.type === 'notice' && /compaction started/i.test(event.message)) ||
      xs.some(event => event.type === 'notice' && /context was compacted/i.test(event.message)));
    const requests = await calls();
    assert.ok(requests.some(request => request.method === 'thread/fork'));
    assert.ok(requests.filter(request => request.method === 'thread/start').length >= 2);
    assert.ok(requests.some(request => request.method === 'thread/compact/start'));
  });
});

test('app-server process failure produces one terminal error', async () => {
  await harness(async ({ lines }) => {
    // Harness fixture exits just after returning thread/start.
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal(lines.filter(event => event.terminal === true).length, 1);
    assert.match(lines.find(event => event.terminal === true).message, /app-server stopped/i);
  }, { FAKE_CRASH_AFTER_START: '1' });
});

test('app-server startup request failure settles once instead of leaving controls loading', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'floaty-codex-failed-start-'));
  const codex = join(dir, 'fake-codex');
  const log = join(dir, 'rpc.jsonl');
  await writeFile(codex, fakeAppServer, { mode: 0o755 });
  const child = spawn(process.execPath, [sidecar], {
    env: { ...process.env, FAKE_LOG: log, FAKE_EXIT_ON_METHOD: 'model/list' }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  const lines = [];
  createInterface({ input: child.stdout, crlfDelay: Infinity }).on('line', line => { try { lines.push(JSON.parse(line)); } catch {} });
  try {
    child.stdin.write(JSON.stringify({ type: 'start', cwd: dir, codexPath: codex }) + '\n');
    for (let i = 0; i < 300 && !lines.some(event => event.terminal === true); i++) await new Promise(resolve => setTimeout(resolve, 10));
    assert.equal(lines.filter(event => event.terminal === true).length, 1);
    assert.ok(lines.some(event => event.type === 'notice' && event.terminal === true));
  } finally {
    child.stdin.end();
    await Promise.race([new Promise(resolve => child.once('close', resolve)), new Promise(resolve => setTimeout(resolve, 2000))]);
    if (child.exitCode === null) child.kill('SIGKILL');
    await rm(dir, { recursive: true, force: true });
  }
});

test('oversized app-server output settles the session and kills the protocol child', async () => {
  await harness(async ({ lines, until, child, pidFile }) => {
    await until(xs => xs.some(event => event.terminal === true));
    assert.equal(lines.filter(event => event.terminal === true).length, 1);
    child.stdin.end();
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('sidecar did not stop after host input closed')), 1500);
      child.once('close', () => { clearTimeout(timer); resolve(); });
    });
    const pid = Number((await readFile(pidFile, 'utf8')).trim());
    assert.ok(Number.isInteger(pid) && pid > 0);
    assert.throws(() => process.kill(pid, 0), error => error.code === 'ESRCH');
  }, { FAKE_OVERSIZED_AFTER_START: '1' });
});

test('catalog lists enabled skills, apps, plugins and MCP servers; $mentions and images go out as structured input', async () => {
  await harness(async ({ lines, send, until, calls }) => {
    await until(xs => xs.some(event => event.type === 'catalog'));
    const catalog = lines.find(event => event.type === 'catalog');
    assert.deepEqual(catalog.skills.map(skill => skill.name), ['imagegen']);
    assert.equal(catalog.skills[0].description, 'Generate images');
    assert.deepEqual(catalog.apps.map(app => app.path), ['app://connector_1']);
    assert.deepEqual(catalog.plugins.map(plugin => plugin.name), ['GitHub']);
    assert.deepEqual(catalog.mcp.map(server => [server.name, server.status, server.tools]), [['docs', 'connected', ['search']]]);
    send({ type: 'user', text: 'make a logo $imagegen and read $google-drive then $github', images: [{ mediaType: 'image/png', data: 'AAAA' }, { mediaType: 'text/plain', data: 'x' }] });
    await until(xs => xs.some(event => event.type === 'turn.end'));
    const input = (await calls()).find(request => request.method === 'turn/start').params.input;
    assert.equal(input[0].type, 'image');
    assert.equal(input[0].url, 'data:image/png;base64,AAAA');
    assert.equal(input[1].type, 'text');
    assert.deepEqual(input.slice(2), [
      { type: 'skill', name: 'imagegen', path: '/skills/imagegen/SKILL.md' },
      { type: 'mention', name: 'Google Drive', path: 'app://connector_1' },
      { type: 'mention', name: 'GitHub', path: 'plugin://github@official' },
    ]);
  });
});

test('child agents become task.start and task.end events joined to the Agent tool row', async () => {
  await harness(async ({ lines, send, until }) => {
    send({ type: 'user', text: 'spawn' });
    await until(xs => xs.some(event => event.type === 'task.end'));
    const start = lines.find(event => event.type === 'task.start');
    const end = lines.find(event => event.type === 'task.end');
    assert.equal(start.taskId, 'child-1');
    assert.equal(start.description, 'Review the diff');
    assert.equal(start.toolId, end.toolId);
    assert.equal(end.status, 'completed');
    assert.equal(end.summary, 'Looks fine');
    assert.equal(lines.filter(event => event.type === 'task.start').length, 1);
  });
});

test('@file suggestions, /rename and ! shell commands use app-server search, thread names and the session folder', async () => {
  await harness(async ({ lines, send, until, calls }) => {
    send({ type: 'files', id: 7, query: 'dart' });
    await until(xs => xs.some(event => event.type === 'files'));
    const files = lines.find(event => event.type === 'files');
    assert.equal(files.id, 7);
    assert.deepEqual(files.suggestions.map(file => file.path), ['lib/b.dart', 'lib/a.dart']);
    send({ type: 'rename', title: 'Nice name' });
    await until(xs => xs.some(event => event.type === 'title' && event.title === 'Nice name'));
    assert.deepEqual((await calls()).find(request => request.method === 'thread/name/set').params.name, 'Nice name');
    send({ type: 'shell', id: 'sh1', command: 'echo hello' });
    await until(xs => xs.some(event => event.type === 'shell' && event.done));
    assert.ok(lines.some(event => event.type === 'shell' && event.stream === 'stdout' && /hello/.test(event.chunk)));
    assert.equal(lines.find(event => event.type === 'shell' && event.done).code, 0);
  });
});
