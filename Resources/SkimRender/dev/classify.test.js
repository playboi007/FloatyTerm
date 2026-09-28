// Rules check for skim-classify.js. Run: node Resources/SkimRender/dev/classify.test.js
'use strict';
const assert = require('assert');
const path = require('path');
const { marked } = require(path.join(__dirname, '../vendor/marked.min.js'));
const { classify, parseTree } = require(path.join(__dirname, '../skim-classify.js'));
const samples = require('./samples.js');

let failed = 0;
const check = (name, fn) => {
  try { fn(); console.log('  ok   ' + name); }
  catch (e) { failed++; console.log('  FAIL ' + name + '\n       ' + e.message.split('\n').join('\n       ')); }
};

console.log('samples');
for (const s of samples) {
  check(s.name, () => assert.deepStrictEqual(classify(s.md, marked).map(b => b.kind), s.expect));
}

console.log('details');
const byName = n => classify(samples.find(s => s.name === n).md, marked);

check('options: fields, effort level, recommendation ids', () => {
  const o = byName('Options & trade-offs')[1];
  assert.strictEqual(o.options.length, 3);
  assert.deepStrictEqual(o.options[0].pros, ['smallest diff', 'no API change', 'fixes the flaky test directly']);
  assert.deepStrictEqual(o.options.map(x => x.effort.level), [1, 1, 3]);
  assert.strictEqual(o.options[2].effort.text, 'half a day');
  assert.deepStrictEqual(o.rec.ids, ['A', 'B']);
});

check('phases: status, tags, done steps', () => {
  const p = byName('Phased plan')[1];
  assert.ok(p.hasStatus);
  assert.deepStrictEqual(p.phases.map(x => x.tag), ['today', null, 'optional']);
  assert.deepStrictEqual(p.phases[0].steps.map(x => x.done), [true, true, false]);
});

check('tree: depth, notes, status markers', () => {
  const rows = byName('File tree')[0].rows;
  assert.deepStrictEqual(rows.map(r => r.depth), [0, 1, 1, 1, 1, 0, 1, 1]);
  assert.deepStrictEqual(rows[1], { depth: 1, name: 'session.ts', note: 'refresh + scheduling', status: 'M', isDir: false });
  assert.strictEqual(rows[6].status, 'A');
  assert.ok(rows[0].isDir && rows[5].isDir);
});

check('tree: │-indented nesting', () => {
  const rows = byName('Nested file tree (│ indent)')[0].rows;
  assert.deepStrictEqual(rows.map(r => [r.name, r.depth]), [
    ['Resources/', 0], ['SkimRender/', 1], ['skim.css', 2], ['vendor/', 2], ['marked.min.js', 3], ['README.md', 1]]);
  assert.strictEqual(rows[4].status, 'A');
  assert.strictEqual(rows[4].note, 'v12');
});

check('callouts: types', () => {
  assert.deepStrictEqual(byName('Callouts').map(b => b.type), ['note', 'warning', 'tip']);
});

check('table: pills, numbers, changed marks, alignment', () => {
  const t = byName('Table')[0];
  assert.deepStrictEqual(t.head.map(h => h.align), ['left', 'right', 'right', 'left', 'left']);
  assert.deepStrictEqual(t.rows[0].map(c => c.kind), ['md', 'num', 'num', 'pill', 'pill']);
  assert.strictEqual(t.rows[0][4].changed, true);   // flaky → pass
  assert.ok(!t.rows[1][4].changed);                // pass → pass
});

check('table: commit hashes become sha cells', () => {
  const t = byName('Real reply: commit report')[1];
  assert.deepStrictEqual(t.rows.map(r => r[0].kind), ['sha', 'sha', 'sha']);
});

check('streaming: open tail stays plain', () => {
  const md = samples.find(s => s.name === 'Options & trade-offs').md;
  const cut = md.slice(0, md.indexOf('### Option C'));
  const blocks = classify(cut, marked, { streaming: true });
  assert.ok(blocks.every(b => b.kind === 'md'), blocks.map(b => b.kind).join());
  assert.ok(blocks[blocks.length - 1].open);
});

check('streaming: closed blocks before the tail keep their kind', () => {
  const md = samples.find(s => s.name === 'Table').md + '\n\nNow the next para';
  const kinds = classify(md, marked, { streaming: true }).map(b => b.kind);
  assert.deepStrictEqual(kinds, ['table', 'md']);
});

check('sections: tone from label, inner list classified', () => {
  const b = byName('Labeled sections');
  assert.deepStrictEqual(b.map(x => [x.tone, x.inner.kind]), [['warning', 'md'], ['next', 'checklist'], ['done', 'changelog']]);
  assert.strictEqual(byName('Real reply: commit report')[3].label, 'Things to know');
});

check('parseTree: 2-space indent unit', () => {
  const rows = parseTree('a/\n  ├── b\n  └── c/\n      └── d');
  assert.deepStrictEqual(rows.map(r => r.depth), [0, 1, 1, 2]);
});

console.log(failed ? `\n${failed} failed` : '\nall passed');
process.exit(failed ? 1 : 0);
