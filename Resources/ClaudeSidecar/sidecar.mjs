// FloatyTerm's Claude sidecar: one Claude Code session over the Claude Agent SDK.
//
// Protocol — one JSON object per line.
//
// Host → sidecar (stdin):
//   { type: 'start', cwd, claudePath, resume?, fork?, resumeAt?, dropsTurn?, model?, effort?, permissionMode?, thinking?, appendSystemPrompt? }
//     (resumeAt: with resume, keep the conversation only up to that transcript entry — a rewind; dropsTurn: the prompt it drops, checked by Claude Code)
//     (thinking: true/false shows or hides thinking summaries; omitted, it follows showThinkingSummaries in the settings)
//     (fork: with resume, start a new session from a copy of that transcript — a side chat)
//     (appendSystemPrompt defaults to prompt-contract.md; pass '' for none)
//   { type: 'user', text, images?, uuid? }  images: [{ mediaType, data }] (base64), sent before the text; uuid: the prompt's ID (rewind uses it)
//   { type: 'permission', id, decision: 'allow' | 'allowAlways' | 'deny', message?, updatedInput?, updatedPermissions? }
//     (updatedInput: e.g. AskUserQuestion's answers; updatedPermissions: e.g. a plan approval's mode change)
//   { type: 'interrupt' }
//   { type: 'setModel', model }            { type: 'setPermissionMode', mode }
//   { type: 'setEffort', effort }          { type: 'usage', plan? }  (plan: also fetch plan limits)
//   { type: 'git' }                        the repository state of the session's folder
//   { type: 'setThinking', on }            show thinking summaries (or not) from the next request
//   { type: 'sessions' }                   the conversations of this folder, newest first
//   { type: 'history', sessionId }         a conversation's messages, to draw it when it is resumed
//   { type: 'files', query, id }           @-mention suggestions (Claude Code's own fuzzy file search)
//   { type: 'title' }                      the session's name
//   { type: 'rename', title }              name the session (what /rename does; /resume lists it)
//   { type: 'btw', id, question, history? } a side question (/btw): answered from the conversation so far, no tools,
//                                          not saved to it; history: the earlier [{ question, response }] of this side thread
//   { type: 'rewindFiles', uuid, dryRun?, id }   files back to how they were before that prompt (dryRun: only say what would change)
//
// Sidecar → host (stdout), each stamped with `t` (ms since epoch):
//   { type: 'sdk', msg }                    every SDK message, unchanged
//   { type: 'permission_request', id, toolName, input, title?, … }
//   { type: 'permission_cancelled', id }    Claude withdrew the request
//   { type: 'capabilities', commands, models, agents, mode, outputStyles }   once, after connect
//   { type: 'model', model } · { type: 'mode', mode } · { type: 'effort', effort }   a change took effect
//   { type: 'usage', context?, plan? }      answer to a usage request
//   { type: 'git', repo, branch, … }        answer to a git request (repo: null outside a repository)
//   { type: 'thinking', on, source }        whether thinking text is shown; source: settings | default | user
//   { type: 'sessions', list }              answer to a sessions request
//   { type: 'history', sessionId, messages, omitted }   the last HISTORY_MAX messages, trimmed
//   { type: 'files', id, query, suggestions: [{ path }] }   answer to a files request (folders end with '/')
//   { type: 'btw', id, response, synthetic?, error? }   answer to btw
//   { type: 'rewind', id, uuid, dryRun, canRewind, filesChanged?, insertions?, deletions?, error? }   answer to rewindFiles
//   { type: 'title', sessionId, title, custom }   answer to title and rename (custom: named by the user, not the first prompt)
//   { type: 'error', message }              { type: 'end' }
//
// Nothing else is written to stdout. The session ends when stdin closes.
import { query, listSessions, getSessionMessages, getSessionInfo, renameSession } from '@anthropic-ai/claude-agent-sdk';
import readline from 'node:readline';
import fs from 'node:fs';
import { execFile } from 'node:child_process';

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
let sessionId = null;   // from the latest init (/clear starts a new one)
let mode = 'default';
let cwd = process.cwd();   // the last mode Claude Code confirmed, to fall back to when a change fails

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
    const perms = Array.isArray(m.updatedPermissions) ? m.updatedPermissions : always ? p.suggestions : null;
    p.resolve({ behavior: 'allow',
      // A dialog tool (AskUserQuestion) answers through its input; everything else runs as asked.
      updatedInput: m.updatedInput && typeof m.updatedInput === 'object' ? m.updatedInput : p.input,
      ...(perms ? { updatedPermissions: perms } : {}) });
  }
}

