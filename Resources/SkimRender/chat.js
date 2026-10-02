/*
 * AgentChat — one conversation renderer for normalized agent events.
 *
 *   ClaudeChat.receive([event, …])   host → page, in order
 *   ClaudeChat.boot({ cwd })         once, before the first event
 *
 * Page → host goes through `skim` bridge actions:
 *   { type: 'send', text, images? } · { type: 'permission', id, decision, message?, updatedInput?, updatedPermissions? }
 *   { type: 'files', query, id }  (@-mention suggestions)
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
 * The dock at the bottom holds the task list (when the agent keeps one), the
 * status line (model menu, permission-mode menu, a usage chip that opens the
 * usage panel, TUI hand-off) and the composer, which suggests slash commands
 * and their arguments as you type, and @-mentions of files and subagents.
 * Images arrive by paste or drop and go with the next message.
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
  const CLAUDE_FEATURES = { approvals: true, fork: true, history: true, models: true, effort: true,
    permissionMode: true, thinking: true, usage: true, git: true, tui: true, slashCommands: true, midTurnInput: true,
    mentions: true, images: true, rename: true, rewind: true, btw: true };
  const CODEX_FEATURES = { approvals: true, fork: true, history: true, models: true, effort: true,
    permissionMode: true, thinking: true, usage: true, git: true, tui: true, slashCommands: true, midTurnInput: false,
    mentions: false, images: false };
  let agent = 'claude';
  let features = { ...CLAUDE_FEATURES };
  const supports = name => !!features[name];
  const SHARED = {
    cwd: '', home: '',
    // from the sidecar's capabilities event and later changes
    models: [], commands: [], terminalCmds: new Set(), outputStyles: [],
    plan: null, planAt: 0,  // plan limits (account-wide)
    git: null,              // the sidecar's git state for the session's folder
    info: {},               // from init: Claude Code version, MCP servers, output style
    sessions: null,         // { at, list }: the folder's conversations, for /resume
    agents: []              // subagents the session offers, for @agent-… mentions
  };

  /**
   * One conversation: main, or a side chat forked from it. Unset fields read
   * through to SHARED. Events are processed against their own conversation;
   * only the one in view paints the dock.
   */
  function newConv(id, label) {
    return Object.assign(Object.create(SHARED), {
      id, label, log: null,
      normalizer: root.AgentEvents.createNormalizer(agent), eventState: root.AgentEvents.createState(),
      model: '', mode: 'default', sessionId: null, cost: 0,
      busy: false, turn: null, turns: [],
      eventChildren: new Map(), surfaceViews: new Map(), mediaViews: new Map(), surfaceRoot: null, protocolStatus: null, buffering: false, connectionClosed: false,
      turnViews: new Map(),   // thread + turn identity → owning DOM turn (including completed turns)
      rows: new Map(),        // tool_use id → row
      texts: new Map(),       // `${messageId}:${index}` → text item
      msgTexts: new Map(),    // messageId → [text item] in order (to match full assistant messages)
      cards: new Map(),       // permission id → card
      thinking: false, lastTool: null, unknownDetails: [],
      thinks: new Map(), msgThinks: new Map(), liveThink: null, thinkWord: null,   // thinking blocks
      thinkingOn: null, thinkingSource: null,   // whether thinking text is shown (the sidecar reports it)
      modelChoice: null,      // the model menu value the user picked ('sonnet', 'default', …)
      effort: null,           // null: the model's default
      modelUsage: null, turns_n: 0, apiMs: 0,
      ctx: null, tokens: null, usageUnavailable: null,
      refs: [],               // text referenced from Claude's replies, sent with the next message
      images: [],             // pasted or dropped images { mediaType, data, url, name, w, h, seq }, sent with the next message
      tasks: { list: [], byTool: new Map(), seen: new Set(), open: false },   // the agent's task list (TodoWrite, TaskCreate/TaskUpdate)
      retry: null, limitSeen: new Set(),                     // the retry notice of this turn; limit notices already shown
      title: null, titleCustom: false,
      progressText: null,     // Claude Code's live phrase for the turn (task_summary), for the status line
      lastChain: null,        // the newest transcript entry (a rewind resumes there); null: none yet, undefined: not known                       // the session's name (custom: the user named it)
      agentTasks: new Map(), bgTasks: [],
      subs: new Map(),        // Agent tool id → the subagent's own transcript (a conversation drawn in the panel)
      root: null, parent: null, toolId: null,   // for a subagent's transcript: the conversation, the one with its Agent row, the Agent call                    // subagents and background commands (task_* events); the live background set
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
  let chipSeq = 0;   // orders the chips above the composer (images and references) by when they were added

  let viewBtn, viewMenuBtn, grip, ctxEl, moreBtn, refsEl, refBtn, tasksEl, dock, dockIn, statusEl, statusDot, statusText, modelEl, modeBtn, costEl, usagePanel, composer, input, sendBtn, micBtn, realtimeBtn, popEl, subEl, rewindEl, btwEl;

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

  // ── motion: new things rise in, menus and panels open softly, folds slide ──

  // One set of values (skim.css has the same as CSS variables). Motion is off
  // with the macOS "Reduce motion" setting, with the `no-motion` class on
  // <html> (the test pages), while a history is drawn, and out of view.
  const M = { fast: 120, mid: 180, slow: 260, ease: 'cubic-bezier(.2, .8, .2, 1)' };
  const RISE = [{ opacity: 0, transform: 'translateY(4px)' }, { opacity: 1, transform: 'none' }];
  const POP = [{ opacity: 0, transform: 'scale(.94)' }, { opacity: 1, transform: 'none' }];
  const FADE = [{ opacity: 0 }, { opacity: 1 }];
  const reduceMQ = root.matchMedia ? root.matchMedia('(prefers-reduced-motion: reduce)') : null;
  const motionOn = () => !document.documentElement.classList.contains('no-motion') && !(reduceMQ && reduceMQ.matches);
  /** Nothing moves for a history being drawn, or for a conversation you do not see. */
  const quiet = () => !!S.replaying || !(inView() || subShown() === S);

  function play(el, frames, ms = M.mid, easing = M.ease) {
    if (!el || !el.animate || !motionOn()) return null;
    try { return el.animate(frames, { duration: ms, easing, fill: 'backwards' }); } catch (err) { return null; }
  }
  /** A new element in the conversation rises in (no-op when quiet). */
  const enter = el => { if (el && !quiet()) play(el, RISE); return el; };

  /**
   * Open and close, with a height slide. `apply` changes the state at once (the
   * hidden attribute, a class), so every other check sees the new state now;
   * only the drawing follows. A second toggle during a slide takes over from it.
   */
  function stopSlide(el) { if (el._slide) { const a = el._slide; el._slide = null; a.cancel(); } }
  function expand(el, apply) {
    stopSlide(el);
    apply();
    if (!motionOn() || !el.animate) return;
    const hgt = el.offsetHeight;
    if (!hgt) return;
    el.style.overflow = 'hidden';
    const a = el.animate([{ height: '0px', opacity: 0 }, { height: hgt + 'px', opacity: 1 }], { duration: M.mid, easing: M.ease });
    const end = () => { el.style.overflow = ''; if (el._slide === a) el._slide = null; };
    el._slide = a; a.onfinish = end; a.oncancel = end;
  }
  function collapse(el, apply) {
    stopSlide(el);
    const hgt = el.offsetHeight, disp = getComputedStyle(el).display;
    apply();
    if (!motionOn() || !el.animate || !hgt || disp === 'none') return;
    // Drawn until the slide ends, though already hidden (or folded) as far as the page is concerned.
    el.style.display = disp; el.style.overflow = 'hidden';
    const a = el.animate([{ height: hgt + 'px', opacity: 1 }, { height: '0px', opacity: 0 }], { duration: M.fast + 40, easing: M.ease });
    const end = () => { el.style.display = ''; el.style.overflow = ''; if (el._slide === a) el._slide = null; };
    el._slide = a; a.onfinish = end; a.oncancel = end;
  }

  /** The down button in the composer: shown away from the bottom, dotted when new output came in. */
  let downBtn;
  function paintDown() {
    if (!downBtn) return;
    const away = follow ? !nearBottom() : !nearBottom(4);
    if (away && downBtn.hidden) play(downBtn, POP, M.fast);
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

  /** The user's words as DOM nodes, with @-mentions (plain and quoted) marked. Never markup from the text. */
  function userTextNodes(text) {
    if (!supports('mentions')) return [text];
    const out = [], re = /(^|\s)(@"[^"]*"|@[^\s@"]+)/g;
    let at = 0, m;
    while ((m = re.exec(text))) {
      const start = m.index + m[1].length;
      out.push(text.slice(at, start), h('span', { class: 'ck-mention', text: m[2] }));
      at = start + m[2].length;
    }
    out.push(text.slice(at));
    return out;
  }

  // A long prompt folds to its first lines, faded at the bottom; a click opens it.
  const isLongPrompt = text => text.length > 420 || text.split('\n').length > 6;
  // Folded by the heuristic; a prompt that fits once laid out (a wide window) loses the fold.
  // (The change waits a frame: a size change inside the observer's own callback is a "loop" error.)
  const foldFit = root.ResizeObserver ? new ResizeObserver(list => {
    const fit = list.map(x => x.target).filter(t => t.isConnected && t.offsetHeight && !t.classList.contains('is-open') && !t.dataset.fits
      && t.scrollHeight <= t.clientHeight + 4);
    if (fit.length) requestAnimationFrame(() => fit.forEach(t => { t.dataset.fits = '1'; if (t._more) t._more.hidden = true; foldFit.unobserve(t); }));
  }) : null;

  function foldPrompt(box) {
    const text = box.querySelector('.ck-user-text');
    if (!text) return;
    text.classList.add('is-folded');
    const more = h('button', { class: 'ck-user-more', type: 'button', text: 'Show all', 'aria-expanded': 'false' });
    text._more = more;
    const toggle = () => {
      const open = text.classList.toggle('is-open');
      more.textContent = open ? 'Show less' : 'Show all';
      more.setAttribute('aria-expanded', String(open));
    };
    more.onmousedown = e => e.preventDefault();
    more.onclick = toggle;
    // A click on the folded text opens it; a click that ends a text selection does not.
    text.addEventListener('click', () => { if (!text.classList.contains('is-open') && !text.dataset.fits && !String(root.getSelection ? getSelection() : '')) toggle(); });
    box.append(more);
    if (foldFit) foldFit.observe(text);
  }

  function newTurn(userText, refs, images) {
    closeRun();
    const el = h('section', { class: 'ck-turn' });
    if (userText != null) el.append(h('div', { class: 'ck-user' + (/^\/\S/.test(userText) ? ' is-cmd' : '') },
      refs && refs.length ? h('div', { class: 'ck-user-refs' }, refs.map(r => refChip(r))) : null,
      images && images.length ? h('div', { class: 'ck-user-imgs' }, images.map((im, i) => h('button', { class: 'ck-user-img', type: 'button', title: imageLabel(im, i),
        onclick: () => openLightbox(im) }, h('img', { src: im.url, alt: imageLabel(im, i) })))) : null,
      userText ? h('span', { class: 'ck-user-text' }, userTextNodes(userText)) : null));
    if (userText && isLongPrompt(userText)) foldPrompt(el.firstChild);
    if (userText != null && supports('rewind')) {
      const rw = h('button', { class: 'ck-rewind-btn', type: 'button', title: 'Rewind to before this prompt' }, icon(ICON_REWIND));
      rw.onmousedown = e => e.preventDefault();
      el.firstChild.append(rw);
    }
    const body = h('div', { class: 'ck-body' });
    el.append(body);
    S.log.append(el);
    if (userText != null) enter(el.firstChild);
    S.turn = { el, body, run: null, t0: Date.now(), footer: null };
    S.turns.push(S.turn);
    stick();
    return S.turn;
  }
  const turn = () => S.turn || newTurn(null);

  function bindTurn(e) {
    const key = root.AgentEvents.turnKey(e.threadId || e.sessionId || S.sessionId, e.turnId);
    if (!key) return;
    let view = S.turnViews.get(key);
    if (!view) {
      view = S.turn && !S.turn.key ? S.turn : newTurn(null);
      view.key = key;
      S.turnViews.set(key, view);
    }
    S.turn = view;
    const snapshot = S.eventState.turnDiffs.get(key);
    if (snapshot) paintTurnDiff(snapshot);
    const plan = S.eventState.plans.get(key); if (plan) paintPlan(plan);
  }

  /** Preserve raw unified diff for copying; file folds only organize its lines. */
  function turnDiffFiles(diff) {
    const files = [];
    let file = null;
    for (const line of diff.split('\n')) {
      if (line.startsWith('diff --git ') || !file) {
        file = { path: 'Changes', oldPath: '', lines: [], add: 0, del: 0, inHunk: false };
        files.push(file);
        const paths = line.slice(11).match(/"(?:[^"\\]|\\.)*"|\S+/g);
        if (line.startsWith('diff --git ') && paths?.length >= 2) file.path = diffPath(paths[1]);
      }
      file.lines.push(line);
      if (!file.inHunk && line.startsWith('--- ')) file.oldPath = diffPath(line.slice(4));
      else if (!file.inHunk && line.startsWith('+++ ')) {
        const path = diffPath(line.slice(4));
        file.path = path === '/dev/null' ? file.oldPath : path;
      } else if (!file.inHunk && line.startsWith('rename to ')) file.path = line.slice(10);
      else if (line.startsWith('@@')) file.inHunk = true;
      else if (file.inHunk && line.startsWith('+')) file.add++;
      else if (file.inHunk && line.startsWith('-')) file.del++;
    }
    return files;
  }

  function diffPath(value) {
    let path = value.split('\t')[0];
    if (path.startsWith('"')) { try { path = JSON.parse(path); } catch { /* retain Git's escaped path */ } }
    return path.replace(/^[ab]\//, '');
  }

  function paintTurnDiff(e) {
    const key = root.AgentEvents.turnKey(e.threadId, e.turnId);
    const view = key && S.turnViews.get(key);
    if (!view) return; // A pre-start snapshot stays in reducer state until this turn is bound.
    const diff = S.eventState.turnDiffs.get(key)?.diff || '';
    if (!diff.trim()) {
      if (view.diffUI) view.diffUI.el.remove();
      view.diffUI = null;
      return;
    }
    if (view.diffUI?.diff === diff) return;
    if (!view.diffUI) {
      const summary = h('summary', { class: 'ck-turn-diff-summary' });
      const files = h('div', { class: 'ck-turn-diff-files' });
      const copy = h('button', { type: 'button', class: 'ck-turn-diff-copy', text: 'Copy diff' });
      const el = h('details', { class: 'ck-turn-diff', open: true }, summary, files, copy);
      view.diffUI = { el, summary, files, copy, fileViews: new Map(), diff: null };
      // A sibling of the reply body remains below later streamed text, before the footer.
      view.el.insertBefore(el, view.footer || null);
      copy.onclick = async () => {
        const ui = view.diffUI;
        if (!ui) return;
        const fallback = () => {
          const field = h('textarea', { style: 'position:fixed;opacity:0', 'aria-label': 'Diff to copy' });
          field.value = ui.diff; document.body.append(field); field.select();
          let copied = false;
          try { copied = document.execCommand('copy'); } catch { /* expose failure below */ }
          field.remove(); return copied;
        };
        let copied = false;
        try { await navigator.clipboard.writeText(ui.diff); copied = true; } catch { copied = fallback(); }
        copy.textContent = copied ? 'Copied' : 'Copy failed';
        setTimeout(() => { copy.textContent = 'Copy diff'; }, 1400);
      };
    }
    const ui = view.diffUI, files = turnDiffFiles(diff);
    ui.diff = diff;
    const add = files.reduce((n, f) => n + f.add, 0), del = files.reduce((n, f) => n + f.del, 0);
    ui.summary.textContent = `Changes · ${files.length} ${files.length === 1 ? 'file' : 'files'} · +${add} −${del}`;
    const next = new Map(), occurrences = new Map();
    ui.files.replaceChildren(...files.map((file, index) => {
      const occurrence = occurrences.get(file.path) || 0;
      occurrences.set(file.path, occurrence + 1);
      const identity = JSON.stringify([file.path, occurrence]);
      let fold = ui.fileViews.get(identity);
      if (!fold) fold = h('details', { class: 'ck-turn-diff-file', open: index === 0 }, h('summary'), h('pre', { class: 'ck-turn-diff-code' }));
      fold.firstChild.textContent = `${file.path} · +${file.add} −${file.del}`;
      let inHunk = false;
      fold.lastChild.replaceChildren(...file.lines.map(line => {
        if (line.startsWith('@@')) inHunk = true;
        return h('span', {
          class: 'ck-turn-diff-line' + (line.startsWith('@@') ? ' is-hunk' : inHunk && line.startsWith('+') ? ' is-add' : inHunk && line.startsWith('-') ? ' is-del' : ''), text: line + '\n'
        });
      }));
      next.set(identity, fold); return fold;
    }));
    ui.fileViews = next;
    stick();
  }

  // ── text blocks ────────────────────────────────────────────────────────

  function newText(key, msgId) {
    closeRun();
    const el = h('div', { class: 'sk-doc ck-text' });
    turn().body.append(el);
    const item = { el, text: '', final: false, raf: 0, reveal: !quiet() };   // reveal: a live reply's new words fade in
    S.texts.set(key, item);
    if (!S.msgTexts.has(msgId)) S.msgTexts.set(msgId, []);
    S.msgTexts.get(msgId).push(item);
    return item;
  }

  function paintText(item, streaming) {
    cancelAnimationFrame(item.raf);
    item.raf = 0;
    root.SkimRender.render(item.el, item.text, { streaming, interactive: true, reveal: item.reveal && motionOn(), onAction: a => { if (a.type === 'reply') sendUser(a.text); } });
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
    enter(el);
    const item = { key, el, head, body, verb, peek, time, caret, text: '', redacted: !!redacted,
      t0: clock(), t1: null, open: false, word: pickVerb(), ticks: 0, raf: 0, timer: 0, conv: S };
    head.onclick = () => {
      if (!item.text) return;
      item.open = !item.open;
      el.classList.toggle('is-open', item.open);
      paintThink(item);   // the preview hides while the summary shows
      if (item.open) { paintThinkBody(item); expand(body, () => { body.hidden = false; }); }
      else collapse(body, () => { body.hidden = true; });
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
    const tok = item.tokens ? ' · ~' + fmtTok(item.tokens) + ' tokens' : '';
    item.time.textContent = (live ? secs(Date.now() - item.t0) : item.t1 - item.t0 >= 1000 ? 'for ' + secs(item.t1 - item.t0) : '') + tok;
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
    TodoWrite: 'plan', TaskCreate: 'plan', TaskUpdate: 'plan', ExitPlanMode: 'plan', EnterPlanMode: 'plan', AskUserQuestion: 'plan',
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
    if (name === 'AskUserQuestion' && Array.isArray(input.questions)) return String((input.questions[0] || {}).question || '');
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

  // ── tool calls: a tray per turn, out of the reading flow ──────────────

  // The reply reads as one text: each turn's tool calls go into a tray, a pill
  // under the prompt that stays at the top of the view while you read the turn
  // and counts the calls as they run. A click opens the turn's whole tool
  // history over the reply. Where a run happened, a faint mark stays in the
  // text (it opens the tray at that run). Approval cards stay in the reply.
  // A subagent's transcript (the panel) keeps its runs inline: they are what you open it for.
  let toolsInline = false;
  try { toolsInline = localStorage.getItem('ck.toolsInline') === '1'; } catch (e) { /* storage may be blocked */ }
  let openTray = null;
  const ICON_TOOLS = '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M10.2 2.1a3.4 3.4 0 0 0-3.9 4.4L2.2 10.6a1.4 1.4 0 0 0 2 2l4.1-4.1a3.4 3.4 0 0 0 4.4-3.9l-2 2-1.9-.4-.4-1.9z" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"/></svg>';
  const usesTray = () => !S.root;

  function ensureTray(t) {
    if (t.tray) return t.tray;
    const label = h('span', { class: 'ck-tray-label' });
    const live = h('span', { class: 'ck-tray-live' });
    const pill = h('button', { class: 'ck-tray-pill', type: 'button', 'aria-expanded': 'false', title: 'Tool calls of this turn' },
      h('span', { class: 'ck-tray-ic' }, icon(ICON_TOOLS)), label, live, h('span', { class: 'sk-caret ck-tray-caret' }));
    const list = h('div', { class: 'ck-tray-list' });
    const panel = h('div', { class: 'ck-tray-panel', hidden: true, role: 'dialog', 'aria-label': 'Tool calls of this turn' }, list);
    const el = h('div', { class: 'ck-tray' }, pill, panel);
    t.el.insertBefore(el, t.body);
    const tray = { el, pill, label, live, panel, list, turn: t };
    pill.onmousedown = e => e.preventDefault();
    pill.onclick = () => openTray === tray ? closeTray() : showTray(tray);
    t.tray = tray;
    enter(el);
    return tray;
  }

  /** Opens a turn's tray (only one at a time); `run`: scroll to that run. */
  function showTray(tray, run) {
    if (openTray && openTray !== tray) closeTray();
    openTray = tray;
    tray.el.classList.add('is-open');
    tray.pill.setAttribute('aria-expanded', 'true');
    tray.panel.hidden = false;
    play(tray.panel, POP, M.fast);
    if (run) tray.panel.scrollTop = Math.max(run.el.offsetTop - 6, 0);
    else tray.panel.scrollTop = tray.panel.scrollHeight;   // the newest calls first in view
  }

  function closeTray() {
    const tray = openTray;
    if (!tray) return;
    openTray = null;
    tray.el.classList.remove('is-open');
    tray.pill.setAttribute('aria-expanded', 'false');
    tray.panel.hidden = true;
  }

  /** The pill: what ran in this turn (by phase), what fails, and what runs now. */
  function paintTray(t) {
    const tray = t && t.tray;
    if (!tray) return;
    const rows = t.runs.flatMap(r => r.list);
    const counts = {};
    let failed = 0;
    for (const r of rows) { counts[r.phase] = (counts[r.phase] || 0) + 1; if (r.state === 'error') failed++; }
    const now = rows.find(r => r.state === 'waiting') || [...rows].reverse().find(r => r.state === 'running' || r.state === 'preparing');
    const phases = Object.keys(PHASE_LABEL).filter(p => counts[p]).map(p => `${PHASE_LABEL[p]} ${counts[p]}`).join(' · ');
    tray.label.textContent = plural(rows.length, 'tool') + (phases ? ' · ' + phases : '');
    tray.live.replaceChildren(...(failed ? [h('span', { class: 'ck-tray-bad', text: failed + ' failed' })] : []),
      ...(now ? [h('span', { class: 'ck-tray-now' }, now.state === 'waiting' ? 'waiting for you · ' : '',
        shortName(now.name) + (now.argEl.textContent ? ' ' + clip(now.argEl.textContent, 40) : '') + ' · ' + secs(Date.now() - now.t0))] : []));
    tray.el.dataset.state = now ? (now.state === 'waiting' ? 'waiting' : 'running') : failed ? 'failed' : 'done';
  }

  /** The faint mark where a run happened in the reply: "3 tools", live while it runs. */
  function paintMark(run) {
    if (!run.mark) return;
    const n = run.list.length, failed = run.list.filter(r => r.state === 'error').length;
    run.mark.firstChild.textContent = plural(n, 'tool') + (failed ? ` · ${failed} failed` : '');
    const live = run.list.some(r => r.state === 'running' || r.state === 'preparing' || r.state === 'waiting');
    run.mark.dataset.state = failed ? 'failed' : live ? 'running' : 'done';
  }

  /** "Tool calls: in a tray / inline" (the ⋮ menu): moves every run of every conversation. */
  function setToolsInline(on) {
    toolsInline = !!on;
    try { on ? localStorage.setItem('ck.toolsInline', '1') : localStorage.removeItem('ck.toolsInline'); } catch (e) { /* no storage */ }
    closeTray();
    document.body.classList.toggle('tools-inline', toolsInline);
    for (const c of convs.values()) for (const t of c.turns) for (const run of t.runs || []) {
      if (!run.mark) continue;
      if (toolsInline) run.mark.after(run.el); else t.tray.list.append(run.el);
    }
  }

  function ensureRun() {
    const t = turn();
    if (t.run && !t.run.closed) return t.run;
    const rows = h('div', { class: 'ck-rows' });
    const summary = h('span', { class: 'ck-run-summary' });
    const stats = h('span', { class: 'ck-run-stats' });
    const headEl = h('button', { class: 'ck-run-head', type: 'button' }, h('span', { class: 'sk-caret ck-run-caret' }), summary, stats);
    const el = h('div', { class: 'ck-run is-live' }, headEl, rows);
    headEl.onclick = () => el.classList.contains('is-folded')
      ? expand(rows, () => el.classList.remove('is-folded'))
      : collapse(rows, () => el.classList.add('is-folded'));
    let mark = null;
    if (usesTray()) {
      // In the reply: the mark. The run itself lives in the turn's tray (or after the mark, inline).
      mark = h('button', { class: 'ck-run-mark', type: 'button', title: 'Show these tool calls' }, h('span', { class: 'ck-run-mark-t' }));
      mark.onmousedown = e => e.preventDefault();
      t.body.append(mark);
      if (toolsInline) mark.after(el); else ensureTray(t).list.append(el);
      enter(toolsInline ? el : mark);
    } else { t.body.append(el); enter(el); }
    t.run = { el, rows, summary, stats, list: [], t0: clock(), t1: null, closed: false, timer: 0, mark, turn: t };
    (t.runs || (t.runs = [])).push(t.run);
    const run = t.run;
    if (mark) mark.onclick = () => { if (toolsInline) return; showTray(t.tray, run); };
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
    // A long run folds to its summary, in the reply; in the tray, which you open to read, it stays open.
    if (run.list.length > 3 && !run.list.some(r => r.state === 'error') && (!run.mark || toolsInline)) run.el.classList.add('is-folded');
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
    paintMark(run);
    paintTray(run.turn);
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
    const agentRow = isAgentTool(name);
    const line = h('div', { class: 'ck-row' + (parentId ? ' is-sub' : '') + (agentRow ? ' is-agent' : '') }, icon, nameEl, badge, argEl, h('span', { class: 'ck-track' }, bar), metaEl);
    const detail = h('div', { class: 'ck-detail', hidden: true });
    const top = S.root || S;
    // An Agent row opens the subagent's transcript; other rows fold their output open.
    line.onclick = agentRow ? () => openSub(top, id)
      : () => {
        if (!detail.childNodes.length) return;
        if (detail.hidden) expand(detail, () => { detail.hidden = false; fitChanges(detail); });
        else collapse(detail, () => { detail.hidden = true; });
      };
    if (agentRow) line.title = 'Show what this agent did';
    const row = { id, name, input: {}, phase: 'explore', state: 'preparing', t0: clock(), t1: null, waitMs: 0, waitStart: 0,
      line, detail, icon, argEl, metaEl, bar, badge, waitBar: bar.firstChild, run, top, output: null };
    run.rows.append(line, detail);
    if (run.list.length) enter(line);   // the first row comes with its run, which rises in itself
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
    if (row.run && row.run.mark) { paintMark(row.run); paintTray(row.run.turn); }
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
      if ((agent !== 'codex' && req.suppressAlwaysAllowRule) || req.defaultToNo || DESTRUCTIVE.test(cmd)) return ['high', 'Destructive'];
      if (READ_CMD.test(cmd) || VERIFY_CMD.test(cmd)) return ['low', 'Shell · read-only'];
      return ['mid', 'Runs a command'];
    }
    if (/^(Edit|MultiEdit|Write|NotebookEdit|File changes)$/.test(req.toolName)) return [req.defaultToNo ? 'high' : 'mid', req.toolName === 'Write' ? 'Writes a file' : 'Edits a file'];
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
    if (Array.isArray(inp?.changes) && inp.changes.length) {
      return h('div', { class: 'ck-file-changes' }, inp.changes.map(change =>
        h('details', null, h('summary', { text: change.path || 'File change' }),
          h('pre', { class: 'ck-json', text: change.diff || JSON.stringify(change, null, 2) }))));
    }
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

  const optBtn = (key, label, fn, cls) => {
    const b = h('button', { class: 'ck-opt' + (cls ? ' ' + cls : ''), type: 'button' }, h('span', { class: 'ck-key', text: key }), label);
    b.onclick = fn;
    return b;
  };

  /** Puts a finished card in the flow and books it: its keys, the row waiting on it, the status line. */
  function registerCard(req, card, keys, opts) {
    turn().body.append(card);
    enter(card);
    S.cards.set(req.id, { card, keys, req, opts });
    const row = req.toolUseID && rowAnywhere(req.toolUseID);
    if (row) { row.waitStart = clock(); setRowState(row, 'waiting'); }
    updateStatus();
    stick();
  }

  function addCard(req) {
    if (req.kind) { addNativeCard(req); return; }
    if (agent === 'claude' && req.toolName === 'AskUserQuestion' && Array.isArray(req.input && req.input.questions) && req.input.questions.length) { addQuestionCard(req); return; }
    if (agent === 'claude' && req.toolName === 'ExitPlanMode' && typeof (req.input && req.input.plan) === 'string') { addPlanCard(req); return; }
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
      why && h('div', { class: 'ck-why' }, h('span', { class: 'ck-why-k', text: (agent === 'codex' ? 'Codex' : 'Claude') + '\'s reason · ' }), why),
      opts);
    const choose = (decision, message) => {
      if (card.dataset.done) return;
      card.dataset.done = '1';
      post({ type: 'permission', id: req.id, decision, message });
      resolveCard(req.id, decision === 'deny' ? 'denied' : decision === 'allowAlways' ? 'always' : 'allowed', always);
    };
    const btn = optBtn;
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
    const decline = () => agent === 'codex' ? choose('deny') : showNo();
    const noBtn = btn(noKey, agent === 'codex' ? 'No' : 'No, and tell Claude what to do differently', decline, 'is-no');
    opts.append(noBtn);
    keys[noKey] = decline;
    const noForm = h('div', { class: 'ck-no', hidden: true });
    const noInput = h('textarea', { class: 'ck-no-input', rows: '2', placeholder: 'What should ' + (agent === 'codex' ? 'Codex' : 'Claude') + ' do instead? (optional)' });
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
    registerCard(req, card, keys, opts);
    if (req.defaultToNo && inView()) noBtn.focus();
  }

  /** `custom`: what the outcome line says instead of the standard label (a node, a string, or a list of them). */
  function resolveCard(id, outcome, always, custom) {
    const c = S.cards.get(id);
    if (!c) return;
    S.cards.delete(id);
    const labels = { allowed: 'Allowed once', always: 'Allowed · rule added ' + (always ? always.where : ''), denied: 'Declined', cancelled: 'Cancelled' };
    const outcomeEl = h('div', { class: 'ck-outcome', 'data-outcome': outcome },
      h('span', { class: 'ck-outcome-dot' }), custom || labels[outcome] || outcome,
      outcome === 'always' && always && always.rules.length ? h('code', { text: always.rules.join(', ') }) : null);
    c.opts.replaceWith(outcomeEl);
    if (!quiet()) play(outcomeEl, FADE, M.mid);
    c.card.classList.add('is-resolved');
    const row = c.req.toolUseID && rowAnywhere(c.req.toolUseID);
    if (row && row.waitStart) { row.waitMs += clock() - row.waitStart; row.waitStart = 0; setRowState(row, outcome === 'denied' || outcome === 'cancelled' ? 'error' : 'running'); }
    updateStatus();
  }

  // ── dialog tools: AskUserQuestion and ExitPlanMode get their own cards ──

  /**
   * AskUserQuestion: the questions as one card. The answers go back in the
   * tool's input ({ ...input, answers: { [question]: answer } }); Skip declines.
   * Number keys answer the current question (the first one not yet answered).
   */
  function addQuestionCard(req) {
    closeRun();
    const qs = req.input.questions.map(q => ({ ...q, options: Array.isArray(q.options) ? q.options : [] }));
    const st = qs.map(() => ({ picked: new Set(), other: false, otherText: '' }));
    const answerOf = i => {
      const s = st[i], labels = [...s.picked].sort((a, b) => a - b).map(n => String(qs[i].options[n].label));
      const other = s.other && s.otherText.trim() ? s.otherText.trim() : null;
      const all = other ? [...labels, other] : labels;
      return all.length ? all.join(', ') : null;
    };
    const complete = () => qs.every((_, i) => answerOf(i) != null);
    let cur = 0;
    const keys = {};

    const parts = qs.map((q, qi) => {
      const mark = () => h('span', { class: q.multiSelect ? 'ck-check' : 'ck-radio' });
      const opts = q.options.map((o, oi) => {
        const b = optBtn('', [mark(), h('span', { class: 'ck-q-opt-main' },
          h('span', { class: 'ck-q-opt-l', text: String(o.label) }),
          o.description ? h('span', { class: 'ck-q-opt-d', title: String(o.description), text: String(o.description) }) : null)], () => pick(qi, oi), 'ck-q-opt');
        b.onmouseenter = b.onfocus = () => showPreview(qi, oi);
        b.onmouseleave = b.onblur = () => showPreview(qi, chosenPreview(qi));
        return b;
      });
      const other = optBtn('', [mark(), h('span', { class: 'ck-q-opt-main' }, h('span', { class: 'ck-q-opt-l', text: 'Other' }))], () => pick(qi, q.options.length), 'ck-q-opt is-other');
      const otherIn = h('input', { class: 'ck-q-other', type: 'text', placeholder: 'Type your answer', hidden: true });
      otherIn.oninput = () => { st[qi].otherText = otherIn.value; paint(); };
      otherIn.onkeydown = e => {
        e.stopPropagation();
        if (e.key === 'Enter') { e.preventDefault(); if (complete()) submit(); }
      };
      otherIn.onfocus = () => { cur = qi; paint(); };
      const prev = h('div', { class: 'sk-doc ck-q-prev', hidden: true });
      const el = h('div', { class: 'ck-q' },
        q.header ? h('div', { class: 'ck-q-h', text: String(q.header) }) : null,
        h('div', { class: 'ck-q-t', text: String(q.question || '') }),
        h('div', { class: 'ck-q-opts' }, opts, other), otherIn, prev);
      el.addEventListener('pointerdown', () => { if (cur !== qi) { cur = qi; paint(); } });
      return { el, opts, other, otherIn, prev };
    });
    // The option whose preview stays up when the pointer leaves: the chosen one (single choice only).
    const chosenPreview = qi => { const n = qs[qi].multiSelect ? null : [...st[qi].picked][0]; return n != null && qs[qi].options[n].preview ? n : -1; };
    function showPreview(qi, oi) {
      const p = parts[qi].prev, md = oi >= 0 && qs[qi].options[oi] ? qs[qi].options[oi].preview : null;
      if (!md) { p.hidden = true; return; }
      if (p.dataset.at !== String(oi)) { root.SkimRender.render(p, String(md), { streaming: false, interactive: false }); p.dataset.at = String(oi); }
      p.hidden = false;
    }

    function paint() {
      qs.forEach((q, qi) => {
        const { el, opts, other, otherIn } = parts[qi], s = st[qi], live = qi === cur && !card.dataset.done;
        el.classList.toggle('is-cur', live);
        el.classList.toggle('is-done', answerOf(qi) != null);
        opts.forEach((b, oi) => { b.classList.toggle('is-on', s.picked.has(oi)); b.firstChild.textContent = live ? String(oi + 1) : ''; });
        other.classList.toggle('is-on', s.other);
        other.firstChild.textContent = live ? String(q.options.length + 1) : '';
        otherIn.hidden = !s.other;
      });
      go.disabled = !complete();
      for (const k of Object.keys(keys)) delete keys[k];
      const n = qs[cur].options.length;
      for (let oi = 0; oi <= n && oi < 9; oi++) keys[String(oi + 1)] = () => pick(cur, oi);
      keys.Enter = e => { if ((e && e.target && e.target.tagName === 'BUTTON') || !complete()) return false; submit(); };
    }

    function pick(qi, oi) {
      if (card.dataset.done) return;
      const q = qs[qi], s = st[qi];
      if (oi === q.options.length) {   // Other
        if (q.multiSelect) s.other = !s.other;
        else { s.picked.clear(); s.other = true; }
      } else if (q.multiSelect) {
        if (!s.picked.delete(oi)) s.picked.add(oi);
      } else { s.picked = new Set([oi]); s.other = false; }
      cur = qi;
      if (s.other) { parts[qi].otherIn.hidden = false; parts[qi].otherIn.focus(); }
      else if (!q.multiSelect) { const next = qs.findIndex((_, i) => answerOf(i) == null); if (next >= 0) cur = next; }
      paint();
      showPreview(qi, chosenPreview(qi));
    }

    function submit() {
      if (card.dataset.done || !complete()) return;
      card.dataset.done = '1';
      const answers = {};
      qs.forEach((q, i) => { answers[q.question] = answerOf(i); });
      post({ type: 'permission', id: req.id, decision: 'allow', updatedInput: { ...req.input, answers } });
      resolveCard(req.id, 'allowed', null, h('span', { class: 'ck-answers' }, qs.map((q, i) =>
        h('span', { class: 'ck-answer' }, h('span', { class: 'ck-answer-h', text: String(q.header || q.question) }), ' · ', answerOf(i)))));
    }
    function skip() {
      if (card.dataset.done) return;
      card.dataset.done = '1';
      post({ type: 'permission', id: req.id, decision: 'deny', message: 'The user chose not to answer these questions.' });
      resolveCard(req.id, 'denied', null, 'Skipped');
    }

    const go = h('button', { class: 'sk-btn ck-go', type: 'button', text: 'Answer', disabled: true });
    go.onclick = submit;
    const body = h('div', { class: 'ck-ask' }, parts.map(p => p.el),
      h('div', { class: 'ck-ask-foot' }, go, h('button', { class: 'sk-btn', type: 'button', text: 'Skip', onclick: skip }),
        h('span', { class: 'ck-ask-hint', text: 'number keys choose · Enter sends' })));
    const card = h('div', { class: 'ck-card ck-ask-card', 'data-risk': 'info' },
      h('div', { class: 'ck-card-head' }, h('span', { class: 'ck-risk' }, h('span', { class: 'ck-risk-dot' }), 'Question'), h('span', { class: 'ck-card-title', text: 'Claude asks' })),
      body);
    paint();
    registerCard(req, card, keys, body);
  }

  /**
   * ExitPlanMode: the plan to read, then how to go on. Approving can switch the
   * permission mode for the session; declining keeps Claude planning.
   */
  function addPlanCard(req) {
    closeRun();
    const inp = req.input, keys = {};
    const box = h('div', { class: 'sk-doc ck-plan-box' });
    root.SkimRender.render(box, inp.plan, { streaming: false, interactive: false });
    let big = false;
    const expT = h('span', { class: 'ck-chg-exp-t', text: 'Expand' });
    const expand = h('button', { type: 'button', class: 'ck-chg-exp', hidden: true, title: 'Show more of the plan' }, h('span', { class: 'sk-caret ck-chg-exp-ic' }), expT);
    const wrap = h('div', { class: 'ck-plan-wrap' }, h('div', { class: 'ck-plan-bar' }, h('span', { class: 'ck-plan-k', text: 'Plan' }), h('span', { class: 'ck-spacer' }), expand), box);
    // A timer, not requestAnimationFrame: it has to run in a hidden or offscreen view too.
    const fit = () => setTimeout(() => { if (box.clientHeight) expand.hidden = !big && box.scrollHeight <= box.clientHeight + 2; }, 0);
    expand.onclick = () => {
      big = !big;
      wrap.classList.toggle('is-big', big);
      card.classList.toggle('is-wide', big);
      expT.textContent = big ? 'Collapse' : 'Expand';
      if (!big) wrap.scrollIntoView({ block: 'nearest' });
      fit();
    };
    const asks = (Array.isArray(inp.allowedPrompts) ? inp.allowedPrompts : []).filter(p => p && p.prompt);
    const also = asks.length ? h('div', { class: 'ck-plan-also' }, h('span', { class: 'ck-plan-also-k', text: 'Also asks to run: ' }),
      asks.map(p => h('span', { class: 'ck-plan-cmd', title: p.tool || null, text: String(p.prompt) }))) : null;

    const done = (msg, outcome, text) => {
      if (card.dataset.done) return;
      card.dataset.done = '1';
      post({ type: 'permission', id: req.id, ...msg });
      const toggle = h('button', { class: 'ck-plan-toggle', type: 'button', text: 'Show plan' });
      toggle.onclick = () => { toggle.textContent = card.classList.toggle('is-plan-open') ? 'Hide plan' : 'Show plan'; fit(); };
      resolveCard(req.id, outcome, null, [text, h('span', { class: 'ck-spacer' }), toggle]);
    };
    const approve = (mode, text) => () => done({ decision: 'allow', updatedPermissions: [{ type: 'setMode', mode, destination: 'session' }] }, 'allowed', text);
    const opts = h('div', { class: 'ck-opts' });
    const noForm = h('div', { class: 'ck-no', hidden: true });
    const noInput = h('textarea', { class: 'ck-no-input', rows: '2', placeholder: 'What should change in the plan? (optional)' });
    const noSend = h('button', { class: 'sk-btn', type: 'button', text: 'Keep planning' });
    noForm.append(noInput, noSend);
    const showNo = () => { noForm.hidden = false; noInput.focus(); };
    noSend.onclick = () => {
      const fb = noInput.value.trim();
      done({ decision: 'deny', message: 'The user wants to keep planning.' + (fb ? ' Feedback: ' + fb : '') }, 'denied',
        'Kept planning' + (fb ? ' · “' + (fb.length > 120 ? fb.slice(0, 120) + '…' : fb) + '”' : ''));
    };
    noInput.onkeydown = e => {
      e.stopPropagation();
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); noSend.click(); }
      if (e.key === 'Escape') noForm.hidden = true;
    };
    keys['1'] = approve('acceptEdits', 'Approved · auto-accept edits');
    keys['2'] = approve('default', 'Approved · ask before each edit');
    keys['3'] = showNo;
    opts.append(optBtn('1', 'Yes, and auto-accept edits', keys['1']), optBtn('2', 'Yes, and ask before each edit', keys['2']),
      optBtn('3', 'No, keep planning', showNo, 'is-no'), noForm);
    const card = h('div', { class: 'ck-card ck-plan-card', 'data-risk': 'info' },
      h('div', { class: 'ck-card-head' }, h('span', { class: 'ck-risk' }, h('span', { class: 'ck-risk-dot' }), 'Plan'), h('span', { class: 'ck-card-title', text: 'Ready to code?' })),
      wrap, also, opts);
    registerCard(req, card, keys, opts);
    fit();
  }

  document.addEventListener('keydown', e => {
    if (!S.cards.size || e.metaKey || e.ctrlKey || e.altKey) return;
    const t = e.target;
    // A field inside a card (the reason, "Other") is for typing, so its digits stay digits.
    if (t && (t.tagName === 'TEXTAREA' || t.tagName === 'INPUT') && (t.value || (t.closest && t.closest('.ck-card')))) return;
    const last = Array.from(S.cards.values()).pop();
    const fn = last.keys[e.key];
    if (fn && fn(e) !== false) e.preventDefault();
  });

  // ── permission modes, models, effort ───────────────────────────────────

  const MODE_INFO = [
    { mode: 'default', label: 'Ask', desc: 'Asks before it edits files or runs commands' },
    { mode: 'acceptEdits', label: 'Accept edits', desc: 'Edits files without asking; asks before commands' },
    { mode: 'plan', label: 'Plan', desc: 'Reads and plans only; changes nothing' },
    { mode: 'auto', label: 'Auto', desc: 'A classifier approves safe actions and asks about risky ones' }
  ];
  const MODE_LABEL = { default: 'Ask', acceptEdits: 'Accept edits', plan: 'Plan', auto: 'Auto', bypassPermissions: 'Bypass', dontAsk: "Don't ask" };
  const CODEX_MODES = [
    { mode: 'default', label: 'Workspace write', desc: 'Work inside the sandbox; ask before actions that need additional permission' },
    { mode: 'plan', label: 'Read only', desc: 'Use a read-only sandbox; ask before actions that need additional permission' }
  ];

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
    if (agent === 'codex') return CODEX_MODES;
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
    modelEl.hidden = !supports('models');
    modeBtn.hidden = !supports('permissionMode');
    costEl.hidden = !supports('usage');
    // "Opus 5.5" stays; " · 1M · high" is the part a narrow panel drops.
    const [name, ...extra] = (modelLabel(S.model) || 'Model').split(' · ');
    if (S.effort) extra.push(S.effort);
    modelEl.firstChild.replaceChildren(name, extra.length ? h('span', { class: 'ck-model-x', text: ' · ' + extra.join(' · ') }) : '');
    modeBtn.firstChild.textContent = agent === 'codex' ? (CODEX_MODES.find(m => m.mode === S.mode)?.label || S.mode) : MODE_LABEL[S.mode] || S.mode;
    modeBtn.dataset.mode = S.mode;
    const pct = S.ctx && S.ctx.maxTokens ? Math.round(S.ctx.totalTokens / S.ctx.maxTokens * 100) : null;
    costEl.firstChild.textContent = [agent === 'codex' ? (S.tokens ? fmtTok(S.tokens.totalTokens) + ' tokens' : null) : S.cost ? '$' + S.cost.toFixed(2) : null, pct != null ? pct + '%' : null].filter(Boolean).join(' · ') || 'Usage';
    costEl.title = (agent === 'codex' ? 'Usage: tokens, context, account limits' : 'Usage: session cost, context, plan limits') + (pct != null ? ` (context ${pct}% full)` : '');
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
    const was = P.kind;
    P.kind = kind; P.anchor = anchor; P.build = build; P.sel = -1;
    popEl.hidden = false;
    refreshPop();
    // Opens from its chip (menus) or from the composer (suggestions); a switch between suggestion lists does not replay it.
    if (!popEl.hidden && !(was && (was === 'slash' || was === 'mention') && (kind === 'slash' || kind === 'mention')))
      play(popEl, [{ opacity: 0, transform: 'translateY(4px) scale(.98)' }, { opacity: 1, transform: 'none' }], M.fast);
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
    const { head, items, foot, empty, keep } = P.build();   // keep: stay open, saying `empty`, with no items
    if (!items.length && !head && !foot && !keep) { closePop(); return; }
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

  /** Above the composer for suggestions (slash commands, @-mentions); above the status line, right-aligned to its chip, for menus. */
  function placePop() {
    const box = dockIn.getBoundingClientRect();
    if (P.kind === 'slash' || P.kind === 'mention' || P.kind === 'rewind') {
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
    if (!supports('models')) return;
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
    if (!supports('permissionMode')) return;
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
    if (!supports('permissionMode')) return;
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
    if (!supports('usage')) return;
    const show = open != null ? open : usagePanel.hidden;
    const was = !usagePanel.hidden;
    costEl.classList.toggle('is-open', show);
    closePop();
    if (show) { requestUsage(true); paintUsage(); }
    if (show && !was) expand(usagePanel, () => { usagePanel.hidden = false; });
    else if (!show && was) collapse(usagePanel, () => { usagePanel.hidden = true; });
    stick();
  }

  function requestUsage(plan) {
    if (!supports('usage')) return;
    // Plan limits cost a network call: at most once a minute.
    const withPlan = plan && Date.now() - S.planAt > 60e3;
    if (withPlan) SHARED.planAt = Date.now();
    post({ type: 'usage', plan: withPlan });
  }

  function paintUsage() {
    if (agent === 'codex') { paintCodexUsage(); return; }
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

  function paintCodexUsage() {
    const t = S.tokens, c = S.ctx;
    const session = h('div', { class: 'ck-u-col' },
      h('div', { class: 'ck-u-k', text: 'Session tokens' }),
      h('div', { class: 'ck-u-big', text: t ? fmtTok(t.totalTokens) : '—' }),
      h('div', { class: 'ck-u-line', text: t ? `in ${fmtTok(t.inputTokens || 0)} · out ${fmtTok(t.outputTokens || 0)}` : 'No token usage reported yet' }),
      t ? h('div', { class: 'ck-u-line', text: `cached ${fmtTok(t.cachedInputTokens || 0)} · reasoning ${fmtTok(t.reasoningOutputTokens || 0)}` }) : null);
    const context = h('div', { class: 'ck-u-col' }, h('div', { class: 'ck-u-k', text: 'Context' }),
      c && c.maxTokens ? [h('div', { class: 'ck-u-big' }, fmtTok(c.totalTokens), h('span', { class: 'ck-u-of', text: ' / ' + fmtTok(c.maxTokens) })), meter(c.totalTokens / c.maxTokens * 100)] : h('div', { class: 'ck-u-line', text: 'No context usage reported yet' }));
    const plan = h('div', { class: 'ck-u-col' }, h('div', { class: 'ck-u-k', text: 'Account limits' + (S.plan?.subscription ? ' · ' + S.plan.subscription : '') }),
      S.plan?.available && S.plan.limits?.length ? S.plan.limits.map(l => h('div', { class: 'ck-u-limit' },
        h('div', { class: 'ck-u-line' }, h('span', { text: l.label || LIMIT_LABEL[l.kind] || l.kind }), h('span', { text: Math.round(l.percent) + '%' })),
        meter(l.percent), l.resets_at ? h('div', { class: 'ck-u-line', text: resetsIn(l.resets_at) }) : null))
        : h('div', { class: 'ck-u-line', text: S.usageUnavailable || 'No account limits reported yet' }));
    usagePanel.replaceChildren(session, context, plan);
  }

  // ── slash commands ─────────────────────────────────────────────────────

  /** Commands the page runs itself (they need a menu, or leave the page). */
  const LOCAL_CMDS = [
    { name: 'tui', description: 'Open this session in the Claude Code TUI', argumentHint: '', local: true },
    { name: 'resume', aliases: ['continue'], description: 'Resume a conversation from this folder', argumentHint: '[search]', local: true },
    { name: 'exit', aliases: ['quit'], description: 'Close this tab (in a side chat: close the side chat)', argumentHint: '', local: true },
    { name: 'rename', aliases: ['name'], description: 'Name this conversation (/resume lists it by name)', argumentHint: '[name]', local: true, needs: 'rename' },
    { name: 'btw', description: 'Ask a quick side question: answered from this conversation, not added to it', argumentHint: '[question]', local: true, needs: 'btw' },
    { name: 'rewind', aliases: ['checkpoint'], description: 'Go back to before an earlier prompt: code, conversation or both (Esc Esc)', argumentHint: '', local: true, needs: 'rewind' },
    { name: 'voice', description: 'Dictate your message: the mic button (macOS speech recognition)', argumentHint: '', local: true, needs: 'voice' }
  ];
  const CODEX_CMDS = [
    { name: 'model', description: 'Choose the Codex model', argumentHint: '[model]' },
    { name: 'effort', description: 'Choose reasoning effort', argumentHint: '[level]' },
    { name: 'usage', description: 'Session tokens, context and account limits' },
    { name: 'status', description: 'Session, model, workspace and usage' },
    { name: 'permissions', description: 'Choose workspace-write or read-only sandboxing' },
    { name: 'new', aliases: ['clear'], description: 'Start a new conversation' },
    { name: 'compact', description: 'Compact this conversation' },
    { name: 'fork', description: 'Open a side chat from this conversation' },
    { name: 'help', description: 'Show the available commands' }
  ].map(c => ({ ...c, local: true }));
  const HIDDEN_CMD = c => c.name.startsWith('__') || /^\((removed)\)|^Renamed to /.test(c.description || '') || S.terminalCmds.has(c.name);

  const commandList = () => {
    const seen = new Set(), out = [];
    for (const c of [...LOCAL_CMDS.map(c => agent === 'codex' && c.name === 'tui' ? { ...c, description: 'Open this session in the Codex TUI' } : c), ...(agent === 'codex' ? CODEX_CMDS : []), ...S.commands]) {
      if (seen.has(c.name) || HIDDEN_CMD(c) || (c.needs && !supports(c.needs))) continue;
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
    if (!supports('slashCommands')) { if (P.kind === 'slash') closePop(); return; }
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
    if (!supports('slashCommands')) return false;
    const m = text.match(/^\/(\S+)(?:\s+(.*))?$/);
    if (!m) return false;
    const cmd = findCmd(m[1]);
    const name = cmd ? cmd.name : m[1].toLowerCase();
    const arg = (m[2] || '').trim();
    if (agent === 'codex') {
      if (name === 'help') { localOutput(commandList().map(c => `- **/${c.name}** — ${c.description}`).join('\n')); return true; }
      if (name === 'status') { toggleUsage(true); openMoreMenu(); return true; }
      if (name === 'permissions') { openModeMenu(); return true; }
      if (name === 'fork') { newSide(); return true; }
      if (name === 'new' || name === 'compact') {
        if (S.busy || S.cards.size) notice('info', 'Stop the current turn or answer its approval before changing the conversation.');
        else post({ type: name === 'new' ? 'newConversation' : 'compact' });
        return true;
      }
      if (!cmd) { notice('info', `Unknown command /${name}. Type /help to see available commands.`); return true; }
    }
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
    if (name === 'voice' && supports('voice')) { toggleVoice(); return true; }
    if (name === 'rewind' && supports('rewind')) { openRewindPicker(); return true; }
    if (name === 'btw' && supports('btw')) { openBtw(arg); return true; }
    if (name === 'rename' && supports('rename')) {
      if (!arg) { startRename(); return true; }
      if (!S.sessionId) { notice('info', 'Send a message first: the conversation gets its name after it starts.'); return true; }
      post({ type: 'rename', title: arg });
      S.title = arg; S.titleCustom = true;
      if (SHARED.sessions) SHARED.sessions = null;   // /resume reads the new name
      notice('info', `Named this conversation “${arg}”.`);
      return true;
    }
    if (name === 'model' && !arg) { openModelMenu(); return true; }
    if (name === 'model') {
      if (agent === 'codex' && !S.models.some(m => m.value === arg)) { notice('info', `Unknown model: ${arg}. Choose one from /model.`); return true; }
      setModel(arg); notice('info', `Model set to ${arg}.`); return true;
    }
    if (name === 'effort' && !arg) { openModelMenu(); return true; }
    if (name === 'effort' && [...(currentModelRow()?.supportedEffortLevels || EFFORT_ORDER), 'auto'].includes(arg)) { setEffort(arg === 'auto' ? null : arg); notice('info', `Effort set to ${arg === 'auto' ? 'the model default' : arg}.`); return true; }
    if (name === 'usage' && !arg) { toggleUsage(true); return true; }
    if (agent === 'codex') { notice('info', `Invalid arguments for /${name}.`); return true; }
    return false;
  }

  // ── @ mentions: files, folders and subagents ──────────────────────────

  const MENTION_RE = /(^|\s)@("[^"]*|[^\s@"]*)$/;
  /** Claude Code's file search answers, by query; `inflight` is the query we wait for. */
  const MEN = { seq: 0, timer: 0, inflight: null, cache: new Map(), last: null };
  /** `@path`, or `@"path with spaces"` (`closed`: with the closing quote). */
  const asMention = (path, closed) => /\s/.test(path) ? '@"' + path + (closed ? '"' : '') : '@' + path;

  /** The @-token the caret is in: { query, start (of the "@"), caret }, or null. */
  function mentionState() {
    if (!supports('mentions') || !input || input.selectionStart !== input.selectionEnd) return null;
    const caret = input.selectionStart;
    const m = input.value.slice(0, caret).match(MENTION_RE);
    if (!m) return null;
    const raw = m[2];
    return { query: raw.startsWith('"') ? raw.slice(1) : raw, start: caret - raw.length - 1, caret };
  }

  /** Asks the host for files matching `query`, after a short pause in typing. */
  function wantFiles(query) {
    const hit = MEN.cache.get(query);
    if (hit && Date.now() - hit.at < 30e3) { MEN.inflight = null; return; }
    MEN.inflight = query;
    clearTimeout(MEN.timer);
    MEN.timer = setTimeout(() => post({ type: 'files', query, id: ++MEN.seq }), 80);
  }

  /** The host's answer. Only the latest request counts. */
  function onFiles(e) {
    if (e.id !== MEN.seq) return;
    const list = (e.suggestions || []).map(x => String(x && x.path || '')).filter(Boolean);
    // An empty answer may only mean the index is not ready yet: do not keep it.
    if (list.length) { MEN.cache.set(e.query, { at: Date.now(), list }); if (MEN.cache.size > 60) MEN.cache.delete(MEN.cache.keys().next().value); }
    else MEN.cache.delete(e.query);
    MEN.last = { query: e.query, list };
    if (MEN.inflight === e.query) MEN.inflight = null;
    if (P.kind === 'mention' && inView()) refreshPop();
  }

  function buildMention() {
    const st = mentionState();
    if (!st) return { items: [] };
    const q = st.query, ql = q.toLowerCase();
    const items = [];
    for (const a of (S.agents || []).filter(a => a && a.name && ('agent-' + a.name).toLowerCase().includes(ql)).slice(0, 5)) {
      items.push({ mono: true, title: ['@', mark('agent-' + a.name, q)], desc: a.description || null,
        side: h('span', { class: 'ck-pop-tag', text: 'agent' }), run: () => pickMention(st, 'agent-' + a.name, false) });
    }
    const hit = MEN.cache.get(q);
    // While the answer is on its way, the last one, narrowed to what still matches, keeps the list from blinking.
    const files = hit ? hit.list : MEN.last ? MEN.last.list.filter(p => p.toLowerCase().includes(ql)) : [];
    for (const p of files.slice(0, 15)) {
      const dir = p.endsWith('/');
      items.push({ mono: true, title: mark(p, q), side: dir ? h('span', { class: 'ck-pop-tag', text: 'folder' }) : null, run: () => pickMention(st, p, dir) });
    }
    return { items, keep: true, empty: !hit && MEN.inflight === q ? 'Searching files…' : `No file matches @${q}` };
  }

  /** Puts the mention where the token was. A folder stays open, to go on down into it. */
  function pickMention(st, path, dir) {
    const v = input.value, rest = v.slice(st.caret);
    const token = asMention(path, !dir);
    let gap = '', after = rest;
    if (!dir) { if (/^\s/.test(rest)) { gap = rest[0]; after = rest.slice(1); } else gap = ' '; }
    input.value = v.slice(0, st.start) + token + gap + after;
    const at = st.start + token.length + gap.length;
    input.setSelectionRange(at, at);
    grow(); updateStatus(); updateSuggest();
  }

  function updateMention() {
    const st = mentionState();
    if (!st) { if (P.kind === 'mention') closePop(); return false; }
    wantFiles(st.query);
    if (P.kind !== 'mention') openPop('mention', composer, buildMention);
    else { P.sel = -1; refreshPop(); }
    return true;
  }

  /** The composer's suggestions: an @-mention anywhere (also inside a command's arguments), else slash commands. */
  function updateSuggest() {
    if (updateMention()) return;
    updateSlash();
  }

  /** Text at the caret, set off from its neighbours by spaces; the caret ends after it. */
  function insertAtCaret(text) {
    input.focus();
    const v = input.value, before = v.slice(0, input.selectionStart), after = v.slice(input.selectionEnd);
    const head = before + (before && !/\s$/.test(before) ? ' ' : '') + text + (/^\s/.test(after) ? '' : ' ');
    input.value = head + after;
    input.setSelectionRange(head.length, head.length);
    grow(); updateStatus(); updateSuggest();
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
    if (refBtn.hidden) play(refBtn, POP, M.fast);
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
    if (!S.refs.some(x => x.text === r.text)) S.refs.push({ text: r.text, from: r.from, seq: ++chipSeq });
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
    hidePeek();
    const chips = [...S.refs.map((r, i) => ({ seq: r.seq || 0, el: refChip(r, () => { S.refs.splice(i, 1); paintRefs(); updateStatus(); input.focus(); }) })),
      ...S.images.map((im, i) => ({ seq: im.seq, el: imageChip(im, i) }))].sort((a, b) => a.seq - b.seq);
    refsEl.replaceChildren(...chips.map(c => c.el));
    refsEl.hidden = !chips.length;
    // Only a chip added since the last paint pops in (a removal redraws the rest in place).
    const seen = S.chipSeen || 0;
    for (const c of chips) if (c.seq > seen) play(c.el, POP, M.fast);
    S.chipSeen = Math.max(seen, ...chips.map(c => c.seq));
    input.placeholder = chips.length ? 'Say what to do with it…  (⌫ removes the last one)' : `Message ${agent === 'codex' ? 'Codex' : 'Claude'}…${supports('slashCommands') ? '  / for commands' : ''} · ⇧↩ new line`;
    if (P.kind) placePop();
  }

  // ── images: pasted or dropped, sent with the next message ─────────────

  const IMG_MAX = 10, IMG_BYTES = 5 * 1024 * 1024, IMG_SIDE = 2000, IMG_TO = 1568, IMG_OK = /^image\/(png|jpeg|gif|webp)$/;
  const imageLabel = (im, i) => `Image ${i + 1}` + (im.w ? ` · ${im.w}×${im.h}` : '');

  const readDataUrl = file => new Promise((res, rej) => { const r = new FileReader(); r.onload = () => res(String(r.result)); r.onerror = () => rej(r.error); r.readAsDataURL(file); });
  const loadImage = url => new Promise((res, rej) => { const im = new Image(); im.onload = () => res(im); im.onerror = () => rej(new Error('cannot decode')); im.src = url; });

  /** A notice in another conversation than the one being processed. */
  function inConv(conv, fn) { const prev = S; S = conv; try { fn(); } finally { S = prev; } }

  /**
   * Adds an image to the next message. One over 5 MB or 2000 px on its long side
   * is drawn smaller first (long side 1568 px; PNG stays PNG when that is small enough, else JPEG).
   */
  async function attachImage(src, conv = S) {
    if (!supports('images') || !src || !src.data) return;
    const say = text => inConv(conv, () => notice('info', text));
    if (conv.images.length >= IMG_MAX) { say(`At most ${IMG_MAX} images go with one message.`); return; }
    let { mediaType, data } = src, url = `data:${mediaType};base64,${data}`, img;
    try { img = await loadImage(url); } catch (e) { say(`${src.name || 'That file'} is not an image that can be sent.`); return; }
    let w = img.naturalWidth, ht = img.naturalHeight;
    if (data.length > IMG_BYTES || Math.max(w, ht) > IMG_SIDE || !IMG_OK.test(mediaType)) {
      const k = Math.min(1, IMG_TO / Math.max(w, ht));
      const cv = document.createElement('canvas');
      cv.width = w = Math.max(1, Math.round(w * k)); cv.height = ht = Math.max(1, Math.round(ht * k));
      const cx = cv.getContext('2d');
      cx.drawImage(img, 0, 0, w, ht);
      let out = mediaType === 'image/png' ? cv.toDataURL('image/png') : '';
      if (!out || out.length > IMG_BYTES * 0.6) {
        cx.globalCompositeOperation = 'destination-over';   // a white page behind any transparency
        cx.fillStyle = '#fff'; cx.fillRect(0, 0, w, ht);
        out = cv.toDataURL('image/jpeg', 0.85);
      }
      url = out; mediaType = out.slice(5, out.indexOf(';')); data = out.slice(out.indexOf(',') + 1);
    }
    if (conv.images.length >= IMG_MAX) { say(`At most ${IMG_MAX} images go with one message.`); return; }
    conv.images.push({ mediaType, data, url, name: src.name || '', w, h: ht, seq: ++chipSeq });
    if (conv === active) { paintRefs(); updateStatus(); }
  }

  async function attachFile(file) {
    const conv = S;
    try {
      const url = await readDataUrl(file);
      attachImage({ mediaType: file.type || url.slice(5, url.indexOf(';')), data: url.slice(url.indexOf(',') + 1), name: file.name }, conv);
    } catch (e) { inConv(conv, () => notice('info', `Could not read ${file.name || 'that image'}.`)); }
  }

  /** The floating preview while the pointer is on a chip: at most 240 px, kept inside the window. */
  let peekEl = null;
  function hidePeek() { if (peekEl) { peekEl.remove(); peekEl = null; } }
  function showPeek(im, anchor) {
    hidePeek();
    const k = Math.min(1, 240 / Math.max(im.w || 240, im.h || 240));
    const w = Math.round((im.w || 240) * k), ht = Math.round((im.h || 240) * k);
    peekEl = h('div', { class: 'ck-img-peek' }, h('img', { src: im.url, alt: '', width: w, height: ht }));
    document.body.append(peekEl);
    const a = anchor.getBoundingClientRect(), bw = w + 8, bh = ht + 8;
    let top = a.top - bh - 6;
    if (top < 8) top = a.bottom + 6;
    peekEl.style.top = Math.max(8, Math.min(top, window.innerHeight - bh - 8)) + 'px';
    peekEl.style.left = Math.max(8, Math.min(a.left, window.innerWidth - bw - 8)) + 'px';
  }

  function imageChip(im, i) {
    const chip = h('span', { class: 'ck-ref ck-img' },
      h('img', { class: 'ck-img-th', src: im.url, alt: '' }),
      h('span', { class: 'ck-ref-text', text: imageLabel(im, i) }),
      h('button', { class: 'ck-ref-x', type: 'button', title: 'Remove', onmousedown: e => e.preventDefault(),
        onclick: () => { const at = S.images.indexOf(im); if (at >= 0) S.images.splice(at, 1); paintRefs(); updateStatus(); input.focus(); } }));
    chip.onmouseenter = () => showPeek(im, chip);
    chip.onmouseleave = hidePeek;
    return chip;
  }

  /** A larger view of a sent image; a click or Esc closes it. */
  let lightbox = null;
  function closeLightbox() { if (lightbox) { lightbox.remove(); lightbox = null; } }
  function openLightbox(im) {
    closeLightbox();
    lightbox = h('div', { class: 'ck-lightbox', role: 'dialog', title: 'Click or press Esc to close', onclick: closeLightbox }, h('img', { src: im.url, alt: '' }));
    document.body.append(lightbox);
    play(lightbox, FADE, M.fast);
    play(lightbox.firstChild, [{ transform: 'scale(.96)' }, { transform: 'none' }], M.mid);
  }

  /** Backspace in an empty composer: the chip added last, image or reference. */
  function popLastChip() {
    const r = S.refs[S.refs.length - 1], im = S.images[S.images.length - 1];
    if (im && (!r || im.seq > (r.seq || 0))) S.images.pop(); else S.refs.pop();
    paintRefs(); updateStatus();
  }

  // ── where the session runs: folder and git branch, and the ⋮ menu ─────

  const ICON_BRANCH = '<svg viewBox="0 0 16 16" width="11" height="11" aria-hidden="true"><path fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" d="M5 2.5v11M5 10.5c0-3 6-2.5 6-6"/><circle cx="5" cy="13" r="1.6" fill="currentColor"/><circle cx="5" cy="3" r="1.6" fill="currentColor"/><circle cx="11" cy="4" r="1.6" fill="currentColor"/></svg>';
  const icon = svg => { const s = h('span', { class: 'ck-ic-svg' }); s.innerHTML = svg; return s; };   // static markup only
  const baseName = p => String(p || '').replace(/\/+$/, '').split('/').pop() || '/';
  const tilde = p => { p = String(p || ''); return S.home && (p === S.home || p.startsWith(S.home + '/')) ? '~' + p.slice(S.home.length) : p; };
  /** ~/Desktop/development/Hobby/FloatyTerm → ~/…/Hobby/FloatyTerm once it is too long for the menu. */
  const shortPath = p => { const t = tilde(p), parts = t.split('/'); return t.length <= 30 || parts.length < 4 ? t : parts[0] + '/…/' + parts.slice(-2).join('/'); };
  const plural = (n, one, many) => n + ' ' + (n === 1 ? one : (many || one + 's'));

  const requestGit = () => { if (supports('git')) post({ type: 'git' }); };

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
    const name = !supports('rename') || !S.sessionId ? null : S.title
      ? [h('span', { class: 'ck-info-strong', title: S.title, text: S.title }), S.titleCustom ? null : h('span', { class: 'ck-info-dim', text: ' · from the first prompt' })]
      : h('span', { class: 'ck-info-dim', text: S.title === '' ? 'Untitled' : 'Loading…' });
    return h('div', { class: 'ck-info' },
      infoRow('Name', name, 'is-name'),
      infoRow('Folder', h('span', { title: S.cwd, text: shortPath(S.cwd) }), 'is-path'),
      infoRow('Branch', branch),
      infoRow('Changes', changes),
      infoRow('Commit', commit),
      agent === 'codex' ? infoRow('Model', S.model || 'Connecting…') : null,
      agent === 'codex' ? infoRow('Effort', S.effort || 'Model default') : null,
      agent === 'codex' ? infoRow('Sandbox', CODEX_MODES.find(m => m.mode === S.mode)?.label || S.mode) : null,
      infoRow('MCP', mcpText ? h('span', { title: mcp.map(m => `${m.name}: ${m.status}`).join('\n'), text: mcpText }) : null),
      infoRow('Session', S.sessionId || i.version ? [S.sessionId ? h('code', { text: S.sessionId.slice(0, 8) }) : null,
        i.version ? h('span', { class: 'ck-info-dim', text: (S.sessionId ? ' · ' : '') + (agent === 'codex' ? 'Codex ' : 'Claude Code ') + i.version + (i.outputStyle && i.outputStyle !== 'default' ? ' · ' + i.outputStyle : '') }) : null] : null));
  }

  const THINK_SOURCE = { settings: 'From your settings (/config)', default: 'Claude Code default', user: 'Set in this tab' };

  /** "Tool calls inline": off, each turn keeps them in its tray. */
  function toolsItem() {
    return {
      title: 'Tool calls inline',
      desc: toolsInline ? 'In the reply, where they ran' : 'In a tray on each turn',
      side: h('span', { class: 'ck-switch' + (toolsInline ? ' is-on' : ''), role: 'switch', 'aria-checked': String(toolsInline) }),
      run: () => { setToolsInline(!toolsInline); refreshPop(); }
    };
  }

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

  /** "/rename <name>" in the composer, the name selected: type over it, Return names the conversation. */
  function startRename() {
    const cur = S.titleCustom && S.title ? S.title : '';
    input.value = '/rename ' + cur;
    input.focus();
    input.setSelectionRange(8, input.value.length);
    grow(); updateSlash();
  }

  function openMoreMenu() {
    if (P.kind === 'more') { closePop(); return; }
    moreBtn.classList.add('is-open');
    requestGit();
    if (supports('rename') && S.sessionId) post({ type: 'title' });
    const act = (title, desc, fn) => ({ title, desc, run: () => { closePop(); fn(); } });
    openPop('more', moreBtn, () => ({
      head: moreInfo(),
      items: [
        supports('usage') ? act('Usage', 'Tokens, context and account limits', () => toggleUsage(true)) : null,
        supports('models') ? act('Model and effort', null, openModelMenu) : null,
        supports('permissionMode') ? act('Permissions', null, openModeMenu) : null,
        supports('thinking') ? thinkingItem() : null,
        toolsItem(),
        act('Copy path', null, () => post({ type: 'copy', text: S.cwd })),
        act('Reveal in Finder', null, () => post({ type: 'reveal', path: S.cwd })),
        supports('rename') && S.sessionId ? act(S.titleCustom ? 'Rename…' : 'Name this conversation…', '/rename', startRename) : null,
        S.sessionId ? act('Copy session ID', null, () => post({ type: 'copy', text: S.sessionId })) : null,
        supports('history') ? act('Resume a conversation…', null, () => {
          if (active !== main) showConv(main);
          input.value = '/resume '; input.setSelectionRange(8, 8); input.focus(); grow(); updateSlash();
        }) : null,
        supports('credentials') ? act('Check Codex account', null, () => post({ type: 'surfaceAction', action: 'accountRead' })) : null,
        supports('tui') ? act('Open in TUI', null, () => post({ type: 'openTUI', busy: S.busy })) : null,
        supports('fork') ? act('New side chat', null, () => newSide()) : null,
        active !== main ? act('Close this side chat', null, () => closeSide(active)) : null,
        supports('slashCommands') ? act('Compact conversation', null, () => sendUser('/compact')) : null,
        supports('slashCommands') ? act('New conversation', null, () => sendUser('/clear')) : null
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
    if (!supports('fork')) return;
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
    if (V.state !== 'idle') { V.detached = true; stopVoice(); }
    if (supports('realtimeVoice')) post({ type: 'realtimeStop' });
    closeSub(); closeTray(); closeRewind(); closeBtw();
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
    paintMeta(); paintRefs(); paintContext(); updateStatus(); paintTasks(); paintDown(); paintRealtimeButton();
    input.focus();
  }

  /** The strip's switch: main ⇄ the last side chat (a new one when there is none). */
  function toggleView() {
    if (!supports('fork')) return;
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
    viewBtn.hidden = !supports('fork');
    if (!supports('fork')) { viewMenuBtn.hidden = true; return; }
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
    if (!supports('fork')) return;
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
    if (main.busy || main.cards.size) { notice('info', 'The agent is still working. Stop it (Esc) or answer it first, then resume.'); return; }
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
    if (btw && btw.conv === conv) closeBtw();
    if (openTray && conv.turns.includes(openTray.turn)) closeTray();
    if (subShown() && subShown().root === conv) closeSub();
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
    if (/^\[Request interrupted by user/.test(text)) return { kind: 'note', text: 'Stopped' };
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
    S.replaying = true;   // no motion, no usage or git requests, while hundreds of blocks go in
    S.lastChain = e.omitted ? e.before || undefined : null;   // where a rewind of the first prompt drawn would resume
    try { drawHistory(e.messages); } finally { S.replaying = false; }
    evT = 0;
    closeRun();
    for (const th of S.thinks.values()) endThink(th);
    S.busy = false; S.thinking = false; S.buffering = false;
    const done = h('div', { class: 'ck-resumed', text: `Resumed${S.resumeTitle ? ' “' + S.resumeTitle + '”' : ''} · you can continue below` });
    S.log.append(done);
    enter(done);
    S.turn = null;
    updateStatus(); paintMeta();
    if (inView()) { follow = true; stick(); }
  }

  function drawHistory(messages) {
    for (const m of messages) {
      evT = Date.parse(m.timestamp) || 0;
      const c = m.message && m.message.content;
      const before = S.lastChain;
      if (m.uuid && !m.parent_tool_use_id) S.lastChain = m.uuid;
      if (m.type === 'assistant' || (Array.isArray(c) && c.some(x => x.type === 'tool_result'))) {
        for (const normalized of S.normalizer.normalize({ type: 'sdk', msg: m, t: evT })) receiveOne(normalized);
        continue;
      }
      if (m.parent_tool_use_id) continue;   // a subagent's prompt
      const text = typeof c === 'string' ? c : Array.isArray(c) ? c.filter(x => x.type === 'text').map(x => x.text).join('\n') : '';
      const v = userView(text);
      if (!v) continue;
      if (v.kind === 'compacted') notice('info', 'The conversation before this point was compacted.');
      else if (v.kind === 'note') notice('info', v.text);
      else if (v.kind === 'output') localOutput(v.text);
      else {
        const t = newTurn(v.text, v.refs);
        if (supports('rewind') && m.uuid) markPrompt(t, m.uuid, before, { text: v.text, refs: v.refs || [], images: [] });
      }
    }
  }

  // ── /btw: a side question, outside the conversation ──────────────────

  // Claude Code answers it from the conversation so far, with no tools, and
  // keeps it out of the transcript (the side_question request). The panel above
  // the status line holds the side thread: each follow-up sends the earlier
  // questions and answers as its history. Esc or × closes it and drops the thread.
  const ICON_BTW = '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M2.5 3.5h11v7h-6l-3 2.5v-2.5h-2z" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linejoin="round"/></svg>';
  let btw = null;   // { conv, list, field, thread: [{ question, response, error, el }], pending }

  function openBtw(question) {
    if (!supports('btw')) return;
    const conv = S;
    if (!btw || btw.conv !== conv) {
      closeBtw();
      const list = h('div', { class: 'ck-btw-list' });
      const field = h('input', { class: 'ck-btw-field', type: 'text', placeholder: 'Ask a side question…', 'aria-label': 'Side question' });
      const x = h('button', { class: 'ck-sub-btn ck-sub-x', type: 'button', title: 'Close (Esc)' });
      x.onmousedown = e => e.preventDefault();
      x.onclick = () => { closeBtw(); input.focus(); };
      field.addEventListener('keydown', e => {
        if (e.isComposing) return;
        e.stopPropagation();   // the composer's and the page's keys do not apply here
        if (e.key === 'Escape') { e.preventDefault(); closeBtw(); input.focus(); }
        else if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); const q = field.value.trim(); if (q && !btw.pending) { field.value = ''; askBtw(q); } }
      });
      btwEl.replaceChildren(
        h('div', { class: 'ck-btw-head' }, h('span', { class: 'ck-btw-ic' }, icon(ICON_BTW)), h('span', { class: 'ck-btw-t', text: 'Side question' }),
          h('span', { class: 'ck-btw-hint', text: 'Not saved to the conversation · no tools' }), x),
        list, h('div', { class: 'ck-btw-ask' }, field));
      btwEl.hidden = false;
      play(btwEl, RISE, M.fast);
      btw = { conv, list, field, thread: [], pending: null };
    }
    if (question) askBtw(question);
    btw.field.focus();
  }

  function closeBtw() {
    if (!btw) return;
    btw = null;
    btwEl.hidden = true;
    btwEl.replaceChildren();
  }

  function askBtw(question) {
    const b = btw;
    const answer = h('div', { class: 'ck-btw-a is-wait', text: 'Answering…' });
    const item = { question, response: null, error: null, el: answer };
    b.list.append(h('div', { class: 'ck-btw-q', text: question }), answer);
    // The history: the earlier questions of this thread that got an answer.
    const history = b.thread.filter(t => typeof t.response === 'string').map(t => ({ question: t.question, response: t.response }));
    b.thread.push(item);
    b.pending = newId();
    item.id = b.pending;
    b.field.placeholder = 'Ask a follow-up…';
    b.list.scrollTop = b.list.scrollHeight;
    post({ type: 'btw', channel: b.conv.id, id: b.pending, question, history });
  }

  function onBtw(e) {
    const b = btw;
    if (!b || e.id !== b.pending) return;   // closed, or an answer to a thread that is gone
    const item = b.thread.find(t => t.id === e.id);
    b.pending = null;
    if (!item) return;
    item.el.classList.remove('is-wait');
    if (e.error || e.response == null) {
      item.error = e.error || 'No answer';
      item.el.classList.add('is-error');
      item.el.textContent = 'No answer: ' + item.error + '.';
    } else {
      item.response = String(e.response);
      item.el.textContent = '';
      item.el.classList.add('sk-doc');
      item.el.classList.toggle('is-synthetic', !!e.synthetic);
      root.SkimRender.render(item.el, item.response, { streaming: false, interactive: false });
    }
    b.list.scrollTop = b.list.scrollHeight;
  }

  // ── rewind: back to before an earlier prompt ──────────────────────────

  // Each prompt sent here gets an ID (Claude Code keeps it in the transcript)
  // and remembers the transcript entry before it. A rewind can put the files
  // back as they were before the prompt (Claude Code's file checkpoints), cut
  // the conversation back to that entry (the session restarts there), or both.
  // The prompt and everything after it go away; its text goes back in the composer.
  const ICON_REWIND = '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><path d="M3 4.5v3.2h3.2" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/><path d="M3.4 7.5A5 5 0 1 1 4.6 11" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>';
  let lastEsc = 0, rewindCard = null;
  const rewindWait = new Map();   // request id → resolve, for the files answers

  function newId() {
    try { if (root.crypto && crypto.randomUUID) return crypto.randomUUID(); } catch (e) { /* not a secure context */ }
    const b = crypto.getRandomValues(new Uint8Array(16));
    b[6] = b[6] & 15 | 64; b[8] = b[8] & 63 | 128;
    const x = [...b].map(v => v.toString(16).padStart(2, '0')).join('');
    return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
  }

  /** A prompt that can be rewound: its ID, the entry before it (null: the start), and what goes back in the composer. */
  function markPrompt(t, uuid, resumeAt, prompt) {
    t.promptId = uuid; t.resumeAt = resumeAt; t.prompt = prompt;
    const btn = t.el.querySelector('.ck-rewind-btn');
    if (resumeAt === undefined || !btn) return;   // the entry before it is not known (the start of a cut history)
    t.el.dataset.rewind = '1';
    const conv = S;
    btn.onclick = () => { const prev = S; S = conv; try { openRewind(t); } finally { S = prev; } };
  }

  const canRewind = t => !!(t && t.promptId && t.resumeAt !== undefined);

  /** Esc Esc or /rewind: the prompts of this conversation, newest first. */
  function openRewindPicker() {
    if (!supports('rewind')) return;
    if (S.busy || S.cards.size) { notice('info', 'Stop the current turn (Esc) before you rewind.'); return; }
    const list = S.turns.filter(canRewind);
    if (!list.length) { notice('info', 'Nothing to rewind yet: send a message first.'); return; }
    const conv = S;
    openPop('rewind', composer, () => ({
      head: 'Rewind to before…',
      items: [...list].reverse().map(t => {
        const after = conv.turns.length - conv.turns.indexOf(t) - 1;
        return { title: clip(t.prompt.text || '(a message with attachments)', 110),
          desc: after ? `${plural(after, 'later turn')} also go` : 'the last turn',
          run: () => { closePop(); openRewind(t); } };
      })
    }));
  }

  function rewindOpt(key, label, mode) {
    const b = h('button', { class: 'ck-opt', type: 'button', 'data-mode': mode }, h('span', { class: 'ck-key', text: key }), label);
    b.onmousedown = e => e.preventDefault();
    b.onclick = () => runRewind(mode);
    return b;
  }

  /** The panel above the status line: what goes, what the files do, three ways (and cancel). */
  function openRewind(t) {
    if (!canRewind(t)) return;
    if (S.busy || S.cards.size) { notice('info', 'Stop the current turn (Esc) before you rewind.'); return; }
    closePop(); closeTray(); closeSub();
    const conv = S, after = conv.turns.length - conv.turns.indexOf(t) - 1;
    const files = h('div', { class: 'ck-rw-files', text: 'Checking the files…' });
    const opts = { both: rewindOpt('1', 'Code and conversation', 'both'), conversation: rewindOpt('2', 'Conversation only', 'conversation'),
      code: rewindOpt('3', 'Code only', 'code'), cancel: rewindOpt('esc', 'Cancel', 'cancel') };
    opts.both.disabled = opts.code.disabled = true;   // until the files answer comes
    rewindEl.replaceChildren(
      h('div', { class: 'ck-rw-head' }, h('span', { class: 'ck-rw-ic' }, icon(ICON_REWIND)), h('span', { text: 'Rewind to before this prompt' })),
      h('div', { class: 'ck-rw-quote', text: clip(t.prompt.text || '(a message with attachments)', 260) }),
      h('div', { class: 'ck-rw-what', text: after ? `This prompt and the ${plural(after, 'turn')} after it go away. Its text goes back in the composer.`
        : 'This prompt and its reply go away. Its text goes back in the composer.' }),
      files,
      h('div', { class: 'ck-opts' }, opts.both, opts.conversation, opts.code, opts.cancel));
    rewindEl.hidden = false;
    play(rewindEl, RISE, M.fast);
    rewindCard = { turn: t, conv, opts, files, id: newId(), def: 'conversation', busy: false, changed: 0 };
    post({ type: 'rewindFiles', channel: conv.id, uuid: t.promptId, dryRun: true, id: rewindCard.id });
  }

  function closeRewind() {
    if (!rewindCard) return;
    rewindCard = null;
    rewindEl.hidden = true;
    rewindEl.replaceChildren();
  }

  /** 1 2 3, Return (the first choice that can run), Esc: while the panel is open. */
  function rewindKey(e) {
    const c = rewindCard;
    if (!c || e.metaKey || e.ctrlKey || e.altKey) return false;
    if (e.key === 'Escape') { if (!c.busy) closeRewind(); return true; }
    if (input.value && document.activeElement === input) return false;   // typing: digits are text
    const mode = { 1: 'both', 2: 'conversation', 3: 'code' }[e.key] || (e.key === 'Enter' && !e.shiftKey ? c.def : null);
    if (!mode) return false;
    if (!c.opts[mode].disabled) runRewind(mode);
    return true;
  }


  function onRewind(e) {
    const wait = rewindWait.get(e.id);
    if (wait) { rewindWait.delete(e.id); wait(e); return; }
    const c = rewindCard;
    if (!c || e.id !== c.id || !e.dryRun) return;
    const n = (e.filesChanged || []).length;
    c.changed = n;
    if (!e.canRewind) c.files.textContent = 'The files cannot be put back: ' + (e.error || 'there is no checkpoint for this prompt') + '.';
    else if (!n) c.files.textContent = 'No file changes since this prompt.';
    else {
      const names = e.filesChanged.slice(0, 5).map(rel);
      c.files.replaceChildren(h('span', { class: 'ck-rw-files-k', text: `Files: ${plural(n, 'file')} changed` }),
        h('span', { class: 'ck-rw-files-n', text: ` +${e.insertions || 0} −${e.deletions || 0}` }),
        h('span', { class: 'ck-rw-files-list', text: ' · ' + names.join(', ') + (n > 5 ? ` and ${n - 5} more` : ''), title: e.filesChanged.map(rel).join('\n') }));
      c.opts.both.disabled = c.opts.code.disabled = false;
      c.def = 'both';
    }
  }

  function askFiles(conv, uuid) {
    const id = newId();
    return new Promise(res => { rewindWait.set(id, res); post({ type: 'rewindFiles', channel: conv.id, uuid, id }); });
  }

  async function runRewind(mode) {
    const c = rewindCard;
    if (!c || c.busy) return;
    if (mode === 'cancel') { closeRewind(); return; }
    c.busy = true;
    Object.values(c.opts).forEach(b => { b.disabled = true; });
    const { turn: t, conv } = c;
    let restored = 0;
    if (mode === 'both' || mode === 'code') {
      c.files.textContent = 'Putting the files back…';
      const r = await askFiles(conv, t.promptId);
      if (!r.canRewind) {
        c.files.textContent = 'The files were not put back: ' + (r.error || 'unknown error') + '.';
        c.busy = false;
        c.opts.cancel.disabled = false; c.opts.conversation.disabled = false;
        return;
      }
      restored = c.changed;
    }
    closeRewind();
    const prev = S;
    S = conv;
    try {
      if (mode === 'code') { notice('info', `Files put back as they were before “${clip(t.prompt.text, 60)}”` + (restored ? ` · ${plural(restored, 'file')}` : '')); return; }
      cutConversation(conv, t);
      notice('info', 'Rewound' + (restored ? ` · ${plural(restored, 'file')} put back` : ''));
    } finally { S = prev; }
  }

  // ── a prompt's fate (command_lifecycle): queued, started, then how it ended ──

  const PROMPT_STATE = {
    queued: ['Queued', 'Claude is busy: it reads this message next.'],
    unsent: ['Not sent', 'It was still waiting when the turn stopped. Click to put it back in the composer.'],
    discarded: ['Not sent', 'The session ended before it ran. Click to put it back in the composer.'],
    refused: ['Refused', 'The session declined this message. Click to put it back in the composer.']
  };

  /** A badge on the prompt while it waits, or when it never ran. A quick queued → started shows nothing. */
  function onPromptState(e) {
    const t = S.turns.find(x => x.promptId === e.id);
    if (!t) return;
    if (e.state === 'started') t.started = true;
    t.fate = e.state;
    const key = e.state === 'queued' ? 'queued' : e.state === 'refused' ? 'refused' : e.state === 'discarded' && !t.started ? 'discarded'
      : e.state === 'cancelled' && !t.started ? 'unsent' : null;
    if (key === 'queued') { setTimeout(() => { if (t.fate === 'queued') promptBadge(t, 'queued'); }, 600); return; }
    promptBadge(t, key);
  }

  function promptBadge(t, key) {
    const box = t.el.querySelector('.ck-user');
    if (!box) return;
    let b = box.querySelector('.ck-user-state');
    if (!key) { if (b) b.remove(); return; }
    if (!b) { b = h('button', { class: 'ck-user-state', type: 'button' }); b.onmousedown = e => e.preventDefault(); box.append(b); }
    const [label, title] = PROMPT_STATE[key];
    b.textContent = label; b.title = title; b.dataset.state = key;
    b.disabled = key === 'queued';
    b.onclick = key === 'queued' ? null : () => {
      if (input.value.trim() || !t.prompt) return;
      input.value = t.prompt.text || ''; grow(); input.focus();
    };
  }

  /** The prompt's turn and everything after it go; the session restarts at the entry before it. */
  function cutConversation(conv, t) {
    const idx = conv.turns.indexOf(t);
    if (idx < 0) return;
    if (openTray && conv.turns.slice(idx).includes(openTray.turn)) closeTray();
    for (const x of conv.turns.splice(idx)) for (const run of x.runs || (x.run ? [x.run] : [])) clearInterval(run.timer);
    for (let n = t.el; n;) { const next = n.nextSibling; n.remove(); n = next; }
    conv.turn = null;
    conv.lastChain = t.resumeAt;
    if (conv === active && !input.value.trim()) {
      input.value = t.prompt.text || '';
      if (t.prompt.refs && t.prompt.refs.length) conv.refs = t.prompt.refs.slice();
      if (t.prompt.images && t.prompt.images.length) conv.images = t.prompt.images.slice();
      paintRefs(); grow(); input.focus(); input.setSelectionRange(input.value.length, input.value.length);
    }
    post({ type: 'restartAt', channel: conv.id, resumeAt: t.resumeAt, dropsTurn: t.promptId });
    updateStatus();
  }

  // ── dictation: the mic button ─────────────────────────────────────────

  // The host listens (the Mac's speech recognition, on the device when it can)
  // and sends the words heard so far; they go where the caret was. Claude
  // Code's own /voice records in its terminal UI only, so it cannot run here.
  const ICON_MIC = '<svg viewBox="0 0 16 16" width="13" height="13" aria-hidden="true"><rect x="5.5" y="1.5" width="5" height="8.5" rx="2.5" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M3.2 7.6a4.8 4.8 0 0 0 9.6 0M8 12.4v2.1" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>';
  const V = { state: 'idle', before: '', after: '', value: '', detached: false };

  function paintMic() {
    paintRealtimeButton();
    if (!micBtn) return;
    micBtn.hidden = !supports('voice');
    micBtn.dataset.state = V.state;
    micBtn.title = V.state === 'listening' ? 'Listening… click or Esc to stop' : V.state === 'starting' ? 'Starting the microphone…'
      : V.state === 'stopping' ? 'Finishing…' : 'Dictate (speech to text)';
    micBtn.setAttribute('aria-pressed', String(V.state === 'listening' || V.state === 'starting'));
  }

  function toggleVoice() {
    if (!supports('voice')) return;
    if (V.state === 'idle') startVoice();
    else if (V.state !== 'stopping') stopVoice();
  }

  function startVoice() {
    const a = input.selectionStart ?? input.value.length, b = input.selectionEnd ?? a;
    Object.assign(V, { state: 'starting', before: input.value.slice(0, a), after: input.value.slice(b), value: input.value, detached: false });
    paintMic();
    input.focus();
    post({ type: 'voice', on: true });
  }

  function stopVoice() {
    if (V.state === 'idle') return;
    V.state = 'stopping';
    paintMic();
    post({ type: 'voice', on: false });
  }

  /** The words so far, in place of the ones before them, with a space on each side where needed. */
  function placeVoice(text) {
    text = String(text || '').trim();
    const pre = text && V.before && !/\s$/.test(V.before) ? ' ' : '';
    const post_ = text && V.after && !/^\s/.test(V.after) ? ' ' : '';
    input.value = V.before + pre + text + post_ + V.after;
    const at = (V.before + pre + text).length;
    input.setSelectionRange(at, at);
    V.value = input.value;
    grow(); updateStatus();
  }

  /** You typed while it listened: your text wins, and it stops. */
  function voiceTyped() {
    if (V.state === 'idle' || V.detached || input.value === V.value) return;
    V.detached = true;
    stopVoice();
  }

  // ── status line + composer ─────────────────────────────────────────────

  function updateStatus() {
    const waiting = [...S.cards.values()].some(card => card.req.blocking !== false);
    let text = S.bgTasks.length ? `Ready · ${S.bgTasks.length} in the background` : 'Ready', state = 'idle';
    if (S.connectionClosed) { text = 'Conversation closed'; state = 'idle'; }
    else if (waiting) { text = 'Waiting for you'; state = 'waiting'; }
    else if (S.protocolStatus === 'systemError') { text = 'Session needs attention'; state = 'waiting'; }
    else if (S.busy) {
      state = 'busy';
      const live = S.lastTool && (S.lastTool.state === 'running' || S.lastTool.state === 'preparing') ? S.lastTool : null;
      text = S.buffering ? 'Preparing response…' : S.retry && !S.retry.done ? 'Retrying…' : live ? `${shortName(live.name)} ${live.argEl.textContent}`.trim() : S.thinking ? (S.thinkWord || 'Thinking') + '…' : S.progressText || 'Working';
    }
    postState();
    if (!inView()) { paintView(); return; }
    paintTasks();
    statusText.textContent = text;
    statusDot.dataset.state = state;
    dock.dataset.state = state;
    input.disabled = S.connectionClosed; sendBtn.disabled = S.connectionClosed;
    sendBtn.dataset.mode = S.busy && (!supports('midTurnInput') || !input.value.trim() && !S.refs.length && !S.images.length) ? 'stop' : 'send';
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

  function sendUser(text, refs, images) {
    text = String(text || '').trim();
    refs = refs || [];
    images = images || [];
    if (!text && !refs.length && !images.length) return;
    if (text.startsWith('/') && runLocal(text)) return;
    if (S.busy && !supports('midTurnInput')) { notice('info', `${agent === 'codex' ? 'Codex' : 'Agent'} is still working. Stop it before sending another message.`); return; }
    // A slash command must start the message, so references and images wait for the next one.
    if (text.startsWith('/')) { refs = []; images = []; }
    else if (refs.length || images.length) {
      if (refs.length) S.refs = [];
      if (images.length) S.images = [];
      paintRefs();
    }
    // A finished task list has done its job: the next message starts clean.
    if (S.tasks.list.length && S.tasks.list.every(t => t.status === 'completed')) { S.tasks.list = []; S.tasks.byTool.clear(); }
    const t = newTurn(text, refs, images);
    // Rewind keys on the prompt's own ID, and resumes at the entry before it.
    const uuid = supports('rewind') ? newId() : null;
    if (uuid) markPrompt(t, uuid, S.lastChain, { text, refs, images });
    S.busy = true;
    post({ type: 'send', text: refs.length ? withRefs(text, refs) : text, ...(uuid ? { uuid } : {}), ...(images.length ? { images: images.map(im => ({ mediaType: im.mediaType, data: im.data })) } : {}) });
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
    if (agent === 'codex' && input.value.trim().startsWith('/')) {
      const command = input.value.trim(); input.value = ''; grow(); closePop();
      runLocal(command); updateStatus(); return;
    }
    if (sendBtn.dataset.mode === 'stop') { post({ type: 'interrupt' }); return; }
    if (V.state !== 'idle') { V.detached = true; stopVoice(); }
    const text = input.value;
    if (!text.trim() && !S.refs.length && !S.images.length) return;
    input.value = ''; grow(); closePop();
    sendUser(text, S.refs.slice(), S.images.slice());
    updateStatus();
  }

  const chip = (cls, title) => h('button', { class: 'ck-chip ' + cls, type: 'button', title }, h('span', { class: 'ck-chip-t' }), h('span', { class: 'sk-caret ck-chip-caret' }));

  function buildShell() {
    document.body.classList.add('ck');
    document.body.classList.toggle('tools-inline', toolsInline);
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
    micBtn = h('button', { class: 'ck-mic', type: 'button', hidden: !supports('voice') }, icon(ICON_MIC));
    micBtn.onmousedown = e => e.preventDefault();   // the caret stays where the words go
    micBtn.onclick = toggleVoice;
    realtimeBtn = h('button', { class: 'ck-voice-start', type: 'button', hidden: !supports('realtimeVoice'), text: 'Voice', title: 'Start a Codex voice conversation' });
    realtimeBtn.onclick = () => {
      const state = realtimeStatus();
      post({ type: ['starting', 'active', 'muted'].includes(state) ? 'realtimeStop' : 'realtimeStart' });
    };
    refsEl = h('div', { class: 'ck-refs', hidden: true });
    tasksEl = h('div', { class: 'ck-tasks', hidden: true });
    downBtn = h('button', { class: 'ck-down', type: 'button', title: 'Scroll to the bottom', hidden: true }, h('span', { class: 'ck-down-ic' }));
    downBtn.onmousedown = e => e.preventDefault();
    downBtn.onclick = toBottom;
    const field = h('div', { class: 'ck-field' }, grip, refsEl, input, downBtn);
    composer = h('div', { class: 'ck-composer' }, field, h('div', { class: 'ck-actions' }, realtimeBtn, micBtn, sendBtn));
    refBtn = h('button', { class: 'ck-refbtn', type: 'button', hidden: true, title: 'Add the selected text to your next message (⌘L)' },
      h('span', { class: 'ck-refbtn-ic' }), 'Reference to Agent', h('kbd', { text: '⌘L' }));
    refBtn.onmousedown = e => e.preventDefault();   // keep the selection
    refBtn.onclick = () => referenceSelection();
    document.body.append(refBtn);
    statusEl = h('div', { class: 'ck-status' }, viewBtn, viewMenuBtn, statusDot, statusText, h('span', { class: 'ck-spacer' }), ctxEl, modelEl, modeBtn, costEl, moreBtn);
    popEl = h('div', { class: 'ck-pop', hidden: true });
    rewindEl = h('div', { class: 'ck-rewind', hidden: true, role: 'dialog', 'aria-label': 'Rewind' });
    btwEl = h('div', { class: 'ck-btw', hidden: true, role: 'dialog', 'aria-label': 'Side question' });
    dockIn = h('div', { class: 'ck-dock-in' }, tasksEl, usagePanel, btwEl, rewindEl, statusEl, composer, popEl);
    dock = h('div', { class: 'ck-dock' }, dockIn);
    subEl = h('aside', { class: 'ck-subpanel', hidden: true, role: 'dialog', 'aria-label': 'Subagent transcript' });
    document.body.append(main.log, dock, subEl);
    // The panel ends where the dock begins: the composer stays in reach.
    const fitSub = () => document.documentElement.style.setProperty('--ck-dock-h', dock.offsetHeight + 'px');
    if (root.ResizeObserver) new ResizeObserver(fitSub).observe(dock);
    fitSub();

    input.addEventListener('input', () => { voiceTyped(); grow(); updateStatus(); updateSuggest(); });
    input.addEventListener('click', updateSuggest);
    input.addEventListener('keyup', e => { if (e.key === 'ArrowLeft' || e.key === 'ArrowRight' || e.key === 'Home' || e.key === 'End') updateSuggest(); });
    input.addEventListener('blur', () => setTimeout(() => { if ((P.kind === 'slash' || P.kind === 'mention') && document.activeElement !== input) closePop(); }, 120));
    // An image on the clipboard becomes an attachment; text (also rich text with a picture in it) pastes as text.
    input.addEventListener('paste', e => {
      const cd = e.clipboardData;
      if (!supports('images') || !cd) return;
      const files = [...cd.items].filter(i => i.kind === 'file' && /^image\//.test(i.type)).map(i => i.getAsFile()).filter(Boolean);
      const rich = [...cd.types].includes('text/html') && (cd.getData('text/plain') || '').trim();
      if (!files.length || rich) return;
      e.preventDefault();
      files.forEach(attachFile);
    });
    // Image files dragged in from other apps; the page never navigates to a dropped file.
    const isFiles = e => e.dataTransfer && [...(e.dataTransfer.types || [])].includes('Files');
    document.addEventListener('dragover', e => { if (isFiles(e)) { e.preventDefault(); field.classList.add('is-drop'); } });
    document.addEventListener('dragleave', e => { if (!e.relatedTarget) field.classList.remove('is-drop'); });
    document.addEventListener('drop', e => {
      if (!isFiles(e)) return;
      e.preventDefault(); field.classList.remove('is-drop');
      if (supports('images')) for (const f of e.dataTransfer.files) if (/^image\//.test(f.type)) attachFile(f);
    });
    document.addEventListener('keydown', e => { if (lightbox && e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeLightbox(); } }, true);
    input.addEventListener('keydown', e => {
      if (e.isComposing) return;
      // An open menu takes its keys first, whichever menu it is (the focus stays here).
      if (P.kind && popKey(e)) { e.preventDefault(); e.stopPropagation(); return; }
      // Backspace in an empty composer removes the last chip: reference or image.
      if (e.key === 'Backspace' && !input.value && (S.refs.length || S.images.length)) { e.preventDefault(); popLastChip(); return; }
      if (e.key === 'Escape' && V.state !== 'idle') { e.preventDefault(); stopVoice(); return; }
      if (rewindCard && rewindKey(e)) { e.preventDefault(); return; }
      if (e.key === 'Escape' && btw && !input.value) { e.preventDefault(); closeBtw(); return; }
      if (e.key === 'Escape' && openTray) { e.preventDefault(); closeTray(); return; }
      if (e.key === 'Escape' && subShown()) { e.preventDefault(); closeSub(); return; }
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); submit(); }
      else if (e.key === 'Escape' && !usagePanel.hidden) { e.preventDefault(); toggleUsage(false); }
      else if (e.key === 'Escape' && S.busy) { e.preventDefault(); post({ type: 'interrupt' }); }
      else if (e.key === 'Escape' && supports('rewind') && !input.value && !S.cards.size) {
        // Esc Esc, as in the TUI: the list of prompts to rewind to.
        e.preventDefault(); e.stopPropagation();   // the page's own Esc would close the list it opens
        if (Date.now() - lastEsc < 600) { lastEsc = 0; openRewindPicker(); } else lastEsc = Date.now();
      }
      else if (e.key === 'Tab' && e.shiftKey) { e.preventDefault(); cycleMode(); }
    });
    sendBtn.onclick = submit;
    paintMic();
    modelEl.onclick = openModelMenu;
    modeBtn.onclick = openModeMenu;
    costEl.onclick = () => toggleUsage();
    for (const b of [viewBtn, viewMenuBtn, ctxEl, modelEl, modeBtn, costEl, moreBtn]) b.onmousedown = e => e.preventDefault();
    viewBtn.onclick = toggleView;
    viewMenuBtn.onclick = openViewMenu;
    bindGrip();
    ctxEl.onclick = openMoreMenu;
    moreBtn.onclick = openMoreMenu;
    // Content that grows after the follow scroll (images loading, a diagram, late
    // layout) would leave the last lines under the dock: follow the growth too.
    if (root.ResizeObserver) {
      let lastH = 0;
      new ResizeObserver(() => {
        const hNow = document.documentElement.scrollHeight;
        if (hNow > lastH && follow && Date.now() >= pinUntil) window.scrollTo(0, hNow);
        lastH = hNow;
      }).observe(document.body);
    }
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
    document.addEventListener('mousedown', e => { if (openTray && !openTray.el.contains(e.target)) closeTray(); });
    document.addEventListener('mousedown', e => {
      if (P.kind && P.kind !== 'slash' && P.kind !== 'mention' && !popEl.contains(e.target) && !(P.anchor && P.anchor.contains(e.target)) && !(P.kind === 'more' && ctxEl.contains(e.target))) closePop();
    });
    document.addEventListener('keydown', e => {
      if (P.kind && P.kind !== 'slash' && P.kind !== 'mention' && popKey(e)) { e.preventDefault(); return; }
      if (e.altKey && !e.metaKey && !e.ctrlKey && e.code === 'KeyP') { e.preventDefault(); openModelMenu(); return; }
      if (e.metaKey && !e.altKey && !e.ctrlKey && !e.shiftKey && e.key.toLowerCase() === 'l' && selectionRef()) { e.preventDefault(); referenceSelection(); return; }
      if (rewindCard && document.activeElement !== input && rewindKey(e)) { e.preventDefault(); return; }
      if (e.key === 'Escape' && openTray && document.activeElement !== input) { closeTray(); return; }
      if (e.key === 'Escape' && subShown() && document.activeElement !== input) { closeSub(); return; }
      if (e.key === 'Escape' && !usagePanel.hidden && document.activeElement !== input) { toggleUsage(false); return; }
      if (e.key === 'Escape' && S.busy && !S.cards.size && document.activeElement !== input) post({ type: 'interrupt' });
    });
    updateStatus(); paintMeta(); paintContext(); paintView(); grow();
    input.focus();
  }

  function notice(kind, text) {
    const el = h('div', { class: 'ck-notice', 'data-kind': kind, text });
    (S.turn ? S.turn.body : S.log).append(el);
    enter(el);
    stick();
    return el;
  }

  /** Output of a local slash command: drawn like a reply. */
  function localOutput(text) {
    closeRun();
    const el = h('div', { class: 'sk-doc ck-text' });
    turn().body.append(el);
    enter(el);
    root.SkimRender.render(el, String(text || ''), { streaming: false, interactive: true, onAction: a => { if (a.type === 'reply') sendUser(a.text); } });
    stick();
  }

  // ── the task list: from TodoWrite and TaskCreate / TaskUpdate ──────────

  const TASK_STATUS = ['pending', 'in_progress', 'completed'];
  const taskStatus = v => TASK_STATUS.includes(v) ? v : 'pending';
  /** `{"task":{"id":"3"}}`, `{"id":3}` or "Task #3 created": the id the tool gave the new task. */
  function taskIdOf(out) {
    const text = String(out == null ? '' : out);
    try { const j = JSON.parse(text), id = j && (j.task ? j.task.id : j.id); if (id != null) return String(id); } catch (err) { /* plain text */ }
    const m = /#?(\d+)/.exec(text);
    return m ? m[1] : null;
  }

  /** Keeps the conversation's task list in step with the task tools of the main agent. */
  function trackTasks(e) {
    const tool = S.eventState.tools.get(e.id);
    if (!tool || tool.parentId) return;
    const T = S.tasks, inp = tool.input && typeof tool.input === 'object' ? tool.input : null;
    if (tool.name === 'TaskCreate' && e.type === 'tool.result') {
      const t = T.byTool.get(e.id);
      if (!t) return;
      if (e.isError) T.list = T.list.filter(x => x !== t);
      else t.id = taskIdOf(e.output);
    } else if (e.type === 'tool.result' || !inp || T.seen.has(e.id)) return;
    else if (tool.name === 'TodoWrite' && Array.isArray(inp.todos)) {
      T.seen.add(e.id); T.byTool.clear();
      T.list = inp.todos.map(t => ({ id: null, subject: String(t.content || t.subject || ''), activeForm: t.activeForm || '', status: taskStatus(t.status) }));
    } else if (tool.name === 'TaskCreate') {
      T.seen.add(e.id);
      const t = { id: null, subject: String(inp.subject || ''), activeForm: inp.activeForm || '', status: 'pending' };
      T.byTool.set(e.id, t); T.list.push(t);
    } else if (tool.name === 'TaskUpdate') {
      T.seen.add(e.id);
      const t = T.list.find(x => x.id != null && String(x.id) === String(inp.taskId));
      if (!t) return;
      if (inp.status === 'deleted') T.list = T.list.filter(x => x !== t);
      else {
        if (inp.status) t.status = taskStatus(inp.status);
        if (inp.subject) t.subject = String(inp.subject);
        if (inp.activeForm) t.activeForm = String(inp.activeForm);
      }
    } else return;
    paintTasks();
  }

  const taskText = t => t.status === 'in_progress' ? t.activeForm || t.subject : t.subject;

  /** The panel above the status line: folded to a meter and the task in progress; open, the whole list. */
  function paintTasks() {
    if (!tasksEl || !inView()) return;
    const T = S.tasks, list = T.list;
    const done = list.filter(t => t.status === 'completed').length;
    const finished = list.length > 0 && done === list.length && !S.busy;
    const sig = [S.id, T.open, finished, ...list.map(t => t.status + '|' + taskText(t))].join('\n');
    if (tasksEl._sig === sig) return;
    tasksEl._sig = sig;
    if (list.length && tasksEl.hidden) play(tasksEl, RISE, M.mid);
    tasksEl.hidden = !list.length;
    if (!list.length) { tasksEl.replaceChildren(); return; }
    const doing = list.find(t => t.status === 'in_progress');
    tasksEl.classList.toggle('is-open', T.open);
    tasksEl.classList.toggle('is-done', finished);
    const head = h('button', { class: 'ck-tasks-head', type: 'button', title: T.open ? 'Hide the tasks' : 'Show the tasks',
      onmousedown: e => e.preventDefault(), onclick: () => {
        active.tasks.open = !active.tasks.open; paintTasks();
        const list = tasksEl.querySelector('.ck-tasks-list');
        if (list) expand(list, () => {});
        stick();
      } },
      h('span', { class: 'ck-tasks-k', text: `Tasks ${done}/${list.length}` + (finished ? ' · done' : '') }),
      h('span', { class: 'ck-tasks-bar' }, h('span', { class: 'ck-tasks-fill', style: `width:${Math.round(done / list.length * 100)}%` })),
      doing && !finished ? h('span', { class: 'ck-tasks-now' }, h('span', { class: 'ck-task-spin' }), h('span', { class: 'ck-tasks-now-t', text: taskText(doing) })) : h('span', { class: 'ck-spacer' }),
      h('span', { class: 'sk-caret ck-tasks-caret' }));
    tasksEl.replaceChildren(...[head, T.open && T.explanation ? h('p', { class: 'ck-plan-explanation', text: T.explanation }) : null, T.open ? h('div', { class: 'ck-tasks-list' }, list.map(t =>
      h('div', { class: 'ck-task', 'data-status': t.status }, h('span', { class: 'ck-task-box' }), h('span', { class: 'ck-task-t', text: taskText(t) })))) : null].filter(Boolean));
  }

  // ── status notices: retries, limits, hooks ─────────────────────────────

  const retryReason = st => st == null ? 'connection problem' : st === 429 ? 'rate limited (429)' : st === 529 ? 'overloaded (529)'
    : st >= 500 ? `server error (${st})` : `error ${st}`;

  /** One notice per turn, updated in place while the API call is retried. */
  function onRetry(e) {
    let r = S.retry;
    if (!r || r.done || r.turn !== S.turn) r = S.retry = { el: notice('warn', ''), turn: S.turn, done: false, n: 0 };
    r.n = e.attempt || r.n + 1;
    const wait = Math.max(1, Math.round((e.delayMs || 0) / 1000));
    r.el.textContent = `Retrying in ${wait} s · attempt ${r.n}` + (e.maxRetries ? ` of ${e.maxRetries}` : '') + ' · ' + retryReason(e.errorStatus);
    updateStatus();
  }

  /** The next content or tool event says the retry worked (or the turn ended): the notice fades to a record. */
  function settleRetry() {
    const r = S.retry;
    if (!r || r.done) return;
    r.done = true;
    r.el.dataset.kind = 'info';
    r.el.classList.add('is-faded');
    r.el.textContent = `Retried ${r.n}×`;
    updateStatus();
  }

  const LIMIT_NAME = { five_hour: '5-hour', seven_day: 'weekly', seven_day_opus: 'weekly Opus', seven_day_sonnet: 'weekly Sonnet', overage: 'extra usage' };
  /** resetsAt in seconds or milliseconds: "22:09", or "Fri 22:09" when it is more than a day away. */
  function resetClock(at) {
    const ms = at < 1e12 ? at * 1000 : at, d = new Date(ms);
    if (isNaN(d)) return '';
    const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    return d - Date.now() > 20 * 3600e3 ? d.toLocaleDateString([], { weekday: 'short' }) + ' ' + time : time;
  }

  /** A warning or a refusal from the account's rate limits: once for each limit and state. */
  function onLimit(e) {
    if (e.status !== 'allowed_warning' && e.status !== 'rejected') return;
    const key = e.limitType + '/' + e.status;
    if (S.limitSeen.has(key)) return;
    S.limitSeen.add(key);
    const name = LIMIT_NAME[e.limitType] || String(e.limitType || 'usage').replace(/_/g, ' ');
    const reset = e.resetsAt ? ' · resets ' + resetClock(e.resetsAt) : '';
    if (e.status === 'rejected') notice('error', `Rate limit reached for your ${name} limit` + reset);
    else {
      const u = e.utilization == null ? null : Math.round(e.utilization <= 1 ? e.utilization * 100 : e.utilization);
      notice('warn', (u == null ? `You are close to your ${name} limit` : `You have used ${u}% of your ${name} limit`) + reset);
    }
    requestUsage(true);
  }

  /** A hook that blocked something or said something. A quiet success shows nothing. */
  function onHook(e) {
    const out = String(e.output || '').replace(/\s+/g, ' ').trim();
    if (e.outcome === 'success' && !out) return;
    const bad = e.outcome === 'error' || e.outcome === 'cancelled';
    const label = e.name && e.event && !e.name.includes(e.event) ? e.event + ':' + e.name : e.name || e.event || 'hook';
    notice(bad ? 'warn' : 'info', `Hook ${label}` + (e.exitCode ? ` · exit ${e.exitCode}` : '') + (out ? ' — ' + (out.length > 300 ? out.slice(0, 300) + '…' : out) : ''));
  }

  // ── subagents and background commands ──────────────────────────────────

  const TASK_NOUN = { local_agent: 'agent', local_bash: 'command', local_workflow: 'workflow', mcp_task: 'task' };
  const taskNoun = t => TASK_NOUN[t.taskType] || (t.subagentType ? 'agent' : 'task');
  const clip = (s, n) => { s = String(s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n) + '…' : s; };

  /** "Explore · 12 tools · 34k tokens": what a task reports while it runs. */
  function taskLine(t) {
    const u = t.usage || {};
    return [u.tool_uses ? plural(u.tool_uses, 'tool') : null, u.total_tokens ? fmtTok(u.total_tokens) + ' tokens' : null].filter(Boolean).join(' · ');
  }

  /**
   * task_started / progress / updated / notification. A task started by a tool
   * call shows on that row; a background one also says when it ends, since its
   * row finished long before (its result only said "running in the background").
   */
  function onTask(e) {
    let t = S.agentTasks.get(e.taskId);
    if (!t) { t = { id: e.taskId, toolId: null, description: '', background: false, ambient: false, usage: null }; S.agentTasks.set(e.taskId, t); }
    if (e.toolId) t.toolId = e.toolId;
    if (e.description) t.description = e.description;
    if (e.taskType) t.taskType = e.taskType;
    if (e.subagentType) t.subagentType = e.subagentType;
    if (e.ambient) t.ambient = true;
    if (e.background || e.patch?.is_backgrounded) t.background = true;
    if (e.patch?.description) t.description = e.patch.description;
    if (e.usage) t.usage = e.usage;
    if (t.ambient) return;
    const row = t.toolId ? rowAnywhere(t.toolId) : null;
    const status = e.type === 'task.end' ? e.status : e.patch?.status;
    if (row) {
      if (t.background) { row.badge.textContent = 'background' + (status ? ' · ' + (status === 'completed' ? 'done' : status) : ''); row.badge.hidden = false; }
      if (e.type === 'task.progress') {
        if (row.state === 'running' || row.state === 'preparing') row.metaEl.textContent = taskLine(t);
        if (e.summary || e.lastTool) row.line.title = [e.summary, e.lastTool ? 'Last tool: ' + e.lastTool : null].filter(Boolean).join('\n');
      }
    }
    if (e.type === 'task.end' && t.background && !t.ended) {
      t.ended = true;
      const what = `Background ${taskNoun(t)}` + (t.description ? ` “${clip(t.description, 80)}”` : '');
      const how = status === 'completed' ? 'finished' : status === 'failed' ? 'failed' : 'was stopped';
      const bits = [taskLine(t), e.summary ? clip(e.summary, 300) : null].filter(Boolean);
      notice(status === 'failed' ? 'warn' : 'info', `${what} ${how}` + (bits.length ? ' — ' + bits.join(' · ') : ''));
    }
  }

  /** The estimate of thinking tokens so far, on the live thinking line. */
  function onThinkTokens(e) {
    const th = S.liveThink;
    if (!th || !e.tokens) return;
    th.tokens = e.tokens;
    paintThink(th);
  }

  // ── subagents: each one's transcript in a panel, not in the conversation ──

  // A subagent's messages carry the id of the Agent call that started it
  // (parent_tool_use_id). Its text, thinking and tool rows are drawn into a
  // conversation of their own, with the same code as the main one, and shown
  // in a panel when you click the Agent row. The conversation keeps one row.
  const SUB_EVENTS = new Set(['content.start', 'content.delta', 'content.snapshot', 'content.end', 'tool.start', 'tool.input', 'tool.result', 'tool.output.delta', 'tool.progress', 'surface.snapshot', 'media.snapshot', 'plan.snapshot', 'turn.start', 'turn.end', 'turn.diff.snapshot']);
  const isAgentTool = name => name === 'Agent' || name === 'Task';
  let subOpen = null;   // the subagent transcript in the panel
  const subShown = () => subOpen && subEl && !subEl.hidden ? subOpen : null;

  /** The row for a tool call: in the conversation, or in one of its subagents' transcripts. */
  function rowAnywhere(id, top = S.root || S) {
    return top.rows.get(id) || [...top.subs.values()].map(c => c.rows.get(id)).find(Boolean) || null;
  }

  /** The transcript of the subagent started by Agent call `toolId` (made on first use). */
  function subConv(top, toolId) {
    let sub = top.subs.get(toolId);
    if (sub) return sub;
    sub = newConv(top.id + '/' + toolId, 'Agent');
    sub.root = top; sub.toolId = toolId;
    sub.parent = [top, ...top.subs.values()].find(c => c.rows.has(toolId)) || top;   // nested: the subagent with that Agent row
    sub.log = h('div', { class: 'ck-log ck-sub-log' });
    top.subs.set(toolId, sub);
    return sub;
  }

  function toSub(e) {
    const top = S.root || S;
    // A subagent's tool result also settles the approval card for it (the card stays in the conversation).
    if (e.type === 'tool.result') for (const [id, card] of [...top.cards]) if (card.req.toolUseID === e.id) resolveCard(id, e.isError ? 'denied' : 'allowed');
    const sub = subConv(top, e.parentId);
    const own = { ...e, parentId: null };
    const prev = S;
    S = sub;
    try {
      receiveOne(own);
    } finally { S = prev; }
    const row = rowAnywhere(e.parentId, top);
    if (row && row.state !== 'done' && row.state !== 'error' && !(agentTaskOf(top, row.id) || {}).usage) row.metaEl.textContent = agentMeta(row);
    if (subShown() === sub) paintSubPanel(true);
  }

  const agentTaskOf = (top, toolId) => [...top.agentTasks.values()].find(t => t.toolId === toolId) || null;

  /** "12 tools · 34k tokens" (from task progress), else the tool rows drawn so far. */
  function agentMeta(row) {
    const top = row.top || S, t = agentTaskOf(top, row.id), sub = top.subs.get(row.id);
    if (t && t.usage && (t.usage.tool_uses || t.usage.total_tokens)) return taskLine(t);
    return sub && sub.rows.size ? plural(sub.rows.size, 'tool') : '';
  }

  const ICON_AGENT = '<svg viewBox="0 0 16 16" width="12" height="12" aria-hidden="true"><circle cx="8" cy="5.5" r="2.6" fill="none" stroke="currentColor" stroke-width="1.4"/><path d="M3 14c.6-2.8 2.6-4.3 5-4.3s4.4 1.5 5 4.3" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round"/></svg>';

  function openSub(top, toolId) {
    closePop();
    const was = subShown();
    subOpen = subConv(top, toolId);
    subEl.hidden = false;
    if (!was) play(subEl, [{ opacity: 0, transform: 'translateY(-8px)' }, { opacity: 1, transform: 'none' }], M.mid);
    subEl.replaceChildren();
    paintSubPanel(false);
    const sc = subEl.querySelector('.ck-sub-scroll');
    if (sc) sc.scrollTop = sc.scrollHeight;
  }

  function closeSub() {
    if (!subOpen) return;
    subOpen = null;
    subEl.hidden = true;
    subEl.replaceChildren();
  }

  /**
   * The panel: the Agent call (type, description, state, counts), its prompt,
   * then the transcript. A resumed chat has no subagent messages: the result only.
   * `live`: new output; the panel follows it when you are at its bottom.
   */
  function paintSubPanel(live) {
    const sub = subOpen;
    if (!sub) return;
    const row = rowAnywhere(sub.toolId, sub.root);
    const inp = row ? row.input || {} : {};
    const state = !row ? 'done' : ['done', 'error', 'interrupted'].includes(row.state) ? row.state : 'running';
    let sc = subEl.querySelector('.ck-sub-scroll');
    const atEnd = !sc || sc.scrollTop + sc.clientHeight >= sc.scrollHeight - 24;
    const stats = [row ? agentMeta(row) : '', row && row.t0 ? secs((row.t1 || Date.now()) - row.t0) : ''].filter(Boolean).join(' · ');
    const back = sub.parent && sub.parent !== sub.root
      ? h('button', { class: 'ck-sub-btn', type: 'button', title: 'Back to the agent that started this one', onclick: () => openSub(sub.root, sub.parent.toolId) }, icon(ICON_BACK))
      : null;
    const head = h('div', { class: 'ck-sub-head' }, back, h('span', { class: 'ck-sub-ic' }, icon(ICON_AGENT)),
      h('span', { class: 'ck-sub-type', text: inp.subagent_type || (row ? shortName(row.name) : 'Agent') }),
      h('span', { class: 'ck-sub-desc', text: inp.description || '', title: inp.description || '' }),
      h('span', { class: 'ck-sub-state', 'data-state': state, text: state }),
      h('span', { class: 'ck-sub-stats', text: stats }),
      h('button', { class: 'ck-sub-btn ck-sub-x', type: 'button', title: 'Close (Esc)', onclick: closeSub }));
    // Only the head is redrawn on each change; the transcript is the subagent's own log, which grows by itself.
    if (!sc) {
      let prompt = null;
      if (inp.prompt) {
        const body = h('div', { class: 'ck-sub-prompt-t', hidden: true, text: String(inp.prompt) });
        const btn = h('button', { class: 'ck-sub-prompt-h', type: 'button', text: 'Prompt · ' + clip(inp.prompt, 120) });
        prompt = h('div', { class: 'ck-sub-prompt' }, btn, body);
        btn.onclick = () => {
          prompt.classList.toggle('is-open', body.hidden);
          if (body.hidden) expand(body, () => { body.hidden = false; }); else collapse(body, () => { body.hidden = true; });
        };
      }
      sc = h('div', { class: 'ck-sub-scroll' }, h('div', { class: 'ck-sub-in' }, prompt, sub.log, h('div', { class: 'ck-sub-foot' })));
      subEl.replaceChildren(head, sc);
    } else subEl.firstChild.replaceWith(head);
    // With no transcript (a resumed chat, or it has not started yet): the result, or a line that says why it is empty.
    const foot = sc.querySelector('.ck-sub-foot');
    const empty = !sub.log.childNodes.length;
    const fk = [empty, state, row && row.output ? row.output.length : 0].join('|');
    if (foot._k !== fk) {
      foot._k = fk;
      foot.replaceChildren();
      if (empty && state === 'running') foot.append(h('div', { class: 'ck-sub-note', text: 'Waiting for the agent’s first step…' }));
      else if (empty && row && row.output) {
        const doc = h('div', { class: 'sk-doc ck-text' });
        foot.append(h('div', { class: 'ck-sub-note', text: 'Its steps are not in this view (a resumed chat does not load them). Its result:' }), doc);
        root.SkimRender.render(doc, row.output, { streaming: false, interactive: false });
      } else if (empty) foot.append(h('div', { class: 'ck-sub-note', text: 'No steps to show.' }));
    }
    if (live && atEnd) sc.scrollTop = sc.scrollHeight;
  }

  // ── event intake ───────────────────────────────────────────────────────

  function settleLive(status) {
    for (const sub of S.subs.values()) { const prev = S; S = sub; try { settleLive(status); } finally { S = prev; } }
    for (const item of S.texts.values()) if (!item.final) { item.final = true; paintText(item, false); }
    for (const th of S.thinks.values()) endThink(th);
    for (const row of S.rows.values()) {
      if (row.state === 'running' || row.state === 'preparing' || row.state === 'waiting') {
        row.t1 = clock();
        if (row.waitStart) { row.waitMs += row.t1 - row.waitStart; row.waitStart = 0; }
        row.metaEl.textContent = status === 'success' || status === 'interrupted' ? 'stopped' : status;
        setRowState(row, 'interrupted');
      }
    }
    for (const id of [...S.cards.keys()]) resolveCard(id, 'cancelled');
    closeRun();
    S.busy = false; S.thinking = false; S.buffering = false; S.progressText = null;
    updateStatus();
  }

  function paintContent(e) {
    const key = e.id;
    if (!key) return;
    if (e.kind === 'thinking') {
      let th = S.thinks.get(key);
      if (!th) th = newThink(key, e.messageId || key, e.redacted);
      const block = S.eventState.blocks.get(key);
      if (block) th.text = block.text;
      if (e.type === 'content.end' || e.final) endThink(th);
      paintThink(th);
      if (th.open) {
        if (th.t1) paintThinkBody(th);
        else if (!th.raf) th.raf = requestAnimationFrame(() => paintThinkBody(th));
      }
      S.thinking = [...S.thinks.values()].some(item => !item.t1);
      updateStatus();
      return;
    }
    let it = S.texts.get(key);
    if (!it) it = newText(key, e.messageId || key);
    const block = S.eventState.blocks.get(key);
    if (block) it.text = block.text;
    if (e.type === 'content.end' || e.final) { it.final = true; paintText(it, false); }
    else schedulePaint(it);
  }

  function paintTool(e) {
    if (!e.id) return;
    const row = addRow(e.id, e.name || 'Tool', e.parentId);
    for (const [id, view] of S.surfaceViews) if (S.eventState.surfaces.get(id)?.ownerId === e.id && view.parentNode !== row.detail) row.detail.append(view);
    const media = S.mediaViews.get(e.id); if (media && media.parentNode !== row.detail) row.detail.append(media);
    if (e.type === 'tool.input') { setRowInput(row, e.input); return; }
    if (e.type === 'tool.start') { if (e.input !== undefined) setRowInput(row, e.input); else setRowState(row, 'running'); return; }
    const output = String(e.output ?? S.eventState.tools.get(e.id)?.output ?? '');
    row.t1 = clock();
    for (const [cardId, card] of S.cards) if (card.req.toolUseID === row.id) resolveCard(cardId, e.isError ? 'denied' : 'allowed');
    if (row.waitStart) { row.waitMs += row.t1 - row.waitStart; row.waitStart = 0; }
    row.output = output;
    if (row.stdinForm) row.stdinForm.querySelectorAll('input,button').forEach(el => el.disabled = true);
    row.streamEl = null;
    row.metaEl.textContent = isAgentTool(row.name) && !e.isError ? agentMeta(row) || 'done' : metaOf(row, output, e.isError);
    const out = h('pre', { class: 'ck-out', text: output.length > 4000 ? output.slice(0, 4000) + '\n…' : output });
    const extras = [...row.detail.children].filter(el => el.classList.contains('ck-surface') || el.classList.contains('ck-media'));
    if (!row.change) row.detail.replaceChildren(out, ...extras);
    else if (e.isError) row.detail.replaceChildren(out, row.change, ...extras);
    setRowState(row, e.isError ? 'error' : 'done');
    if (row.run) paintRun(row.run);
    if (subShown() && subShown().toolId === row.id) paintSubPanel();
  }

  const END_LABEL = { error_max_turns: 'Stopped at the turn limit', error_max_budget_usd: 'Stopped at the budget limit',
    error_max_structured_output_retries: 'Stopped: no valid structured output', error_during_execution: 'Ended with an error' };

  function onTurnEnd(e) {
    settleLive(e.status);
    if (S.turn && !S.turn.footer) {
      const bits = [];
      if (e.durationMs) bits.push((e.durationMs / 1000).toFixed(1) + 's');
      if (e.steps > 1) bits.push(e.steps + ' steps');
      if (e.cost != null) S.cost = e.cost;
      if (e.modelUsage) S.modelUsage = e.modelUsage;
      S.turns_n++; S.apiMs += e.apiMs || 0;
      // The footer says how the turn ended, in words: a stop is yours, not an error.
      const how = e.status === 'interrupted' ? 'Stopped' : e.status === 'success' ? null : END_LABEL[e.label] || 'Ended with an error';
      S.turn.footer = h('div', { class: 'ck-foot', 'data-status': e.status || 'success' },
        how ? h('span', { class: 'ck-foot-how', text: how }) : null, (how && bits.length ? ' · ' : '') + bits.join(' · '));
      S.turn.el.append(S.turn.footer);
    }
    if (e.status === 'error' && /^Resume rejected by --resume-drops-turn/.test(e.message || '')) {
      // Claude Code would not cut there (more than the dropped turn was after it): go on from the whole session.
      notice('warn', 'Claude Code could not cut the conversation at that point, so it goes on with all of it. Send your message again.');
      post({ type: 'restartAt', plain: true });
    } else if (e.status === 'error' && e.message) notice('error', e.message);
    paintMeta(); stick();
    if (!S.replaying) { requestUsage(!usagePanel.hidden); requestGit(); }
  }

  function showUnknown(e) {
    const detail = h('details', { class: 'ck-unknown' },
      h('summary', { text: 'Unrecognized event: ' + String(e.name || e.raw?.type || e.type).slice(0, 100) }),
      h('pre', { text: (() => { try { return JSON.stringify(e.raw ?? e, null, 2).slice(0, 8000); } catch (_) { return '[unserializable event]'; } })() }));
    (S.turn ? S.turn.body : S.log).append(detail);
    S.unknownDetails.push(detail);
    if (S.unknownDetails.length > 100) S.unknownDetails.shift().remove();
    stick();
  }

  // ── semantic event surfaces shared by live Codex and replay ────────────
  // Event components also work before optional chat enhancements are installed.
  function registerEventCard(req, card, opts) {
    turn().body.append(card);
    S.cards.set(req.id, { card, keys: {}, req, opts });
    const row = req.toolUseID && S.rows.get(req.toolUseID);
    if (row) { row.waitStart = clock(); setRowState(row, 'waiting'); }
    updateStatus(); stick();
  }

  function showEventImage(image) {
    if (typeof openLightbox === 'function') { openLightbox(image); return; }
    const dialog = h('dialog', { class: 'ck-event-image-dialog', 'aria-label': image.name },
      h('img', { src: image.url, alt: image.name }), h('button', { type: 'button', text: 'Close', onclick: () => dialog.close() }));
    dialog.addEventListener('close', () => dialog.remove());
    document.body.append(dialog); dialog.showModal();
  }

  function routeEventChild(e) {
    const top = S;
    let child = top.eventChildren.get(e.parentId);
    if (!child) {
      child = newConv(top.id + '/' + e.parentId, 'Agent');
      child.log = h('div', { class: 'ck-event-child' });
      const panel = h('details', { class: 'ck-surface', 'data-surface': 'agent' }, h('summary', { class: 'ck-surface-head', text: 'Agent transcript' }), child.log);
      const owner = top.rows.get(e.parentId);
      (owner ? owner.detail : turn().body).append(panel);
      top.eventChildren.set(e.parentId, child);
    }
    S = child;
    try { receiveOne({ ...e, parentId: null }); } finally { S = top; }
  }

  const safeLink = value => { try { const url = new URL(value); return ['http:', 'https:'].includes(url.protocol) ? url.href : null; } catch { return null; } };
  const fieldLabel = name => String(name).replace(/([a-z])([A-Z])/g, '$1 $2').replace(/[_/]/g, ' ');
  function eventValue(value, depth = 0) {
    if (depth > 6) return h('span', { text: 'Further details omitted' });
    if (value == null) return h('span', { class: 'ck-surface-muted', text: '—' });
    if (typeof value !== 'object') {
      const text = String(value), url = safeLink(text);
      return url ? h('a', { href: url, target: '_blank', rel: 'noreferrer', text }) : h('span', { text });
    }
    if (Array.isArray(value)) return h('ul', { class: 'ck-surface-list' }, value.slice(0, 100).map(item => h('li', null, eventValue(item, depth + 1))));
    return h('dl', { class: 'ck-surface-fields' }, Object.entries(value).filter(([,v]) => v != null).map(([key, v]) => [h('dt', { text: fieldLabel(key) }), h('dd', null, eventValue(v, depth + 1))]));
  }

  function paintPlan(e) {
    const key = root.AgentEvents.turnKey(e.threadId, e.turnId);
    if (key && !S.turnViews.has(key)) return;
    paintSurface({ ...e, id: 'plan:' + (key || e.id), type: 'surface.snapshot', surface: 'plan', title: 'Plan', method: 'turn/plan/updated', data: { explanation: e.explanation, steps: e.plan } });
    if (key && key !== S.turn?.key || !S.tasks || typeof paintTasks !== 'function') return;
    S.tasks.list = (e.plan || []).map((step, index) => ({ id: String(index), subject: String(step.step || ''),
      status: step.status === 'inProgress' ? 'in_progress' : step.status || 'pending' }));
    S.tasks.explanation = e.explanation || '';
    S.tasks.seen.clear(); S.tasks.byTool.clear();
    paintTasks();
  }

  function paintToolStream(e) {
    const state = S.eventState.tools.get(e.id);
    if (!state) return;
    const row = addRow(e.id, e.name || state.name || 'Tool', e.parentId);
    if (e.type === 'tool.progress') { row.metaEl.textContent = state.progress; return; }
    if (!row.streamEl) {
      row.streamEl = h('pre', { class: 'ck-out ck-stream-output', 'aria-label': 'Live tool output' });
      row.detail.append(row.streamEl);
    }
    row.streamEl.textContent = String(state.output || '') + (state.capped ? '\n[Output limit reached]' : '');
    if (state.state === 'running') setRowState(row, 'running');
    if (state.processHandle && !row.stdinForm) {
      const input = h('input', { type: 'text', placeholder: 'Process input', 'aria-label': 'Process input' });
      const submit = h('button', { type: 'submit', text: 'Send input' });
      row.stdinForm = h('form', { class: 'ck-process-input' }, input, submit);
      row.stdinForm.onsubmit = event => { event.preventDefault(); post({ type: 'surfaceAction', action: 'processInput', id: state.processHandle, text: input.value + '\n' }); input.value = ''; };
      row.detail.append(row.stdinForm);
    }
    stick();
  }

  function paintMedia(e) {
    let view = S.mediaViews.get(e.id);
    if (!view) {
      view = h('figure', { class: 'ck-media' }); S.mediaViews.set(e.id, view);
      const row = S.rows.get(e.id);
      (row ? row.detail : turn().body).append(view);
    }
    const valid = typeof e.url === 'string' && /^data:image\/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=]+$/.test(e.url);
    const children = [valid ? h('img', { src: e.url, alt: e.caption || 'Image result', loading: 'lazy' }) : h('p', { class: 'ck-surface-muted', text: e.error || 'Image preview unavailable' }), h('figcaption', { text: e.caption || e.path || 'Image' })];
    if (e.path) children.push(h('button', { type: 'button', text: 'Reveal image', onclick: () => post({ type: 'reveal', path: e.path }) }));
    if (valid) children.push(h('button', { type: 'button', text: 'View image', onclick: () => showEventImage({ url: e.url, name: e.path || e.caption || 'Image' }) }));
    view.replaceChildren(...children); stick();
  }

  function realtimeStatus() {
    const entry = S.eventState.surfaces.get('codex:voice:' + S.sessionId);
    if (entry) return entry.data?.status || 'closed';
    return 'closed';
  }

  function paintRealtimeButton() {
    if (!realtimeBtn || !inView()) return;
    realtimeBtn.hidden = !supports('realtimeVoice');
    const state = realtimeStatus(), running = ['starting', 'active', 'muted'].includes(state);
    realtimeBtn.textContent = running ? 'End voice' : 'Voice';
    realtimeBtn.setAttribute('aria-pressed', String(running));
    realtimeBtn.dataset.state = state;
    realtimeBtn.title = running ? 'End Codex voice and stop the microphone' : 'Start a Codex voice conversation';
  }

  function paintSurface(e) {
    if (e.clear) {
      for (const [id, view] of S.surfaceViews) if (view.dataset.surface === e.surface) { view.remove(); S.surfaceViews.delete(id); }
      return;
    }
    const entry = S.eventState.surfaces.get(e.id) || e, data = entry.data || {};
    let view = S.surfaceViews.get(e.id);
    if (!view) {
      view = h('details', { class: 'ck-surface ck-event-' + e.surface, 'data-surface': e.surface }, h('summary', { class: 'ck-surface-head' }), h('div', { class: 'ck-surface-content' }));
      S.surfaceViews.set(e.id, view);
      const owner = e.ownerId && S.rows.get(e.ownerId);
      const owningTurn = root.AgentEvents.turnKey(e.threadId, e.turnId);
      const target = owningTurn && S.turnViews.get(owningTurn);
      if (owner) owner.detail.append(view);
      else if (e.placement === 'session') {
        if (!S.surfaceRoot) { S.surfaceRoot = h('section', { class: 'ck-session-surfaces', 'aria-label': 'Conversation status and details' }); S.log.prepend(S.surfaceRoot); }
        S.surfaceRoot.append(view);
      } else (target || turn()).body.append(view);
    }
    const state = typeof data.status === 'string' ? data.status : data.status?.type || data.item?.status || data.run?.status || '';
    view.firstChild.textContent = (e.title || fieldLabel(e.surface)) + (state ? ' · ' + state : '');
    const body = view.lastChild;
    if (e.surface === 'goal' && data.goal) {
      const goal = data.goal;
      body.replaceChildren(...[h('p', { class: 'ck-surface-title', text: goal.objective || 'Goal' }),
        h('p', { class: 'ck-surface-muted', text: `${goal.status || 'active'} · ${goal.tokensUsed || 0} tokens · ${goal.timeUsedSeconds || 0}s` }),
        goal.tokenBudget > 0 ? h('progress', { value: goal.tokensUsed || 0, max: goal.tokenBudget, 'aria-label': 'Goal token budget' }) : null,
        eventValue({ tokenBudget: goal.tokenBudget, tokensUsed: goal.tokensUsed })].filter(Boolean));
    } else if (e.surface === 'queue' && Array.isArray(data.data)) {
      body.replaceChildren(...data.data.map(item => h('div', { class: 'ck-queue-item' }, h('p', { text: (item.input || []).filter(p => p.type === 'text').map(p => p.text).join('\n') || 'Queued message' }),
        h('button', { type: 'button', text: 'Start now', onclick: () => post({ type: 'surfaceAction', action: 'queueStart', id: item.id }) }),
        h('button', { type: 'button', text: 'Remove', onclick: () => post({ type: 'surfaceAction', action: 'queueRemove', id: item.id }) }))));
      if (!data.data.length) body.append(h('p', { class: 'ck-surface-muted', text: 'No queued messages' }));
    } else if (e.surface === 'account' && e.method === 'floaty/account') {
      const busy = ['refreshing', 'checking'].includes(data.status);
      const account = data.account;
      body.replaceChildren(h('p', { text: data.message || 'Codex account' }));
      if (account) body.append(h('p', { class: 'ck-surface-muted', text: [account.email, account.type, account.planType].filter(Boolean).join(' · ') }));
      body.append(h('div', { class: 'ck-integration-actions' },
        h('button', { type: 'button', disabled: busy || data.loginPending, text: 'Refresh credentials', onclick: () => post({ type: 'surfaceAction', action: 'accountRefresh' }) }),
        h('button', { type: 'button', disabled: busy || data.loginPending, text: 'Sign in with ChatGPT', onclick: () => post({ type: 'surfaceAction', action: 'accountLogin' }) }),
        ...(data.loginPending ? [h('button', { type: 'button', text: 'Cancel sign-in', onclick: () => post({ type: 'surfaceAction', action: 'accountLoginCancel' }) })] : [])));
      if (data.status === 'reauthenticationRequired' || data.status === 'signedOut') view.open = true;
    } else if (e.surface === 'realtime') {
      if (e.method === 'floaty/realtime') {
        view.open = true;
        const running = ['starting', 'active', 'muted'].includes(data.status);
        body.replaceChildren(h('p', { text: data.message || ({ active: 'Listening and playing Codex audio', muted: 'Microphone muted; Codex audio still plays', closed: 'Voice ended', starting: 'Connecting voice…' }[data.status] || 'Voice could not connect') }));
        const controls = h('div', { class: 'ck-integration-actions' });
        if (data.status === 'active' || data.status === 'muted') controls.append(h('button', { type: 'button', 'aria-pressed': String(data.status === 'muted'), text: data.status === 'muted' ? 'Unmute microphone' : 'Mute microphone', onclick: () => post({ type: 'realtimeMute', muted: data.status !== 'muted' }) }));
        controls.append(h('button', { type: 'button', text: running ? 'End voice' : 'Start voice', onclick: () => post({ type: running ? 'realtimeStop' : 'realtimeStart' }) }));
        body.append(controls);
        paintRealtimeButton();
      } else if (e.method.includes('transcript')) {
        if (view.transcriptDone && !e.method.endsWith('/done')) view.transcript = '';
        view.transcript ||= '';
        view.transcriptDone = e.method.endsWith('/done');
        view.transcript = e.method.endsWith('/done') ? data.text || '' : (view.transcript + (e.data?.delta || '')).slice(-64000);
        body.replaceChildren(h('p', { text: (data.role ? data.role + ': ' : '') + view.transcript }));
      } else body.replaceChildren(eventValue(data));
      if (e.method === 'thread/realtime/started') body.append(h('button', { type: 'button', text: 'End voice session', onclick: () => post({ type: 'surfaceAction', action: 'realtimeStop' }) }));
    } else body.replaceChildren(eventValue(data));
    if (e.surface === 'status' && e.method === 'thread/status/changed') {
      S.protocolStatus = state; S.busy = state === 'active'; updateStatus();
    }
    if (e.method === 'model/rerouted' && data.toModel) { S.model = data.toModel; paintMeta(); }
    if (e.method === 'model/safetyBuffering/updated') { S.buffering = !!data.showBufferingUi; updateStatus(); }
    if (e.method === 'thread/closed' || e.method === 'thread/deleted') { S.connectionClosed = true; settleLive('cancelled'); updateStatus(); }
    if (e.method === 'thread/started') { S.connectionClosed = false; updateStatus(); }
    stick();
  }

  function addNativeCard(req) {
    const existing = S.cards.get(req.id);
    if (existing) { existing.card.remove(); S.cards.delete(req.id); }
    const data = req.input || {}, fields = [], questions = [];
    const body = h('div', { class: 'ck-native-fields' });
    const opts = h('div', { class: 'ck-opts' });
    const title = req.kind === 'questions' ? 'Codex needs your input' : req.kind === 'permissions' ? 'Grant permissions?' : req.kind === 'elicitation' ? `${data.serverName || 'MCP server'} needs input` : req.toolName;
    const card = h('div', { class: 'ck-card ck-native-card', 'data-kind': req.kind }, h('h3', { class: 'ck-card-title', text: title }),
      req.decisionReason ? h('p', { class: 'ck-why', text: req.decisionReason }) : null, body, opts);
    const respond = (response, decision) => {
      if (card.dataset.done) return;
      if (decision !== 'deny' && !form.reportValidity()) return;
      card.dataset.done = '1';
      post({ type: 'permission', id: req.id, decision, response });
      form.querySelectorAll('input,select,textarea,button').forEach(el => { if (el.type === 'password') el.value = ''; el.disabled = true; });
      resolveCard(req.id, decision === 'deny' ? 'denied' : 'allowed');
    };
    const form = h('form', null, body, opts); card.append(form);
    const button = (text, callback, validate = true) => {
      const b = h('button', { type: 'button', class: 'ck-opt', text });
      b.onclick = () => { if (!validate) { for (const field of fields) field.required = false; } callback(); }; opts.append(b);
    };
    if (req.kind === 'questions') {
      for (const [index, q] of (data.questions || []).entries()) {
        const fieldset = h('fieldset', { class: 'ck-native-question' }, h('legend', { text: q.question || q.header || 'Question' }));
        const choices = [];
        for (const [choiceIndex, choice] of (q.options || []).entries()) {
          const input = h('input', { type: 'radio', name: req.id + '-' + index, value: choice.label });
          if (choiceIndex === 0) input.checked = true;
          choices.push(input);
          fieldset.append(h('label', { class: 'ck-native-choice' }, input, h('span', null, h('strong', { text: choice.label }), choice.description ? h('small', { text: choice.description }) : null)));
        }
        const text = h('input', { type: q.isSecret ? 'password' : 'text', placeholder: choices.length ? 'Or enter your own answer' : 'Your answer', 'aria-label': q.question || q.header || 'Answer', autocomplete: 'off' });
        if (!choices.length) text.required = true;
        fields.push(text); questions.push({ q, text, choices }); fieldset.append(text); body.append(fieldset);
      }
      button('Send answers', () => {
        const answers = Object.fromEntries(questions.map(({q,text,choices}) => [q.id, { answers: [text.value.trim() || choices.find(c=>c.checked)?.value || ''] }]));
        respond({ answers }, 'allow');
      });
      button('Skip', () => respond({ answers: Object.fromEntries(questions.map(({q}) => [q.id,{answers:[]}])) }, 'deny'), false);
    } else if (req.kind === 'permissions') {
      body.append(eventValue(data.permissions || {}));
      const scope = h('select', { 'aria-label': 'Permission duration' }, h('option', { value: 'turn', text: 'This turn' }), h('option', { value: 'session', text: 'This session' }));
      body.append(h('label', null, 'Grant duration ', scope));
      button('Grant requested permissions', () => respond({ scope: scope.value }, 'allow'));
      button('Decline', () => respond({ scope: 'turn' }, 'deny'), false);
    } else if (req.kind === 'elicitation') {
      if (data.mode === 'url') {
        const url = safeLink(data.url); body.append(h('p', { text: data.message || 'Continue in the linked service.' }));
        if (url) body.append(h('a', { href: url, target: '_blank', rel: 'noreferrer', text: 'Open service ↗' }));
        button('Completed in service', () => respond({ action: 'accept' }, 'allow'));
      } else if (data.mode === 'openai/userVerification') {
        body.append(h('p', { text: 'Device verification is unavailable in this host. Use the service’s supported verification client.' }));
      } else {
        const schema = data.requestedSchema || {}, values = [];
        let unsupported = false;
        for (const [key, property] of Object.entries(schema.properties || {})) {
          let input;
          const options = property.oneOf || property.items?.anyOf;
          const enums = property.enum || property.items?.enum;
          if (options || enums) {
            input = h('select', null, (options || enums).map((value, index) => h('option', { value: options ? value.const : value, text: options ? value.title : property.enumNames?.[index] || String(value) })));
            if (property.type === 'array') input.multiple = true;
          } else if (['string','boolean','number','integer'].includes(property.type)) {
            input = h('input', { type: property.type === 'boolean' ? 'checkbox' : ['number','integer'].includes(property.type) ? 'number' : ({ email:'email',uri:'url',date:'date' })[property.format] || 'text' });
            if (property.type === 'number') input.step = 'any';
          } else { unsupported = true; body.append(h('p', { text: 'Unsupported field: ' + key })); continue; }
          // Required booleans may validly be false; checkbox required would forbid that.
          input.required = property.type !== 'boolean' && (schema.required || []).includes(key);
          if (property.minimum != null) input.min = property.minimum;
          if (property.maximum != null) input.max = property.maximum;
          if (property.minLength != null) input.minLength = property.minLength;
          if (property.maxLength != null) input.maxLength = property.maxLength;
          if (property.default != null) {
            if (property.type === 'boolean') input.checked = property.default;
            else if (property.type === 'array') [...input.options].forEach(option => option.selected = property.default.includes(option.value));
            else input.value = String(property.default);
          }
          fields.push(input); values.push({ key, property, input });
          body.append(h('label', null, property.title || fieldLabel(key), input, property.description ? h('small', { text: property.description }) : null));
        }
        if (!unsupported) button('Submit', () => {
          const content = {};
          for (const { key, property, input } of values) {
            input.setCustomValidity('');
            let value = input.value;
            if (property.type === 'array') {
              value = [...input.selectedOptions].map(option => option.value);
              if (value.length < (property.minItems || 0) || (property.maxItems != null && value.length > property.maxItems)) input.setCustomValidity('Select the requested number of options.');
            } else if (property.type === 'boolean') value = input.checked;
            else if (['number','integer'].includes(property.type)) {
              if (!value && !input.required) continue;
              value = Number(value);
            } else if (!value && !input.required) continue;
            content[key] = value;
          }
          respond({ action: 'accept', content }, 'allow');
        });
      }
      button('Decline', () => respond({ action: 'decline' }, 'deny'), false);
      button('Cancel', () => respond({ action: 'cancel' }, 'deny'), false);
    } else {
      body.append(eventValue(data));
      for (const decision of data.availableDecisions || ['accept','acceptForSession','decline','cancel']) {
        const key = typeof decision === 'string' ? decision : Object.keys(decision)[0];
        const label = ({ accept:'Allow once',acceptForSession:'Allow for session',decline:'Decline',cancel:'Cancel',acceptWithExecpolicyAmendment:'Allow and apply command policy',applyNetworkPolicyAmendment:'Apply offered network policy' })[key] || fieldLabel(key);
        button(label, () => respond({ decision }, ['decline','cancel'].includes(key) ? 'deny' : 'allow'));
      }
    }
    form.onsubmit = event => event.preventDefault();
    if (typeof registerCard === 'function') registerCard(req, card, {}, opts);
    else registerEventCard(req, card, opts);
  }


  function receiveOne(e) {
    if (e.parentId) {
      if (typeof SUB_EVENTS !== 'undefined' && SUB_EVENTS.has(e.type)) { toSub(e); return; }
      if (typeof SUB_EVENTS === 'undefined' && !e.type.startsWith('approval.')) { routeEventChild(e); return; }
    }
    root.AgentEvents.reduce(S.eventState, e);
    switch (e.type) {
      case 'session': {
        if (agent === 'codex' && S.sessionId && e.sessionId && S.sessionId !== e.sessionId) resetConv(S);
        if (S.sessionId && e.sessionId && e.sessionId !== S.sessionId) { notice('info', 'New conversation'); S.cost = 0; S.modelUsage = null; S.turns_n = 0; S.apiMs = 0; }
        S.sessionId = e.sessionId || S.sessionId;
        S.model = e.model || S.model; S.mode = e.mode || S.mode;
        SHARED.cwd = e.cwd || SHARED.cwd;
        if (e.info) SHARED.info = e.info;
        if (e.terminalCommands) SHARED.terminalCmds = new Set(e.terminalCommands);
        paintMeta(); paintContext(); break;
      }
      case 'turn.start': bindTurn(e); S.busy = true; updateStatus(); break;
      case 'turn.diff.snapshot': paintTurnDiff(e); break;
      case 'plan.snapshot': paintPlan(e); break;
      case 'tool.output.delta': case 'tool.progress': paintToolStream(e); updateStatus(); break;
      case 'surface.snapshot': paintSurface(e); break;
      case 'media.snapshot': paintMedia(e); break;
      case 'turn.end':
        settleRetry();
        if (e.local) { settleLive(e.status); paintMeta(); }
        else onTurnEnd(e);
        break;
      case 'content.start': case 'content.delta': case 'content.snapshot': case 'content.end':
        settleRetry(); S.busy = true; paintContent(e); updateStatus(); break;
      case 'tool.start': case 'tool.input': case 'tool.result':
        settleRetry(); S.busy = e.type === 'tool.result' ? S.busy : true; paintTool(e); trackTasks(e); updateStatus(); break;
      case 'commands': SHARED.commands = e.commands || []; if (P.kind === 'slash') refreshPop(); break;
      case 'approval.request': if (supports('approvals')) addCard(e.request); else showUnknown(e); break;
      case 'approval.cancel': resolveCard(e.id, 'cancelled'); break;
      case 'notice':
        if (e.terminal) settleRetry();
        notice(e.kind || 'info', e.message || 'Session ended');
        if (e.terminal) settleLive(e.kind === 'error' ? 'error' : 'cancelled');
        break;
      case 'retry': onRetry(e); break;
      case 'limit': onLimit(e); break;
      case 'hook': onHook(e); break;
      case 'task.start': case 'task.progress': case 'task.update': case 'task.end': onTask(e); break;
      case 'tasks.background': S.bgTasks = e.tasks || []; updateStatus(); break;
      case 'thinking.tokens': onThinkTokens(e); break;
      case 'files': onFiles(e); break;
      case 'unknown': showUnknown(e); break;
      case 'local.output': localOutput(e.content ?? e.text); break;
      case 'capabilities':
        SHARED.commands = e.commands || []; SHARED.models = e.models || []; SHARED.outputStyles = e.outputStyles || [];
        SHARED.agents = e.agents || [];
        if (e.features) features = { ...features, ...e.features };
        if (e.mode) S.mode = e.mode;
        if (!supports('slashCommands') && P.kind === 'slash') closePop();
        if (!supports('mentions') && P.kind === 'mention') closePop();
        paintMeta(); paintView(); paintRefs(); paintMic(); if (P.kind) refreshPop();
        requestUsage(false); requestGit(); break;
      case 'model': if (e.model) { const r = S.models.find(x => x.value === e.model); S.modelChoice = e.model; S.model = r ? (r.resolvedModel || r.value) : e.model; paintMeta(); } break;
      case 'mode': S.mode = e.mode || S.mode; paintMeta(); break;
      case 'effort': S.effort = e.effort || null; paintMeta(); break;
      case 'git': SHARED.git = e; paintContext(); break;
      case 'sessions': SHARED.sessions = { at: Date.now(), list: e.list || [] }; if (P.kind === 'slash') refreshPop(); break;
      case 'history': loadHistory(e); break;
      case 'rewind': onRewind(e); break;
      case 'btw': onBtw(e); break;
      case 'prompt.state': onPromptState(e); break;
      case 'vcs': if (!S.replaying) requestGit(); break;
      case 'progress.summary': S.progressText = e.text || null; updateStatus(); break;
      case 'title':
        if (e.sessionId && S.sessionId && e.sessionId !== S.sessionId) break;
        S.title = e.title || ''; S.titleCustom = !!e.custom;
        if (inView() && P.kind === 'more') refreshPop();
        break;
      case 'history.replay':
        if (e.sessionId !== S.sessionId) break;
        S.replaying = true;
        try {
          for (const recorded of e.turns || []) {
            newTurn(recorded.userText ?? null);
            for (const event of recorded.events || []) { evT = event.t || 0; receiveOne(event); }
          }
        } finally { S.replaying = false; }
        evT = 0; settleLive('success'); S.turn = null;
        S.log.append(h('div', { class: 'ck-resumed', text: 'Resumed · you can continue below' }));
        break;
      case 'thinking': S.thinkingOn = !!e.on; S.thinkingSource = e.source || null; if (inView() && P.kind === 'more') refreshPop(); break;
      case 'usage':
        if (e.context !== undefined) S.ctx = e.context;
        if (e.tokens !== undefined) S.tokens = e.tokens;
        if (e.plan) SHARED.plan = e.plan;
        if (e.unavailable !== undefined) S.usageUnavailable = e.unavailable;
        paintMeta(); break;
      default: showUnknown(e);
    }
  }

  const AgentChat = {
    boot(cfg) {
      agent = cfg.agent || 'claude';
      features = { ...(agent === 'claude' ? CLAUDE_FEATURES : CODEX_FEATURES) };
      if (cfg.voice) features.voice = true;   // the host can listen (the mic button)
      main.normalizer = root.AgentEvents.createNormalizer(agent);
      main.eventState = root.AgentEvents.createState();
      SHARED.cwd = cfg.cwd || ''; SHARED.home = cfg.home || '';
      if (cfg.model) S.model = cfg.model;
      buildShell();
      paintMeta(); paintView(); paintRefs();
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
        for (const raw of batch) {
          evT = raw.t || 0;
          const rm = raw.type === 'sdk' && raw.msg;
          if (rm && (rm.type === 'assistant' || rm.type === 'user') && rm.uuid && !rm.parent_tool_use_id) conv.lastChain = rm.uuid;
          try {
            for (const e of conv.normalizer.normalize(raw)) { evT = e.t || 0; receiveOne(e); }
          } catch (err) { console.error('AgentChat', raw.type, err); }
        }
      } finally { evT = 0; S = prev; }
      if (!batch.some(e => e.type === 'sdk' || e.type === 'native' || e.type === 'permission_request' || e.type === 'host' || e.v === 1)) return;
      if (conv !== active) { conv.unseen = true; paintView(); }
      // Output arrived while you read higher up: the down button says so.
      else if (!follow && downBtn) { downBtn.dataset.fresh = '1'; paintDown(); }
    },
    /**
     * Files dropped on the tab (the host reads them): `[{ path, rel, isDir, image? }]`.
     * Pictures become attachments; the rest become @-mentions at the caret.
     */
    dropFiles(items) {
      if (!input || !Array.isArray(items)) return;
      const marks = [];
      for (const it of items) {
        if (!it) continue;
        if (it.image && it.image.data && supports('images')) attachImage({ mediaType: it.image.mediaType, data: it.image.data, name: it.image.name || baseName(it.path) });
        else {
          const p = String(it.rel || it.path || '');
          if (p) marks.push(asMention(it.isDir && !p.endsWith('/') ? p + '/' : p, true));
        }
      }
      if (marks.length) insertAtCaret(marks.join(' '));
      else input.focus();
    },
    /** Draws a user turn without sending it (replays, resumed history). */
    showUser(text) { newTurn(text); S.busy = true; updateStatus(); },
    focus() { input && input.focus(); },
    /** Dictation from the host: `{ state: listening | idle | error, text?, final?, message? }`. */
    voice(e) {
      if (!e || !input) return;
      if (e.text != null && !V.detached && V.state !== 'idle') placeVoice(e.text);
      if (e.state === 'error') {
        const prev = S; S = active;
        notice('warn', e.message || 'Dictation stopped.');
        S = prev;
      }
      if (e.state === 'listening') { if (V.state === 'starting') V.state = 'listening'; }
      else { V.state = 'idle'; V.detached = false; }
      paintMic();
    }
  };
  root.AgentChat = AgentChat;
  root.ClaudeChat = AgentChat;
})(typeof self !== 'undefined' ? self : this);
