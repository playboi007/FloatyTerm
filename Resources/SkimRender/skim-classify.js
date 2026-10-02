/**
 * Parses Markdown into typed blocks (options, findings, changes, etc.) or plain
 * blocks; misses degrade to ordinary Markdown, never broken output. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.SkimClassify = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const OPTION_HEAD = /^(?:Option|Approach|Alternative)\s+([A-Z0-9]{1,3})\s*[:.)—–-]\s*(.+)$/i;
  const PHASE_HEAD = /^(?:Phase|Stage|Milestone)\s+(\d{1,2})\s*[:.)—–-]\s*(.+?)(?:\s*\(([^)]{1,40})\))?\s*$/i;
  const FIELD = /^\*\*(Pros?|Cons?|Effort|Cost)\s*:?\*\*\s*:?\s*([\s\S]*)$/i;
  const RECOMMEND = /^\*\*(?:My\s+)?(?:Recommendation|Recommended|I recommend)\s*:?\*\*\s*:?\s*/i;
  const ALERT = /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\][ \t]*\n?/i;
  // The colon is required: a bare `**Important**` line is a label, not an aside.
  const BOLD_LABEL = /^\*\*(Note|Tip|Important|Warning|Caution|Heads[- ]up)\s*(?::\*\*|\*\*\s*:)\s*/i;
  const VERBS = {
    fixed: 'fix', resolved: 'fix', patched: 'fix',
    added: 'add', created: 'add', new: 'add', introduced: 'add',
    removed: 'remove', deleted: 'remove', dropped: 'remove',
    changed: 'change', updated: 'change', moved: 'change', refactored: 'change',
    renamed: 'change', replaced: 'change', improved: 'change', kept: 'keep'
  };
  const LEAD_VERB = /^\*\*([A-Za-z]+)\*\*\s+/;
  const KEY_FACT = /^\*\*([^*]{1,40}?)(?::\*\*|\*\*:)\s*/;
  const BOX = /[─│┌┐└┘├┤┬┴┼═║╔╗╚╝╠╣╦╩╬╭╮╯╰]/g;
  // A branch must lead into a name: `└───────┬` is a box edge, not a tree row.
  const TREE_BRANCH = /(├──|└──|\|--|`--|\+--)[ \t]?(?=[^\s─━┬┴┼│])/;
  const PLAIN_LANGS = new Set(['', 'text', 'txt', 'plain', 'plaintext', 'ascii', 'diagram', 'tree']);
  const STATUS = {
    pass: 'good', passed: 'good', passing: 'good', ok: 'good', success: 'good', done: 'good', '✓': 'good', '✅': 'good',
    fail: 'bad', failed: 'bad', failing: 'bad', error: 'bad', broken: 'bad', '✗': 'bad', '❌': 'bad',
    flaky: 'warn', warn: 'warn', warning: 'warn', partial: 'warn', '⚠️': 'warn',
    skip: 'muted', skipped: 'muted', pending: 'muted', todo: 'muted', 'n/a': 'muted'
  };
  // A paragraph that is only a bold label ending in a colon, directly above a list.
  const SECTION_LABEL = /^\*\*([^*\n]{2,48}?)(?::\*\*|\*\*:)$/;
  const SECTION_TONES = [
    ['warning', /risk|warning|caveat|careful|watch out|breaking|gotcha|limitation|known issue/i],
    ['next', /next|to ?do|follow[- ]?up|action|open question|question|decision|before (you|we)/i],
    ['done', /done|completed|verif|result|what (i|we) (did|changed)|changes made|summary/i]
  ];
  const NUMERIC = /^[-+−]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?\s*(?:ms|s|m|h|b|kb|mb|gb|%|x|×|k)?$/i;
  const DIFFSTAT = /^\+\d+\s*[−-]\d+$/;
  const SHA = /^[0-9a-f]{7,40}$/;
  const FILE_EXTS = new Set(('swift m h c cc cpp hpp js mjs cjs jsx ts tsx json jsonl md mdx txt yaml yml toml ini ' +
    'plist xml html htm css scss less dart kt kts java py rb go rs sh zsh bash fish sql csv tsv lock log env ' +
    'gradle png jpg jpeg gif svg webp pdf zip gz tar woff2 ttf arb proto graphql vue svelte').split(' '));

  // ── helpers ────────────────────────────────────────────────────────────

  const isSpace = t => t.type === 'space';
  const unwrapCode = s => s.replace(/^`([^`]+)`$/, '$1');

  /** True when inline code reads as a filesystem path rather than code. */
  function looksLikePath(s) {
    if (!s || /\s/.test(s) || /\(\)$/.test(s) || s.length > 200) return false;
    if (/^(https?:)?\/\//.test(s)) return false;
    if (/\//.test(s)) return true;
    if (/^\.[\w.-]{2,}$/.test(s)) return true;   // dotfiles: .gitignore, .env
    // A bare `name.ext` is a file only for known extensions: `telemetry.auth` is code.
    const m = s.match(/^[\w.-]+\.([A-Za-z0-9]{1,10})$/);
    return !!m && FILE_EXTS.has(m[1].toLowerCase());
  }

  /** The inline Markdown of a list item's first line, and its nested lists. */
  function itemParts(item) {
    const toks = item.tokens || [];
    const first = toks.find(t => t.type === 'text' || t.type === 'paragraph');
    const kids = [];
    for (const t of toks) {
      if (t.type === 'list') for (const k of t.items) kids.push(itemParts(k).text);
    }
    return { text: first ? first.text : '', kids, extra: toks.filter(t => t !== first && t.type !== 'list' && !isSpace(t)) };
  }

  function effortLevel(text) {
    const m = text.match(/^(XS|S|M|L|XL|small|medium|large|low|high)\b/i);
    if (!m) return { level: 0, text };
    const k = m[1].toLowerCase();
    const level = ['xs', 's', 'small', 'low'].includes(k) ? 1 : ['m', 'medium'].includes(k) ? 2 : 3;
    return { level, text: text.slice(m[0].length).replace(/^\s*[—–-]\s*/, '').trim() || m[1] };
  }

  const splitList = s => s.split(/;\s*/).map(x => x.trim()).filter(Boolean);

  // ── group rules (consume several tokens) ───────────────────────────────

  /** `### Option A: …` headings, each with an optional Pros/Cons/Effort list. */
  function takeOptions(toks, i, end) {
    const head = toks[i];
    if (head.type !== 'heading' || head.depth < 2 || !OPTION_HEAD.test(head.text)) return null;
    const depth = head.depth, options = [];
    let j = i, cur = null, rec = null;
    for (; j < end; j++) {
      const t = toks[j];
      if (isSpace(t)) continue;
      if (t.type === 'heading' && t.depth <= depth) {
        const m = t.text.match(OPTION_HEAD);
        if (!m || t.depth !== depth) break;
        cur = { id: m[1].toUpperCase(), title: m[2].trim(), body: [], pros: [], cons: [], effort: null };
        options.push(cur);
        continue;
      }
      if (t.type === 'hr') break;
      if (t.type === 'paragraph' && RECOMMEND.test(t.text)) { rec = t.text.replace(RECOMMEND, ''); j++; break; }
      if (t.type === 'list') {
        const rest = [];
        for (const item of t.items) {
          const p = itemParts(item), m = p.text.match(FIELD);
          if (!m) { rest.push(item); continue; }
          const k = m[1].toLowerCase(), val = m[2].trim();
          const vals = p.kids.length ? (val ? [val, ...p.kids] : p.kids) : splitList(val);
          if (k.startsWith('pro')) cur.pros.push(...vals);
          else if (k.startsWith('con')) cur.cons.push(...vals);
          else cur.effort = effortLevel(val);
        }
        if (rest.length) cur.body.push({ ...t, items: rest, raw: rest.map(x => x.raw).join('') });
        continue;
      }
      cur.body.push(t);
    }
    // A recommendation can also follow the group after a blank line.
    if (!rec) {
      let k = j;
      while (k < end && isSpace(toks[k])) k++;
      if (k < end && toks[k].type === 'paragraph' && RECOMMEND.test(toks[k].text)) {
        rec = toks[k].text.replace(RECOMMEND, ''); j = k + 1;
      }
    }
    if (options.length < 2) return null;
    const ids = rec ? [...rec.matchAll(/\b(?:Option|Approach)\s+([A-Z0-9]{1,3})\b/gi)].map(m => m[1].toUpperCase()) : [];
    return { next: j, block: { kind: 'options', options, rec: rec && { text: rec, ids } } };
  }

  /** `### Phase 1: … (tag)` headings, each followed by its steps. */
  function takePhases(toks, i, end) {
    const head = toks[i];
    if (head.type !== 'heading' || head.depth < 2 || !PHASE_HEAD.test(head.text)) return null;
    const depth = head.depth, phases = [];
    let j = i, cur = null;
    for (; j < end; j++) {
      const t = toks[j];
      if (isSpace(t)) continue;
      if (t.type === 'heading' && t.depth <= depth) {
        const m = t.text.match(PHASE_HEAD);
        if (!m || t.depth !== depth) break;
        cur = { num: m[1], title: m[2].trim(), tag: m[3] ? m[3].trim() : null, steps: [], notes: [] };
        phases.push(cur);
        continue;
      }
      if (t.type === 'hr') break;
      if (t.type === 'list') {
        for (const item of t.items) {
          const p = itemParts(item);
          cur.steps.push({ text: p.text, task: !!item.task, done: !!item.checked, kids: p.kids });
        }
        continue;
      }
      cur.notes.push(t);
    }
    if (phases.length < 2) return null;
    const hasStatus = phases.some(p => p.steps.some(s => s.task));
    return { next: j, block: { kind: 'phases', phases, hasStatus } };
  }

  // ── single-token rules ─────────────────────────────────────────────────

  function parseTree(src) {
    const lines = src.replace(/\s+$/, '').split('\n');
    const cols = [];
    for (const l of lines) { const m = l.match(TREE_BRANCH); if (m) cols.push(m.index); }
    // Branch depth = column rank, independent of indent width.
    const distinct = [...new Set(cols)].sort((a, b) => a - b);
    const rows = [];
    for (const line of lines) {
      if (!line.trim() || /^[\s│|]+$/.test(line)) continue;
      const m = line.match(TREE_BRANCH);
      const depth = m ? distinct.indexOf(m.index) + 1 : 0;
      const rest = m ? line.slice(m.index + m[0].length) : line.trim();
      const split = rest.match(/^(.*?)(?:\s{2,}(?:#|\/\/|←|<-|—)?\s*|\s+(?:#|←|<-|\/\/)\s+)(.+)$/);
      let name = (split ? split[1] : rest).trim(), note = split ? split[2].trim() : '';
      let status = null;
      const sm = note.match(/\((modified|changed|updated|new|added|created|deleted|removed)\)/i);
      if (sm) {
        const w = sm[1].toLowerCase();
        status = ['new', 'added', 'created'].includes(w) ? 'A' : ['deleted', 'removed'].includes(w) ? 'D' : 'M';
        note = note.replace(sm[0], '').replace(/^[\s,;·—-]+|[\s,;·—-]+$/g, '');
      }
      rows.push({ depth, name: unwrapCode(name), note, status });
    }
    rows.forEach((r, k) => { r.isDir = /\/$/.test(r.name) || (k + 1 < rows.length && rows[k + 1].depth > r.depth); });
    return rows;
  }

  function classifyCode(t) {
    const lang = (t.lang || '').trim().split(/\s+/)[0].toLowerCase();
    const src = t.text;
    if (lang === 'mermaid') return { kind: 'mermaid', source: src };
    if (PLAIN_LANGS.has(lang)) {
      const branches = src.split('\n').filter(l => TREE_BRANCH.test(l)).length;
      if (branches >= 2) return { kind: 'tree', rows: parseTree(src), source: src };
      if ((src.match(BOX) || []).length >= 8) return { kind: 'ascii', source: src };
    }
    return { kind: 'code', lang, source: src };
  }

  function classifyCallout(t) {
    const b = calloutOf(t);
    return b && b.md.trim() ? b : null;
  }

  function calloutOf(t) {
    if (t.type === 'blockquote') {
      const body = t.text;
      let m = body.match(ALERT);
      if (m) return { kind: 'callout', type: m[1].toLowerCase(), md: body.slice(m[0].length) };
      m = body.match(BOLD_LABEL);
      if (m) return { kind: 'callout', type: normType(m[1]), md: body.slice(m[0].length) };
      return null;
    }
    if (t.type === 'paragraph') {
      const m = t.text.match(BOLD_LABEL);
      if (m) return { kind: 'callout', type: normType(m[1]), md: t.text.slice(m[0].length) };
    }
    return null;
  }
  const normType = w => (/heads/i.test(w) ? 'note' : w.toLowerCase());

  function classifyList(t) {
    const items = t.items.map(it => ({ it, p: itemParts(it) }));
    if (items.length < 2) return null;

    if (items.every(x => x.it.task)) {
      return { kind: 'checklist', items: items.map(x => ({ done: !!x.it.checked, md: x.p.text, kids: x.p.kids })) };
    }
    if (t.ordered) return null;

    const verbs = items.map(x => { const m = x.p.text.match(LEAD_VERB); return m && VERBS[m[1].toLowerCase()] ? m : null; });
    if (verbs.every(Boolean)) {
      return {
        kind: 'changelog',
        items: items.map((x, k) => ({ verb: verbs[k][1], tone: VERBS[verbs[k][1].toLowerCase()], md: x.p.text.slice(verbs[k][0].length), kids: x.p.kids }))
      };
    }
    const keys = items.map(x => x.p.text.match(KEY_FACT));
    if (keys.every(Boolean)) {
      return { kind: 'keyfacts', items: items.map((x, k) => ({ key: keys[k][1].trim(), md: x.p.text.slice(keys[k][0].length), kids: x.p.kids })) };
    }
    const anyKids = items.some(x => x.p.kids.length);
    if (anyKids && items.every(x => x.p.kids.length || / — /.test(x.p.text))) {
      return {
        kind: 'findings',
        items: items.map(x => {
          const k = x.p.text.indexOf(' — ');
          return k > 0 ? { lead: x.p.text.slice(0, k), md: x.p.text.slice(k + 3), kids: x.p.kids }
                       : { lead: null, md: x.p.text, kids: x.p.kids };
        })
      };
    }
    return null;
  }

  function classifyCell(text) {
    const raw = text.trim(), bare = unwrapCode(raw), low = bare.toLowerCase();
    if (STATUS[low]) return { kind: 'pill', text: bare, tone: STATUS[low] };
    if (DIFFSTAT.test(bare)) return { kind: 'diffstat', text: bare };
    if (NUMERIC.test(bare)) return { kind: 'num', text: bare };
    if (SHA.test(bare) && /\d/.test(bare) && /[a-f]/.test(bare)) return { kind: 'sha', text: bare };
    if (raw !== bare && looksLikePath(bare)) return { kind: 'path', text: bare };
    return { kind: 'md', md: raw };
  }

  function classifyTable(t) {
    const rows = t.rows.map(r => r.map(c => classifyCell(c.text)));
    rows.forEach(r => r.forEach((c, k) => {
      const prev = r[k - 1];
      if (c.kind === 'pill' && prev && prev.kind === 'pill' && prev.text.toLowerCase() !== c.text.toLowerCase()) c.changed = true;
    }));
    const head = t.header.map((h, k) => {
      const numeric = rows.length > 0 && rows.every(r => r[k] && ['num', 'diffstat'].includes(r[k].kind));
      return { md: h.text, align: t.align[k] || (numeric ? 'right' : 'left') };
    });
    return { kind: 'table', head, rows };
  }

  /** `**Things to know:**` + a list → a labeled section around the list. */
  function takeSection(toks, i, end) {
    const t = toks[i];
    if (t.type !== 'paragraph') return null;
    const m = t.text.trim().match(SECTION_LABEL);
    if (!m) return null;
    let k = i + 1;
    while (k < end && isSpace(toks[k])) k++;
    if (k >= end || toks[k].type !== 'list') return null;
    const label = m[1].trim();
    const tone = (SECTION_TONES.find(([, re]) => re.test(label)) || ['note'])[0];
    const inner = classifyList(toks[k]) || { kind: 'md', tokens: [toks[k]] };
    return { next: k + 1, block: { kind: 'section', label, tone, inner } };
  }

  // ── driver ─────────────────────────────────────────────────────────────

  function classifyTokens(toks, opts) {
    const streaming = !!(opts && opts.streaming);
    let end = toks.length;
    let openFrom = end;
    if (streaming) {
      let k = end - 1;
      while (k >= 0 && isSpace(toks[k])) k--;
      openFrom = Math.max(k, 0);
      end = openFrom;
    }
    const blocks = [];
    let pendingMd = [];
    const flush = () => { if (pendingMd.length) { blocks.push({ kind: 'md', tokens: pendingMd }); pendingMd = []; } };
    const push = (b, from, to) => {
      flush();
      b.raw = toks.slice(from, to).map(x => x.raw || '').join('');
      blocks.push(b);
    };

    let i = 0;
    while (i < end) {
      const t = toks[i];
      if (isSpace(t)) { i++; continue; }
      const group = takeOptions(toks, i, end) || takePhases(toks, i, end) || takeSection(toks, i, end);
      if (group) {
        // A group that ran into the open tail is still growing: keep it plain.
        if (streaming && group.next >= end && openFrom < toks.length) break;
        push(group.block, i, group.next); i = group.next; continue;
      }
      let b = null;
      if (t.type === 'code') b = classifyCode(t);
      else if (t.type === 'blockquote' || t.type === 'paragraph') b = classifyCallout(t);
      else if (t.type === 'list') b = classifyList(t);
      else if (t.type === 'table') b = classifyTable(t);
      if (b) push(b, i, i + 1); else pendingMd.push(t);
      i++;
    }
    flush();
    if (i < toks.length) {
      const tail = toks.slice(i).filter(x => !isSpace(x));
      if (tail.length) blocks.push({ kind: 'md', tokens: tail, open: streaming });
    }
    blocks.forEach(b => { if (b.raw === undefined) b.raw = (b.tokens || []).map(x => x.raw || '').join(''); });
    return blocks;
  }

  function classify(markdown, marked, opts) {
    return classifyTokens(marked.lexer(markdown || ''), opts);
  }

  return { classify, classifyTokens, looksLikePath, parseTree };
});