function start(m) {
  if (session) return;
  if (m.cwd) cwd = m.cwd;
  session = query({
    prompt: inbox,
    options: {
      cwd: m.cwd,
      pathToClaudeCodeExecutable: m.claudePath,
      resume: m.resume || undefined,
      forkSession: m.resume && m.fork ? true : undefined,
      // A rewind: the conversation up to that entry; Claude Code refuses if more than the dropped turn would go.
      resumeSessionAt: m.resume && m.resumeAt ? m.resumeAt : undefined,
      resumeDropsTurn: m.resume && m.resumeAt && m.dropsTurn ? m.dropsTurn : undefined,
      // Backups of the files Claude edits, so a rewind can put them back (the TUI keeps them by default; the SDK only when asked).
      enableFileCheckpointing: true,
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
        if (msg.type === 'system' && msg.subtype === 'init' && msg.session_id) sessionId = msg.session_id;
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
      agents: (r.agents || []).map(a => ({ name: a.name, description: a.description || '' })),
      // What this runner adds to the shared page's defaults.
      features: { mentions: true, images: true },
      outputStyles: r.available_output_styles || [], outputStyle: r.output_style });
    // Claude Code builds its file index on the first @-mention search: start it now.
    session.request({ subtype: 'file_suggestions', query: '' }).catch(() => {});
    return initThinking(m.thinking);
  }).catch(e => send({ type: 'error', message: 'initialize: ' + e.message }));
}

/**
 * Thinking summaries. Claude Code's display default is "omitted" (the blocks
 * arrive empty), and over the SDK it does not apply showThinkingSummaries
 * itself, so the sidecar does: the host's choice, else the merged settings
 * (what /config says), else off. The thinking tokens cost the same either way.
 */
