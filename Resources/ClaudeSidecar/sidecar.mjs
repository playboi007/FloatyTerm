// FloatyTerm's Claude sidecar: one Claude Code session over the Claude Agent SDK.
//
// Protocol — one JSON object per line.
//
// Host → sidecar (stdin):
//   { type: 'start', cwd, claudePath, resume?, model?, effort?, permissionMode?, appendSystemPrompt? }
//     (appendSystemPrompt defaults to prompt-contract.md; pass '' for none)
//   { type: 'user', text }
//   { type: 'permission', id, decision: 'allow' | 'allowAlways' | 'deny', message? }
//   { type: 'interrupt' }
//   { type: 'setModel', model }            { type: 'setPermissionMode', mode }
//   { type: 'setEffort', effort }          { type: 'usage', plan? }  (plan: also fetch plan limits)
//
// Sidecar → host (stdout), each stamped with `t` (ms since epoch):
//   { type: 'sdk', msg }                    every SDK message, unchanged
//   { type: 'permission_request', id, toolName, input, title?, … }
//   { type: 'permission_cancelled', id }    Claude withdrew the request
//   { type: 'capabilities', commands, models, mode, outputStyles }   once, after connect
//   { type: 'model', model } · { type: 'mode', mode } · { type: 'effort', effort }   a change took effect
//   { type: 'usage', context?, plan? }      answer to a usage request
//   { type: 'error', message }              { type: 'end' }
//
// Nothing else is written to stdout. The session ends when stdin closes.
import { query } from '@anthropic-ai/claude-agent-sdk';
import readline from 'node:readline';
import fs from 'node:fs';

// Output shapes the Claude tab renders specially (editable, next to this file).
// A host-supplied appendSystemPrompt replaces it.
const CONTRACT = (() => {
  try { return fs.readFileSync(new URL('./prompt-contract.md', import.meta.url), 'utf8'); } catch { return ''; }
})();

const send = obj => process.stdout.write(JSON.stringify({ t: Date.now(), ...obj }) + '\n');

