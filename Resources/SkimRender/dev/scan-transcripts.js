// Runs the classifier over real assistant replies in Claude Code session
// transcripts, to see how often each pattern fires and to spot false matches.
//
//   node Resources/SkimRender/dev/scan-transcripts.js [dir-or-jsonl…] [--show kind] [--limit N]
//
// Defaults to every transcript under ~/.claude/projects.
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { marked } = require(path.join(__dirname, '../vendor/marked.min.js'));
const { classify } = require(path.join(__dirname, '../skim-classify.js'));

const args = process.argv.slice(2);
const flag = n => { const k = args.indexOf(n); return k >= 0 ? args.splice(k, 2)[1] : null; };
const show = flag('--show'), limit = Number(flag('--limit') || 5);
const roots = args.length ? args : [path.join(os.homedir(), '.claude/projects')];

const files = [];
const walk = p => {
  const st = fs.statSync(p);
  if (st.isDirectory()) for (const f of fs.readdirSync(p)) walk(path.join(p, f));
  else if (p.endsWith('.jsonl')) files.push(p);
};
roots.forEach(walk);

const counts = {}, examples = [];
let replies = 0;
for (const f of files) {
  for (const line of fs.readFileSync(f, 'utf8').split('\n')) {
    if (!line.includes('"assistant"')) continue;
    let d; try { d = JSON.parse(line); } catch { continue; }
    if (d.type !== 'assistant' || !Array.isArray(d.message?.content)) continue;
    for (const c of d.message.content) {
      if (c.type !== 'text' || !c.text || c.text.length < 40) continue;
      replies++;
      for (const b of classify(c.text, marked)) {
        counts[b.kind] = (counts[b.kind] || 0) + 1;
        if (show === b.kind && examples.length < limit) examples.push(b.raw);
      }
    }
  }
}
console.log(`${files.length} transcripts, ${replies} replies`);
for (const [k, v] of Object.entries(counts).sort((a, b) => b[1] - a[1])) console.log(`  ${k.padEnd(10)} ${v}`);
for (const e of examples) console.log('\n──── ' + show + ' ────\n' + e.trim());
