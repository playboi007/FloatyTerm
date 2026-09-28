/*
 * ClaudeChat — the Claude tab's page: a conversation drawn from the sidecar's
 * event stream (Resources/ClaudeSidecar/sidecar.mjs).
 *
 *   ClaudeChat.receive([event, …])   host → page, in order
 *   ClaudeChat.boot({ cwd })         once, before the first event
 *
 * Page → host goes through `skim` bridge actions:
 *   { type: 'send', text } · { type: 'permission', id, decision, message? }
 *   { type: 'interrupt' } · { type: 'setPermissionMode', mode } · { type: 'openTUI' }
 *   { type: 'setModel', model } · { type: 'setEffort', effort } · { type: 'usage', plan? }
 *   { type: 'state', busy, waiting }  (for the tab's attention dot)
 *
 * Replies render through SkimRender as they stream. Tool calls gather into
 * activity groups — one per run of calls between two pieces of text — drawn
 * as the design's timeline and folded to one summary line once the run ends.
 * Approval requests become cards in the flow; answered cards collapse to one
 * line and cannot be undone (the tool may already have run).
 *
 * The dock at the bottom holds the status line (model menu, permission-mode
 * menu, a usage chip that opens the usage panel, TUI hand-off) and the
 * composer, which suggests slash commands and their arguments as you type.
 */
