// Made-up requests for the dialog cards (AskUserQuestion, ExitPlanMode) and the task list, for chat-replay.html and dock-test.html.
window.ASK_INPUT = { questions: [
  { header: 'Cache scope', question: 'Where should the feed cache live?', multiSelect: false, options: [
    { label: 'In memory', description: 'Fast and simple; empty again after a restart',
      preview: '```js\nconst cache = new Map();\nexport const get = k => cache.get(k);\nexport const set = (k, v) => cache.set(k, v);\n```\n\nOne process, no disk I/O.' },
    { label: 'On disk', description: 'Survives restarts; needs a cleanup pass',
      preview: '```js\nconst file = path.join(dir, hash(key) + \'.json\');\nawait fs.writeFile(file, JSON.stringify(value));\n```\n\nEntries need an **eviction** job.' },
    { label: 'Both', description: 'Memory first, disk behind it' }] },
  { header: 'Extras', question: 'Which extras do you want with it?', multiSelect: true, options: [
    { label: 'Metrics', description: 'Hit and miss counters in the log' },
    { label: 'Eviction log', description: 'One line for every entry that expires' },
    { label: 'Tests', description: 'Unit tests for get, set and expiry' },
    { label: 'Docs', description: 'A short section in the README' }] }] };

window.PLAN_INPUT = {
  plan: [
    '## Plan: add a feed cache', '',
    'The feed is fetched on every render. A small cache in front of `fetchFeed` removes most of that traffic.', '',
    '### Steps', '',
    '1. Add `src/cache.js` with `get`, `set` and `expire` (a `Map` with per-entry timestamps).',
    '2. Wrap `fetchFeed` in `src/feed.js` so a fresh entry is returned without a request.',
    '3. Read the TTL from `config.cacheTtl` (default 5 minutes, because the feed updates hourly).',
    '4. Expire entries lazily on read; add a sweep every 10 minutes for the rest.',
    '5. Cover it with tests in `test/cache.test.js`.', '',
    '### Files', '',
    '- `src/cache.js` (new)', '- `src/feed.js` (wrap the fetch)', '- `src/config.js` (new option)', '- `test/cache.test.js` (new)', '',
    '### Sketch', '',
    '```js', 'const store = new Map();', 'export function get(key, ttl) {', '  const hit = store.get(key);', '  return hit && Date.now() - hit.at < ttl ? hit.value : undefined;', '}', '```', '',
    '### Risks', '',
    '- A stale entry can hide a fix for up to one TTL.', '- The sweep timer must not keep the process alive (`unref()` it).', '',
    'Nothing outside these files changes.'].join('\n'),
  allowedPrompts: [{ tool: 'Bash', prompt: 'run the test suite' }, { tool: 'Bash', prompt: 'install dependencies' }] };

/** Raw sidecar lines: an assistant message with one tool call, then its result. */
window.toolLines = (id, name, input, result) => [
  { type: 'sdk', msg: { type: 'assistant', parent_tool_use_id: null, message: { id: 'm-' + id, model: 'claude-opus-5-5', content: [{ type: 'tool_use', id, name, input }] } } },
  ...(result === undefined ? [] : [{ type: 'sdk', msg: { type: 'user', parent_tool_use_id: null, message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: id, content: result }] } } }])];

/** A picture as base64 PNG (drawn on a canvas): a gradient with a label. */
window.samplePng = (w, h, label, hue) => {
  const cv = document.createElement('canvas'); cv.width = w; cv.height = h;
  const cx = cv.getContext('2d'), g = cx.createLinearGradient(0, 0, w, h);
  g.addColorStop(0, `hsl(${hue},55%,42%)`); g.addColorStop(1, `hsl(${hue + 50},60%,22%)`);
  cx.fillStyle = g; cx.fillRect(0, 0, w, h);
  cx.fillStyle = 'rgba(255,255,255,.85)'; cx.font = `bold ${Math.round(h / 8)}px sans-serif`; cx.fillText(label, w / 12, h / 2);
  return cv.toDataURL('image/png').split(',')[1];
};
