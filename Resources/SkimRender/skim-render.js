/*
 * SkimRender — draws SkimClassify blocks as DOM.
 *
 *   SkimRender.render(container, markdown, { streaming, interactive, onAction })
 *
 * Needs marked, DOMPurify and SkimClassify on the page; highlight.js and
 * mermaid are used when present. Every piece of Markdown-derived HTML goes
 * through DOMPurify before it touches the DOM — the text comes from a model,
 * and the host page may expose a bridge to native code. Our own structure is
 * built with createElement and textContent.
 *
 * Re-rendering is keyed: a block whose source did not change keeps its DOM, so
 * a streaming reply does not redraw finished diagrams or lose checklist ticks.
 *
 * `onAction({ type: 'reply', text })` fires when a control answers Claude
 * (choosing an option). Without `interactive`, those controls are hidden.
 *
 * `reveal` (a live reply): text that arrived since the last render fades in,
 * and a block that is new rises in. The block still growing is rebuilt on each
 * render, so the words still fading are wrapped again with their fade already
 * under way (a negative animation delay): the fade does not restart or stop.
 */
(function (root) {
  'use strict';

  // ── DOM + Markdown helpers ─────────────────────────────────────────────

  function h(tag, props, ...kids) {
    const el = document.createElement(tag);
    for (const [k, v] of Object.entries(props || {})) {
      if (v == null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'text') el.textContent = v;
      else if (k === 'html') el.innerHTML = v;   // callers pass sanitized HTML only
      else if (k.startsWith('on')) el.addEventListener(k.slice(2).toLowerCase(), v);
      else if (k === 'dataset') Object.assign(el.dataset, v);
      else el.setAttribute(k, v === true ? '' : v);
    }
    for (const kid of kids.flat(Infinity)) {
      if (kid == null || kid === false) continue;
      el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
    }
    return el;
  }

  const clean = html => root.DOMPurify.sanitize(html, { USE_PROFILES: { html: true } });

  /** Tags inline code that reads as a path or a commit hash. */
  function decorate(el, { metrics } = {}) {
    for (const c of el.querySelectorAll('code')) {
      if (c.closest('pre')) continue;
      const t = c.textContent;
      if (/^[0-9a-f]{7,40}$/.test(t) && /\d/.test(t) && /[a-f]/.test(t)) c.classList.add('sk-sha');
      else if (root.SkimClassify.looksLikePath(t)) c.classList.add('sk-path');
    }
    if (metrics) wrapText(el, /\b\d+\/\d+\b/g, 'sk-metric');
    for (const pre of el.querySelectorAll('pre > code')) highlight(pre, (pre.className.match(/language-(\S+)/) || [])[1]);
    return el;
  }

  function wrapText(el, re, cls) {
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    const hits = [];
    while (walker.nextNode()) if (!walker.currentNode.parentElement.closest('code')) hits.push(walker.currentNode);
    for (const node of hits) {
      const s = node.nodeValue; re.lastIndex = 0;
      if (!re.test(s)) continue;
      re.lastIndex = 0;
      const frag = document.createDocumentFragment(); let last = 0, m;
      while ((m = re.exec(s))) {
        frag.append(s.slice(last, m.index), h('span', { class: cls, text: m[0] }));
        last = re.lastIndex;
      }
      frag.append(s.slice(last));
      node.replaceWith(frag);
    }
  }

  const inline = (md, o) => decorate(h('span', { html: clean(root.marked.parseInline(md || '')) }), o);
  const blockMd = (md, cls) => decorate(h('div', { class: cls, html: clean(root.marked.parse(md || '')) }));
  const tokensMd = (tokens, cls) => decorate(h('div', { class: cls, html: clean(root.marked.parser(tokens)) }));

  function highlight(codeEl, lang) {
    const hl = root.hljs;
    if (!hl || !lang || !hl.getLanguage(lang)) return;
    codeEl.innerHTML = clean(hl.highlight(codeEl.textContent, { language: lang, ignoreIllegals: true }).value);
  }

  function copyText(text, btn) {
    const done = () => { const was = btn.textContent; btn.textContent = 'Copied'; setTimeout(() => { btn.textContent = was; }, 1400); };
    const fallback = () => {
      const ta = h('textarea', { style: 'position:fixed;opacity:0' }); ta.value = text;
      document.body.append(ta); ta.select();
      try { document.execCommand('copy'); } catch (e) { /* nothing else to try */ }
      ta.remove(); done();
    };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, fallback);
    else fallback();
  }

  const copyBtn = text => { const b = h('button', { class: 'sk-icon-btn', text: 'Copy' }); b.onclick = () => copyText(text, b); return b; };

  // ── progressive disclosure ─────────────────────────────────────────────
  // FloatyTerm's panel is small (about 700 × 420 pt), so a long block shows
  // its head and folds the rest behind one "Show …" row.
  const FOLD = { keepRows: 5, keepTableRows: 6, codeLines: 16, treeRows: 12, keepKids: 2 };

  function moreBtn(label, onClick) {
    const b = h('button', { class: 'sk-more', type: 'button' }, h('span', { class: 'sk-caret sk-more-chev' }), label);
    b.onclick = e => { e.stopPropagation(); onClick(b); };
    return b;
  }

  /** Hides `items` after the first `keep`. Returns the row that shows them, or null. */
  function foldItems(items, keep, noun) {
    if (items.length <= keep + 1) return null;   // folding a single row saves nothing
    const rest = items.slice(keep);
    rest.forEach(x => { x.hidden = true; });
    return moreBtn(`Show ${rest.length} more ${noun}`, b => { rest.forEach(x => { x.hidden = false; }); b.remove(); });
  }

  /** Folds the top-level items of the first list inside a rendered Markdown div. */
  function foldMdList(el) {
    const list = el.querySelector(':scope > ul, :scope > ol');
    if (!list) return el;
    const more = foldItems(Array.from(list.children), FOLD.keepRows, 'items');
    if (more) list.after(more);
    return el;
  }

  // ── 01 options ─────────────────────────────────────────────────────────

  function renderOptions(b, ctx) {
    const recIds = b.rec ? b.rec.ids : [];
    const wrap = h('div', { class: 'sk-options' });
    const sent = h('span', { class: 'sk-sent', hidden: true });
    const bars = level => h('span', { class: 'sk-bars', 'data-level': level }, h('span'), h('span'), h('span'));
    const cards = b.options.map((o, idx) => {
      const rec = recIds.includes(o.id);
      // In the narrow panel only the recommended option (or the first) starts
      // open; the rest show a one-line peek — effort and pro/con counts.
      const open = rec || (!recIds.length && idx === 0);
      const peek = h('span', { class: 'sk-card-peek' },
        o.effort && o.effort.level ? bars(o.effort.level) : null,
        o.pros.length > 0 && h('span', { class: 'sk-peek-pro', text: '+' + o.pros.length }),
        o.cons.length > 0 && h('span', { class: 'sk-peek-con', text: '−' + o.cons.length }));
      const head = h('div', { class: 'sk-card-head' },
        h('span', { class: 'sk-badge', text: o.id }),
        h('div', { class: 'sk-card-titles' },
          rec && h('span', { class: 'sk-rec-tag', text: 'Recommended' }),
          h('span', { class: 'sk-card-title' }, inline(o.title))),
        h('span', { class: 'sk-card-end' }, peek, h('span', { class: 'sk-caret sk-card-chev' })));
      const details = h('div', { class: 'sk-card-details' },
        o.body.length > 0 && tokensMd(o.body, 'sk-card-body'),
        (o.pros.length + o.cons.length > 0) && h('div', { class: 'sk-procon' },
          o.pros.map(p => h('div', null, h('span', { class: 'sk-mark pro', text: '+' }), inline(p))),
          o.cons.map(p => h('div', null, h('span', { class: 'sk-mark con', text: '−' }), inline(p)))));
      const card = h('div', { class: 'sk-card' + (rec ? ' is-rec' : '') + (open ? ' is-open' : '') }, head, details);
      head.onclick = () => card.classList.toggle('is-open');
      const foot = h('div', { class: 'sk-card-foot' });
      if (o.effort && o.effort.level) foot.append(bars(o.effort.level), h('span', { class: 'sk-effort', text: o.effort.text }));
      else if (o.effort) foot.append(h('span', { class: 'sk-effort', text: o.effort.text }));
      if (ctx.interactive) {
        const btn = h('button', { class: 'sk-btn', text: 'Choose ' + o.id });
        btn.onclick = () => {
          if (wrap.dataset.picked) return;   // one answer per question
          wrap.dataset.picked = o.id;
          card.classList.add('is-picked'); btn.classList.add('is-on'); btn.textContent = 'Chosen';
          const text = 'Go with option ' + o.id;
          sent.textContent = '→ reply sent: “' + text + '”'; sent.hidden = false;
          ctx.onAction({ type: 'reply', text });
        };
        foot.append(btn);
      }
      if (foot.childNodes.length) details.append(foot);
      return card;
    });
    wrap.append(h('div', { class: 'sk-cards' }, cards));
    if (b.rec) {
      const who = recIds.length ? recIds.map(x => 'Option ' + x).join(' + ') + ': ' : '';
      const rest = b.rec.text.replace(/^(?:Option\s+[A-Z0-9]+(?:\s*(?:\+|and|&)\s*Option\s+[A-Z0-9]+)*)\s*(?:together)?\s*[.:—-]?\s*/i, '');
      wrap.append(h('div', { class: 'sk-recbar' }, h('span', { class: 'sk-label', text: 'Claude recommends' }),
        h('span', null, who, inline(rest))));
    }
    wrap.append(sent);
    return wrap;
  }

  // ── 02 phases ──────────────────────────────────────────────────────────

  function renderPhases(b) {
    let seenCurrent = false;
    const phases = b.phases.map(p => {
      const done = p.steps.filter(s => s.done).length, all = p.steps.length;
      let st = 'plain';
      if (b.hasStatus) {
        st = all && done === all ? 'done' : !seenCurrent ? 'current' : 'upcoming';
        if (st === 'current') seenCurrent = true;
      }
      return { ...p, done, all, st };
    });
    const color = st => st === 'done' ? 'var(--good)' : st === 'current' ? 'var(--accent)' : 'var(--faint)';
    const wrap = h('div', { class: 'sk-phases' });
    if (b.hasStatus) {
      wrap.append(h('div', { class: 'sk-progress-row' }, phases.map(p => h('div', { style: `flex:${Math.max(p.all, 1)}` },
        h('div', { class: 'sk-meter' }, h('div', { style: `width:${Math.max(p.all ? p.done / p.all * 100 : 0, p.st === 'current' ? 4 : 0)}%;background:${color(p.st)}` })),
        h('span', { class: 'sk-cap', text: `P${p.num} · ${p.done}/${p.all}` })))));
    }
    // Only the phase in progress starts open. A plan with no status opens in
    // full when it is short, and as an outline of titles when it is long.
    const totalSteps = phases.reduce((n, p) => n + p.all, 0);
    const startsOpen = (p, i) => b.hasStatus ? p.st === 'current' : (totalSteps <= 10 || i === 0);
    wrap.append(h('div', { class: 'sk-track' }, phases.map((p, i) => {
      const count = b.hasStatus ? `${p.done}/${p.all}` : `${p.all} step${p.all === 1 ? '' : 's'}`;
      const head = h('div', { class: 'sk-phase-head' },
        h('span', { class: 'sk-phase-title' }, inline(p.title)),
        p.tag && h('span', { class: 'sk-tag' + (/optional|later|maybe/i.test(p.tag) ? ' is-optional' : ''), text: p.tag }),
        h('span', { class: 'sk-phase-count', text: count }),
        h('span', { class: 'sk-caret sk-phase-chev' }));
      const el = h('div', { class: 'sk-phase' + (startsOpen(p, i) ? '' : ' is-folded') },
        h('div', { class: 'sk-rail' },
          h('span', { class: 'sk-node ' + p.st, text: p.st === 'done' ? '✓' : p.num }),
          i < phases.length - 1 && h('span', { class: 'sk-rail-line' })),
        h('div', { class: 'sk-phase-main' }, head,
          p.notes.length > 0 && tokensMd(p.notes, 'sk-phase-notes'),
          p.steps.length > 0 && h('div', { class: 'sk-steps' }, p.steps.map((s, k) => h('div', { class: 'sk-step' + (s.done ? ' done' : '') },
            h('span', { class: 'sk-step-n', text: `${p.num}.${k + 1}` }),
            h('span', null, inline(s.text), kids(s.kids)))))));
      head.onclick = () => el.classList.toggle('is-folded');
      return el;
    })));
    return wrap;
  }

  // ── 03 diagrams ────────────────────────────────────────────────────────

  const BOX_CH = /[─│┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬╭╮╯╰]/, ARROW_CH = /[▶▼◀▲►→←↑↓⟶⟵]/;

  function renderAscii(b) {
    const pre = h('pre');
    for (const line of b.source.split('\n')) {
      let run = '', cls = null;
      const flush = () => { if (run) pre.append(cls ? h('span', { class: cls, text: run }) : run); run = ''; };
      for (const ch of line) {
        const c = BOX_CH.test(ch) ? 'bx' : ARROW_CH.test(ch) ? 'ar' : null;
        if (c !== cls) { flush(); cls = c; }
        run += ch;
      }
      flush(); pre.append('\n');
    }
    let zoom = 13, manual = false, natural = 0;
    const label = h('span', { class: 'sk-zoom-label', text: '100%' });
    const apply = () => { pre.style.fontSize = zoom + 'px'; label.textContent = Math.round(zoom / 13 * 100) + '%'; };
    const zb = (t, d) => {
      const x = h('button', { class: 'sk-icon-btn', text: t });
      x.onclick = () => { manual = true; zoom = Math.max(8, Math.min(20, Math.round(zoom + d))); apply(); };
      return x;
    };
    apply();
    const canvas = h('div', { class: 'sk-canvas' }, pre);
    // Shrink a wide diagram to the panel width (never below 8 px, where box
    // characters stop reading); past that the canvas scrolls. A manual zoom wins.
    if (typeof ResizeObserver === 'function') {
      new ResizeObserver(() => {
        if (manual || !canvas.clientWidth) return;
        if (!natural) natural = pre.scrollWidth / zoom * 13;
        const cs = getComputedStyle(canvas);
        const avail = canvas.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight);
        zoom = Math.max(8, Math.min(13, Math.floor(13 * avail / natural * 4) / 4));
        apply();
      }).observe(canvas);
    }
    return h('div', { class: 'sk-frame' },
      h('div', { class: 'sk-frame-bar' }, h('span', { class: 'sk-frame-title', text: 'Diagram' }), h('span', { class: 'sk-spacer' }),
        label, zb('−', -1), zb('+', 1), copyBtn(b.source)),
      canvas);
  }

  let mermaidReady = null, mermaidSeq = 0, mermaidQueue = Promise.resolve();

  function ensureMermaid() {
    if (root.mermaid) return Promise.resolve(root.mermaid);
    if (!mermaidReady) {
      mermaidReady = typeof SkimRender.requestMermaid === 'function'
        ? Promise.resolve(SkimRender.requestMermaid()).then(() => root.mermaid || Promise.reject(new Error('mermaid not loaded')))
        : Promise.reject(new Error('mermaid not available'));
      mermaidReady.catch(() => { mermaidReady = null; });
    }
    return mermaidReady;
  }

  let mermaidInited = false;
  function initMermaid(m) {
    if (mermaidInited) return;
    mermaidInited = true;
    m.initialize({
      startOnLoad: false, theme: 'base', securityLevel: 'strict', fontFamily: 'Rubik, system-ui, sans-serif',
      themeVariables: {
        darkMode: true, background: '#0e0e0d', fontSize: '13px', primaryColor: '#211f1c', primaryTextColor: '#ebe7de',
        primaryBorderColor: '#3a3732', lineColor: '#a8a397', secondaryColor: '#1a1917', tertiaryColor: '#161614',
        actorBkg: '#211f1c', actorBorder: '#3a3732', actorTextColor: '#ebe7de', actorLineColor: '#3a3732',
        signalColor: '#d9d4c9', signalTextColor: '#d9d4c9', noteBkgColor: '#3a2a20', noteBorderColor: '#e08a5f',
        noteTextColor: '#f0c3a8', labelBoxBkgColor: '#211f1c', labelTextColor: '#ebe7de', sequenceNumberColor: '#121211'
      }
    });
  }

  function renderMermaid(b) {
    const kind = (b.source.trim().split(/\s|\n/)[0] || 'mermaid');
    const view = h('div', { class: 'sk-mermaid', text: 'Drawing diagram…' });
    const src = h('pre', { class: 'sk-source', text: b.source, hidden: true });
    const tabs = h('span', { class: 'sk-seg' });
    const tab = (name, show) => {
      const t = h('button', { text: name, class: show ? 'is-on' : null });
      t.onclick = () => { setTab(name); };
      return t;
    };
    const diagramTab = tab('Diagram', true), sourceTab = tab('Source', false);
    const setTab = name => {
      const d = name === 'Diagram';
      view.hidden = !d; src.hidden = d;
      diagramTab.classList.toggle('is-on', d); sourceTab.classList.toggle('is-on', !d);
    };
    tabs.append(diagramTab, sourceTab);
    mermaidQueue = mermaidQueue.then(() => ensureMermaid()).then(async m => {
      initMermaid(m);
      try { await Promise.race([document.fonts.ready, new Promise(r => setTimeout(r, 1500))]); } catch (e) { /* fonts optional */ }
      const { svg } = await m.render('skmmd' + (++mermaidSeq), b.source);
      view.innerHTML = svg;   // mermaid output under securityLevel 'strict'
      requestAnimationFrame(() => {
        if (view.scrollHeight <= 380) return;
        frame.classList.add('is-clamped');
        const x = h('button', { class: 'sk-icon-btn', text: 'Expand' });
        x.onclick = () => { const c = frame.classList.toggle('is-clamped'); x.textContent = c ? 'Expand' : 'Collapse'; };
        bar.insertBefore(x, tabs);
      });
    }).catch(e => {
      view.textContent = 'Diagram could not be drawn: ' + (e && e.message ? e.message.split('\n')[0] : e);
      document.querySelectorAll('[id^="dskmmd"]').forEach(n => n.remove());
      setTab('Source');
    });
    const bar = h('div', { class: 'sk-frame-bar' }, h('span', { class: 'sk-frame-title', text: kind }), h('span', { class: 'sk-spacer' }), tabs, copyBtn(b.source));
    const frame = h('div', { class: 'sk-frame sk-mermaid-frame' }, bar, view, src);
    return frame;
  }

  // ── 04 file tree ───────────────────────────────────────────────────────

  function renderTree(b) {
    const wrap = h('div', { class: 'sk-tree' });
    const rows = b.rows.map((r, i) => {
      const el = h('div', { class: 'sk-row' + (r.isDir ? ' is-dir' : ''), style: `padding-left:${14 + r.depth * 20}px`, 'data-st': r.status },
        r.isDir ? [h('span', { class: 'sk-caret sk-chev' }), h('span', { class: 'sk-folder' })] : [h('span', { class: 'sk-chev' }), h('span', { class: 'sk-file' })],
        h('span', { class: 'sk-name', text: r.name }),
        r.status && h('span', { class: 'sk-st ' + r.status, text: r.status }),
        h('span', { class: 'sk-note', text: r.note }));
      return { r, el, i, collapsed: false };
    });
    const refresh = () => {
      const stack = [];
      for (const row of rows) {
        stack.length = row.r.depth;
        row.el.hidden = stack.some(Boolean);
        stack[row.r.depth] = row.collapsed;
      }
    };
    const setChev = row => { row.el.classList.toggle('is-collapsed', row.collapsed); };
    for (const row of rows) {
      if (!row.r.isDir) continue;
      row.el.onclick = () => { row.collapsed = !row.collapsed; setChev(row); refresh(); };
    }
    // A long tree folds every nested folder that holds no changed file, so
    // the rows marked M / A / D stay in view.
    if (rows.length > FOLD.treeRows) {
      rows.forEach((row, i) => {
        if (!row.r.isDir || row.r.depth < 1) return;
        let changed = false;
        for (let k = i + 1; k < rows.length && rows[k].r.depth > row.r.depth; k++) if (rows[k].r.status) { changed = true; break; }
        if (!changed) { row.collapsed = true; setChev(row); }
      });
      refresh();
    }
    wrap.append(...rows.map(x => x.el));
    return wrap;
  }

  // ── 05 callouts ────────────────────────────────────────────────────────

  const CALLOUT = { note: ['i', 'Note'], tip: ['→', 'Tip'], important: ['★', 'Important'], warning: ['!', 'Warning'], caution: ['!', 'Caution'] };

  function renderCallout(b) {
    const [glyph, label] = CALLOUT[b.type] || CALLOUT.note;
    return h('div', { class: 'sk-callout', 'data-type': CALLOUT[b.type] ? b.type : 'note' },
      h('span', { class: 'sk-glyph', text: glyph }),
      h('div', { class: 'sk-callout-main' }, h('span', { class: 'sk-label', text: label }), blockMd(b.md, 'sk-callout-body')));
  }

  // ── 06 itemized notes ──────────────────────────────────────────────────

  function kids(list) {
    if (!list || !list.length) return null;
    const els = list.map(k => h('div', null, inline(k)));
    return h('div', { class: 'sk-kids' }, els, foldItems(els, FOLD.keepKids, 'details'));
  }

  /** A list-shaped block: its rows, then a "Show N more" row when it is long. */
  const folded = (cls, els, noun) => h('div', { class: cls }, els, foldItems(els, FOLD.keepRows, noun));

  const renderChangelog = b => folded('sk-changelog', b.items.map(it => h('div', { class: 'sk-change' },
    h('span', { class: 'sk-verb ' + it.tone, text: it.verb }),
    h('div', { class: 'sk-change-text' }, inline(it.md), kids(it.kids)))), 'changes');

  const renderKeyfacts = b => folded('sk-facts', b.items.map(it => h('div', { class: 'sk-fact' },
    h('span', { class: 'sk-fact-key' }, inline(it.key)),
    h('div', { class: 'sk-fact-val' }, inline(it.md, { metrics: true }), kids(it.kids)))), 'facts');

  const renderFindings = b => folded('sk-findings', b.items.map(it => h('div', { class: 'sk-finding' },
    h('div', { class: 'sk-finding-line' }, h('span', { class: 'sk-dot' }),
      h('span', null, it.lead != null && h('span', { class: 'sk-lead' }, inline(it.lead), ' — '),
        h('span', { class: it.lead != null ? 'sk-finding-rest' : null }, inline(it.md)))),
    kids(it.kids))), 'findings');

  // ── labeled section ("**Things to know:**" + a list) ──────────────────

  const SECTION_GLYPH = { note: 'i', warning: '!', next: '→', done: '✓' };

  function renderSection(b, ctx) {
    const inner = b.inner.kind === 'md' ? foldMdList(tokensMd(b.inner.tokens, 'sk-md')) : (RENDER[b.inner.kind] || RENDER.md)(b.inner, ctx);
    return h('div', { class: 'sk-section', 'data-tone': b.tone },
      h('div', { class: 'sk-section-head' }, h('span', { class: 'sk-glyph', text: SECTION_GLYPH[b.tone] || '•' }), h('span', { class: 'sk-label' }, inline(b.label))),
      inner);
  }

  // ── 07 tables ──────────────────────────────────────────────────────────

  function cell(c) {
    switch (c.kind) {
      case 'pill': return h('td', null, h('span', { class: 'sk-pill ' + c.tone }, c.text, c.changed && h('span', { class: 'sk-changed', text: '●', title: 'Changed' })));
      case 'num': return h('td', { class: 'num', text: c.text });
      case 'diffstat': {
        const [plus, minus] = c.text.split(/\s+/);
        return h('td', { class: 'diffstat' }, h('span', { class: 'plus', text: plus }), ' ', h('span', { class: 'minus', text: minus }));
      }
      case 'sha': return h('td', { class: 'sha', text: c.text });
      case 'path': return h('td', { class: 'path', text: c.text });
      default: return h('td', null, inline(c.md));
    }
  }

  function renderTable(b) {
    const align = b.head.map(x => x.align);
    const trs = b.rows.map(r => h('tr', null, r.map((c, k) => { const td = cell(c); td.style.textAlign = align[k] || 'left'; return td; })));
    return h('div', { class: 'sk-table-block' },
      h('div', { class: 'sk-table-wrap' }, h('table', { class: 'sk-table' },
        h('thead', null, h('tr', null, b.head.map(x => h('th', { style: `text-align:${x.align}` }, inline(x.md))))),
        h('tbody', null, trs))),
      foldItems(trs, FOLD.keepTableRows, 'rows'));
  }

  // ── 08 checklists ──────────────────────────────────────────────────────

  function renderChecklist(b) {
    const items = b.items.map(it => ({ ...it }));
    const bar = h('div'), label = h('span');
    const list = h('div', { class: 'sk-items' });
    const els = items.map(it => {
      const el = h('div', { class: 'sk-item', role: 'checkbox', tabindex: '0' },
        h('span', { class: 'sk-box' }), h('span', { class: 'sk-item-text' }, inline(it.md), kids(it.kids)));
      el.onclick = () => { it.done = !it.done; paint(); };
      el.onkeydown = e => { if (e.key === ' ' || e.key === 'Enter') { e.preventDefault(); el.click(); } };
      return { it, el };
    });
    const paint = () => {
      const done = items.filter(x => x.done).length;
      bar.style.width = (done / items.length * 100) + '%';
      label.textContent = `${done} of ${items.length} done`;
      for (const { it, el } of els) {
        el.classList.toggle('done', it.done);
        el.setAttribute('aria-checked', String(it.done));
        el.querySelector('.sk-box').textContent = it.done ? '✓' : '';
      }
    };
    // Open items first; the order is fixed at render so rows don't jump on tick.
    const sorted = els.slice().sort((a, b2) => a.it.done - b2.it.done).map(x => x.el);
    list.append(...sorted);
    // A long list folds what is already done; the open work is what matters.
    const doneEls = els.filter(x => x.it.done).map(x => x.el);
    if (items.length > FOLD.keepRows + 1 && doneEls.length > 1) {
      doneEls.forEach(el => { el.hidden = true; });
      list.append(moreBtn(`Show ${doneEls.length} done`, btn => { doneEls.forEach(el => { el.hidden = false; }); btn.remove(); }));
    }
    paint();
    return h('div', { class: 'sk-check' }, h('div', { class: 'sk-check-head' }, h('div', { class: 'sk-meter' }, bar), label), list);
  }

  // ── code ───────────────────────────────────────────────────────────────

  function renderCode(b) {
    const code = h('code', { text: b.source });
    highlight(code, b.lang === 'sh' || b.lang === 'zsh' || b.lang === 'console' ? 'bash' : b.lang);
    const lines = b.source.replace(/\n$/, '').split('\n').length;
    const frame = h('div', { class: 'sk-code' },
      h('div', { class: 'sk-frame-bar' }, h('span', { class: 'sk-frame-title', text: b.lang || 'text' }),
        h('span', { class: 'sk-lines', text: lines + ' lines' }), h('span', { class: 'sk-spacer' }), copyBtn(b.source)),
      h('pre', null, code));
    if (lines > FOLD.codeLines + 2) {
      frame.classList.add('is-clamped');
      frame.style.setProperty('--sk-code-lines', FOLD.codeLines);
      const more = moreBtn(`Show all ${lines} lines`, btn => {
        const c = frame.classList.toggle('is-clamped');
        btn.lastChild.textContent = c ? `Show all ${lines} lines` : 'Show less';
        btn.classList.toggle('is-open', !c);
      });
      more.classList.add('sk-code-more');
      frame.append(more);
    }
    return frame;
  }

  // ── driver ─────────────────────────────────────────────────────────────

  const RENDER = {
    md: b => tokensMd(b.tokens, 'sk-md' + (b.open ? ' is-open' : '')),
    options: renderOptions, phases: renderPhases, ascii: renderAscii, mermaid: renderMermaid,
    tree: renderTree, callout: renderCallout, changelog: renderChangelog, keyfacts: renderKeyfacts,
    findings: renderFindings, section: renderSection, table: renderTable, checklist: renderChecklist, code: renderCode
  };

  function hash(s) {
    let x = 5381;
    for (let i = 0; i < s.length; i++) x = ((x << 5) + x + s.charCodeAt(i)) | 0;
    return (x >>> 0).toString(36) + ':' + s.length;
  }

  function renderBlock(b, ctx) {
    let el;
    try { el = (RENDER[b.kind] || RENDER.md)(b, ctx); }
    catch (e) {
      // A renderer bug must never lose the text: fall back to plain Markdown.
      console.error('SkimRender:', b.kind, e);
      el = b.tokens ? RENDER.md(b) : blockMd(b.raw, 'sk-md');
    }
    el.classList.add('sk-block');
    el.dataset.kind = b.kind;
    return el;
  }

  // ── reveal: new text fades in ──────────────────────────────────────────

  const REVEAL_MS = 260;
  /** Blocks whose text is not read as it streams: a diagram, a picture. */
  const noReveal = el => !!el.querySelector('svg, canvas, img, .sk-mermaid');

  function commonPrefix(a, b) {
    const n = Math.min(a.length, b.length);
    let i = 0;
    while (i < n && a.charCodeAt(i) === b.charCodeAt(i)) i++;
    return i;
  }

  /**
   * `marks`: [{ at, t }] — the text from offset `at` (to the next mark) arrived
   * at time `t`. Wraps each range still fading in a span that carries its age.
   */
  function wrapFresh(el, marks, now) {
    if (!marks.length) return;
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    const nodes = [];
    for (let n = walker.nextNode(); n; n = walker.nextNode()) nodes.push(n);
    const total = el.textContent.length;
    const ranges = marks.map((m, i) => [m.at, i + 1 < marks.length ? marks[i + 1].at : total, now - m.t]).filter(r => r[1] > r[0]);
    let pos = 0;
    for (const node of nodes) {
      const start = pos, end = pos + node.data.length;
      pos = end;
      if (!ranges.some(r => r[0] < end && r[1] > start)) continue;
      // Split this text node at every range edge inside it; wrap the fading pieces.
      const cuts = [...new Set(ranges.flatMap(r => [r[0], r[1]]).filter(c => c > start && c < end))].sort((a, b) => a - b);
      let cur = node, curStart = start;
      for (const c of [...cuts, end]) {
        const piece = cur;
        if (c < end) cur = piece.splitText(c - curStart);
        const r = ranges.find(x => x[0] <= curStart && x[1] >= c);
        if (r && piece.data.trim()) {   // white space has nothing to fade
          const span = document.createElement('span');
          span.className = 'sk-fresh';
          span.style.animationDelay = -Math.round(r[2]) + 'ms';
          piece.replaceWith(span);
          span.append(piece);
        }
        curStart = c;
      }
    }
  }

  /** The new element for a block that changed: carry the fades of the old one, add the text that is new. */
  function reveal(el, cur, now) {
    if (noReveal(el)) return;
    const text = el.textContent;
    let marks = [];
    if (cur) {
      const keep = commonPrefix(cur.textContent, text);
      marks = (cur._marks || []).filter(m => now - m.t < REVEAL_MS && m.at < keep);
      if (text.length > keep) marks.push({ at: keep, t: now });
    } else if (text) marks = [{ at: 0, t: now }];
    el._marks = marks;
    wrapFresh(el, marks, now);
  }

  function render(container, markdown, opts) {
    opts = opts || {};
    const ctx = { interactive: !!opts.interactive, onAction: opts.onAction || function () {} };
    const blocks = root.SkimClassify.classify(markdown, root.marked, { streaming: !!opts.streaming });
    const old = Array.from(container.children);
    const now = Date.now();
    blocks.forEach((b, i) => {
      const key = b.kind + '|' + hash(b.raw) + (b.open ? '|open' : '');
      const cur = old[i];
      if (cur && cur.dataset.key === key) return;
      const el = renderBlock(b, ctx);
      el.dataset.key = key;
      if (opts.reveal) {
        reveal(el, cur, now);
        // A new block that is not text to read (a table, a card, a diagram) rises in instead.
        if (!cur && !el._marks?.length) el.classList.add('sk-in');
      }
      if (cur) cur.replaceWith(el); else container.append(el);
      old[i] = el;
    });
    for (let i = blocks.length; i < old.length; i++) old[i].remove();
    return blocks;
  }

  const SkimRender = { render, requestMermaid: null };
  root.SkimRender = SkimRender;
})(typeof self !== 'undefined' ? self : this);
