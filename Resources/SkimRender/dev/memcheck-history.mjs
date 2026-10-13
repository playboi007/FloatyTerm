// Makes a resume history message (as ClaudeSidecar sends it) from a Claude transcript, for memcheck.swift:
//   node memcheck-history.mjs ~/.claude/projects/<project>/<session>.jsonl /tmp/history.json
// Same trimming as history() in Resources/ClaudeSidecar/sidecar.mjs.
import fs from 'fs';
const [file, out] = process.argv.slice(2);
const HISTORY_MAX = 400, RESULT_MAX = 4000, INPUT_MAX = 20000;
const cut = (s, n) => typeof s === 'string' && s.length > n ? s.slice(0, n) + `\n… (${s.length - n} more characters)` : s;
function trimBlock(b) {
  if (!b || typeof b !== 'object') return b;
  if (b.type === 'image') return { type: 'text', text: '[image]' };
  if (b.type === 'thinking') return { type: 'thinking', thinking: cut(b.thinking || '', RESULT_MAX) };
  if (b.type === 'redacted_thinking') return { type: 'redacted_thinking' };
  if (b.type === 'tool_result') {
    const c = typeof b.content === 'string' ? cut(b.content, RESULT_MAX)
      : Array.isArray(b.content) ? b.content.map(x => x.type === 'text' ? { type: 'text', text: cut(x.text, RESULT_MAX) } : { type: 'text', text: '[' + x.type + ']' }) : b.content;
    return { ...b, content: c };
  }
  if (b.type === 'tool_use' && b.input && typeof b.input === 'object') {
    const input = {}; for (const [k, v] of Object.entries(b.input)) input[k] = cut(v, INPUT_MAX); return { ...b, input };
  }
  if (b.type === 'text') return { ...b, text: cut(b.text, INPUT_MAX) };
  return b;
}
const all = fs.readFileSync(file, 'utf8').split('\n').filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } })
  .filter(m => m && (m.type === 'user' || m.type === 'assistant') && !m.isSidechain);
let from = Math.max(all.length - HISTORY_MAX, 0);
while (from > 0 && from < all.length && !(all[from].type === 'user' && !(Array.isArray(all[from].message?.content) && all[from].message.content.some(c => c.type === 'tool_result')))) from++;
const messages = all.slice(from).map(m => { const msg = m.message || {};
  const content = Array.isArray(msg.content) ? msg.content.map(trimBlock) : cut(msg.content, INPUT_MAX);
  return { type: m.type, uuid: m.uuid, parent_tool_use_id: m.parent_tool_use_id || null, timestamp: m.timestamp, message: { id: msg.id, role: msg.role, model: msg.model, content } }; });
const line = JSON.stringify({ type: 'history', sessionId: 'S1', messages, omitted: from, before: null });
fs.writeFileSync(out, line);
console.log(`messages ${messages.length} of ${all.length}, ${(line.length / 1e6).toFixed(2)} MB`);