async function initThinking(choice) {
  let on = false, source = 'default';
  if (typeof choice === 'boolean') { on = choice; source = 'user'; }
  else {
    const s = await session.getSettings().catch(() => null);
    const v = s && s.effective && s.effective.showThinkingSummaries;
    if (typeof v === 'boolean') { on = v; source = 'settings'; }
  }
  if (on) await session.setMaxThinkingTokens(null, 'summarized');
  send({ type: 'thinking', on, source });
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

/** Branch, upstream counts and file counts for the status line (git status --branch). */
async function gitState() {
  const run = args => new Promise(res => execFile('git', args, { cwd, timeout: 3000, maxBuffer: 4 << 20 }, (e, out) => res(e ? null : String(out))));
  const [st, top, last] = await Promise.all([
    run(['status', '--porcelain=v1', '--branch', '--untracked-files=normal']),
    run(['rev-parse', '--show-toplevel']),
    run(['log', '-1', '--format=%h%x09%s%x09%cr'])
  ]);
  if (st == null) return { type: 'git', repo: null };
  const [head = '', ...files] = st.split('\n').filter(Boolean);
  // "## main...origin/main [ahead 1, behind 2]" · "## HEAD (no branch)" · "## No commits yet on main"
  const m = head.match(/^## (?:No commits yet on )?(.+?)(?:\.\.\.(\S+))?(?: \[(.+)\])?$/) || [];
  let branch = m[1] || null, detached = false;
  if (branch === 'HEAD (no branch)') { detached = true; branch = ((await run(['rev-parse', '--short', 'HEAD'])) || '').trim() || 'HEAD'; }
  const count = re => files.filter(l => re.test(l)).length;
  const [sha, subject, when] = (last || '').trim().split('\t');
  return {
    type: 'git', repo: top ? top.trim() : null, branch, detached, upstream: m[2] || null,
    ahead: +((m[3] || '').match(/ahead (\d+)/) || [0, 0])[1], behind: +((m[3] || '').match(/behind (\d+)/) || [0, 0])[1],
    changed: files.length, staged: count(/^[MADRCU]/), untracked: count(/^\?\?/),
    last: sha ? { sha, subject, when } : null
  };
}

/** The conversations of the session's folder (what the TUI's /resume lists). */
async function sessionList() {
  const list = await listSessions({ dir: cwd, limit: 60 });
  return { type: 'sessions', list: list.map(s => ({ id: s.sessionId, title: s.customTitle || s.summary || '', firstPrompt: (s.firstPrompt || '').slice(0, 200),
    branch: s.gitBranch || null, modified: s.lastModified, size: s.fileSize || 0 })) };
}

/** The session's name: the one the user gave it, else Claude Code's summary or first prompt. */
async function sessionTitle() {
  const s = sessionId ? await getSessionInfo(sessionId, { dir: cwd }) : null;
  return { type: 'title', sessionId, title: s ? s.customTitle || s.summary || '' : '', custom: !!(s && s.customTitle) };
}

/**
 * Names the session through the running Claude Code, as a rename made in the
 * host app, so its own copy of the title stays the same. An older Claude Code
 * without the request gets the title entry written to the transcript instead.
 */
async function rename(m) {
  const title = String(m.title || '').replace(/\s+/g, ' ').trim().slice(0, 200);
  if (!title) throw new Error('the name is empty');
  if (!sessionId) throw new Error('send a message first: the session has no ID yet');
  try { await session.request({ subtype: 'rename_session', title, source: 'host', session_id: sessionId }); }
  catch { await renameSession(sessionId, title, { dir: cwd }); }
  return sessionTitle();
}

// History for a resumed conversation: the page draws the last messages, not a whole
// transcript (one can be tens of MB). Long tool output and file contents are cut.
const HISTORY_MAX = 400, RESULT_MAX = 4000, INPUT_MAX = 20000;
const cut = (s, n) => typeof s === 'string' && s.length > n ? s.slice(0, n) + `\n… (${s.length - n} more characters)` : s;
function trimBlock(b) {
  if (!b || typeof b !== 'object') return b;
  if (b.type === 'image') return { type: 'text', text: '[image]' };
  if (b.type === 'thinking') return { type: 'thinking', thinking: cut(b.thinking || '', RESULT_MAX) };   // no signature
  if (b.type === 'redacted_thinking') return { type: 'redacted_thinking' };
  if (b.type === 'tool_result') {
    const c = typeof b.content === 'string' ? cut(b.content, RESULT_MAX)
      : Array.isArray(b.content) ? b.content.map(x => x.type === 'text' ? { type: 'text', text: cut(x.text, RESULT_MAX) } : { type: 'text', text: '[' + x.type + ']' }) : b.content;
    return { ...b, content: c };
  }
  if (b.type === 'tool_use' && b.input && typeof b.input === 'object') {
    const input = {};
    for (const [k, v] of Object.entries(b.input)) input[k] = cut(v, INPUT_MAX);
    return { ...b, input };
  }
  if (b.type === 'text') return { ...b, text: cut(b.text, INPUT_MAX) };
  return b;
}
async function history(sessionId) {
  const all = (await getSessionMessages(sessionId, { dir: cwd })).filter(m => m.type === 'user' || m.type === 'assistant');
  let from = Math.max(all.length - HISTORY_MAX, 0);
  // Start at a prompt, not in the middle of a tool call.
  while (from > 0 && from < all.length && !(all[from].type === 'user' && !(Array.isArray(all[from].message?.content) && all[from].message.content.some(c => c.type === 'tool_result')))) from++;
  const messages = all.slice(from).map(m => {
    const msg = m.message || {};
    const content = Array.isArray(msg.content) ? msg.content.map(trimBlock) : cut(msg.content, INPUT_MAX);
    return { type: m.type, uuid: m.uuid, parent_tool_use_id: m.parent_tool_use_id || null, timestamp: m.timestamp,
      message: { id: msg.id, role: msg.role, model: msg.model, content } };
  });
  // before: the entry just before the first one sent, where a rewind of that first prompt resumes.
  return { type: 'history', sessionId, messages, omitted: from, before: from > 0 ? all[from - 1].uuid || null : null };
}

/**
 * @-mention suggestions: the same fuzzy file search the TUI shows. There is no
 * public method for it, so this sends the control request directly.
 */
async function fileSuggestions(m) {
  const r = session ? await session.request({ subtype: 'file_suggestions', query: String(m.query || '') }) : null;
  const res = (r && (r.response || r)) || {};
  return { type: 'files', id: m.id, query: m.query || '', suggestions: (res.suggestions || []).map(s => ({ path: s.path })) };
}

/** A user turn: images first (as the TUI sends a pasted image), then the text. */
function userContent(m) {
  const images = Array.isArray(m.images) ? m.images.filter(i => i && i.data && /^image\/(png|jpeg|gif|webp)$/.test(i.mediaType)) : [];
  if (!images.length) return m.text;
  const blocks = images.map(i => ({ type: 'image', source: { type: 'base64', media_type: i.mediaType, data: i.data } }));
  if (m.text) blocks.push({ type: 'text', text: m.text });
  return blocks;
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
        inbox.push({ type: 'user', ...(m.uuid ? { uuid: m.uuid } : {}), message: { role: 'user', content: userContent(m) }, parent_tool_use_id: null });
        break;
      case 'permission': answer(m); break;
      case 'interrupt': session?.interrupt().catch(e => send({ type: 'error', message: 'interrupt: ' + e.message })); break;
      case 'setModel': control('Model', () => session.setModel(m.model || undefined), { type: 'model', model: m.model }); break;
      case 'setPermissionMode':
        control('Permission mode', () => session.setPermissionMode(m.mode).then(() => { mode = m.mode; }),
          { type: 'mode', mode: m.mode }, () => ({ type: 'mode', mode }));
        break;
      case 'setEffort': control('Effort', () => session.applyFlagSettings({ effortLevel: m.effort || null }), { type: 'effort', effort: m.effort || null }); break;
      case 'setThinking':
        // null keeps the model's own thinking amount; only the display changes.
        control('Thinking display', () => session.setMaxThinkingTokens(null, m.on ? 'summarized' : 'omitted'),
          { type: 'thinking', on: !!m.on, source: 'user' });
        break;
      case 'files': fileSuggestions(m).then(send, e => send({ type: 'files', id: m.id, query: m.query || '', suggestions: [], error: e.message })); break;
      case 'sessions': sessionList().then(send, e => send({ type: 'error', message: 'sessions: ' + e.message })); break;
      case 'history': history(m.sessionId).then(send, e => send({ type: 'error', message: 'history: ' + e.message })); break;
      case 'btw': {
        if (!session) { send({ type: 'btw', id: m.id, error: 'the session is not running' }); break; }
        const history = (Array.isArray(m.history) ? m.history : []).filter(x => x && typeof x.question === 'string' && typeof x.response === 'string')
          .map(x => ({ question: x.question, response: x.response }));
        session.request({ subtype: 'side_question', question: String(m.question || ''), ...(history.length ? { history } : {}) })
          .then(r => { const a = r.response || {}; send({ type: 'btw', id: m.id, response: a.response ?? null, synthetic: !!a.synthetic }); },
            e => send({ type: 'btw', id: m.id, error: e.message }));
        break;
      }
      case 'rewindFiles': {
        const base = { type: 'rewind', id: m.id, uuid: m.uuid, dryRun: !!m.dryRun };
        if (!session) { send({ ...base, canRewind: false, error: 'the session is not running' }); break; }
        session.rewindFiles(m.uuid, { dryRun: !!m.dryRun }).then(r => send({ ...base, ...r }), e => send({ ...base, canRewind: false, error: e.message }));
        break;
      }
      case 'title': sessionTitle().then(send, e => send({ type: 'error', message: 'title: ' + e.message })); break;
      case 'rename': rename(m).then(send, e => { send({ type: 'error', message: 'Rename: ' + e.message }); sessionTitle().then(send, () => {}); }); break;
      case 'git': gitState().then(send, e => send({ type: 'error', message: 'git: ' + e.message })); break;
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
