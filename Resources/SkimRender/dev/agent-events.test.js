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
  const subEvents = c.feed(sdk({ type: 'assistant', uuid: 'u1', parent_tool_use_id: 'parent', message: { id: 'sub', content: [{ type: 'text', text: 'private subagent chatter' }, { type: 'tool_use', id: 'subtool', name: 'Read', input: {} }] } }));
  assert.equal(c.state.blocks.size, 0);
  assert.equal(c.state.tools.get('subtool').parentId, 'parent');
  // …but the subagent's text is there for its own transcript, marked with its Agent call
  assert.deepEqual(subEvents.filter(e => e.type === 'content.snapshot').map(e => [e.id, e.kind, e.text, e.parentId, e.final]),
    [['sub:u1:0', 'text', 'private subagent chatter', 'parent', true]]);
  const [subResult] = c.feed(sdk({ type: 'user', parent_tool_use_id: 'parent', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 'subtool', content: 'x' }] } }));
  assert.deepEqual([subResult.type, subResult.parentId], ['tool.result', 'parent']);
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

const sys = (subtype, fields) => sdk({ type: 'system', subtype, ...fields });

test('status messages map to canonical events, none is unknown', () => {
  const c = conversation();
  const [retry] = c.feed(sys('api_retry', { attempt: 2, max_retries: 10, retry_delay_ms: 5000, error_status: 529 }));
  assert.deepEqual({ ...retry, v: 0, agent: 0, t: 0, raw: 0 }, { type: 'retry', attempt: 2, maxRetries: 10, delayMs: 5000, errorStatus: 529, v: 0, agent: 0, t: 0, raw: 0 });
  assert.equal(c.feed(sys('api_retry', { attempt: 1, max_retries: 3, retry_delay_ms: 500, error_status: null }))[0].errorStatus, null);
  const [limit] = c.feed(sdk({ type: 'rate_limit_event', rate_limit_info: { status: 'allowed_warning', resetsAt: 1790625400, rateLimitType: 'five_hour', utilization: 0.85 } }));
  assert.equal(limit.type, 'limit');
  assert.deepEqual([limit.status, limit.resetsAt, limit.limitType, limit.utilization], ['allowed_warning', 1790625400, 'five_hour', 0.85]);
  const [hook] = c.feed(sys('hook_response', { hook_name: 'PreToolUse:Bash', hook_event: 'PreToolUse', output: 'out', stdout: 'so', stderr: '  blocked by policy \n', exit_code: 2, outcome: 'error' }));
  assert.deepEqual([hook.type, hook.name, hook.event, hook.outcome, hook.exitCode, hook.output], ['hook', 'PreToolUse:Bash', 'PreToolUse', 'error', 2, 'blocked by policy']);
  assert.equal(c.feed(sys('hook_response', { hook_name: 'h', hook_event: 'Stop', stdout: '', stderr: '', output: 'fallback', exit_code: 0, outcome: 'success' }))[0].output, 'fallback');
  assert.deepEqual(c.feed(sys('hook_started', { hook_name: 'PreToolUse:Bash', hook_event: 'PreToolUse' })), []);
  const notices = [
    [sys('permission_denied', { tool_name: 'Bash', message: 'rm is not allowed' }), 'warn', 'Blocked Bash: rm is not allowed'],
    [sys('notification', { text: 'Build finished', priority: 'low' }), 'info', 'Build finished'],
    [sys('notification', { text: 'Disk almost full', priority: 'high' }), 'warn', 'Disk almost full'],
    [sys('informational', { content: 'Heads up', level: 'warning' }), 'warn', 'Heads up'],
    [sys('informational', { content: 'FYI', level: 'info' }), 'info', 'FYI'],
    [sys('model_refusal_fallback', { content: 'Switched models for this request', original_model: 'a', fallback_model: 'b' }), 'info', 'Switched models for this request'],
    [sys('model_refusal_fallback', { original_model: 'opus', fallback_model: 'sonnet' }), 'info', 'opus declined; retried with sonnet']
  ];
  for (const [raw, kind, message] of notices) {
    const events = c.feed(raw);
    assert.equal(events.length, 1);
    assert.deepEqual([events[0].type, events[0].kind, events[0].message, !!events[0].terminal], ['notice', kind, message, false]);
  }
  assert.equal(c.state.unknown.length, 0);
  assert.equal(c.state.busy, false);
});

