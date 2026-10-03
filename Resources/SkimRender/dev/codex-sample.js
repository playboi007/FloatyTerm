/* Synthetic Codex exec --json fixture, shaped from the official non-interactive-mode documentation.
   https://learn.chatgpt.com/docs/non-interactive-mode#make-output-machine-readable */
(function (root) {
  const t0 = Date.now() - 8000;
  const native = (dt, event, turnId = 'fixture-turn-1') => ({ type: 'native', agent: 'codex', event, t: t0 + dt, turnId });
  const control = (type, fields) => ({ v: 1, agent: 'codex', t: t0, type, raw: { synthetic: true }, ...fields });
  root.CODEX_SAMPLE = [
    control('capabilities', { models: [{ value: 'fixture-model', displayName: 'Codex fixture model', resolvedModel: 'fixture-model', description: 'Synthetic model for local replay', supportsEffort: true, supportedEffortLevels: ['low', 'medium', 'high'] }], commands: [], features: { models: true, effort: true, usage: true, slashCommands: true, permissionMode: true, history: true, fork: true, tui: true, git: true, thinking: true, approvals: true, midTurnInput: false } }),
    control('model', { model: 'fixture-model' }),
    control('effort', { effort: 'high' }),
    control('mode', { mode: 'default' }),
    control('thinking', { on: true, source: 'user' }),
    control('git', { repo: '/Users/demo/project', branch: 'feature/shared-agent-renderer', changed: 2, staged: 0, untracked: 1 }),
    native(0, { type: 'thread.started', thread_id: 'synthetic-codex-thread' }),
    native(100, { type: 'turn.started' }),
    native(400, { type: 'item.started', item: { id: 'item_0', type: 'reasoning', text: 'I will inspect the project files.' } }),
    native(800, { type: 'item.completed', item: { id: 'item_0', type: 'reasoning', text: 'I will inspect the project files.' } }),
    native(1100, { type: 'item.started', item: { id: 'item_1', type: 'command_execution', command: 'ls -la', status: 'in_progress' } }),
    native(2100, { type: 'item.completed', item: { id: 'item_1', type: 'command_execution', command: 'ls -la', aggregated_output: 'README.md\nSources\n', exit_code: 0, status: 'completed' } }),
    native(2600, { type: 'item.started', item: { id: 'item_2', type: 'agent_message', text: 'The project contains a README and source directory.' } }),
    native(3100, { type: 'item.updated', item: { id: 'item_2', type: 'agent_message', text: 'The project contains a README and source directory.\n\nI listed the top level entries.' } }),
    native(3500, { type: 'item.completed', item: { id: 'item_2', type: 'agent_message', text: 'The project contains a README and source directory.\n\nI listed the top level entries.' } }),
    native(3700, { type: 'turn.completed', usage: { input_tokens: 220, cached_input_tokens: 100, output_tokens: 72 } }),
    control('usage', { tokens: { totalTokens: 292, inputTokens: 220, cachedInputTokens: 100, outputTokens: 72, reasoningOutputTokens: 16 }, context: { totalTokens: 292, maxTokens: 32000 }, plan: { available: true, subscription: 'fixture', limits: [{ kind: 'session', label: 'Session · 5h', percent: 23, resets_at: new Date(Date.now() + 7200000).toISOString() }] } })
  ];
})(typeof globalThis !== 'undefined' ? globalThis : this);
