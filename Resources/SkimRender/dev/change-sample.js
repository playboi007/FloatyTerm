// File changes for the change view (chat-replay.html ?change=…, dock-test.html). Made-up code.
(function () {
  const fn = (ttl, extra) => [
    'export function makeCache(opts = {}) {',
    '  const store = new Map();',
    `  const ttl = opts.ttl ?? ${ttl};`,
    '  const now = () => Date.now();',
    '',
    '  function get(key) {',
    '    const hit = store.get(key);',
    '    if (!hit) return undefined;',
    '    if (now() - hit.at > ttl) {',
    '      store.delete(key);',
    '      return undefined;',
    '    }',
    '    return hit.value;',
    '  }',
    '',
    '  function set(key, value) {',
    ...extra,
    '    store.set(key, { value, at: now() });',
    '  }',
    '',
    '  return { get, set, size: () => store.size };',
    '}'].join('\n');
  const longLine = '  const message = `Cache miss for ${key}: fetched from origin in ${ms} ms, stored with a TTL of ${ttl} ms, ${store.size} entries now in memory`;';
  window.CHANGE_SAMPLE = {
    edit: { file_path: '/tmp/demo/src/cache.js',
      old_string: fn('5 * 60e3', []),
      new_string: fn('10 * 60e3', ['    if (store.size >= (opts.max ?? 500)) {', '      store.delete(store.keys().next().value);', '    }', longLine]) },
    write: { file_path: '/tmp/demo/notes/plan.md',
      content: Array.from({ length: 48 }, (_, i) => i % 8 === 0 ? `## Part ${i / 8 + 1}` : `- Step ${i}: check the cache before the network call`).join('\n') + '\n' },
    multi: { file_path: '/tmp/demo/src/config.js', edits: [
      { old_string: 'export const TTL = 300;', new_string: 'export const TTL = 600;' },
      { old_string: 'export const MAX = 100;\nexport const LOG = false;', new_string: 'export const MAX = 500;' }] }
  };
})();