test('task, thinking-token and housekeeping messages map to events, none is unknown', () => {
  const c = conversation();
  const [start] = c.feed(sys('task_started', { task_id: 't1', tool_use_id: 'toolu_1', description: 'Explore the repo', task_type: 'local_agent', subagent_type: 'Explore', is_backgrounded: true }));
  assert.deepEqual([start.type, start.taskId, start.toolId, start.description, start.taskType, start.subagentType, start.background, start.ambient],
    ['task.start', 't1', 'toolu_1', 'Explore the repo', 'local_agent', 'Explore', true, false]);
  assert.equal(c.feed(sys('task_started', { task_id: 't2', description: 'watch', skip_transcript: true }))[0].ambient, true);
  const [prog] = c.feed(sys('task_progress', { task_id: 't1', tool_use_id: 'toolu_1', description: 'Explore', summary: 'Reading files', last_tool_name: 'Read', usage: { total_tokens: 1200, tool_uses: 4, duration_ms: 900 } }));
  assert.deepEqual([prog.type, prog.summary, prog.lastTool, prog.usage.tool_uses], ['task.progress', 'Reading files', 'Read', 4]);
  const [upd] = c.feed(sys('task_updated', { task_id: 't1', patch: { is_backgrounded: true, status: 'running' } }));
  assert.deepEqual([upd.type, upd.patch.is_backgrounded], ['task.update', true]);
  const [end] = c.feed(sys('task_notification', { task_id: 't1', tool_use_id: 'toolu_1', status: 'completed', output_file: '/tmp/o', summary: 'Found 3 files', usage: { total_tokens: 2000, tool_uses: 6, duration_ms: 3000 } }));
  assert.deepEqual([end.type, end.status, end.summary, end.outputFile], ['task.end', 'completed', 'Found 3 files', '/tmp/o']);
  const [bg] = c.feed(sys('background_tasks_changed', { tasks: [{ task_id: 't1', task_type: 'local_agent', description: 'a' }, { task_id: 't2', task_type: 'x', description: 'w', ambient: true }] }));
  assert.deepEqual([bg.type, bg.tasks.map(t => t.id)], ['tasks.background', ['t1']]);
  const [tok] = c.feed(sys('thinking_tokens', { estimated_tokens: 900, estimated_tokens_delta: 40 }));
  assert.deepEqual([tok.type, tok.tokens], ['thinking.tokens', 900]);
  for (const raw of [sys('session_state_changed', { state: 'idle' }), sys('files_persisted', { files: [], failed: [] }), sys('elicitation_complete', {}),
    sys('control_request_progress', { request_id: 'r', status: 'started' }), sys('plugin_install', { status: 'started' }), sys('memory_recall', { mode: 'select', memories: [] }),
    sdk({ type: 'tool_progress', tool_use_id: 'x', tool_name: 'Bash', parent_tool_use_id: null, elapsed_time_seconds: 3 }),
    sdk({ type: 'tool_use_summary', summary: 's', preceding_tool_use_ids: [] }), sdk({ type: 'prompt_suggestion', suggestion: 'next' }),
    sdk({ type: 'active_goal', value: null }), sdk({ type: 'auth_status', isAuthenticating: false, output: [] })]) assert.deepEqual(c.feed(raw), []);
  const notices = [
    [sys('memory_recall', { mode: 'select', memories: [{ path: '/m1', scope: 'personal' }, { path: '/m2', scope: 'personal' }] }), 'info', 'Recalled 2 memories'],
    [sys('model_refusal_no_fallback', { original_model: 'opus', content: '' }), 'warn', 'opus declined to answer'],
    [sys('mirror_error', { error: 'timeout', key: {} }), 'warn', 'Transcript not saved: timeout'],
    [sys('worker_shutting_down', { reason: 'host_exit' }), 'info', 'Session shutting down (host exit)'],
    [sys('plugin_install', { status: 'failed', name: 'x', error: 'boom' }), 'warn', 'Plugin x failed to install: boom'],
    [sdk({ type: 'conversation_reset', new_conversation_id: 'n', trigger: 'clear' }), 'info', 'New conversation'],
    [sdk({ type: 'auth_status', isAuthenticating: false, output: [], error: 'expired' }), 'error', 'Sign-in: expired']
  ];
  for (const [raw, kind, message] of notices) {
    const events = c.feed(raw);
    assert.deepEqual(events.map(e => [e.type, e.kind, e.message]), [['notice', kind, message]]);
  }
  assert.equal(c.state.unknown.length, 0);
});