(function (root) {
  'use strict';

  const h = (tag, props, ...kids) => {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(props || {})) {
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k.startsWith('on')) el.addEventListener(k.slice(2).toLowerCase(), v);
      else el.setAttribute(k, v === true ? '' : v);
    }
    for (const kid of kids.flat(Infinity)) if (kid != null && kid !== false) el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
    return el;
  };
  // Every action names the conversation it comes from (main or a side chat).
  const post = action => {
    if (!('channel' in action) && S) action = { channel: S.id, ...action };
    try { root.webkit.messageHandlers.skim.postMessage({ type: 'action', action }); } catch (e) { console.log('action', action); }
  };

  // ── state ──────────────────────────────────────────────────────────────

  /** Facts of the folder and account, the same for every conversation. */
  const SHARED = {
    cwd: '', home: '',
    // from the sidecar's capabilities event and later changes
    models: [], commands: [], terminalCmds: new Set(), outputStyles: [],
    plan: null, planAt: 0,  // plan limits (account-wide)
    git: null,              // the sidecar's git state for the session's folder
    info: {},               // from init: Claude Code version, MCP servers, output style
    sessions: null          // { at, list }: the folder's conversations, for /resume
  };

  /**
   * One conversation: main, or a side chat forked from it. Unset fields read
   * through to SHARED. Events are processed against their own conversation;
   * only the one in view paints the dock.
   */
  function newConv(id, label) {
    return Object.assign(Object.create(SHARED), {
      id, label, log: null,
      model: '', mode: 'default', sessionId: null, cost: 0,
      busy: false, turn: null, turns: [],
      rows: new Map(),        // tool_use id → row
      texts: new Map(),       // `${messageId}:${index}` → text item
      msgTexts: new Map(),    // messageId → [text item] in order (to match full assistant messages)
      cards: new Map(),       // permission id → card
      blockKind: new Map(),   // `${messageId}:${index}` → 'text' | 'tool_use' | 'thinking'
      currentMsg: null, thinking: false, lastTool: null,
      thinks: new Map(), msgThinks: new Map(), liveThink: null, thinkWord: null,   // thinking blocks
      thinkingOn: null, thinkingSource: null,   // whether thinking text is shown (the sidecar reports it)
      modelChoice: null,      // the model menu value the user picked ('sonnet', 'default', …)
      effort: null,           // null: the model's default
      modelUsage: null, turns_n: 0, apiMs: 0,
      ctx: null,
      refs: [],               // text referenced from Claude's replies, sent with the next message
      draft: '', follow: true, scrollY: 0, unseen: false
    });
  }
  const main = newConv('main', 'Main');
  const convs = new Map([['main', main]]);
  let S = main;          // the conversation being worked on (events, actions)
  let active = main;     // the conversation in view
  const inView = () => S === active;

  /** The time of the event being processed (sidecar stamp), else now. */
  let evT = 0;
  const clock = () => evT || Date.now();

  let viewBtn, viewMenuBtn, grip, ctxEl, moreBtn, refsEl, refBtn, dock, dockIn, statusEl, statusDot, statusText, modelEl, modeBtn, costEl, usagePanel, composer, input, sendBtn, popEl;

  // ── scrolling: follow the bottom while the user is near it ────────────

  // Only sending a message (or the down button) moves the view: typing never
  // does, and output that arrives while you read higher up leaves you there.
  let follow = true;
  const nearBottom = (slack = 80) => window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - slack;
  // A scroll up that you make stops following at once, even a few pixels, so the
  // next streamed paint does not pull you back. Following resumes at the very bottom.
  let upAt = 0, dragging = false, pinUntil = 0;
  const leaveBottom = () => { follow = false; upAt = Date.now(); paintDown(); };
  function onScroll() {
    if (Date.now() < pinUntil) return;                         // the down button's smooth scroll
    if (dragging || Date.now() - upAt < 300) follow = false;
    else if (nearBottom(4)) follow = true;
    else if (!nearBottom()) follow = false;
  }
  const stick = () => { if (inView() && follow) requestAnimationFrame(() => { window.scrollTo(0, document.documentElement.scrollHeight); paintDown(); }); };

  /** The down button in the composer: shown away from the bottom, dotted when new output came in. */
  let downBtn;
  function paintDown() {
    if (!downBtn) return;
    const away = follow ? !nearBottom() : !nearBottom(4);
    downBtn.hidden = !away;
    if (!away) delete downBtn.dataset.fresh;
  }
  function toBottom() {
    follow = true;
    pinUntil = Date.now() + 700;
    window.scrollTo({ top: document.documentElement.scrollHeight, behavior: 'smooth' });
    delete downBtn.dataset.fresh;
    input.focus();
  }

  // ── turns ──────────────────────────────────────────────────────────────

  function newTurn(userText, refs) {
    closeRun();
    const el = h('section', { class: 'ck-turn' });
    if (userText != null) el.append(h('div', { class: 'ck-user' + (/^\/\S/.test(userText) ? ' is-cmd' : '') },
      refs && refs.length ? h('div', { class: 'ck-user-refs' }, refs.map(r => refChip(r))) : null,
      userText ? h('span', { class: 'ck-user-text', text: userText }) : null));
    const body = h('div', { class: 'ck-body' });
    el.append(body);
    S.log.append(el);
    S.turn = { el, body, run: null, t0: Date.now(), footer: null };
    S.turns.push(S.turn);
    stick();
    return S.turn;
  }
  const turn = () => S.turn || newTurn(null);

  // ── text blocks ────────────────────────────────────────────────────────

  function newText(key, msgId) {
    closeRun();
    const el = h('div', { class: 'sk-doc ck-text' });
    turn().body.append(el);
    const item = { el, text: '', final: false, raf: 0 };
    S.texts.set(key, item);
    if (!S.msgTexts.has(msgId)) S.msgTexts.set(msgId, []);
    S.msgTexts.get(msgId).push(item);
    return item;
  }

  function paintText(item, streaming) {
    cancelAnimationFrame(item.raf);
    item.raf = 0;
    root.SkimRender.render(item.el, item.text, { streaming, interactive: true, onAction: a => { if (a.type === 'reply') sendUser(a.text); } });
    stick();
  }
  const schedulePaint = item => { if (!item.raf) item.raf = requestAnimationFrame(() => paintText(item, true)); };

  // ── thinking: a folded line while Claude thinks, the summary on request ──

  const THINK_VERBS = ['Pondering', 'Noodling', 'Canoodling', 'Cogitating', 'Ruminating', 'Percolating', 'Mulling', 'Musing',
    'Brewing', 'Simmering', 'Marinating', 'Contemplating', 'Deliberating', 'Puzzling', 'Scheming', 'Tinkering', 'Wrangling',
    'Untangling', 'Synthesizing', 'Ideating', 'Concocting', 'Conjuring', 'Divining', 'Moseying', 'Meandering', 'Spelunking',
    'Stewing', 'Sussing', 'Whirring', 'Wibbling', 'Finagling', 'Hatching', 'Incubating', 'Philosophising', 'Reticulating',
    'Churning', 'Combobulating', 'Envisioning'];
  const pickVerb = not => { let v; do v = THINK_VERBS[Math.floor(Math.random() * THINK_VERBS.length)]; while (v === not); return v; };
  const ICON_THINK = '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M8 1.2 9.5 6.5 14.8 8 9.5 9.5 8 14.8 6.5 9.5 1.2 8 6.5 6.5Z" fill="currentColor"/></svg>';
  const secs = ms => ms < 60e3 ? Math.max(1, Math.round(ms / 1000)) + 's' : Math.floor(ms / 60e3) + 'm ' + Math.round(ms % 60e3 / 1000) + 's';

  /** The last line of the summary so far, without Markdown marks: the folded line's preview. */
  const thinkPreview = t => (String(t).trim().split('\n').filter(l => l.trim()).pop() || '').replace(/[*_`#>]+/g, '').trim();

  function newThink(key, msgId, redacted) {
    closeRun();
    const ic = icon(ICON_THINK);
    ic.classList.add('ck-think-ic');
    const verb = h('span', { class: 'ck-think-verb' });
    const peek = h('span', { class: 'ck-think-peek' });
    const time = h('span', { class: 'ck-think-time' });
    const caret = h('span', { class: 'sk-caret ck-think-caret', hidden: true });
    const head = h('button', { class: 'ck-think-head', type: 'button' }, ic, verb, peek, time, caret);
    const body = h('div', { class: 'sk-doc ck-think-body', hidden: true });
    const el = h('div', { class: 'ck-think is-live' }, head, body);
    turn().body.append(el);
    const item = { key, el, head, body, verb, peek, time, caret, text: '', redacted: !!redacted,
      t0: clock(), t1: null, open: false, word: pickVerb(), ticks: 0, raf: 0, timer: 0, conv: S };
    head.onclick = () => {
      if (!item.text) return;
      item.open = !item.open;
      el.classList.toggle('is-open', item.open);
      body.hidden = !item.open;
      paintThink(item);   // the preview hides while the summary shows
      if (item.open) paintThinkBody(item);
    };
    // A new word every few seconds while it thinks, like the TUI's spinner.
    item.timer = setInterval(() => { if (++item.ticks % 3 === 0) item.word = pickVerb(item.word); paintThink(item); }, 1000);
    S.thinks.set(key, item);
    if (!S.msgThinks.has(msgId)) S.msgThinks.set(msgId, []);
    S.msgThinks.get(msgId).push(item);
    S.liveThink = item;
    paintThink(item);
    stick();
    return item;
  }

  function paintThink(item) {
    const live = !item.t1;
    item.verb.textContent = live ? item.word + '…' : item.redacted ? 'Thought (hidden)' : 'Thought';
    item.time.textContent = live ? secs(Date.now() - item.t0) : item.t1 - item.t0 >= 1000 ? 'for ' + secs(item.t1 - item.t0) : '';
    item.peek.textContent = item.open ? '' : thinkPreview(item.text);
    item.caret.hidden = !item.text;
    item.el.classList.toggle('has-text', !!item.text);
    item.head.title = item.text ? (item.open ? 'Hide the thinking' : 'Show the thinking') : live ? '' : 'No thinking text was sent for this block';
    if (live && item.conv.liveThink === item) {
      item.conv.thinkWord = item.word;
      const prev = S; S = item.conv; updateStatus(); S = prev;   // the status line says the same word
    }
  }

  function paintThinkBody(item) {
    cancelAnimationFrame(item.raf);
    item.raf = 0;
    root.SkimRender.render(item.body, item.text, { streaming: !item.t1, interactive: false });
    if (item.open) stick();
  }

  function endThink(item, t1) {
    if (!item || item.t1) return;
    item.t1 = t1 || clock();
    clearInterval(item.timer);
    item.el.classList.remove('is-live');
    if (S.liveThink === item) S.liveThink = null;
    paintThink(item);
    if (item.open) paintThinkBody(item);
  }

  // ── tool activity (design 09) ──────────────────────────────────────────

  const PHASE_OF = {
    TodoWrite: 'plan', TaskCreate: 'plan', TaskUpdate: 'plan', ExitPlanMode: 'plan', EnterPlanMode: 'plan',
    Read: 'explore', Grep: 'explore', Glob: 'explore', LS: 'explore', WebFetch: 'explore', WebSearch: 'explore',
    NotebookRead: 'explore', LSP: 'explore', ToolSearch: 'explore', Agent: 'explore', Task: 'explore',
    Edit: 'change', MultiEdit: 'change', Write: 'change', NotebookEdit: 'change'
  };
  const VERIFY_CMD = /\b(test|tests|jest|vitest|pytest|mocha|analyze|analyzer|lint|eslint|ruff|mypy|tsc|clippy|build|xcodebuild|make|check|typecheck)\b/;
  const READ_CMD = /^\s*(ls|cat|head|tail|less|grep|rg|find|fd|pwd|wc|which|file|stat|tree|du|echo|git\s+(status|log|diff|show|branch|rev-parse|ls-files|blame))\b/;
  const BADGE = [[/\b(test|tests|jest|vitest|pytest|mocha)\b/, 'tests'], [/\b(lint|eslint|ruff|clippy|analyze|analyzer)\b/, 'linter'], [/\b(tsc|mypy|typecheck)\b/, 'types'], [/\b(build|xcodebuild|make)\b/, 'build']];

  function phaseOf(name, input) {
    if (name === 'Bash') {
      const cmd = String(input.command || '');
      if (VERIFY_CMD.test(cmd)) return 'verify';
      if (READ_CMD.test(cmd)) return 'explore';
      return 'change';
    }
    if (name.startsWith('mcp__')) return 'explore';
    return PHASE_OF[name] || 'explore';
  }

  const rel = p => {
    p = String(p || '');
    if (S.cwd && p.startsWith(S.cwd + '/')) return p.slice(S.cwd.length + 1);
    const home = S.home;
    return home && p.startsWith(home + '/') ? '~/' + p.slice(home.length + 1) : p;
  };

  function argOf(name, input) {
    if (!input) return '';
    if (input.file_path || input.notebook_path) return rel(input.file_path || input.notebook_path);
    if (name === 'Bash') return String(input.command || '').split('\n')[0];
    if (name === 'Grep') return `"${input.pattern || ''}"` + (input.path || input.glob ? ' in ' + rel(input.glob || input.path) : '');
    if (name === 'Glob') return String(input.pattern || '');
    if (name === 'WebFetch') return String(input.url || '');
    if (name === 'WebSearch') return String(input.query || '');
    if (name === 'TodoWrite' && Array.isArray(input.todos)) return input.todos.length + ' tasks';
    if (input.description) return String(input.description);
    const first = Object.values(input).find(v => typeof v === 'string');
    return first ? String(first).slice(0, 120) : '';
  }

  const shortName = name => name.startsWith('mcp__') ? name.split('__').slice(-1)[0] : name;
  /** Lines as an editor counts them: a final newline does not start a new line. */
  const lineCount = s => { const t = String(s || '').replace(/\n$/, ''); return t ? t.split('\n').length : 0; };

  function metaOf(row, resultText, isError) {
    const { name, input } = row;
    if (isError) return name === 'Bash' ? 'failed' : 'error';
    if (name === 'Read') return lineCount(resultText) + ' lines';
    if (name === 'Grep' || name === 'Glob') { const n = String(resultText || '').split('\n').filter(Boolean).length; return n + (n === 1 ? ' match' : ' matches'); }
    if (name === 'Edit' || name === 'MultiEdit') { const st = changeStats(name, input); return `+${st.add} −${st.del}`; }
    if (name === 'Write') return `+${lineCount(input.content)}`;
    if (name === 'Bash') { const t = String(resultText || '').trim(); return t ? (lineCount(t) + ' lines') : 'no output'; }
    return 'done';
  }

  const resultText = c => typeof c.content === 'string' ? c.content
    : Array.isArray(c.content) ? c.content.map(x => x.type === 'text' ? x.text : '[' + x.type + ']').join('\n') : '';

  function ensureRun() {
    const t = turn();
    if (t.run && !t.run.closed) return t.run;
    const rows = h('div', { class: 'ck-rows' });
    const summary = h('span', { class: 'ck-run-summary' });
    const stats = h('span', { class: 'ck-run-stats' });
    const headEl = h('button', { class: 'ck-run-head', type: 'button' }, h('span', { class: 'sk-caret ck-run-caret' }), summary, stats);
    const el = h('div', { class: 'ck-run is-live' }, headEl, rows);
    headEl.onclick = () => el.classList.toggle('is-folded');
    t.body.append(el);
    t.run = { el, rows, summary, stats, list: [], t0: clock(), t1: null, closed: false, timer: 0 };
    t.run.timer = setInterval(() => paintRun(t.run), 250);
    return t.run;
  }

  /** Ends the current run: bars freeze, and a long run folds to its summary. */
  function closeRun() {
    const run = S.turn && S.turn.run;
    if (!run || run.closed) return;
    if (run.list.some(r => r.state === 'running' || r.state === 'waiting' || r.state === 'preparing')) return;
    run.closed = true;
    run.t1 = Math.max(...run.list.map(r => r.t1 || r.t0), run.t0 + 1);
    clearInterval(run.timer);
    run.el.classList.remove('is-live');
    if (run.list.length > 3 && !run.list.some(r => r.state === 'error')) run.el.classList.add('is-folded');
    paintRun(run);
  }

  const PHASE_LABEL = { plan: 'Plan', explore: 'Explore', change: 'Change', verify: 'Verify' };

  function paintRun(run) {
    const now = Date.now();
    const end = run.t1 || now;
    const span = Math.max(end - run.t0, 1000);
    const counts = {};
    let running = 0, waiting = 0, failed = 0;
    for (const r of run.list) {
      counts[r.phase] = (counts[r.phase] || 0) + 1;
      const r1 = r.t1 || now;
      const w = r.waitMs + (r.waitStart ? now - r.waitStart : 0);
      running += Math.max(r1 - r.t0 - w, 0);
      waiting += w;
      if (r.state === 'error') failed++;
      r.bar.style.left = ((r.t0 - run.t0) / span * 100) + '%';
      r.bar.style.width = Math.max((r1 - r.t0) / span * 100, 1.2) + '%';
      r.waitBar.style.width = w ? (w / Math.max(r1 - r.t0, 1) * 100) + '%' : '0';
      r.bar.dataset.state = r.state;
    }
    run.summary.textContent = Object.keys(PHASE_LABEL).filter(p => counts[p]).map(p => `${PHASE_LABEL[p]} ${counts[p]}`).join(' · ') || 'Tools';
    const sec = ms => (ms / 1000).toFixed(1) + 's';
    run.stats.textContent = [run.list.length + (run.list.length === 1 ? ' call' : ' calls'), sec(running) + ' running',
      waiting > 400 ? sec(waiting) + ' waiting on you' : null, failed ? failed + ' failed' : null].filter(Boolean).join(' · ');
    run.el.classList.toggle('has-failed', failed > 0);
  }

  function addRow(id, name, parentId) {
    if (S.rows.has(id)) return S.rows.get(id);
    const run = ensureRun();
    const icon = h('span', { class: 'ck-ic' });
    const nameEl = h('span', { class: 'ck-name', text: shortName(name) });
    const badge = h('span', { class: 'ck-badge', hidden: true });
    const argEl = h('span', { class: 'ck-arg' });
    const bar = h('span', { class: 'ck-bar' }, h('span', { class: 'ck-wait' }));
    const metaEl = h('span', { class: 'ck-meta' });
    const line = h('div', { class: 'ck-row' + (parentId ? ' is-sub' : '') }, icon, nameEl, badge, argEl, h('span', { class: 'ck-track' }, bar), metaEl);
    const detail = h('div', { class: 'ck-detail', hidden: true });
    line.onclick = () => { if (detail.childNodes.length) { detail.hidden = !detail.hidden; if (!detail.hidden) fitChanges(detail); } };
    const row = { id, name, input: {}, phase: 'explore', state: 'preparing', t0: clock(), t1: null, waitMs: 0, waitStart: 0,
      line, detail, icon, argEl, metaEl, bar, badge, waitBar: bar.firstChild, run };
    run.rows.append(line, detail);
    run.list.push(row);
    S.rows.set(id, row);
    setRowState(row, 'preparing');
    stick();
    return row;
  }

  function setRowInput(row, input) {
    row.input = input || {};
    row.phase = phaseOf(row.name, row.input);
    row.line.dataset.phase = row.phase;
    row.argEl.textContent = argOf(row.name, row.input);
    row.argEl.title = row.input.description || row.argEl.textContent;
    if (row.name === 'Bash') {
      const b = BADGE.find(([re]) => re.test(String(row.input.command || '')));
      if (b) { row.badge.textContent = b[1]; row.badge.hidden = false; }
    }
    // File changes get the change view in the row, since edits may run with no card.
    const chg = changeView(row.name, row.input);
    if (chg) { row.change = chg; row.detail.classList.add('is-change'); row.detail.replaceChildren(chg); }
    if (row.state === 'preparing') setRowState(row, 'running');
    S.lastTool = row;
  }

  function setRowState(row, state) {
    row.state = state;
    row.line.dataset.state = state;
    row.icon.textContent = state === 'done' ? '✓' : state === 'error' ? '!' : '';
    updateStatus();
  }

  // ── approval cards (design 10) ─────────────────────────────────────────

  const DESTRUCTIVE = /\b(rm\s+-[a-z]*[rf]|rmdir|git\s+(reset\s+--hard|clean\s+-[a-z]*f|push\s+(-f|--force)|checkout\s+--\s|branch\s+-D)|dd\s+if=|mkfs|chmod\s+-R|chown\s+-R|truncate|shred|kill\s+-9|pkill|killall|drop\s+table|DELETE\s+FROM)\b/i;

  function riskOf(req) {
    const inp = req.input || {};
    if (req.toolName === 'Bash') {
      const cmd = String(inp.command || '');
      if (req.suppressAlwaysAllowRule || req.defaultToNo || DESTRUCTIVE.test(cmd)) return ['high', 'Destructive'];
      if (READ_CMD.test(cmd) || VERIFY_CMD.test(cmd)) return ['low', 'Shell · read-only'];
      return ['mid', 'Runs a command'];
    }
    if (/^(Edit|MultiEdit|Write|NotebookEdit)$/.test(req.toolName)) return [req.defaultToNo ? 'high' : 'mid', req.toolName === 'Write' ? 'Writes a file' : 'Edits a file'];
    if (req.defaultToNo || req.suppressAlwaysAllowRule) return ['high', 'Needs care'];
    return ['low', 'Reads'];
  }

  function bashTokens(line) {
    const out = [], re = /("(?:[^"\\]|\\.)*"|'[^']*')|(\s--?[\w-]+(?:=\S*)?)|(\s+)|([^\s"']+)/g;
    let m, first = true;
    while ((m = re.exec(line))) {
      if (m[1]) out.push(h('span', { class: 'ck-t-str', text: m[1] }));
      else if (m[2]) out.push(h('span', { class: 'ck-t-flag', text: m[2] }));
      else if (m[3]) out.push(m[3]);
      else { out.push(h('span', { class: first ? 'ck-t-cmd' : DESTRUCTIVE.test(m[4]) || /^(rm|-rf)$/.test(m[4]) ? 'ck-t-bad' : null, text: m[4] })); first = false; if (/^[|;&]+$/.test(m[4])) first = true; }
    }
    return out;
  }

  // ── file changes: the "now" view, a diff view, expand for big changes ──

  /** Line diff (LCS) of two texts: [['eq' | 'del' | 'add', line], …]. */
  function lineDiff(a, b) {
    const split = t => t ? String(t).replace(/\n$/, '').split('\n') : [];
    const A = split(a), B = split(b);
    let pre = 0;
    while (pre < A.length && pre < B.length && A[pre] === B[pre]) pre++;
    let suf = 0;
    while (suf < A.length - pre && suf < B.length - pre && A[A.length - 1 - suf] === B[B.length - 1 - suf]) suf++;
    const a1 = A.slice(pre, A.length - suf), b1 = B.slice(pre, B.length - suf);
    const ops = A.slice(0, pre).map(t => ['eq', t]);
    const n = a1.length, m = b1.length;
    if (n * m > 4e6) {
      // Too big to align: all old lines out, all new lines in.
      for (const t of a1) ops.push(['del', t]);
      for (const t of b1) ops.push(['add', t]);
    } else {
      const dp = Array.from({ length: n + 1 }, () => new Uint32Array(m + 1));
      for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) dp[i][j] = a1[i] === b1[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
      let i = 0, j = 0;
      while (i < n && j < m) {
        if (a1[i] === b1[j]) { ops.push(['eq', a1[i]]); i++; j++; }
        else if (dp[i + 1][j] >= dp[i][j + 1]) ops.push(['del', a1[i++]]);
        else ops.push(['add', b1[j++]]);
      }
      while (i < n) ops.push(['del', a1[i++]]);
      while (j < m) ops.push(['add', b1[j++]]);
    }
    for (const t of A.slice(A.length - suf)) ops.push(['eq', t]);
    return ops;
  }

  /** The file change a tool call makes, with its line diff (worked out once per input). */
  const changeCache = new WeakMap();
  function changeOf(name, inp) {
    if (!inp || typeof inp !== 'object') return null;
    if (changeCache.has(inp)) return changeCache.get(inp);
    let c = null;
    if (name === 'Write' && inp.content != null) c = { file: inp.file_path, write: true, edits: [['', String(inp.content)]] };
    else if (name === 'Edit' && inp.new_string != null) c = { file: inp.file_path, all: !!inp.replace_all, edits: [[inp.old_string || '', inp.new_string]] };
    else if (name === 'MultiEdit' && Array.isArray(inp.edits)) c = { file: inp.file_path, edits: inp.edits.map(e => [e.old_string || '', e.new_string || '']) };
    if (c) {
      c.ops = c.edits.map(([o, n]) => lineDiff(o, n));
      c.add = 0; c.del = 0;
      for (const ops of c.ops) for (const [k] of ops) { if (k === 'add') c.add++; else if (k === 'del') c.del++; }
    }
    changeCache.set(inp, c);
    return c;
  }
  const changeStats = (name, inp) => changeOf(name, inp) || { add: 0, del: 0 };

  const ln = (kind, text, num) => h('div', { class: 'ck-ln is-' + kind },
    num != null ? h('span', { class: 'ck-ln-no', text: String(num) }) : null,
    h('span', { class: 'ck-ln-m', text: kind === 'add' ? '+' : kind === 'del' ? '−' : ' ' }),
    text || ' ');

  /** A folded run of lines: one clickable line that opens them in place. */
  function foldRun(lines, kind, label) {
    const gap = h('div', { class: 'ck-ln-gap is-' + kind, role: 'button' });
    let shown = [];
    const paint = () => { gap.textContent = shown.length ? 'Hide' : label; };
    gap.onclick = () => {
      if (shown.length) { shown.forEach(e => e.remove()); shown = []; }
      else { shown = lines.map(t => ln(kind, t)); gap.after(...shown); }
      paint();
      const box = gap.closest('.ck-chg');
      if (box && box._fit) box._fit();
    };
    paint();
    return gap;
  }

  /** The edit as it reads after the change: new lines marked, removed lines folded to one line. */
  function nowLines(ops, numbered) {
    const out = [];
    let no = 0;
    for (let i = 0; i < ops.length;) {
      if (ops[i][0] === 'del') {
        let j = i;
        while (j < ops.length && ops[j][0] === 'del') j++;
        const n = j - i;
        out.push(foldRun(ops.slice(i, j).map(o => o[1]), 'del', `− ${n} line${n === 1 ? '' : 's'} removed`));
        i = j;
        continue;
      }
      no++;
      out.push(ln(numbered ? 'new' : ops[i][0], ops[i][1], numbered ? no : null));
      i++;
    }
    return out;
  }

  /** Unified diff; unchanged runs longer than 7 lines keep 3 lines of context each side. */
  function diffView(ops) {
    const out = [];
    for (let i = 0; i < ops.length;) {
      if (ops[i][0] !== 'eq') { out.push(ln(ops[i][0], ops[i][1])); i++; continue; }
      let j = i;
      while (j < ops.length && ops[j][0] === 'eq') j++;
      const run = ops.slice(i, j).map(o => o[1]);
      const head = i === 0 ? 0 : 3, tail = j === ops.length ? 0 : 3;
      if (run.length > head + tail + 1 && run.length > 7) {
        run.slice(0, head).forEach(t => out.push(ln('eq', t)));
        const mid = run.slice(head, run.length - tail);
        out.push(foldRun(mid, 'eq', `⋯ ${mid.length} unchanged lines`));
        run.slice(run.length - tail).forEach(t => out.push(ln('eq', t)));
      } else run.forEach(t => out.push(ln('eq', t)));
      i = j;
    }
    return out;
  }

  /**
   * The change view for Edit / MultiEdit / Write, in approval cards and in the
   * tool rows. "Now" first; "Diff" on request. The body scrolls; a change that
   * does not fit gets Expand, which makes the box taller (and a card wider).
   */
  function changeView(name, inp) {
    const c = changeOf(name, inp);
    if (!c) return null;
    let mode = 'now', big = false;
    const body = h('div', { class: 'ck-chg-body' });
    const seg = c.write ? null : h('div', { class: 'ck-seg ck-chg-seg' },
      [['now', 'Now'], ['diff', 'Diff']].map(([m, label]) => h('button', { type: 'button', class: 'ck-seg-b', 'data-m': m, text: label,
        onclick: e => { e.stopPropagation(); mode = m; paint(); } })));
    const expT = h('span', { class: 'ck-chg-exp-t', text: 'Expand' });
    const expand = h('button', { type: 'button', class: 'ck-chg-exp', hidden: true, title: 'Show more of the change' }, h('span', { class: 'sk-caret ck-chg-exp-ic' }), expT);
    const el = h('div', { class: 'ck-chg' },
      h('div', { class: 'ck-chg-head' },
        h('span', { class: 'ck-chg-file', text: rel(c.file), title: c.file }),
        c.write ? h('span', { class: 'ck-chg-tag', text: 'whole file' }) : null,
        c.all ? h('span', { class: 'ck-chg-tag', text: 'every match' }) : null,
        h('span', { class: 'ck-chg-stat' }, c.add ? h('span', { class: 'is-add', text: '+' + c.add }) : null, c.del ? h('span', { class: 'is-del', text: '−' + c.del }) : null),
        h('span', { class: 'ck-spacer' }), seg, expand),
      body);

    // A timer, not requestAnimationFrame: it has to run in a hidden or offscreen view too.
    const fit = () => setTimeout(() => {
      if (!body.clientHeight) return;   // still hidden (a folded row)
      const over = body.scrollHeight > body.clientHeight + 2 || body.scrollWidth > body.clientWidth + 2;
      expand.hidden = !over && !big;
    }, 0);
    el._fit = fit;
    function paint() {
      body.replaceChildren(h('div', { class: 'ck-chg-lines' }, c.ops.map((ops, i) => [
        c.ops.length > 1 ? h('div', { class: 'ck-ln-hunk', text: `Edit ${i + 1} of ${c.ops.length}` }) : null,
        mode === 'now' ? nowLines(ops, c.write) : diffView(ops)])));
      if (seg) seg.querySelectorAll('.ck-seg-b').forEach(b => b.classList.toggle('is-on', b.dataset.m === mode));
      fit();
    }
    expand.onclick = e => {
      e.stopPropagation();
      big = !big;
      el.classList.toggle('is-big', big);
      const card = el.closest('.ck-card');
      if (card) card.classList.toggle('is-wide', big);
      expT.textContent = big ? 'Collapse' : 'Expand';
      if (!big) el.scrollIntoView({ block: 'nearest' });
      fit();
    };
    paint();
    return el;
  }

  /** A row's detail was opened: its change view can now measure itself. */
  const fitChanges = root => root.querySelectorAll('.ck-chg').forEach(el => el._fit && el._fit());

  function preview(req) {
    const inp = req.input || {};
    if (req.toolName === 'Bash' && inp.command) {
      return h('div', { class: 'ck-cmd' }, String(inp.command).split('\n').map((l, i) => h('div', null, h('span', { class: 'ck-prompt', text: i ? '  ' : '$ ' }), bashTokens(l))));
    }
    const chg = changeView(req.toolName, inp);
    if (chg) return chg;
    const json = JSON.stringify(inp, null, 1);
    return json && json !== '{}' ? h('pre', { class: 'ck-json', text: json.length > 600 ? json.slice(0, 600) + '…' : json }) : null;
  }

  /** The "always allow" choice, from the permission suggestions Claude Code sent. */
  function alwaysChoice(req) {
    if (req.suppressAlwaysAllowRule || !req.suggestions || !req.suggestions.length) return null;
    const [, risk] = riskOf(req);
    if (risk === 'Destructive') return null;
    const rules = [], dests = new Set();
    let label = null;
    for (const s of req.suggestions) {
      dests.add(s.destination);
      if (s.type === 'addRules') for (const r of s.rules || []) rules.push(r.ruleContent ? `${r.toolName}(${r.ruleContent})` : r.toolName);
      if (s.type === 'setMode' && s.mode === 'acceptEdits') label = 'Yes, allow all edits this session';
      if (s.type === 'addDirectories') label = `Yes, and allow access to ${(s.directories || []).map(rel).join(', ')}`;
    }
    const where = dests.has('session') ? 'for this session' : dests.has('localSettings') || dests.has('projectSettings') ? 'for this project' : dests.has('userSettings') ? 'everywhere' : 'for this session';
    if (!label) label = rules.length ? `Yes, and don't ask again for ${rules.join(', ')}` : 'Yes, and don\'t ask again';
    return { label, rules, where };
  }

  function addCard(req) {
    closeRun();
    const [level, risk] = riskOf(req);
    const always = alwaysChoice(req);
    const title = req.title || (req.displayName ? `${req.displayName}${req.description ? ' ' + req.description : ''}` : req.toolName);
    const why = req.input && req.input.description ? String(req.input.description) : req.decisionReason || null;
    const opts = h('div', { class: 'ck-opts' });
    const card = h('div', { class: 'ck-card', 'data-risk': level },
      h('div', { class: 'ck-card-head' },
        h('span', { class: 'ck-risk' }, h('span', { class: 'ck-risk-dot' }), risk),
        h('span', { class: 'ck-card-title', text: title })),
      preview(req),
      why && h('div', { class: 'ck-why' }, h('span', { class: 'ck-why-k', text: 'Claude\'s reason · ' }), why),
      opts);
    const choose = (decision, message) => {
      if (card.dataset.done) return;
      card.dataset.done = '1';
      post({ type: 'permission', id: req.id, decision, message });
      resolveCard(req.id, decision === 'deny' ? 'denied' : decision === 'allowAlways' ? 'always' : 'allowed', always);
    };
    const btn = (key, label, fn, cls) => {
      const b = h('button', { class: 'ck-opt' + (cls ? ' ' + cls : ''), type: 'button' }, h('span', { class: 'ck-key', text: key }), label);
      b.onclick = fn;
      return b;
    };
    const keys = {};
    // A request marked defaultToNo gets no one-key approval (Claude Code's rule).
    const yes = btn(req.defaultToNo ? '' : '1', 'Yes', () => choose('allow'));
    opts.append(yes);
    if (!req.defaultToNo) keys['1'] = () => choose('allow');
    if (always) {
      opts.append(btn('2', always.label, () => choose('allowAlways')));
      keys['2'] = () => choose('allowAlways');
    }
    const noKey = always ? '3' : '2';
    const noBtn = btn(noKey, 'No, and tell Claude what to do differently', () => showNo(), 'is-no');
    opts.append(noBtn);
    keys[noKey] = () => showNo();
    const noForm = h('div', { class: 'ck-no', hidden: true });
    const noInput = h('textarea', { class: 'ck-no-input', rows: '2', placeholder: 'What should Claude do instead? (optional)' });
    const noSend = h('button', { class: 'sk-btn', type: 'button', text: 'Decline' });
    noForm.append(noInput, noSend);
    opts.append(noForm);
    const showNo = () => { noForm.hidden = false; noInput.focus(); };
    noSend.onclick = () => choose('deny', noInput.value.trim() || undefined);
    noInput.onkeydown = e => {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); noSend.click(); }
      if (e.key === 'Escape') { noForm.hidden = true; }
    };
    if (always && always.rules.length) opts.append(h('span', { class: 'ck-rule-hint' }, 'Always-allow adds ', h('code', { text: always.rules.join(', ') }), ' ' + always.where));
    if (req.defaultToNo || riskOf(req)[1] === 'Destructive') opts.append(h('span', { class: 'ck-rule-hint is-bad', text: 'Destructive: can only be allowed one time' }));
    turn().body.append(card);
    S.cards.set(req.id, { card, keys, req, opts });
    const row = req.toolUseID && S.rows.get(req.toolUseID);
    if (row) { row.waitStart = clock(); setRowState(row, 'waiting'); }
    updateStatus();
    stick();
    if (req.defaultToNo && inView()) noBtn.focus();
  }

  function resolveCard(id, outcome, always) {
    const c = S.cards.get(id);
    if (!c) return;
    S.cards.delete(id);
    const labels = { allowed: 'Allowed once', always: 'Allowed · rule added ' + (always ? always.where : ''), denied: 'Declined · Claude was told', cancelled: 'Cancelled by Claude' };
    c.opts.replaceWith(h('div', { class: 'ck-outcome', 'data-outcome': outcome },
      h('span', { class: 'ck-outcome-dot' }), labels[outcome] || outcome,
      outcome === 'always' && always && always.rules.length ? h('code', { text: always.rules.join(', ') }) : null));
    c.card.classList.add('is-resolved');
    const row = c.req.toolUseID && S.rows.get(c.req.toolUseID);
    if (row && row.waitStart) { row.waitMs += clock() - row.waitStart; row.waitStart = 0; setRowState(row, outcome === 'denied' || outcome === 'cancelled' ? 'error' : 'running'); }
    updateStatus();
  }

  document.addEventListener('keydown', e => {
    if (!S.cards.size || e.metaKey || e.ctrlKey || e.altKey) return;
    const t = e.target;
    if (t && (t.tagName === 'TEXTAREA' || t.tagName === 'INPUT') && t.value) return;
    const last = Array.from(S.cards.values()).pop();
    const fn = last.keys[e.key];
    if (fn) { e.preventDefault(); fn(); }
  });

  // ── permission modes, models, effort ───────────────────────────────────

  const MODE_INFO = [
    { mode: 'default', label: 'Ask', desc: 'Asks before it edits files or runs commands' },
    { mode: 'acceptEdits', label: 'Accept edits', desc: 'Edits files without asking; asks before commands' },
    { mode: 'plan', label: 'Plan', desc: 'Reads and plans only; changes nothing' },
    { mode: 'auto', label: 'Auto', desc: 'A classifier approves safe actions and asks about risky ones' }
  ];
  const MODE_LABEL = { default: 'Ask', acceptEdits: 'Accept edits', plan: 'Plan', auto: 'Auto', bypassPermissions: 'Bypass', dontAsk: "Don't ask" };

  /** claude-opus-5-5[1m] → "Opus 5.5 · 1M"; anything unexpected stays as-is. */
  function modelLabel(id) {
    if (!id) return '';
    const m = String(id).match(/^claude-([a-z]+)-(\d+)(?:-(\d+))?(?:-\d{8})?(\[1m\])?$/i);
    if (!m) return String(id);
    return m[1][0].toUpperCase() + m[1].slice(1) + ' ' + m[2] + (m[3] ? '.' + m[3] : '') + (m[4] ? ' · 1M' : '');
  }

  /** The model menu row in use: the one picked, else the one the session runs. */
  function currentModelRow() {
    if (S.modelChoice) { const r = S.models.find(m => m.value === S.modelChoice); if (r) return r; }
    return S.models.find(m => m.resolvedModel === S.model || m.value === S.model) || null;
  }
  const modes = () => {
    const row = currentModelRow();
    return MODE_INFO.filter(m => m.mode !== 'auto' || !row || row.supportsAutoMode !== false || S.mode === 'auto');
  };

  function setMode(mode) {
    if (mode === S.mode) return;
    S.mode = mode; paintMeta();
    post({ type: 'setPermissionMode', mode });
  }

  function setModel(value) {
    const row = S.models.find(m => m.value === value);
    S.modelChoice = value;
    S.model = row ? (row.resolvedModel || row.value) : value;
    // An effort level the new model does not have falls back to its default.
    if (S.effort && row && !(row.supportedEffortLevels || []).includes(S.effort)) setEffort(null);
    paintMeta();
    post({ type: 'setModel', model: value });
  }

  function setEffort(effort) {
    S.effort = effort || null; paintMeta();
    post({ type: 'setEffort', effort: S.effort || '' });
  }

  function paintMeta() {
    if (!inView()) return;
    // "Opus 5.5" stays; " · 1M · high" is the part a narrow panel drops.
    const [name, ...extra] = (modelLabel(S.model) || 'Model').split(' · ');
    if (S.effort) extra.push(S.effort);
    modelEl.firstChild.replaceChildren(name, extra.length ? h('span', { class: 'ck-model-x', text: ' · ' + extra.join(' · ') }) : '');
    modeBtn.firstChild.textContent = MODE_LABEL[S.mode] || S.mode;
    modeBtn.dataset.mode = S.mode;
    const pct = S.ctx && S.ctx.maxTokens ? Math.round(S.ctx.totalTokens / S.ctx.maxTokens * 100) : null;
    costEl.firstChild.textContent = [S.cost ? '$' + S.cost.toFixed(2) : null, pct != null ? pct + '%' : null].filter(Boolean).join(' · ') || 'Usage';
    costEl.title = 'Usage: session cost, context, plan limits' + (pct != null ? ` (context ${pct}% full)` : '');
    costEl.dataset.level = pct == null ? '' : pct >= 80 ? 'bad' : pct >= 60 ? 'warn' : '';
    if (!usagePanel.hidden) paintUsage();
    if (P.kind === 'model' || P.kind === 'mode') refreshPop();
  }

  // ── menus: one popover for the model menu, the mode menu and slash suggestions ──

  const P = { kind: null, items: [], sel: -1, anchor: null, build: null };

  /**
   * Opens the popover. `build()` returns { head?, items, foot? } and runs again
   * on refreshPop(); an item is { title, desc?, side?, current?, run, mono? }.
   */
  function openPop(kind, anchor, build) {
    P.kind = kind; P.anchor = anchor; P.build = build; P.sel = -1;
    popEl.hidden = false;
    refreshPop();
  }

  function closePop() {
    if (!P.kind) return;
    P.kind = null; P.items = []; P.build = null;
    popEl.hidden = true; popEl.replaceChildren();
    modelEl.classList.remove('is-open'); modeBtn.classList.remove('is-open');
    if (moreBtn) moreBtn.classList.remove('is-open');
    if (viewMenuBtn) viewMenuBtn.classList.remove('is-open');
  }

  function refreshPop() {
    if (!P.kind) return;
    const { head, items, foot, empty } = P.build();
    if (!items.length && !head && !foot) { closePop(); return; }
    P.items = items;
    if (P.sel < 0 || P.sel >= items.length) P.sel = Math.max(0, items.findIndex(i => i.current));
    if (!items.length) P.sel = -1;
    const list = h('div', { class: 'ck-pop-list', role: 'listbox' }, items.map((it, i) => {
      const el = h('div', { class: 'ck-pop-item' + (i === P.sel ? ' is-sel' : '') + (it.current ? ' is-current' : ''), role: 'option' },
        h('span', { class: 'ck-pop-check' }),
        h('span', { class: 'ck-pop-main' },
          h('span', { class: 'ck-pop-title' + (it.mono ? ' is-mono' : '') }, it.title),
          it.desc ? h('span', { class: 'ck-pop-desc', text: it.desc }) : null),
        it.side ? h('span', { class: 'ck-pop-side' }, it.side) : null);
      el.onmousedown = e => e.preventDefault();   // keep the focus in the composer
      el.onclick = () => { P.sel = i; pickPop(false); };
      el.onmousemove = () => { if (P.sel !== i) { P.sel = i; markSel(); } };
      return el;
    }));
    popEl.replaceChildren(...[head ? h('div', { class: 'ck-pop-head' }, head) : null, items.length ? list : empty ? h('div', { class: 'ck-pop-empty', text: empty }) : null, foot].filter(Boolean));
    popEl.dataset.kind = P.kind;
    placePop();
    markSel();
  }

  function markSel() {
    const els = popEl.querySelectorAll('.ck-pop-item');
    els.forEach((el, i) => el.classList.toggle('is-sel', i === P.sel));
    const el = els[P.sel];
    if (el) el.scrollIntoView({ block: 'nearest' });
  }

  /** Above the composer for suggestions; above the status line, right-aligned to its chip, for menus. */
  function placePop() {
    const box = dockIn.getBoundingClientRect();
    if (P.kind === 'slash') {
      popEl.style.left = '0'; popEl.style.right = '0';
      popEl.style.bottom = (box.bottom - composer.getBoundingClientRect().top + 6) + 'px';
    } else {
      const a = P.anchor.getBoundingClientRect();
      if (a.left - box.left < box.width / 2) {   // near the left edge: open rightwards
        popEl.style.right = 'auto';
        popEl.style.left = Math.max(a.left - box.left, 0) + 'px';
      } else {
        popEl.style.left = 'auto';
        popEl.style.right = Math.max(box.right - a.right, 0) + 'px';
      }
      popEl.style.bottom = (box.bottom - a.top + 6) + 'px';
    }
    const popBottom = box.bottom - parseFloat(popEl.style.bottom);   // viewport y of the popover's bottom edge
    popEl.style.maxHeight = Math.max(Math.min(popBottom - 8, 300), 96) + 'px';
  }

  function pickPop(completeOnly) {
    const it = P.items[P.sel];
    if (it) it.run(completeOnly);
  }

  /** Popover keys. Returns true when the key was used. */
  function popKey(e) {
    if (!P.kind) return false;
    const n = P.items.length;
    if (e.key === 'Escape') { closePop(); return true; }
    if (e.key === 'ArrowDown' && n) { P.sel = (P.sel + 1) % n; markSel(); return true; }
    if (e.key === 'ArrowUp' && n) { P.sel = (P.sel - 1 + n) % n; markSel(); return true; }
    if ((e.key === 'Enter' && !e.shiftKey) && n) { pickPop(false); return true; }
    if (e.key === 'Tab' && !e.shiftKey && n) { pickPop(true); return true; }
    if (P.kind === 'model' && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) { stepEffort(e.key === 'ArrowRight' ? 1 : -1); return true; }
    return false;
  }

  function openModelMenu() {
    if (P.kind === 'model') { closePop(); return; }
    modelEl.classList.add('is-open');
    openPop('model', modelEl, () => {
      const cur = currentModelRow();
      const items = S.models.map(m => ({
        title: m.displayName, desc: m.description, current: cur ? m.value === cur.value : false,
        side: m.value === 'default' ? null : h('code', { class: 'ck-pop-val', text: m.value }),
        run: () => { setModel(m.value); closePop(); input.focus(); }
      }));
      return {
        head: 'Model',
        items,
        empty: 'Models appear when the session has started.',
        foot: cur && cur.supportsEffort ? effortRow(cur) : null
      };
    });
  }

  const EFFORT_ORDER = ['low', 'medium', 'high', 'xhigh', 'max'];
  function effortRow(row) {
    const levels = (row.supportedEffortLevels || EFFORT_ORDER);
    return h('div', { class: 'ck-effort' },
      h('span', { class: 'ck-effort-k', text: 'Effort' }),
      h('div', { class: 'ck-seg' },
        h('button', { type: 'button', class: 'ck-seg-b' + (!S.effort ? ' is-on' : ''), text: 'default', onmousedown: e => e.preventDefault(), onclick: () => setEffort(null) }),
        levels.map(l => h('button', { type: 'button', class: 'ck-seg-b' + (S.effort === l ? ' is-on' : ''), text: l, onmousedown: e => e.preventDefault(), onclick: () => setEffort(l) }))),
      h('span', { class: 'ck-effort-hint', text: '← →' }));
  }
  function stepEffort(d) {
    const row = currentModelRow();
    if (!row || !row.supportsEffort) return;
    const opts = [null, ...(row.supportedEffortLevels || EFFORT_ORDER)];
    const i = Math.min(Math.max(opts.indexOf(S.effort) + d, 0), opts.length - 1);
    if (opts[i] !== S.effort) setEffort(opts[i]);
  }

  function openModeMenu() {
    if (P.kind === 'mode') { closePop(); return; }
    modeBtn.classList.add('is-open');
    openPop('mode', modeBtn, () => ({
      head: h('span', null, 'Permission mode', h('span', { class: 'ck-pop-head-k', text: '⇧Tab cycles' })),
      items: modes().map(m => ({
        title: h('span', { class: 'ck-mode-dot', 'data-mode': m.mode }, m.label), desc: m.desc, current: m.mode === S.mode,
        run: () => { setMode(m.mode); closePop(); input.focus(); }
      }))
    }));
  }

  function cycleMode() {
    const list = modes().map(m => m.mode);
    setMode(list[(list.indexOf(S.mode) + 1) % list.length]);
  }

  // ── usage: a chip in the status line that opens a panel ───────────────

  const fmtTok = n => n >= 1e6 ? (n / 1e6).toFixed(n >= 1e7 ? 0 : 1).replace(/\.0$/, '') + 'M' : n >= 1e3 ? (n / 1e3).toFixed(n >= 1e4 ? 0 : 1).replace(/\.0$/, '') + 'k' : String(n || 0);
  const LIMIT_LABEL = { session: 'Session · 5h', weekly_all: 'Weekly', weekly_opus: 'Weekly · Opus', weekly_sonnet: 'Weekly · Sonnet' };

  function resetsIn(iso) {
    if (!iso) return '';
    const d = new Date(iso), ms = d - Date.now();
    if (!(ms > 0)) return 'resets soon';
    const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    if (ms < 20 * 3600e3) { const hrs = Math.floor(ms / 3600e3), min = Math.round(ms % 3600e3 / 60e3); return `resets in ${hrs ? hrs + 'h ' : ''}${min}m · ${time}`; }
    return 'resets ' + d.toLocaleDateString([], { weekday: 'short' }) + ' ' + time;
  }

  const meter = (pct, level) => h('span', { class: 'ck-meter', 'data-level': level || (pct >= 80 ? 'bad' : pct >= 60 ? 'warn' : '') },
    h('span', { class: 'ck-meter-fill', style: `width:${Math.min(Math.max(pct, 0), 100)}%` }));

  function toggleUsage(open) {
    const show = open != null ? open : usagePanel.hidden;
    usagePanel.hidden = !show;
    costEl.classList.toggle('is-open', show);
    closePop();
    if (show) { requestUsage(true); paintUsage(); }
    stick();
  }

  function requestUsage(plan) {
    // Plan limits cost a network call: at most once a minute.
    const withPlan = plan && Date.now() - S.planAt > 60e3;
    if (withPlan) SHARED.planAt = Date.now();
    post({ type: 'usage', plan: withPlan });
  }

  function paintUsage() {
    const u = S.modelUsage ? Object.entries(S.modelUsage) : [];
    const sum = k => u.reduce((a, [, m]) => a + (m[k] || 0), 0);
    const session = h('div', { class: 'ck-u-col' },
      h('div', { class: 'ck-u-k', text: 'Session' }),
      h('div', { class: 'ck-u-big', text: '$' + (S.cost || 0).toFixed(2) }),
      h('div', { class: 'ck-u-line', text: [S.turns_n ? S.turns_n + (S.turns_n === 1 ? ' turn' : ' turns') : null, S.apiMs ? (S.apiMs / 1000).toFixed(1) + 's API' : null].filter(Boolean).join(' · ') || 'No turns yet' }),
      u.length ? h('div', { class: 'ck-u-line', text: `in ${fmtTok(sum('inputTokens'))} · out ${fmtTok(sum('outputTokens'))} · cache ${fmtTok(sum('cacheReadInputTokens') + sum('cacheCreationInputTokens'))}` }) : null,
      u.length > 1 ? u.map(([id, m]) => h('div', { class: 'ck-u-line is-sub' }, h('span', { text: modelLabel(id) }), h('span', { text: '$' + (m.costUSD || 0).toFixed(2) }))) : null);

    let context;
    if (S.ctx && S.ctx.maxTokens) {
      const c = S.ctx, pct = c.totalTokens / c.maxTokens * 100;
      const used = (c.categories || []).filter(x => x.kind === 'used' && x.tokens > 0).sort((a, b) => b.tokens - a.tokens);
      context = h('div', { class: 'ck-u-col' },
        h('div', { class: 'ck-u-k', text: 'Context' }),
        h('div', { class: 'ck-u-big' }, fmtTok(c.totalTokens), h('span', { class: 'ck-u-of', text: ' / ' + fmtTok(c.maxTokens) })),
        meter(pct),
        h('div', { class: 'ck-u-line', text: `${pct < 1 ? '<1' : Math.round(pct)}% full` + (c.isAutoCompactEnabled && c.autoCompactThreshold ? ` · compacts at ${fmtTok(c.autoCompactThreshold)}` : '') }),
        used.slice(0, 3).map(x => h('div', { class: 'ck-u-line is-sub' }, h('span', { text: x.name }), h('span', { text: fmtTok(x.tokens) }))));
    } else context = h('div', { class: 'ck-u-col' }, h('div', { class: 'ck-u-k', text: 'Context' }), h('div', { class: 'ck-u-line', text: 'Loading…' }));

    let plan = null;
    if (S.plan && S.plan.available && S.plan.limits.length) {
      plan = h('div', { class: 'ck-u-col' },
        h('div', { class: 'ck-u-k', text: 'Plan limits' + (S.plan.subscription ? ' · ' + S.plan.subscription : '') }),
        S.plan.limits.slice(0, 4).map(l => h('div', { class: 'ck-u-limit' + (l.is_active ? ' is-active' : '') },
          h('div', { class: 'ck-u-line' }, h('span', { text: LIMIT_LABEL[l.kind] || l.kind.replace(/_/g, ' ') }), h('span', { class: 'ck-u-pct', text: Math.round(l.percent) + '%' })),
          meter(l.percent, l.severity && l.severity !== 'normal' ? 'bad' : null),
          h('div', { class: 'ck-u-line is-faint', text: resetsIn(l.resets_at) }))));
    }
    usagePanel.replaceChildren(...[session, context, plan].filter(Boolean));
  }

  // ── slash commands ─────────────────────────────────────────────────────

  /** Commands the page runs itself (they need a menu, or leave the page). */
  const LOCAL_CMDS = [
    { name: 'tui', description: 'Open this session in the Claude Code TUI', argumentHint: '', local: true },
    { name: 'resume', aliases: ['continue'], description: 'Resume a conversation from this folder', argumentHint: '[search]', local: true },
    { name: 'exit', aliases: ['quit'], description: 'Close this tab (in a side chat: close the side chat)', argumentHint: '', local: true }
  ];
  const HIDDEN_CMD = c => c.name.startsWith('__') || /^\((removed)\)|^Renamed to /.test(c.description || '') || S.terminalCmds.has(c.name);

  const commandList = () => {
    const seen = new Set(), out = [];
    for (const c of [...LOCAL_CMDS, ...S.commands]) {
      if (seen.has(c.name) || HIDDEN_CMD(c)) continue;
      seen.add(c.name); out.push(c);
    }
    return out;
  };
  const findCmd = name => { const n = name.toLowerCase(); const list = commandList(); return list.find(c => c.name.toLowerCase() === n) || list.find(c => (c.aliases || []).some(a => a.toLowerCase() === n)); };

  function rankCommands(q) {
    q = q.toLowerCase();
    const out = [];
    for (const c of commandList()) {
      const n = c.name.toLowerCase(), al = (c.aliases || []).map(a => a.toLowerCase());
      let score = -1, via = null;
      if (!q) score = 1;
      else if (n === q) score = 100;
      else if (n.startsWith(q)) score = 80;
      else if (al.some(a => a.startsWith(q))) { score = 70; via = c.aliases[al.findIndex(a => a.startsWith(q))]; }
      else if (n.split(/[-:_]/).some(w => w.startsWith(q))) score = 60;
      else if (n.includes(q)) score = 45;
      else if (q.length > 2 && (c.description || '').toLowerCase().includes(q)) score = 20;
      if (score >= 0) out.push({ c, score, via });
    }
    // A bare "/" lists everything A–Z; a query puts the closest names first.
    return out.sort((a, b) => b.score - a.score || (q ? a.c.name.length - b.c.name.length : 0) || a.c.name.localeCompare(b.c.name));
  }

  /** `[low|high] [--fix] <file>` → ['[low|high]', '[--fix]', '<file>']; `consent | revoke` stays one group. */
  const hintGroups = hint => String(hint || '').match(/\[[^\]]*\]|\([^)]*\)|<[^>]*>|[^\s[(<|]+(?:\s*\|\s*[^\s[(<|]+)*/g) || [];
  function groupChoices(g) {
    const inner = g.replace(/^[[(<]|[\])>]$/g, '');
    if (/^</.test(g)) return [];
    const alts = inner.split('|').map(a => a.trim()).filter(Boolean);
    if (alts.length === 1 && !/^--?\w/.test(alts[0])) return [];   // a lone placeholder, e.g. [prompt]
    return alts.filter(a => /^--?[\w-]+$|^[\w.@:-]+$/.test(a) && !/^[A-Z]/.test(a));
  }

  /** Argument choices for `cmd`, given the arguments already typed. */
  function argChoices(cmd, prior) {
    const n = cmd.name;
    if (n === 'model' && !prior.length) return S.models.map(m => ({ value: m.value, desc: m.displayName + (m.description ? ' — ' + m.description : '') }));
    if (n === 'effort' && !prior.length) { const r = currentModelRow(); return ((r && r.supportedEffortLevels) || EFFORT_ORDER).concat('auto').map(v => ({ value: v })); }
    if (n === 'output-style' && !prior.length) return S.outputStyles.map(v => ({ value: v }));
    const used = new Set(prior);
    const out = [];
    for (const g of hintGroups(cmd.argumentHint)) {
      const alts = groupChoices(g);
      if (alts.some(a => used.has(a))) continue;
      for (const a of alts) out.push({ value: a });
    }
    return out;
  }

  /** What the composer is asking for: a command name, an argument, or nothing. */
  function slashState() {
    const v = input.value, caret = input.selectionStart;
    if (!v.startsWith('/') || v.includes('\n') || caret !== input.selectionEnd) return null;
    const upto = v.slice(0, caret);
    const nameOnly = upto.match(/^\/(\S*)$/);
    if (nameOnly) return { stage: 'name', query: nameOnly[1] };
    const m = upto.match(/^\/(\S+)\s+(.*)$/);
    if (!m) return null;
    const cmd = findCmd(m[1]);
    if (!cmd) return null;
    const parts = m[2].split(/\s+/);
    const query = parts.pop();
    return { stage: 'arg', cmd, query, prior: parts.filter(Boolean), start: caret - query.length };
  }

  function updateSlash() {
    const st = slashState();
    if (!st) { if (P.kind === 'slash') closePop(); return; }
    if (P.kind !== 'slash') openPop('slash', composer, buildSlash);
    else { P.sel = -1; refreshPop(); }
  }

  const mark = (text, q) => {
    const i = q ? text.toLowerCase().indexOf(q.toLowerCase()) : -1;
    return i < 0 ? text : [text.slice(0, i), h('b', { text: text.slice(i, i + q.length) }), text.slice(i + q.length)];
  };

  function buildSlash() {
    const st = slashState();
    if (!st) return { items: [] };
    if (st.stage === 'name') {
      const ranked = rankCommands(st.query).slice(0, 40);
      return {
        items: ranked.map(({ c, via }) => ({
          mono: true,
          title: ['/', mark(c.name, st.query), c.argumentHint ? h('span', { class: 'ck-pop-hint', text: ' ' + c.argumentHint }) : null],
          desc: (via ? `/${via} · ` : '') + (c.description || ''),
          side: !c.builtin && !c.local ? h('span', { class: 'ck-pop-tag', text: c.name.includes(':') ? 'plugin' : 'skill' }) : null,
          run: completeOnly => {
            input.value = '/' + c.name + ' ';
            input.setSelectionRange(input.value.length, input.value.length);
            grow();
            // Return on a command that takes nothing runs it, as the TUI does.
            if (!completeOnly && !c.argumentHint && !argChoices(c, []).length) { submit(); return; }
            updateSlash(); updateStatus();
          }
        })),
        empty: st.query ? `No command matches /${st.query}` : 'Commands appear when the session has started.'
      };
    }
    const { cmd, query, prior, start } = st;
    if (cmd.name === 'resume') { requestSessions(); return resumeItems([...prior, query].join(' ')); }
    const q = query.toLowerCase();
    const choices = argChoices(cmd, prior).filter(ch => !q || ch.value.toLowerCase().startsWith(q) && ch.value.toLowerCase() !== q);
    const groups = hintGroups(cmd.argumentHint);
    const head = h('span', { class: 'ck-pop-sig' }, '/' + cmd.name + ' ',
      groups.map((g, i) => h('span', { class: i === prior.length ? 'is-now' : null, text: g + ' ' })),
      cmd.description ? h('span', { class: 'ck-pop-sig-desc', text: cmd.description }) : null);
    if (!groups.length && !choices.length) return { items: [] };
    return {
      head,
      items: choices.slice(0, 40).map(ch => ({
        mono: true, title: mark(ch.value, query), desc: ch.desc || null,
        run: () => {
          input.value = input.value.slice(0, start) + ch.value + ' ' + input.value.slice(input.selectionEnd).replace(/^\s+/, '');
          const at = start + ch.value.length + 1;
          input.setSelectionRange(at, at);
          grow(); updateSlash(); updateStatus();
        }
      }))
    };
  }

  /** Slash commands the page handles itself; true when `text` was one of them. */
  function runLocal(text) {
    const m = text.match(/^\/(\S+)(?:\s+(.*))?$/);
    if (!m) return false;
    const cmd = findCmd(m[1]);
    const name = cmd ? cmd.name : m[1].toLowerCase();
    const arg = (m[2] || '').trim();
    if (name === 'tui') { post({ type: 'openTUI', busy: S.busy }); return true; }
    if (name === 'resume') {
      const list = SHARED.sessions ? SHARED.sessions.list : [];
      const hit = arg && (list.find(x => x.id === arg) || list.find(x => arg.length >= 6 && x.id.startsWith(arg)));
      if (hit) resumeSession(hit.id, hit.title || hit.firstPrompt);
      else if (/^[0-9a-f-]{36}$/i.test(arg)) resumeSession(arg, null);
      else { input.value = '/resume ' + arg; input.setSelectionRange(input.value.length, input.value.length); grow(); updateSlash(); }
      return true;
    }
    if (name === 'exit') { if (active !== main) closeSide(active); else post({ type: 'close' }); return true; }
    if (name === 'model' && !arg) { openModelMenu(); return true; }
    if (name === 'model') { setModel(arg); notice('info', `Model set to ${arg}.`); return true; }
    if (name === 'effort' && !arg) { openModelMenu(); return true; }
    if (name === 'effort' && [...EFFORT_ORDER, 'auto'].includes(arg)) { setEffort(arg === 'auto' ? null : arg); notice('info', `Effort set to ${arg === 'auto' ? 'the model default' : arg}.`); return true; }
    if (name === 'usage' && !arg) { toggleUsage(true); return true; }
    return false;
  }

  // ── references: selected reply text, sent with the next message ───────

  /**
   * Claude reads this with each referenced passage; the user sees only the
   * chips. It says where the text came from, so the reply keeps to that thread.
   */
  const REF_NOTE = 'The user selected the passage(s) below from your earlier replies in this conversation and referenced them in this message.';

  function withRefs(text, refs) {
    const q = v => String(v).replace(/"/g, "'").replace(/\s+/g, ' ').slice(0, 160);
    const blocks = refs.map(r => `<referenced_text${r.from ? ` from_reply_to="${q(r.from)}"` : ''}>\n${r.text}\n</referenced_text>`);
    return `${REF_NOTE}\n\n${blocks.join('\n\n')}\n\n${text || '(The user sent only the referenced text.)'}`;
  }

  /** The current selection, when it lies inside one of Claude's turns. */
  function selectionRef() {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
    const text = sel.toString().replace(/\u00a0/g, ' ').trim();
    if (text.length < 2) return null;
    const range = sel.getRangeAt(0);
    const node = range.commonAncestorContainer;
    const el = node.nodeType === 1 ? node : node.parentElement;
    const body = el && el.closest('.ck-body');
    if (!body) return null;
    const prompt = body.closest('.ck-turn').querySelector('.ck-user-text');
    return { text, from: prompt ? prompt.textContent : null, range };
  }

  /** Puts the button under the end of the selection (above it, near the dock). */
  function placeRefBtn() {
    const r = selectionRef();
    if (!r) { refBtn.hidden = true; return; }
    const rects = r.range.getClientRects();
    if (!rects.length) { refBtn.hidden = true; return; }
    const first = rects[0], last = rects[rects.length - 1];
    refBtn.hidden = false;
    const w = refBtn.offsetWidth, hgt = refBtn.offsetHeight;
    const dockTop = dock.getBoundingClientRect().top;
    let top = last.bottom + 6;
    if (top + hgt > dockTop - 4) top = first.top - hgt - 6;
    top = Math.max(4, Math.min(top, dockTop - hgt - 4));
    const left = Math.max(8, Math.min(last.right - w / 2, window.innerWidth - w - 8));
    refBtn.style.top = top + 'px';
    refBtn.style.left = left + 'px';
  }

  function referenceSelection() {
    const r = selectionRef();
    if (!r) return;
    if (!S.refs.some(x => x.text === r.text)) S.refs.push({ text: r.text, from: r.from });
    window.getSelection().removeAllRanges();
    refBtn.hidden = true;
    paintRefs(); updateStatus();
    input.focus();
  }

  const refPreview = t => t.replace(/\s+/g, ' ').slice(0, 240);
  function refChip(r, onRemove) {
    const lines = r.text.split('\n').filter(l => l.trim()).length;
    return h('span', { class: 'ck-ref', title: r.text.length > 600 ? r.text.slice(0, 600) + '…' : r.text },
      h('span', { class: 'ck-ref-text', text: refPreview(r.text) }),
      lines > 1 ? h('span', { class: 'ck-ref-n', text: lines + ' lines' }) : null,
      onRemove ? h('button', { class: 'ck-ref-x', type: 'button', title: 'Remove', onmousedown: e => e.preventDefault(), onclick: onRemove }) : null);
  }

  function paintRefs() {
    if (!inView()) return;
    refsEl.replaceChildren(...S.refs.map((r, i) => refChip(r, () => { S.refs.splice(i, 1); paintRefs(); updateStatus(); input.focus(); })));
    refsEl.hidden = !S.refs.length;
    input.placeholder = S.refs.length ? 'Say what to do with it…  (⌫ removes the last one)' : 'Message Claude…  / for commands · ⇧↩ new line';
    if (P.kind) placePop();
  }

  // ── where the session runs: folder and git branch, and the ⋮ menu ─────

  const ICON_BRANCH = '<svg viewBox="0 0 16 16" width="11" height="11" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" d="M5 2.5v11M5 10.5c0-3 6-2.5 6-6"/><circle cx="5" cy="13" r="1.6" fill="currentColor"/><circle cx="5" cy="3" r="1.6" fill="currentColor"/><circle cx="11" cy="4" r="1.6" fill="currentColor"/></svg>';
  const icon = svg => { const s = h('span', { class: 'ck-ic-svg' }); s.innerHTML = svg; return s; };   // static markup only
  const baseName = p => String(p || '').replace(/\/+$/, '').split('/').pop() || '/';
  const tilde = p => { p = String(p || ''); return S.home && (p === S.home || p.startsWith(S.home + '/')) ? '~' + p.slice(S.home.length) : p; };
  /** ~/Desktop/development/Hobby/FloatyTerm → ~/…/Hobby/FloatyTerm once it is too long for the menu. */
  const shortPath = p => { const t = tilde(p), parts = t.split('/'); return t.length <= 30 || parts.length < 4 ? t : parts[0] + '/…/' + parts.slice(-2).join('/'); };
  const plural = (n, one, many) => n + ' ' + (n === 1 ? one : (many || one + 's'));

  const requestGit = () => post({ type: 'git' });

  function paintContext() {
    const g = S.git;
    const kids = [h('span', { class: 'ck-ctx-dir', text: baseName(S.cwd) })];
    if (g && g.repo && g.branch) {
      kids.push(h('span', { class: 'ck-ctx-branch' }, icon(ICON_BRANCH), h('span', { class: 'ck-ctx-b', text: g.branch })));
      if (g.changed) kids.push(h('span', { class: 'ck-ctx-dirty', title: plural(g.changed, 'changed file') }));
    }
    ctxEl.replaceChildren(...kids);
    ctxEl.title = [tilde(S.cwd), g && g.branch ? `on ${g.branch}` + (g.changed ? ` · ${plural(g.changed, 'change')}` : '') : null].filter(Boolean).join('\n');
    if (P.kind === 'more') refreshPop();
  }

  function infoRow(k, v, cls) { return v ? h('div', { class: 'ck-info-row' + (cls ? ' ' + cls : '') }, h('span', { class: 'ck-info-k', text: k }), h('span', { class: 'ck-info-v' }, v)) : null; }

  function moreInfo() {
    const g = S.git, i = S.info;
    let branch = null, changes = null, commit = null;
    if (g && g.repo) {
      branch = h('span', { class: 'ck-info-strong', title: g.branch + (g.upstream ? ' → ' + g.upstream : ''), text: (g.branch || '?') + (g.detached ? ' (detached)' : '') });
      changes = [g.changed ? [g.changed + ' changed', g.staged ? ` · ${g.staged} staged` : '', g.untracked ? ` · ${g.untracked} new` : ''].join('') : 'clean',
        g.ahead ? ` · ↑${g.ahead}` : '', g.behind ? ` · ↓${g.behind}` : ''].join('');
      if (g.last) commit = h('span', { title: `${g.last.sha} ${g.last.subject} (${g.last.when})` }, h('code', { text: g.last.sha }), ' ' + g.last.subject);
    } else if (g) branch = h('span', { class: 'ck-info-dim', text: 'not a git repository' });
    const mcp = (i.mcp || []);
    const mcpBad = mcp.filter(m => m.status !== 'connected');
    const mcpText = mcp.length ? plural(mcp.length, 'server') + (mcpBad.length ? ` · ${mcpBad.length} not connected` : ' · all connected') : null;
    return h('div', { class: 'ck-info' },
      infoRow('Folder', h('span', { title: S.cwd, text: shortPath(S.cwd) }), 'is-path'),
      infoRow('Branch', branch),
      infoRow('Changes', changes),
      infoRow('Commit', commit),
      infoRow('MCP', mcpText ? h('span', { title: mcp.map(m => `${m.name}: ${m.status}`).join('\n'), text: mcpText }) : null),
      infoRow('Session', S.sessionId || i.version ? [S.sessionId ? h('code', { text: S.sessionId.slice(0, 8) }) : null,
        i.version ? h('span', { class: 'ck-info-dim', text: (S.sessionId ? ' · ' : '') + 'Claude Code ' + i.version + (i.outputStyle && i.outputStyle !== 'default' ? ' · ' + i.outputStyle : '') }) : null] : null));
  }

  const THINK_SOURCE = { settings: 'From your settings (/config)', default: 'Claude Code default', user: 'Set in this tab' };

  /** "Show thinking": a switch that stays in the menu, so you see it flip. */
  function thinkingItem() {
    const on = !!S.thinkingOn, known = S.thinkingOn != null;
    return {
      title: 'Show thinking',
      desc: known ? THINK_SOURCE[S.thinkingSource] || null : 'Known when the session has started',
      side: h('span', { class: 'ck-switch' + (on ? ' is-on' : '') + (known ? '' : ' is-unknown'), role: 'switch', 'aria-checked': String(on) }),
      run: () => {
        if (!known) return;
        S.thinkingOn = !on; S.thinkingSource = 'user';
        post({ type: 'setThinking', on: !on });
        refreshPop();
      }
    };
  }

  function openMoreMenu() {
    if (P.kind === 'more') { closePop(); return; }
    moreBtn.classList.add('is-open');
    requestGit();
    const act = (title, desc, fn) => ({ title, desc, run: () => { closePop(); fn(); } });
    openPop('more', moreBtn, () => ({
      head: moreInfo(),
      items: [
        thinkingItem(),
        act('Copy path', null, () => post({ type: 'copy', text: S.cwd })),
        act('Reveal in Finder', null, () => post({ type: 'reveal', path: S.cwd })),
        S.sessionId ? act('Copy session ID', null, () => post({ type: 'copy', text: S.sessionId })) : null,
        act('Resume a conversation…', null, () => {
          if (active !== main) showConv(main);
          input.value = '/resume '; input.setSelectionRange(8, 8); input.focus(); grow(); updateSlash();
        }),
        act('Open in TUI', null, () => post({ type: 'openTUI', busy: S.busy })),
        act('New side chat', null, () => newSide()),
        active !== main ? act('Close this side chat', null, () => closeSide(active)) : null,
        act('Compact conversation', null, () => sendUser('/compact')),
        act('New conversation', null, () => sendUser('/clear'))
      ].filter(Boolean)
    }));
  }

  // ── side chats: forks of main, shown one full view at a time ──────────

  const ICON_SIDE = '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><rect x="1.5" y="2.5" width="9" height="7" rx="2" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M6.5 12.5h6a2 2 0 0 0 2-2V7" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>';
  const ICON_BACK = '<svg viewBox="0 0 16 16" width="11" height="11" aria-hidden="true"><path d="M10 3 5 8l5 5" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>';

  let sideN = 0, lastSide = null;
  const sides = () => [...convs.values()].filter(c => c !== main);
  const convState = c => c.cards.size ? 'waiting' : c.busy ? 'busy' : c.unseen ? 'unseen' : '';

  /** Opens a side chat: a fork of main as it is now, with main's model and effort (so it reads main's prompt cache) and manual approvals. */
  function newSide() {
    if (!main.sessionId) {
      const prev = S;
      S = main;
      notice('info', 'Send the main conversation a message first: a side chat is a fork of it.');
      S = prev;
      return;
    }
    const n = ++sideN, id = 'side-' + n;
    const conv = newConv(id, 'Side ' + n);
    Object.assign(conv, { model: main.model, modelChoice: main.modelChoice, effort: main.effort, mode: 'default' });
    conv.log = h('main', { class: 'ck-log is-side', hidden: true }, sideHead(conv));
    dock.before(conv.log);
    convs.set(id, conv);
    // Thinking follows main's current state (null: the settings decide, as for main).
    post({ type: 'openSide', channel: id, model: main.modelChoice || null, effort: main.effort || null,
      thinking: main.thinkingSource === 'user' ? main.thinkingOn : null });
    showConv(conv);
  }

  function sideHead(conv) {
    const prompts = main.turns.map(t => t.el.querySelector('.ck-user-text')).filter(Boolean);
    const last = prompts.length ? prompts[prompts.length - 1].textContent.trim() : null;
    const time = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    return h('div', { class: 'ck-side-head' },
      h('div', { class: 'ck-side-title' }, h('span', { class: 'ck-side-badge', text: conv.label }), `A fork of main at ${time}`),
      h('div', { class: 'ck-side-note', text: 'It has the whole conversation so far' +
        (last ? `, up to “${last.length > 90 ? last.slice(0, 90) + '…' : last}”` : '') + '. Main does not see what happens here.' }));
  }

  /** Puts `conv` in view: its log, its draft and scroll position, its dock state. */
  function showConv(conv) {
    if (!conv || conv === active || !convs.has(conv.id)) return;
    closePop();
    if (!usagePanel.hidden) toggleUsage(false);
    active.draft = input.value;
    active.follow = follow;
    active.scrollY = window.scrollY;
    active.log.hidden = true;
    active = S = conv;
    if (conv !== main) lastSide = conv;
    conv.unseen = false;
    conv.log.hidden = false;
    document.body.classList.toggle('is-side', conv !== main);
    input.value = conv.draft || '';
    grow();
    follow = conv.follow;
    window.scrollTo(0, follow ? document.documentElement.scrollHeight : conv.scrollY);
    paintMeta(); paintRefs(); paintContext(); updateStatus(); paintDown();
    input.focus();
  }

  /** The strip's switch: main ⇄ the last side chat (a new one when there is none). */
  function toggleView() {
    if (active !== main) showConv(main);
    else if (lastSide && convs.has(lastSide.id)) showConv(lastSide);
    else newSide();
  }

  function closeSide(conv) {
    if (!conv || conv === main) return;
    if (active === conv) showConv(main);
    post({ type: 'closeSide', channel: conv.id });
    conv.log.remove();
    convs.delete(conv.id);
    if (lastSide === conv) lastSide = sides().pop() || null;
    postState(); paintView();
  }

  function paintView() {
    if (!viewBtn) return;
    const inSide = active !== main;
    const others = [...convs.values()].filter(c => c !== active);
    // The loudest state among the conversations out of view.
    const states = others.map(convState);
    viewBtn.dataset.attn = ['waiting', 'busy', 'unseen'].find(st => states.includes(st)) || '';
    viewBtn.classList.toggle('is-side', inSide);
    viewBtn.querySelector('.ck-view-ic').innerHTML = inSide ? ICON_BACK : ICON_SIDE;   // static markup only
    viewBtn.querySelector('.ck-view-t').textContent = inSide ? 'Main' : lastSide && convs.has(lastSide.id) ? lastSide.label : 'Side chat';
    viewBtn.title = inSide ? 'Back to the main conversation' : lastSide && convs.has(lastSide.id)
      ? `Show ${lastSide.label}` : 'Open a side chat: a fork of this conversation';
    viewMenuBtn.hidden = !sides().length;
  }

  function openViewMenu() {
    if (P.kind === 'view') { closePop(); return; }
    viewMenuBtn.classList.add('is-open');
    openPop('view', viewMenuBtn, () => ({
      head: 'Conversations',
      items: [main, ...sides()].map(c => ({
        title: h('span', { class: 'ck-view-row' }, h('span', { class: 'ck-view-state', 'data-state': convState(c) }), c.label),
        desc: [modelLabel(c.model) || null, c === main ? null : plural(c.turns.length, 'turn')].filter(Boolean).join(' · ') || null,
        current: c === active,
        run: () => { closePop(); showConv(c); }
      })).concat([{ title: 'New side chat', desc: 'A fork of main as it is now', run: () => { closePop(); newSide(); } }])
    }));
  }

  // ── composer height: a grip on the left edge of the field ─────────────

  /** 0: the composer grows with its text (up to 160px); otherwise the height you set. */
  let userH = 0;
  try { userH = +localStorage.getItem('ck.composerHeight') || 0; } catch (e) { /* storage may be blocked */ }

  function setUserH(v, save) {
    userH = v;
    grow();
    if (P.kind) placePop();
    if (!save) return;
    try { v ? localStorage.setItem('ck.composerHeight', String(v)) : localStorage.removeItem('ck.composerHeight'); } catch (e) { /* no storage */ }
  }

  function bindGrip() {
    let drag = false, y0 = 0, h0 = 0;
    grip.addEventListener('pointerdown', e => {
      e.preventDefault();
      drag = true; y0 = e.clientY; h0 = input.offsetHeight;
      document.body.classList.add('is-resizing');
    });
    // On the document, so the drag keeps going when the pointer leaves the grip.
    document.addEventListener('pointermove', e => {
      if (!drag) return;
      // Up makes it taller; at most 60% of the window.
      setUserH(Math.round(Math.min(Math.max(h0 + (y0 - e.clientY), 34), window.innerHeight * 0.6)), false);
    });
    document.addEventListener('pointerup', () => {
      if (!drag) return;
      drag = false;
      document.body.classList.remove('is-resizing');
      setUserH(userH, true);
      input.focus();
    });
    grip.addEventListener('dblclick', () => { setUserH(0, true); input.focus(); });
  }

  // ── /resume: continue another conversation of this folder ─────────────

  const ago = ms => {
    const s = (Date.now() - ms) / 1000;
    if (s < 90) return 'just now';
    if (s < 3600) return Math.round(s / 60) + ' min ago';
    if (s < 86400) return Math.round(s / 3600) + ' h ago';
    if (s < 86400 * 14) return Math.round(s / 86400) + ' d ago';
    return new Date(ms).toLocaleDateString([], { day: 'numeric', month: 'short' });
  };
  const fmtSize = b => b >= 1e6 ? (b / 1e6).toFixed(1) + ' MB' : Math.max(1, Math.round(b / 1e3)) + ' kB';

  function requestSessions() {
    // Fresh enough for a minute; the list is cheap to read again after that.
    if (SHARED.sessions && Date.now() - SHARED.sessions.at < 60e3) return;
    post({ type: 'sessions' });
  }

  /** The list for "/resume <search>": newest first; not main's own conversation, side chats marked. */
  function resumeItems(search) {
    const q = search.trim().toLowerCase();
    const own = new Map([...convs.values()].filter(c => c.sessionId).map(c => [c.sessionId, c]));
    if (!SHARED.sessions) return { head: 'Resume a conversation · this folder', items: [], empty: 'Loading conversations…' };
    const list = SHARED.sessions.list.filter(s => s.id !== main.sessionId && (!q || [s.title, s.firstPrompt, s.branch, s.id].some(v => v && v.toLowerCase().includes(q))));
    return {
      head: 'Resume a conversation · this folder',
      empty: q ? `No conversation matches “${search.trim()}”` : 'No other conversations in this folder yet.',
      items: list.slice(0, 40).map(s => {
        const mine = own.get(s.id);
        const title = s.title || s.firstPrompt || s.id.slice(0, 8);
        const tag = mine ? mine.label : Date.now() - s.modified < 120e3 ? 'active now' : null;
        return {
          title: mark(title.length > 90 ? title.slice(0, 90) + '…' : title, q),
          desc: [ago(s.modified), s.branch, fmtSize(s.size), s.title && s.firstPrompt && s.firstPrompt !== s.title ? '“' + s.firstPrompt.replace(/\s+/g, ' ').slice(0, 70) + '”' : null].filter(Boolean).join(' · '),
          side: tag ? h('span', { class: 'ck-pop-tag' + (tag === 'active now' ? ' is-warn' : ''), title: tag === 'active now' ? 'Changed in the last 2 minutes: it may be open in another tab or terminal' : null, text: tag }) : null,
          run: () => resumeSession(s.id, title)
        };
      })
    };
  }

  /** Main continues session `id`: its log clears, the sidecar restarts on it, the history is drawn. */
  function resumeSession(id, title) {
    closePop();
    input.value = ''; grow();
    if (active !== main) showConv(main);
    if (id === main.sessionId) { notice('info', 'That is the conversation in this tab.'); return; }
    if (main.busy || main.cards.size) { notice('info', 'Claude is still working. Stop it (Esc) or answer it first, then resume.'); return; }
    resetConv(main);
    main.sessionId = id;
    main.resumeTitle = title || null;
    const prev = S; S = main;
    notice('info', `Resuming “${title || id.slice(0, 8)}”…`);
    S = prev;
    SHARED.sessions = null;   // the list changes once this one moves on
    post({ type: 'resume', channel: 'main', sessionId: id });
    updateStatus(); paintMeta(); paintRefs();
  }

  /** Clears a conversation's log and state (its model, mode and effort stay). */
  function resetConv(conv) {
    for (const t of conv.turns) if (t.run) clearInterval(t.run.timer);
    for (const th of conv.thinks.values()) clearInterval(th.timer);
    const keep = { model: conv.model, modelChoice: conv.modelChoice, mode: conv.mode, effort: conv.effort, thinkingOn: conv.thinkingOn, thinkingSource: conv.thinkingSource };
    const fresh = newConv(conv.id, conv.label);
    for (const k of Object.keys(fresh)) if (k !== 'log') conv[k] = fresh[k];
    Object.assign(conv, keep);
    conv.log.replaceChildren();
    if (conv === active) follow = true;
  }

  /** What a stored user message was: a prompt, a command, its output, or noise to skip. */
  function userView(text) {
    text = String(text || '').replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '').trim();
    if (!text) return null;
    if (/^This session is being continued from a previous conversation/.test(text)) return { kind: 'compacted' };
    if (/^<local-command-caveat>/.test(text)) return null;
    if (/^\[Request interrupted by user/.test(text)) return { kind: 'note', text: 'Interrupted' };
    const cmd = text.match(/<command-name>([\s\S]*?)<\/command-name>/);
    if (cmd) {
      const args = (text.match(/<command-args>([\s\S]*?)<\/command-args>/) || [])[1] || '';
      return { kind: 'prompt', text: (cmd[1].trim().startsWith('/') ? '' : '/') + cmd[1].trim() + (args.trim() ? ' ' + args.trim() : '') };
    }
    const out = text.match(/^<local-command-std(?:out|err)>([\s\S]*?)<\/local-command-std(?:out|err)>$/);
    if (out) { const t = out[1].replace(/\x1b\[[0-9;]*m/g, '').trim(); return t ? { kind: 'output', text: t } : null; }
    // A message sent with references: chips again, and the user's own words.
    if (text.startsWith(REF_NOTE)) {
      const refs = [...text.matchAll(/<referenced_text(?: from_reply_to="([^"]*)")?>\n([\s\S]*?)\n<\/referenced_text>/g)].map(m => ({ text: m[2], from: m[1] || null }));
      const rest = text.slice(text.lastIndexOf('</referenced_text>') + '</referenced_text>'.length).trim();
      return { kind: 'prompt', text: rest === '(The user sent only the referenced text.)' ? '' : rest, refs };
    }
    return { kind: 'prompt', text };
  }

  /** Draws a resumed conversation from its stored messages (in S, the conversation it belongs to). */
  function loadHistory(e) {
    if (e.sessionId !== S.sessionId) return;
    if (e.omitted) notice('info', `${e.omitted} earlier messages are not shown here. The whole history is in the TUI (⋮ → Open in TUI).`);
    for (const m of e.messages) {
      evT = Date.parse(m.timestamp) || 0;
      const c = m.message && m.message.content;
      if (m.type === 'assistant') { onAssistant({ message: m.message, parent_tool_use_id: m.parent_tool_use_id }); continue; }
      if (Array.isArray(c) && c.some(x => x.type === 'tool_result')) { onUser({ message: m.message }); continue; }
      if (m.parent_tool_use_id) continue;   // a subagent's prompt
      const text = typeof c === 'string' ? c : Array.isArray(c) ? c.filter(x => x.type === 'text').map(x => x.text).join('\n') : '';
      const v = userView(text);
      if (!v) continue;
      if (v.kind === 'compacted') notice('info', 'The conversation before this point was compacted.');
      else if (v.kind === 'note') notice('info', v.text);
      else if (v.kind === 'output') localOutput(v.text);
      else newTurn(v.text, v.refs);
    }
    evT = 0;
    closeRun();
    for (const th of S.thinks.values()) endThink(th);
    S.busy = false; S.thinking = false;
    const done = h('div', { class: 'ck-resumed', text: `Resumed${S.resumeTitle ? ' “' + S.resumeTitle + '”' : ''} · you can continue below` });
    S.log.append(done);
    S.turn = null;
    updateStatus(); paintMeta();
    if (inView()) { follow = true; stick(); }
  }

  // ── status line + composer ─────────────────────────────────────────────

  function updateStatus() {
    const waiting = S.cards.size > 0;
    let text = 'Ready', state = 'idle';
    if (waiting) { text = 'Waiting for you'; state = 'waiting'; }
    else if (S.busy) {
      state = 'busy';
      const live = S.lastTool && (S.lastTool.state === 'running' || S.lastTool.state === 'preparing') ? S.lastTool : null;
      text = live ? `${shortName(live.name)} ${live.argEl.textContent}`.trim() : S.thinking ? (S.thinkWord || 'Thinking') + '…' : 'Working';
    }
    postState();
    if (!inView()) { paintView(); return; }
    statusText.textContent = text;
    statusDot.dataset.state = state;
    dock.dataset.state = state;
    sendBtn.dataset.mode = S.busy && !input.value.trim() && !S.refs.length ? 'stop' : 'send';
    sendBtn.title = sendBtn.dataset.mode === 'stop' ? 'Stop (Esc)' : 'Send (Return)';
    paintView();
  }

  /** The tab's attention dot covers every conversation, main and side. */
  let lastState = '';
  function postState() {
    const all = [...convs.values()];
    const busy = all.some(c => c.busy), waiting = all.some(c => c.cards.size > 0);
    if (lastState === busy + '/' + waiting) return;
    lastState = busy + '/' + waiting;
    post({ type: 'state', channel: 'main', busy, waiting });
  }

  function sendUser(text, refs) {
    text = String(text || '').trim();
    refs = refs || [];
    if (!text && !refs.length) return;
    if (text.startsWith('/') && runLocal(text)) return;
    // A slash command must start the message, so references wait for the next one.
    if (text.startsWith('/')) refs = [];
    else if (refs.length) { S.refs = []; paintRefs(); }
    newTurn(text, refs);
    S.busy = true;
    post({ type: 'send', text: refs.length ? withRefs(text, refs) : text });
    updateStatus();
    follow = true; stick();
  }

  const grow = () => {
    if (userH) { input.style.maxHeight = 'none'; input.style.height = userH + 'px'; return; }
    input.style.maxHeight = '';
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, 160) + 'px';
  };
  function submit() {
    if (sendBtn.dataset.mode === 'stop') { post({ type: 'interrupt' }); return; }
    const text = input.value;
    if (!text.trim() && !S.refs.length) return;
    input.value = ''; grow(); closePop();
    sendUser(text, S.refs.slice());
    updateStatus();
  }

  const chip = (cls, title) => h('button', { class: 'ck-chip ' + cls, type: 'button', title }, h('span', { class: 'ck-chip-t' }), h('span', { class: 'sk-caret ck-chip-caret' }));

  function buildShell() {
    document.body.classList.add('ck');
    main.log = h('main', { class: 'ck-log', id: 'ck-log' });
    statusDot = h('span', { class: 'ck-dot' });
    statusText = h('span', { class: 'ck-status-text', text: 'Starting…' });
    modelEl = chip('ck-model', 'Model and effort (⌥P)');
    modeBtn = chip('ck-mode', 'Permission mode (⇧Tab cycles)');
    costEl = chip('ck-usage', 'Usage');
    viewBtn = h('button', { class: 'ck-chip ck-view', type: 'button' }, h('span', { class: 'ck-view-ic' }), h('span', { class: 'ck-view-t' }), h('span', { class: 'ck-view-dot' }));
    viewMenuBtn = h('button', { class: 'ck-chip ck-view-more', type: 'button', title: 'All conversations', hidden: true }, h('span', { class: 'sk-caret ck-chip-caret' }));
    grip = h('div', { class: 'ck-grip', title: 'Drag to resize · double-click to reset' }, h('span', { class: 'ck-grip-ic' }));
    ctxEl = h('button', { class: 'ck-ctx', type: 'button' });
    moreBtn = h('button', { class: 'ck-chip ck-more', type: 'button', title: 'More: folder, git, session, actions' }, h('span', { class: 'ck-more-ic' }));
    usagePanel = h('div', { class: 'ck-usage-panel', hidden: true });
    input = h('textarea', { class: 'ck-input', rows: '1', placeholder: 'Message Claude…  / for commands · ⇧↩ new line' });
    sendBtn = h('button', { class: 'ck-send', type: 'button' }, h('span', { class: 'ck-send-ic' }));
    refsEl = h('div', { class: 'ck-refs', hidden: true });
    downBtn = h('button', { class: 'ck-down', type: 'button', title: 'Scroll to the bottom', hidden: true }, h('span', { class: 'ck-down-ic' }));
    downBtn.onmousedown = e => e.preventDefault();
    downBtn.onclick = toBottom;
    composer = h('div', { class: 'ck-composer' }, h('div', { class: 'ck-field' }, grip, refsEl, input, downBtn), sendBtn);
    refBtn = h('button', { class: 'ck-refbtn', type: 'button', hidden: true, title: 'Add the selected text to your next message (⌘L)' },
      h('span', { class: 'ck-refbtn-ic' }), 'Reference to Agent', h('kbd', { text: '⌘L' }));
    refBtn.onmousedown = e => e.preventDefault();   // keep the selection
    refBtn.onclick = () => referenceSelection();
    document.body.append(refBtn);
    statusEl = h('div', { class: 'ck-status' }, viewBtn, viewMenuBtn, statusDot, statusText, h('span', { class: 'ck-spacer' }), ctxEl, modelEl, modeBtn, costEl, moreBtn);
    popEl = h('div', { class: 'ck-pop', hidden: true });
    dockIn = h('div', { class: 'ck-dock-in' }, usagePanel, statusEl, composer, popEl);
    dock = h('div', { class: 'ck-dock' }, dockIn);
    document.body.append(main.log, dock);

    input.addEventListener('input', () => { grow(); updateStatus(); updateSlash(); });
    input.addEventListener('click', updateSlash);
    input.addEventListener('keyup', e => { if (e.key === 'ArrowLeft' || e.key === 'ArrowRight' || e.key === 'Home' || e.key === 'End') updateSlash(); });
    input.addEventListener('blur', () => setTimeout(() => { if (P.kind === 'slash' && document.activeElement !== input) closePop(); }, 120));
    input.addEventListener('keydown', e => {
      if (e.isComposing) return;
      // An open menu takes its keys first, whichever menu it is (the focus stays here).
      if (P.kind && popKey(e)) { e.preventDefault(); e.stopPropagation(); return; }
      // Backspace in an empty composer removes the last reference.
      if (e.key === 'Backspace' && !input.value && S.refs.length) { e.preventDefault(); S.refs.pop(); paintRefs(); updateStatus(); return; }
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit(); }
      else if (e.key === 'Escape' && !usagePanel.hidden) { e.preventDefault(); toggleUsage(false); }
      else if (e.key === 'Escape' && S.busy) { e.preventDefault(); post({ type: 'interrupt' }); }
      else if (e.key === 'Tab' && e.shiftKey) { e.preventDefault(); cycleMode(); }
    });
    sendBtn.onclick = submit;
    modelEl.onclick = openModelMenu;
    modeBtn.onclick = openModeMenu;
    costEl.onclick = () => toggleUsage();
    for (const b of [viewBtn, viewMenuBtn, ctxEl, modelEl, modeBtn, costEl, moreBtn]) b.onmousedown = e => e.preventDefault();
    viewBtn.onclick = toggleView;
    viewMenuBtn.onclick = openViewMenu;
    bindGrip();
    ctxEl.onclick = openMoreMenu;
    moreBtn.onclick = openMoreMenu;
    window.addEventListener('wheel', e => { if (e.deltaY < 0) leaveBottom(); }, { passive: true });
    document.addEventListener('keydown', e => {
      const t = e.target;
      if (P.kind || (t && (t.tagName === 'TEXTAREA' || t.tagName === 'INPUT'))) return;
      if (e.key === 'ArrowUp' || e.key === 'PageUp' || e.key === 'Home' || (e.key === ' ' && e.shiftKey)) leaveBottom();
    });
    // Dragging the scrollbar (a press right of the page's content box) also stops following.
    document.addEventListener('pointerdown', e => { if (e.clientX >= document.documentElement.clientWidth) { dragging = true; follow = false; } });
    document.addEventListener('pointerup', () => { if (dragging) { dragging = false; onScroll(); paintDown(); } });
    window.addEventListener('scroll', () => { onScroll(); paintDown(); if (P.kind) placePop(); if (!refBtn.hidden) placeRefBtn(); }, { passive: true });
    document.addEventListener('mouseup', () => setTimeout(placeRefBtn, 0));
    document.addEventListener('keyup', e => { if (e.shiftKey || e.key === 'Shift') placeRefBtn(); });
    document.addEventListener('selectionchange', () => { if (!refBtn.hidden && !selectionRef()) refBtn.hidden = true; });
    window.addEventListener('resize', () => { if (P.kind) placePop(); });
    document.addEventListener('mousedown', e => {
      if (P.kind && P.kind !== 'slash' && !popEl.contains(e.target) && !(P.anchor && P.anchor.contains(e.target)) && !(P.kind === 'more' && ctxEl.contains(e.target))) closePop();
    });
    document.addEventListener('keydown', e => {
      if (P.kind && P.kind !== 'slash' && popKey(e)) { e.preventDefault(); return; }
      if (e.altKey && !e.metaKey && !e.ctrlKey && e.code === 'KeyP') { e.preventDefault(); openModelMenu(); return; }
      if (e.metaKey && !e.altKey && !e.ctrlKey && !e.shiftKey && e.key.toLowerCase() === 'l' && selectionRef()) { e.preventDefault(); referenceSelection(); return; }
      if (e.key === 'Escape' && !usagePanel.hidden && document.activeElement !== input) { toggleUsage(false); return; }
      if (e.key === 'Escape' && S.busy && !S.cards.size && document.activeElement !== input) post({ type: 'interrupt' });
    });
    updateStatus(); paintMeta(); paintContext(); paintView(); grow();
    input.focus();
  }

  function notice(kind, text) {
    const el = h('div', { class: 'ck-notice', 'data-kind': kind, text });
    (S.turn ? S.turn.body : S.log).append(el);
    stick();
  }

  /** Output of a local slash command: drawn like a reply. */
  function localOutput(text) {
    closeRun();
    const el = h('div', { class: 'sk-doc ck-text' });
    turn().body.append(el);
    root.SkimRender.render(el, String(text || ''), { streaming: false, interactive: true, onAction: a => { if (a.type === 'reply') sendUser(a.text); } });
    stick();
  }

  // ── event intake ───────────────────────────────────────────────────────

  function onStream(ev, msg) {
    if (msg.parent_tool_use_id) return;   // subagent streams: shown as rows only
    switch (ev.type) {
      case 'message_start': S.currentMsg = ev.message.id; break;
      case 'content_block_start': {
        const key = S.currentMsg + ':' + ev.index, b = ev.content_block;
        S.blockKind.set(key, b.type);
        if (b.type === 'text') newText(key, S.currentMsg);
        else if (b.type === 'tool_use') addRow(b.id, b.name, null);
        else if (b.type === 'thinking' || b.type === 'redacted_thinking') { S.thinking = true; newThink(key, S.currentMsg, b.type === 'redacted_thinking'); updateStatus(); }
        break;
      }
      case 'content_block_delta': {
        const key = S.currentMsg + ':' + ev.index;
        if (ev.delta.type === 'text_delta') { const it = S.texts.get(key); if (it) { it.text += ev.delta.text; schedulePaint(it); } }
        else if (ev.delta.type === 'thinking_delta' && ev.delta.thinking) {
          const th = S.thinks.get(key);
          if (th) {
            th.text += ev.delta.thinking;
            paintThink(th);
            if (th.open && !th.raf) th.raf = requestAnimationFrame(() => paintThinkBody(th));
          }
        }
        break;
      }
      case 'content_block_stop': {
        const key = S.currentMsg + ':' + ev.index;
        const it = S.texts.get(key);
        if (it) { it.final = true; paintText(it, false); }
        if (S.blockKind.get(key) === 'thinking' || S.blockKind.get(key) === 'redacted_thinking') { endThink(S.thinks.get(key)); S.thinking = false; updateStatus(); }
        break;
      }
    }
  }

  function onAssistant(msg) {
    const m = msg.message, sub = msg.parent_tool_use_id;
    for (const c of m.content || []) {
      if (c.type === 'text' && !sub) {
        // The full block is authoritative; match it to the streamed item.
        const items = S.msgTexts.get(m.id) || [];
        let it = items.find(x => !x.confirmed);
        if (!it) it = newText(m.id + ':full' + items.length, m.id);
        it.confirmed = true;
        if (it.text !== c.text || !it.final) { it.text = c.text; it.final = true; paintText(it, false); }
      } else if ((c.type === 'thinking' || c.type === 'redacted_thinking') && !sub) {
        // The full block is authoritative too (and the only copy when nothing streamed).
        const items = S.msgThinks.get(m.id) || [];
        let th = items.find(x => !x.confirmed);
        if (!th) { th = newThink(m.id + ':fullthink' + items.length, m.id, c.type === 'redacted_thinking'); endThink(th); }
        th.confirmed = true;
        if (c.type === 'thinking' && c.thinking && c.thinking !== th.text) { th.text = c.thinking; paintThink(th); if (th.open) paintThinkBody(th); }
      } else if (c.type === 'tool_use') {
        const row = addRow(c.id, c.name, sub);
        setRowInput(row, c.input);
      }
    }
    if (m.model && !sub && !S.model) { S.model = m.model; paintMeta(); }   // init's id (with [1m]) wins
  }

  function onUser(msg) {
    const content = msg.message && msg.message.content;
    if (!Array.isArray(content)) return;
    for (const c of content) {
      if (c.type !== 'tool_result') continue;
      const row = S.rows.get(c.tool_use_id);
      if (!row) continue;
      const text = resultText(c);
      row.t1 = clock();
      // A card still open for this call was answered some other way: settle it from the result.
      for (const [cardId, card] of S.cards) {
        if (card.req.toolUseID === row.id) resolveCard(cardId, c.is_error ? 'denied' : 'allowed');
      }
      if (row.waitStart) { row.waitMs += row.t1 - row.waitStart; row.waitStart = 0; }
      row.metaEl.textContent = metaOf(row, text, c.is_error);
      const out = h('pre', { class: 'ck-out', text: text.length > 4000 ? text.slice(0, 4000) + '\n…' : text });
      // A change keeps its view; only a failure adds the tool's message above it.
      if (!row.change) row.detail.replaceChildren(out);
      else if (c.is_error) row.detail.replaceChildren(out, row.change);
      setRowState(row, c.is_error ? 'error' : 'done');
      if (row.run) paintRun(row.run);
    }
  }

  function onResult(msg) {
    // A turn that ended mid-thought (interrupted) leaves no block open.
    for (const th of S.thinks.values()) endThink(th);
    closeRun();
    if (S.turn && !S.turn.footer) {
      const bits = [];
      if (msg.duration_ms) bits.push((msg.duration_ms / 1000).toFixed(1) + 's');
      if (msg.num_turns > 1) bits.push(msg.num_turns + ' steps');
      if (msg.total_cost_usd) S.cost = msg.total_cost_usd;
      if (msg.modelUsage) S.modelUsage = msg.modelUsage;
      S.turns_n++; S.apiMs += msg.duration_api_ms || 0;
      if (msg.subtype !== 'success') bits.push(msg.subtype.replace(/_/g, ' '));
      S.turn.footer = h('div', { class: 'ck-foot', text: bits.join(' · ') });
      S.turn.body.append(S.turn.footer);
    }
    if (msg.is_error && msg.result) notice('error', msg.result);
    S.busy = false; S.thinking = false;
    paintMeta(); updateStatus(); stick();
    requestUsage(!usagePanel.hidden);   // context use after this turn (and plan limits, when the panel is open)
    requestGit();                       // the turn may have changed files or the branch
  }

  function receiveOne(e) {
    switch (e.type) {
      case 'sdk': {
        const m = e.msg;
        if (m.type === 'stream_event') onStream(m.event, m);
        else if (m.type === 'assistant') { S.busy = true; onAssistant(m); }
        else if (m.type === 'user') onUser(m);
        else if (m.type === 'result') onResult(m);
        else if (m.type === 'system' && m.subtype === 'init') {
          // Sent at the start of every turn; a new session ID means /clear started a new conversation.
          if (S.sessionId && m.session_id && m.session_id !== S.sessionId) { notice('info', 'New conversation'); S.cost = 0; S.modelUsage = null; S.turns_n = 0; S.apiMs = 0; }
          S.model = m.model || S.model; S.mode = m.permissionMode || S.mode; S.sessionId = m.session_id; SHARED.cwd = m.cwd || SHARED.cwd;
          SHARED.terminalCmds = new Set(m.terminal_slash_commands || []);
          SHARED.info = { version: m.claude_code_version, mcp: (m.mcp_servers || []).map(x => ({ name: x.name, status: x.status })), outputStyle: m.output_style };
          paintMeta(); paintContext();
        } else if (m.type === 'system' && m.subtype === 'status' && m.permissionMode) { S.mode = m.permissionMode; paintMeta(); }
        else if (m.type === 'system' && m.subtype === 'commands_changed') { SHARED.commands = m.commands || []; if (P.kind === 'slash') refreshPop(); }
        else if (m.type === 'system' && m.subtype === 'local_command_output') localOutput(m.content);
        else if (m.type === 'system' && m.subtype === 'compact_boundary') notice('info', 'Conversation compacted');
        break;
      }
      case 'capabilities':
        SHARED.commands = e.commands || []; SHARED.models = e.models || []; SHARED.outputStyles = e.outputStyles || [];
        if (e.mode) S.mode = e.mode;
        paintMeta(); if (P.kind) refreshPop();
        requestUsage(false); requestGit();
        break;
      case 'model': if (e.model) { const r = S.models.find(x => x.value === e.model); S.modelChoice = e.model; S.model = r ? (r.resolvedModel || r.value) : e.model; paintMeta(); } break;
      case 'mode': S.mode = e.mode || S.mode; paintMeta(); break;
      case 'effort': S.effort = e.effort || null; paintMeta(); break;
      case 'git': SHARED.git = e; paintContext(); break;
      case 'sessions': SHARED.sessions = { at: Date.now(), list: e.list || [] }; if (P.kind === 'slash') refreshPop(); break;
      case 'history': loadHistory(e); break;
      case 'thinking': S.thinkingOn = !!e.on; S.thinkingSource = e.source || null; if (inView() && P.kind === 'more') refreshPop(); break;
      case 'usage': if (e.context) S.ctx = e.context; if (e.plan) SHARED.plan = e.plan; paintMeta(); break;
      case 'permission_request': addCard(e); break;
      case 'permission_cancelled': resolveCard(e.id, 'cancelled'); break;
      case 'error': notice('error', e.message); S.busy = false; updateStatus(); break;
      case 'end': notice('info', 'Session ended'); S.busy = false; updateStatus(); break;
      case 'host': // messages from FloatyTerm itself (e.g. the sidecar could not start)
        notice(e.kind || 'info', e.message); if (e.kind === 'error') { S.busy = false; updateStatus(); }
        break;
    }
  }

  const ClaudeChat = {
    boot(cfg) {
      SHARED.cwd = cfg.cwd || ''; SHARED.home = cfg.home || '';
      if (cfg.model) S.model = cfg.model;
      buildShell();
      statusText.textContent = 'Ready';
      if (cfg.intro) notice('info', cfg.intro);
    },
    /** `channel`: the conversation the events belong to ('main' when omitted). */
    receive(batch, channel) {
      const conv = convs.get(channel || 'main');
      if (!conv) return;
      const prev = S;
      S = conv;
      try {
        for (const e of batch) {
          evT = e.t || 0;
          try { receiveOne(e); } catch (err) { console.error('ClaudeChat', e.type, err); }
        }
      } finally { evT = 0; S = prev; }
      if (!batch.some(e => e.type === 'sdk' || e.type === 'permission_request' || e.type === 'host')) return;
      if (conv !== active) { conv.unseen = true; paintView(); }
      // Output arrived while you read higher up: the down button says so.
      else if (!follow && downBtn) { downBtn.dataset.fresh = '1'; paintDown(); }
    },
    /** Draws a user turn without sending it (replays, resumed history). */
    showUser(text) { newTurn(text); S.busy = true; updateStatus(); },
    focus() { input && input.focus(); }
  };
  root.ClaudeChat = ClaudeChat;
})(typeof self !== 'undefined' ? self : this);