/** Streaming input: user turns are pushed here and read by the SDK. */
class Inbox {
  #items = [];
  #wake = null;
  #closed = false;
  push(item) { this.#items.push(item); this.#wake?.(); }
  close() { this.#closed = true; this.#wake?.(); }
  async *[Symbol.asyncIterator]() {
    while (true) {
      while (this.#items.length) yield this.#items.shift();
      if (this.#closed) return;
      await new Promise(r => { this.#wake = r; });
      this.#wake = null;
    }
  }
}

const inbox = new Inbox();
const abort = new AbortController();
const pending = new Map();   // permission id → { resolve, input, suggestions }
let session = null;
let mode = 'default';   // the last mode Claude Code confirmed, to fall back to when a change fails

async function canUseTool(toolName, input, opts) {
  const id = opts.requestId || opts.toolUseID;
  send({
    type: 'permission_request', id, toolName, input,
    toolUseID: opts.toolUseID, agentID: opts.agentID,
    title: opts.title, displayName: opts.displayName, description: opts.description,
    decisionReason: opts.decisionReason, blockedPath: opts.blockedPath,
    suggestions: opts.suggestions || [],
    defaultToNo: !!opts.defaultToNo, suppressAlwaysAllowRule: !!opts.suppressAlwaysAllowRule
  });
  return new Promise(resolve => {
    pending.set(id, { resolve, input, suggestions: opts.suggestions || [] });
    opts.signal?.addEventListener('abort', () => {
      if (!pending.delete(id)) return;
      send({ type: 'permission_cancelled', id });
      resolve({ behavior: 'deny', message: 'The request was cancelled.' });
    }, { once: true });
  });
}

function answer(m) {
  const p = pending.get(m.id);
  if (!p) return;
  pending.delete(m.id);
  if (m.decision === 'deny') {
    p.resolve({ behavior: 'deny', message: m.message || 'The user declined this action.' });
  } else {
    const always = m.decision === 'allowAlways' && p.suggestions.length > 0;
    p.resolve({ behavior: 'allow', updatedInput: p.input, ...(always ? { updatedPermissions: p.suggestions } : {}) });
  }
}

function start(m) {
  if (session) return;
  session = query({
    prompt: inbox,
    options: {
      cwd: m.cwd,
      pathToClaudeCodeExecutable: m.claudePath,
      resume: m.resume || undefined,
      model: m.model || undefined,
      effort: m.effort || undefined,
      permissionMode: m.permissionMode || undefined,
      includePartialMessages: true,
      // The same settings, CLAUDE.md files, skills and hooks as the TUI.
      settingSources: ['user', 'project', 'local'],
      systemPrompt: (m.appendSystemPrompt ?? CONTRACT)
        ? { type: 'preset', preset: 'claude_code', append: m.appendSystemPrompt ?? CONTRACT }
        : { type: 'preset', preset: 'claude_code' },
      canUseTool,
      abortController: abort,
      stderr: line => process.stderr.write(line.endsWith('\n') ? line : line + '\n')
    }
  });
  (async () => {
    try {
      for await (const msg of session) {
        if (msg.type === 'system' && (msg.subtype === 'init' || msg.subtype === 'status') && msg.permissionMode) mode = msg.permissionMode;
        send({ type: 'sdk', msg });
      }
      send({ type: 'end' });
    } catch (e) {
      send({ type: 'error', message: String(e && e.message || e) });
    }
  })();
  // What the page needs for its menus: slash commands, models, output styles.
  session.initializationResult().then(r => {
    if (r.current_permission_mode) mode = r.current_permission_mode;
    send({ type: 'capabilities', commands: r.commands || [], models: r.models || [], mode: r.current_permission_mode,
      outputStyles: r.available_output_styles || [], outputStyle: r.output_style });
  }, e => send({ type: 'error', message: 'initialize: ' + e.message }));
}

async function usage(m) {
  const out = { type: 'usage' };
  const [ctx, plan] = await Promise.allSettled([
    session.getContextUsage({ detail: 'summary' }),
    m.plan ? session.usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET({ skipBehaviors: true }) : null
  ]);
  if (ctx.status === 'fulfilled' && ctx.value) {
    const c = ctx.value;
    out.context = { totalTokens: c.totalTokens, maxTokens: c.maxTokens, percentage: c.percentage, model: c.model,
      autoCompactThreshold: c.autoCompactThreshold, isAutoCompactEnabled: c.isAutoCompactEnabled,
      categories: (c.categories || []).map(({ name, tokens, kind }) => ({ name, tokens, kind })) };
  }
  if (plan.status === 'fulfilled' && plan.value) {
    const u = plan.value;
    out.plan = { subscription: u.subscription_type, available: !!u.rate_limits_available,
      limits: ((u.rate_limits && u.rate_limits.limits) || []).map(({ kind, group, percent, severity, resets_at, is_active }) => ({ kind, group, percent, severity, resets_at, is_active })),
      session: u.session ? { linesAdded: u.session.total_lines_added, linesRemoved: u.session.total_lines_removed } : null };
  }
  send(out);
}

/** Runs a control request; reports success as `ok`, failure as an error (and `fail`). */
function control(name, run, ok, fail) {
  if (!session) return;
  run().then(() => ok && send(ok), e => { send({ type: 'error', message: name + ': ' + e.message }); if (fail) send(fail()); });
}

const rl = readline.createInterface({ input: process.stdin });
rl.on('line', line => {
  let m;
  try { m = JSON.parse(line); } catch { return send({ type: 'error', message: 'bad input line' }); }
  try {
    switch (m.type) {
      case 'start': start(m); break;
      case 'user':
        inbox.push({ type: 'user', message: { role: 'user', content: m.text }, parent_tool_use_id: null });
        break;
      case 'permission': answer(m); break;
      case 'interrupt': session?.interrupt().catch(e => send({ type: 'error', message: 'interrupt: ' + e.message })); break;
      case 'setModel': control('Model', () => session.setModel(m.model || undefined), { type: 'model', model: m.model }); break;
      case 'setPermissionMode':
        control('Permission mode', () => session.setPermissionMode(m.mode).then(() => { mode = m.mode; }),
          { type: 'mode', mode: m.mode }, () => ({ type: 'mode', mode }));
        break;
      case 'setEffort': control('Effort', () => session.applyFlagSettings({ effortLevel: m.effort || null }), { type: 'effort', effort: m.effort || null }); break;
      case 'usage': if (session) usage(m).catch(e => send({ type: 'error', message: 'usage: ' + e.message })); break;
      default: send({ type: 'error', message: 'unknown message ' + m.type });
    }
  } catch (e) {
    send({ type: 'error', message: String(e && e.message || e) });
  }
});
rl.on('close', () => {
  // The host went away: deny anything still waiting, stop the session, exit.
  for (const [id, p] of pending) p.resolve({ behavior: 'deny', message: 'FloatyTerm closed the session.' });
  pending.clear();
  inbox.close();
  abort.abort();
  setTimeout(() => process.exit(0), 500);
});