test('a stop ends the turn as interrupted, with no diagnostic text', () => {
  const c = conversation();
  const diag = ['[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null'];
  // the shape Claude Code sends when the user stops a turn (verified live)
  c.feed(sdk({ type: 'user', parent_tool_use_id: null, message: { role: 'user', content: [{ type: 'text', text: '[Request interrupted by user]' }] } }));
  const [stop] = c.feed(sdk({ type: 'result', subtype: 'error_during_execution', is_error: true, terminal_reason: 'aborted_streaming', errors: diag, num_turns: 2, duration_ms: 1941 }));
  assert.deepEqual([stop.type, stop.status, stop.message], ['turn.end', 'interrupted', undefined]);
  // the stop marker alone is enough (an older Claude Code with no terminal_reason)
  c.feed(sdk({ type: 'user', parent_tool_use_id: null, message: { role: 'user', content: '[Request interrupted by user for tool use]' } }));
  assert.equal(c.feed(sdk({ type: 'result', subtype: 'error_during_execution', is_error: true, errors: diag }))[0].status, 'interrupted');
  // a real error keeps its message, without the diagnostic lines; the stop marker does not carry over
  const [err] = c.feed(sdk({ type: 'result', subtype: 'error_during_execution', is_error: true, errors: [...diag, 'API Error: 500'] }));
  assert.deepEqual([err.status, err.message], ['error', 'API Error: 500']);
  assert.equal(c.feed(sdk({ type: 'result', subtype: 'error_during_execution', is_error: true, errors: diag }))[0].message, undefined);
  assert.equal(c.state.status, 'error');
});

test('prompt lifecycle, banners and housekeeping frames: mapped, none unknown', () => {
  const c = conversation();
  assert.deepEqual(c.feed(sdk({ type: 'command_lifecycle', command_uuid: 'p-1', state: 'queued', uuid: 'u', session_id: 's' })).map(e => [e.type, e.id, e.state]), [['prompt.state', 'p-1', 'queued']]);
  assert.deepEqual(c.feed(sdk({ type: 'command_lifecycle', state: 'queued' })), []);   // no uuid: nothing to attach it to
  const notices = [
    [sys('api_error', { formatted: 'API Error: 529 overloaded', message: 'overloaded' }), 'error', 'API Error: 529 overloaded'],
    [sys('agents_killed', {}), 'info', 'Background agents stopped'],
    [sys('away_summary', { content: 'While you were away: 2 tasks finished' }), 'info', 'While you were away: 2 tasks finished'],
    [sys('memory_saved', { written_paths: ['/a', '/b'], verb: 'Saved' }), 'info', 'Saved 2 memories'],
    [sys('model_fallback', { original_model: 'opus', fallback_model: 'sonnet' }), 'info', 'Switched from opus to sonnet'],
    [sys('permission_retry', { commands: ['ls'] }), 'info', 'Retrying with the new permissions'],
    [sys('scheduled_task_fire', { content: 'Daily check started' }), 'info', 'Daily check started'],
    [sys('stop_hook_summary', { hook_errors: ['lint failed'], prevented_continuation: false }), 'warn', 'Stop hook: lint failed'],
    [sys('code_change_published', { action: 'opened', url: 'https://github.com/x/y/pull/7' }), 'info', 'Change opened: https://github.com/x/y/pull/7'],
    [sys('feedback_draft_queued', { title: 'Tray flicker' }), 'info', 'Feedback draft saved: Tray flicker'],
    [sdk({ type: 'session_notice', notice_class: 'peer_notice', content: 'build is green' }), 'info', 'From another session: build is green']
  ];
  for (const [raw, kind, message] of notices) assert.deepEqual(c.feed(raw).map(e => [e.type, e.kind, e.message]), [['notice', kind, message]], message);
  assert.deepEqual(c.feed(sys('stop_hook_summary', { hook_errors: [], prevented_continuation: false })), []);
  assert.deepEqual(c.feed(sys('vcs_state_changed', { kind: 'commit', branch: 'main' })).map(e => [e.type, e.kind, e.branch]), [['vcs', 'commit', 'main']]);
  assert.deepEqual(c.feed(sys('task_summary', { detail: 'Running the tests' })).map(e => [e.type, e.text]), [['progress.summary', 'Running the tests']]);
  for (const raw of ['turn_duration', 'post_turn_summary', 'file_snapshot', 'per_turn_effort_changed', 'cloud_session_delta', 'session_metadata',
    'turn_handoff_available', 'upgrade_relay_marker', 'dev_intent', 'peer_message_hold', 'turn_preempted'].map(st => sys(st, {}))
    .concat(['keep_alive', 'transcript_mirror', 'autocompact_state'].map(type => sdk({ type })))) assert.deepEqual(c.feed(raw), [], raw.msg.subtype || raw.msg.type);
  assert.equal(c.state.unknown.length, 0);
});

test('title answers pass through as a control event', () => {
  const c = conversation();
  const [t] = c.feed({ type: 'title', sessionId: 's1', title: 'Fix the parser', custom: true });
  assert.deepEqual([t.type, t.title, t.custom], ['title', 'Fix the parser', true]);
});

test('files answers pass through the normalizer unchanged', () => {
  const c = conversation();
  const [files] = c.feed({ type: 'files', id: 4, query: 'chat', suggestions: [{ path: 'Resources/SkimRender/chat.js' }, { path: 'Resources/' }] });
  assert.equal(files.type, 'files');
  assert.deepEqual([files.id, files.query, files.suggestions.length], [4, 'chat', 2]);
  assert.equal(c.state.unknown.length, 0);
});
