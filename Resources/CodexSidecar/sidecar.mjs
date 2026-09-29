import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';

// FloatyTerm <-> Codex app-server bridge. App-server speaks newline-delimited
// JSON-RPC on stdio; this process owns one persistent connection and exposes a
// small, versioned event stream to the native host.
const MAX_LINE_BYTES = 1024 * 1024;
const STDERR_BYTES = 4000;
const REQUEST_TIMEOUT_MS = 30_000;
const HISTORY_TURN_LIMIT = 300;
const HISTORY_ITEM_LIMIT = 5000;

const COMMANDS = [
  ['model', 'Choose the Codex model', '[model]'],
  ['effort', 'Set reasoning effort', '[low|medium|high|xhigh|max|auto]'],
  ['usage', 'Show token, context, and account usage', ''],
  ['status', 'Show session status and usage', ''],
  ['permissions', 'Choose workspace-write or read-only mode', ''],
  ['new', 'Start a new Codex conversation', ''],
  ['clear', 'Start a new Codex conversation', ''],
  ['compact', 'Compact this conversation', ''],
  ['resume', 'Resume a conversation in this folder', '[search]'],
  ['fork', 'Fork this conversation into a new tab', ''],
  ['tui', 'Open this conversation in the Codex terminal UI', ''],
  ['help', 'Show available commands', ''],
  ['exit', 'Close this conversation', ''],
].map(([name, description, argumentHint]) => ({ name, description, argumentHint }));

const featureSet = {
  approvals: true, fork: true, history: true, models: true, effort: true,
  permissionMode: true, thinking: true, usage: true, git: true, tui: true,
  slashCommands: true, midTurnInput: false,
};

const output = value => {
  try { process.stdout.write(JSON.stringify({ v: 1, agent: 'codex', t: Date.now(), ...value }) + '\n'); }
  catch { /* stdout may already be closed during host shutdown */ }
};
const plainError = error => String(error?.message || error || 'Unknown app-server error').replace(/\s+/g, ' ').trim();
const tokenKey = value => encodeURIComponent(String(value ?? 'unknown'));
const toolId = (threadId, turnId, itemId) => `codex:${tokenKey(threadId)}:${tokenKey(turnId)}:${tokenKey(itemId)}`;
const toText = value => typeof value === 'string' ? value : value == null ? '' : JSON.stringify(value, null, 2);

class AppServer {
  constructor(command, cwd, onMessage) {
    this.command = command;
    this.cwd = cwd;
    this.onMessage = onMessage;
    this.child = null;
    this.buffer = Buffer.alloc(0);
    this.stderr = '';
    this.pending = new Map();
    this.nextId = 1;
    this.dead = false;
    this.closePromise = null;
  }

  start() {
    return new Promise((resolve, reject) => {
      let child;
      try {
        child = spawn(this.command, ['app-server', '--listen', 'stdio://'], {
          cwd: this.cwd, env: process.env, stdio: ['pipe', 'pipe', 'pipe'], detached: true,
        });
      } catch (error) { reject(error); return; }
      this.child = child;
      child.stdout.on('data', chunk => this.read(chunk));
      child.stderr.on('data', chunk => {
        this.stderr = (this.stderr + chunk.toString('utf8')).slice(-STDERR_BYTES);
      });
      child.on('error', error => {
        if (!this.dead) this.fail(error);
        reject(error);
      });
      child.on('close', (code, signal) => {
        const reason = this.stderr.trim() || `Codex app-server exited (${signal || (code ?? 'unknown')}).`;
        this.fail(new Error(reason));
      });
      child.stdin.on('error', error => this.fail(error));
      resolve();
    });
  }

  read(chunk) {
    if (this.dead) return;
    this.buffer = this.buffer.length ? Buffer.concat([this.buffer, chunk]) : Buffer.from(chunk);
    let newline;
    while ((newline = this.buffer.indexOf(0x0a)) >= 0) {
      const line = this.buffer.subarray(0, newline);
      this.buffer = this.buffer.subarray(newline + 1);
      if (!line.length) continue;
      if (line.length > MAX_LINE_BYTES) { this.fail(new Error('Codex app-server emitted an oversized JSON-RPC message.')); return; }
      let message;
      try { message = JSON.parse(line.toString('utf8')); }
      catch { this.onMessage({ kind: 'invalid', message: 'Codex app-server emitted invalid JSON-RPC data.' }); continue; }
      if (!message || typeof message !== 'object' || Array.isArray(message)) {
        this.onMessage({ kind: 'invalid', message: 'Codex app-server emitted a non-object JSON-RPC message.' });
        continue;
      }
      this.dispatch(message);
    }
    if (this.buffer.length > MAX_LINE_BYTES) this.fail(new Error('Codex app-server emitted an oversized JSON-RPC message.'));
  }

  dispatch(message) {
    if (Object.hasOwn(message, 'method')) {
      if (Object.hasOwn(message, 'id')) this.onMessage({ kind: 'serverRequest', message });
      else this.onMessage({ kind: 'notification', message });
      return;
    }
    if (!Object.hasOwn(message, 'id')) {
      this.onMessage({ kind: 'invalid', message: 'Codex app-server returned a JSON-RPC response without an id.' });
      return;
    }
    const key = String(message.id);
    const pending = this.pending.get(key);
    if (!pending) return; // late response to a timed-out/cancelled request
    this.pending.delete(key);
    clearTimeout(pending.timer);
    if (message.error) {
      const error = new Error(message.error.message || `Codex app-server request failed (${message.error.code ?? 'unknown'}).`);
      error.code = message.error.code;
      pending.reject(error);
    } else pending.resolve(message.result);
  }

  write(message) {
    if (!this.child || this.dead || !this.child.stdin.writable) throw new Error('Codex app-server is not running.');
    this.child.stdin.write(JSON.stringify(message) + '\n');
  }

  notify(method, params) {
    this.write({ jsonrpc: '2.0', method, ...(params === undefined ? {} : { params }) });
  }

  request(method, params, timeoutMs = REQUEST_TIMEOUT_MS) {
    if (this.dead) return Promise.reject(new Error('Codex app-server is not running.'));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(String(id));
        reject(new Error(`Codex app-server request timed out: ${method}`));
      }, timeoutMs);
      timer.unref();
      this.pending.set(String(id), { resolve, reject, timer, method });
      try { this.write({ jsonrpc: '2.0', id, method, ...(params === undefined ? {} : { params }) }); }
      catch (error) {
        this.pending.delete(String(id)); clearTimeout(timer); reject(error);
      }
    });
  }

  respond(id, result) {
    this.write({ jsonrpc: '2.0', id, result });
  }

  rejectRequest(id, code, message) {
    this.write({ jsonrpc: '2.0', id, error: { code, message } });
  }

  fail(error) {
    if (this.dead) return;
    this.dead = true;
    const failure = error instanceof Error ? error : new Error(String(error));
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(failure);
    }
    this.pending.clear();
    this.onMessage({ kind: 'exit', error: failure });
    void this.stop();
  }

  async stop(signal = 'SIGTERM') {
    if (!this.child || this.child.exitCode !== null || this.child.signalCode !== null) return;
    try { process.kill(-this.child.pid, signal); }
    catch { try { this.child.kill(signal); } catch {} }
    await Promise.race([
      new Promise(resolve => this.child.once('close', resolve)),
      new Promise(resolve => setTimeout(resolve, 1200)),
    ]);
    if (this.child.exitCode === null && this.child.signalCode === null) {
      try { process.kill(-this.child.pid, 'SIGKILL'); }
      catch { try { this.child.kill('SIGKILL'); } catch {} }
    }
  }
}

class CodexBridge {
  constructor() {
    this.config = null;
    this.rpc = null;
    this.started = false;
    this.closing = false;
    this.starting = false;
    this.startQueue = [];
    this.threadId = null;
    this.thread = null;
    this.models = [];
    this.modelsById = new Map();
    this.model = null;
    this.effort = null;
    this.permissionMode = 'default';
    this.thinkingOn = false;
    this.configEffort = null;
    this.configSummary = null;
    this.active = null;
    this.approvals = new Map();
    this.items = new Map();
    this.latestUsage = null;
    this.plan = null;
    this.failureSent = false;
    this.transitioning = false;
  }

  emit(type, fields = {}, raw = undefined) {
    output({ type, ...fields, raw: raw ?? { type: 'codex.app-server', event: type } });
  }

  notice(kind, message, terminal = false, raw = undefined) {
    this.emit('notice', { kind, message, ...(terminal ? { terminal: true } : {}) }, raw);
  }

  async start(message) {
    if (this.config || this.starting) return;
    if (typeof message.cwd !== 'string' || !message.cwd || typeof message.codexPath !== 'string' || !message.codexPath.startsWith('/')) {
      this.notice('error', 'Invalid Codex app-server configuration.', true, { type: 'start.invalid' });
      return;
    }
    this.starting = true;
    this.config = { cwd: message.cwd, codexPath: message.codexPath };
    this.permissionMode = message.permissionMode === 'plan' ? 'plan' : 'default';
    this.effort = typeof message.effort === 'string' && message.effort ? message.effort : null;
    this.thinkingOn = typeof message.thinking === 'boolean' ? message.thinking : false;
    this.rpc = new AppServer(message.codexPath, message.cwd, event => this.handleServer(event));
    try {
      await this.rpc.start();
      const initialize = await this.rpc.request('initialize', {
        clientInfo: { name: 'floatyterm', title: 'FloatyTerm', version: '0.1.0' },
        capabilities: { experimentalApi: true, requestAttestation: false },
      });
      this.rpc.notify('initialized');
      const [modelsResult, configResult] = await Promise.allSettled([
        this.loadModels(), this.rpc.request('config/read', { cwd: this.config.cwd }),
      ]);
      if (this.rpc.dead) throw new Error('Codex app-server disconnected during initialization.');
      if (modelsResult.status === 'fulfilled') this.models = modelsResult.value;
      else this.notice('error', `Could not read Codex model catalog: ${plainError(modelsResult.reason)}`, false,
        { type: 'model/list.error', error: plainError(modelsResult.reason) });
      if (configResult.status === 'fulfilled') {
        this.configEffort = configResult.value?.config?.model_reasoning_effort || null;
        this.configSummary = configResult.value?.config?.model_reasoning_summary || null;
        if (typeof message.thinking !== 'boolean') this.thinkingOn = this.configSummary !== 'none';
      }
      this.modelsById = new Map();
      for (const model of this.models) {
        if (model?.id) this.modelsById.set(model.id, model);
        if (model?.model) this.modelsById.set(model.model, model);
      }
      const selectedModel = this.resolveModel(message.model, true);
      const selectedEffort = selectedModel ? this.resolveEffort(this.effort, selectedModel, true) : this.effort;
      if (selectedModel === false || selectedEffort === false) {
        throw new Error("Invalid model or effort selection.");
      }
      this.model = selectedModel;
      this.effort = selectedEffort;
      this.emitCapabilities();
      await this.readRateLimits(false);
      await this.openThread(message);
      this.started = true;
      this.starting = false;
      for (const pending of this.startQueue.splice(0)) this.handleControl(pending);
    } catch (error) {
      this.starting = false;
      if (!this.failureSent && !this.closing) {
        this.failureSent = true;
        this.notice('error', `Codex app-server could not start: ${plainError(error)}`, true,
          { type: 'app-server.start.failed' });
      }
      await this.rpc?.stop();
    }
  }

  async loadModels() {
    const out = [];
    let cursor;
    do {
      const result = await this.rpc.request('model/list', { includeHidden: false, limit: 100, ...(cursor ? { cursor } : {}) });
      if (Array.isArray(result?.data)) out.push(...result.data);
      cursor = result?.nextCursor || null;
      if (out.length > 300) break;
    } while (cursor);
    return out.filter(model => model && typeof model.id === 'string');
  }

  modelRows() {
    return this.models.map(model => ({
      value: model.model || model.id,
      displayName: model.displayName || model.id,
      description: model.description || '',
      resolvedModel: model.model || model.id,
      supportsEffort: Array.isArray(model.supportedReasoningEfforts),
      supportedEffortLevels: (model.supportedReasoningEfforts || []).map(option => option.reasoningEffort).filter(Boolean),
      defaultEffort: model.defaultReasoningEffort || null,
      supportsAutoMode: false,
    }));
  }

  emitCapabilities() {
    const features = { ...featureSet, models: this.models.length > 0, effort: this.models.length > 0 };
    this.emit('capabilities', {
      features, commands: COMMANDS, models: this.modelRows(), mode: this.permissionMode,
      permissionModes: ['default', 'plan'],
    }, { type: 'app-server.capabilities', methods: ['thread/start', 'thread/resume', 'thread/fork', 'turn/start', 'turn/interrupt'] });
  }

  resolveModel(value, announce = true) {
    if (!value) return null;
    const found = this.modelsById.get(value);
    if (found) return found;
    if (announce) this.notice('error', `Codex model is unavailable: ${value}`, false, { type: 'model.invalid', value });
    return false;
  }

  resolveEffort(value, model = null, announce = true) {
    if (!value) return null;
    const row = model || (this.model && this.modelsById.get(this.model.id));
    const choices = (row?.supportedReasoningEfforts || []).map(option => option.reasoningEffort);
    if (choices.includes(value)) return value;
    if (announce) this.notice('error', `Reasoning effort “${value}” is not supported by the selected Codex model.`, false,
      { type: 'effort.invalid', value, model: row?.id });
    return false;
  }

  currentSandbox() { return this.permissionMode === 'plan' ? 'read-only' : 'workspace-write'; }

  async openThread(message = {}) {
    const sandbox = this.currentSandbox();
    const config = {};
    if (this.effort) config.model_reasoning_effort = this.effort;
    if (typeof message.thinking === 'boolean' || this.configSummary) config.model_reasoning_summary = this.thinkingOn ? 'detailed' : 'none';
    const common = {
      cwd: this.config.cwd,
      approvalPolicy: 'on-request',
      sandbox,
      ...(this.model?.model ? { model: this.model.model } : {}),
      ...(Object.keys(config).length ? { config } : {}),
    };
    let response;
    if (typeof message.fork === 'string' && message.fork) {
      response = await this.rpc.request('thread/fork', { threadId: message.fork, ...common, excludeTurns: true });
    } else if (message.fork && typeof message.resume === 'string' && message.resume) {
      response = await this.rpc.request('thread/fork', { threadId: message.resume, ...common, excludeTurns: true });
    } else if (typeof message.resume === 'string' && message.resume) {
      response = await this.rpc.request('thread/resume', { threadId: message.resume, ...common, excludeTurns: true });
    } else {
      response = await this.rpc.request('thread/start', common);
    }
    this.applyThread(response, { emitSession: true });
  }

  applyThread(response, { emitSession = true } = {}) {
    const thread = response?.thread;
    if (!thread?.id) throw new Error('Codex app-server did not return a thread id.');
    if (this.threadId !== thread.id) { this.items.clear(); this.latestUsage = null; this.cancelApprovals(); }
    this.thread = thread;
    this.threadId = thread.id;
    if (response.model) {
      const current = this.modelsById.get(response.model) || [...this.modelsById.values()].find(model => model.model === response.model);
      this.model = current || this.model;
    }
    const settings = response.threadSettings || response.settings;
    const threadEffort = response.reasoningEffort ?? thread.reasoningEffort ?? settings?.effort;
    if (this.effort == null && threadEffort) this.effort = threadEffort;
    if (emitSession) {
      this.emit('session', {
        sessionId: thread.id, model: this.model?.model || response.model || thread.model || undefined,
        mode: this.permissionMode, cwd: response.cwd || thread.cwd || this.config.cwd,
        info: { provider: response.modelProvider || thread.modelProvider || 'openai', title: thread.name || null, version: thread.cliVersion || null,
          sandbox: response.sandbox || null, approvalPolicy: response.approvalPolicy || 'on-request' },
      }, { type: 'thread.ready', thread });
      if (this.model) this.emit('model', { model: this.model.model || this.model.id }, { type: 'thread.model', model: this.model.model || this.model.id });
      this.emit('mode', { mode: this.permissionMode }, { type: 'thread.permissionMode', mode: this.permissionMode });
      this.emit('effort', { effort: this.effort || '' }, { type: 'thread.effort', effort: this.effort });
      this.emit('thinking', { on: this.thinkingOn, source: 'codex' }, { type: 'thread.reasoningSummary', on: this.thinkingOn });
    }
  }

  async readRateLimits(announceFailure = true) {
    try {
      const response = await this.rpc.request('account/rateLimits/read', {});
      this.plan = this.convertPlan(response);
      this.emitUsage();
    } catch (error) {
      this.plan = { available: false, limits: [] };
      this.emitUsage(plainError(error));
      if (announceFailure) this.notice('info', `Codex account limits are unavailable: ${plainError(error)}`,
        false, { type: 'account/rateLimits/read.error' });
    }
  }

  convertPlan(response) {
    const snapshots = response?.rateLimitsByLimitId && Object.values(response.rateLimitsByLimitId).length
      ? Object.values(response.rateLimitsByLimitId) : [response?.rateLimits].filter(Boolean);
    const limits = [];
    for (const snapshot of snapshots) {
      for (const [kind, window] of [['primary', snapshot?.primary], ['secondary', snapshot?.secondary]]) {
        if (!window) continue;
        limits.push({
          kind, limitId: snapshot.limitId || 'default', label: [snapshot.limitName || snapshot.normalModelSlug || snapshot.limitId, window.windowDurationMins ? `${window.windowDurationMins / 60}h` : kind].filter(Boolean).join(' · '),
          percent: Number(window.usedPercent) || 0,
          resets_at: window.resetsAt == null ? null : Number(window.resetsAt) * (Number(window.resetsAt) < 10_000_000_000 ? 1000 : 1),
          is_active: true,
        });
      }
    }
    const snapshot = snapshots[0];
    return {
      available: limits.length > 0,
      ...(snapshot?.planType ? { subscription: snapshot.planType } : {}), limits,
    };
  }

  emitUsage(unavailable = undefined) {
    const usage = this.latestUsage;
    const value = {
      type: 'usage',
      tokens: usage ? {
        totalTokens: usage.total?.totalTokens ?? 0,
        inputTokens: usage.total?.inputTokens ?? 0,
        outputTokens: usage.total?.outputTokens ?? 0,
        cachedInputTokens: usage.total?.cachedInputTokens ?? 0,
        reasoningOutputTokens: usage.total?.reasoningOutputTokens ?? 0,
      } : null,
      context: usage?.modelContextWindow ? {
        totalTokens: usage.last?.totalTokens ?? 0,
        maxTokens: usage.modelContextWindow,
      } : null,
      ...(this.plan ? { plan: this.plan } : {}),
      unavailable: unavailable || null,
    };
    this.emit('usage', value, { type: 'usage.snapshot', source: unavailable ? 'unavailable' : 'app-server' });
  }

  async user(text) {
    if (!this.started || !this.threadId) { this.notice('error', 'Codex app-server is not ready.', true); return; }
    if (this.transitioning) { this.notice('info', 'Wait for the conversation operation to finish.'); return; }
    if (this.active) { this.notice('info', 'Codex is already working on a turn.'); return; }
    if (typeof text !== 'string' || !text.trim()) return;
    this.items.clear();
    const turn = { id: null, started: false, ended: false, interruptRequested: false, usage: null };
    this.active = turn;
    try {
      const model = this.model?.model;
      const effort = this.effort || this.modelsById.get(model)?.defaultReasoningEffort || this.configEffort || undefined;
      const summary = this.thinkingOn ? (this.configSummary && this.configSummary !== 'none' ? this.configSummary : 'detailed') : 'none';
      const params = {
        threadId: this.threadId,
        input: [{ type: 'text', text, text_elements: [] }],
        sandboxPolicy: { type: 'workspaceWrite', writableRoots: [], networkAccess: false, excludeTmpdirEnvVar: false, excludeSlashTmp: false },
        approvalPolicy: 'on-request',
        ...(this.permissionMode === 'plan' ? { sandboxPolicy: { type: 'readOnly', networkAccess: false } } : {}),
        ...(model ? { model } : {}), ...(effort ? { effort } : {}), summary,
        clientUserMessageId: randomUUID(),
      };
      const response = await this.rpc.request('turn/start', params);
      if (response?.turn?.id) turn.id = response.turn.id;
      if (!turn.ended && !turn.started && response?.turn) this.onTurnStarted({ threadId: this.threadId, turn: response.turn }, { method: 'turn/started', params: { threadId: this.threadId, turn: response.turn } });
      if (turn.interruptRequested && turn.id) await this.interruptActive();
    } catch (error) {
      if (this.active === turn && !turn.ended) this.endTurn(turn, 'error', plainError(error), { type: 'turn/start.error', error: plainError(error) });
    }
  }

  async interruptActive() {
    const turn = this.active;
    if (!turn || turn.ended) return;
    turn.interruptRequested = true;
    if (!turn.id || turn.interruptSent) return;
    turn.interruptSent = true;
    try { await this.rpc.request('turn/interrupt', { threadId: this.threadId, turnId: turn.id }); }
    catch (error) { this.notice('info', `Could not interrupt Codex turn: ${plainError(error)}`, false, { type: 'turn/interrupt.error' }); }
  }

  onTurnStarted(params, raw) {
    if (params.threadId !== this.threadId) return;
    const turn = this.active || (this.active = { id: null, started: false, ended: false, interruptRequested: false });
    turn.id = params.turn?.id || turn.id;
    if (turn.started) return;
    turn.started = true;
    this.emit('turn.start', { sessionId: this.threadId, turnId: turn.id }, raw);
    if (turn.interruptRequested) void this.interruptActive();
  }

  onTurnCompleted(params, raw) {
    if (params.threadId !== this.threadId) return;
    const turn = this.active;
    if (!turn) return;
    if (turn.id && params.turn?.id && turn.id !== params.turn.id) return;
    const status = params.turn?.status === 'completed' ? 'success' : params.turn?.status === 'interrupted' ? 'cancelled' : 'error';
    const message = status === 'error' ? params.turn?.error?.message || 'Codex turn failed.' : undefined;
    this.endTurn(turn, status, message, raw, params.turn);
  }

  endTurn(turn, status, message, raw, serverTurn = null) {
    if (turn.ended) return;
    turn.ended = true;
    if (this.active === turn) this.active = null;
    this.cancelApprovals();
    this.emit('turn.end', {
      status,
      ...(message ? { message } : {}),
      ...(serverTurn?.durationMs != null ? { durationMs: serverTurn.durationMs } : {}),
      ...(turn.usage ? { usage: turn.usage } : {}),
    }, raw);
    if (this.closing) void this.rpc?.stop();
  }

  onUsage(params, raw) {
    if (params.threadId !== this.threadId) return;
    this.latestUsage = params.tokenUsage;
    if (this.active && this.active.id === params.turnId) this.active.usage = this.usageForTurn(params.tokenUsage);
    this.emitUsage();
  }

  usageForTurn(usage) {
    return usage ? {
      totalTokens: usage.total?.totalTokens ?? 0,
      inputTokens: usage.last?.inputTokens ?? 0,
      outputTokens: usage.last?.outputTokens ?? 0,
      cachedInputTokens: usage.last?.cachedInputTokens ?? 0,
      reasoningOutputTokens: usage.last?.reasoningOutputTokens ?? 0,
    } : undefined;
  }

  async history(sessionId) {
    if (typeof sessionId !== 'string' || !sessionId) return;
    try {
      const turns = [];
      let cursor;
      let itemCount = 0;
      do {
        const page = await this.rpc.request('thread/turns/list', {
          threadId: sessionId, limit: 100, sortDirection: 'desc', itemsView: 'full', ...(cursor ? { cursor } : {}),
        });
        for (const turn of page?.data || []) {
          const items = Array.isArray(turn.items) ? turn.items : [];
          const user = items.find(item => item.type === 'userMessage');
          const userText = user?.content?.filter(content => content.type === 'text').map(content => content.text || '').join('\n') || '';
          const events = [];
          for (const item of items) {
            if (++itemCount > HISTORY_ITEM_LIMIT) break;
            events.push(...this.historyItem(sessionId, turn.id, item));
          }
          events.push({ type: 'turn.end', status: turn.status === 'completed' ? 'success' : turn.status === 'interrupted' ? 'cancelled' : 'error', ...(turn.error?.message ? { message: turn.error.message } : {}) });
          turns.push({ userText, events: events.map(event => ({ v: 1, agent: 'codex', t: 0, raw: { type: 'thread.history' }, ...event })) });
          if (turns.length >= HISTORY_TURN_LIMIT || itemCount > HISTORY_ITEM_LIMIT) break;
        }
        cursor = page?.nextCursor || null;
      } while (cursor && turns.length < HISTORY_TURN_LIMIT && itemCount <= HISTORY_ITEM_LIMIT);
      this.emit('history.replay', { sessionId, turns: turns.reverse(), ...(cursor ? { omitted: true } : {}) }, { type: 'thread.history', sessionId });
    } catch (error) {
      this.notice('error', `Could not read Codex conversation history: ${plainError(error)}`, false,
        { type: 'thread.history.error', sessionId, error: plainError(error) });
    }
  }

  historyItem(threadId, turnId, item) {
    const id = toolId(threadId, turnId, item.id);
    const content = (kind, text) => [
      { type: 'content.start', id, messageId: id, kind },
      { type: 'content.snapshot', id, messageId: id, kind, text: text || '', final: true },
      { type: 'content.end', id, messageId: id, kind },
    ];
    if (item.type === 'agentMessage') return content('text', item.text);
    if (item.type === 'reasoning') return content('thinking', Array.isArray(item.summary) ? item.summary.join('\n') : '');
    if (item.type === 'commandExecution') return [
      { type: 'tool.start', id, name: 'Bash', input: { command: item.command || '', cwd: item.cwd || '' } },
      { type: 'tool.result', id, name: 'Bash', output: item.aggregatedOutput || '', isError: item.status === 'failed' || (item.exitCode != null && item.exitCode !== 0) },
    ];
    if (item.type === 'fileChange') return [
      { type: 'tool.start', id, name: 'File changes', input: { changes: item.changes || [] } },
      { type: 'tool.result', id, name: 'File changes', output: item.status || 'completed', isError: item.status === 'failed' },
    ];
    if (item.type === 'mcpToolCall') return [
      { type: 'tool.start', id, name: `MCP: ${item.server || ''}/${item.tool || 'tool'}`, input: item.arguments || {} },
      { type: 'tool.result', id, output: toText(item.result ?? item.error), isError: !!item.error || item.status === 'failed' },
    ];
    if (item.type === 'webSearch') return [
      { type: 'tool.start', id, name: 'Web search', input: { query: item.query || '' } },
      { type: 'tool.result', id, output: toText(item.results || item.result), isError: false },
    ];
    if (item.type === 'userMessage') return [];
    return [{ type: 'unknown', name: `history:${item.type}`, raw: item }];
  }

  async sessions() {
    try {
      const list = [];
      let cursor;
      do {
        const page = await this.rpc.request('thread/list', {
          cwd: [this.config.cwd], limit: 100, sortKey: 'updated_at', sortDirection: 'desc',
          sourceKinds: ['cli', 'vscode', 'appServer', 'exec'], ...(cursor ? { cursor } : {}),
        });
        for (const thread of page?.data || []) {
          list.push({
            id: thread.id,
            title: thread.name || thread.preview || thread.id,
            firstPrompt: thread.preview || '',
            branch: thread.gitInfo?.branch || '',
            modified: Number(thread.updatedAt || thread.createdAt || 0) * 1000,
          });
        }
        cursor = page?.nextCursor || null;
      } while (cursor && list.length < 300);
      this.emit('sessions', { list }, { type: 'thread.list', cwd: this.config.cwd });
    } catch (error) {
      this.emit('sessions', { list: [] }, { type: 'thread.list.error' });
      this.notice('error', `Could not list Codex conversations: ${plainError(error)}`, false, { type: 'thread.list.error' });
    }
  }

  async fork() {
    if (this.active) { this.notice('info', 'Stop the current turn before forking this conversation.'); return; }
    const source = this.threadId;
    if (!source) return;
    try {
      const config = {};
      if (this.effort) config.model_reasoning_effort = this.effort;
      const response = await this.rpc.request('thread/fork', {
        threadId: source, cwd: this.config.cwd, approvalPolicy: 'on-request', sandbox: this.currentSandbox(),
        ...(this.model?.model ? { model: this.model.model } : {}), ...(Object.keys(config).length ? { config } : {}), excludeTurns: true,
      });
      this.applyThread(response);
      this.emit('notice', { kind: 'info', message: 'Conversation forked.' }, { type: 'thread.forked', source, threadId: this.threadId });
    } catch (error) { this.notice('error', `Could not fork Codex conversation: ${plainError(error)}`, false, { type: 'thread.fork.error' }); }
  }

  async newConversation() {
    if (this.active) { this.notice('info', 'Stop the current turn before starting a new conversation.'); return; }
    try {
      const message = { type: 'start', cwd: this.config.cwd, codexPath: this.config.codexPath,
        ...(this.model?.model ? { model: this.model.model } : {}), ...(this.effort ? { effort: this.effort } : {}),
        permissionMode: this.permissionMode, thinking: this.thinkingOn };
      await this.openThread(message);
    } catch (error) { this.notice('error', `Could not start a new Codex conversation: ${plainError(error)}`, false, { type: 'thread.start.error' }); }
  }

  async compact() {
    if (this.active) { this.notice('info', 'Stop the current turn before compacting the conversation.'); return; }
    try {
      await this.rpc.request('thread/compact/start', { threadId: this.threadId });
      this.notice('info', 'Codex context compaction started.', false, { type: 'thread.compact.start', threadId: this.threadId });
    } catch (error) { this.notice('error', `Could not compact Codex conversation: ${plainError(error)}`, false, { type: 'thread.compact.error' }); }
  }

  async git() {
    const fields = ['-C', this.config.cwd];
    try {
      const [status, last] = await Promise.all([
        this.runGit([...fields, '--no-optional-locks', 'status', '--porcelain=2', '--branch']),
        this.runGit([...fields, 'log', '-1', '--format=%h%x1f%s%x1f%cr']).catch(() => ''),
      ]);
      if (!status) { this.emit('git', { repo: false }, { type: 'git.not-repository' }); return; }
      const lines = status.split('\n');
      const head = lines.find(line => line.startsWith('# branch.head '))?.slice(14) || '';
      const upstream = lines.find(line => line.startsWith('# branch.upstream '))?.slice(18) || '';
      const aheadBehind = lines.find(line => line.startsWith('# branch.ab ')) || '';
      const ab = aheadBehind.match(/\+(\d+) -(\d+)/);
      const records = lines.filter(line => /^[12u?]/.test(line));
      let staged = 0, unstaged = 0, untracked = 0;
      for (const line of records) {
        if (line.startsWith('?')) { untracked++; continue; }
        const statusCode = line.split(' ')[1] || '';
        if (statusCode[0] && statusCode[0] !== '.') staged++;
        if (statusCode[1] && statusCode[1] !== '.') unstaged++;
      }
      const parts = last.trim().split('\x1f');
      const changed = staged + unstaged + untracked;
      this.emit('git', {
        repo: true, branch: head === '(detached)' ? '' : head, detached: head === '(detached)',
        ...(upstream ? { upstream } : {}), changed, staged, untracked,
        ahead: ab ? Number(ab[1]) : 0, behind: ab ? Number(ab[2]) : 0,
        ...(parts[0] ? { last: { sha: parts[0], subject: parts[1] || '', when: parts[2] || '' } } : {}),
      }, { type: 'git.status', cwd: this.config.cwd });
    } catch (error) { this.notice('info', `Git status is unavailable: ${plainError(error)}`, false, { type: 'git.error' }); }
  }

  runGit(args) {
    return new Promise((resolve, reject) => {
      let child;
      try { child = spawn('git', args, { cwd: this.config.cwd, env: process.env, stdio: ['ignore', 'pipe', 'pipe'] }); }
      catch (error) { reject(error); return; }
      let stdout = '', stderr = '';
      const timer = setTimeout(() => { child.kill('SIGKILL'); reject(new Error('git status timed out')); }, 5000);
      timer.unref();
      child.stdout.on('data', chunk => { stdout = (stdout + chunk.toString()).slice(-64 * 1024); });
      child.stderr.on('data', chunk => { stderr = (stderr + chunk.toString()).slice(-4000); });
      child.on('error', error => { clearTimeout(timer); reject(error); });
      child.on('close', code => {
        clearTimeout(timer);
        if (code === 0) resolve(stdout);
        else if (/not a git repository/i.test(stderr)) resolve('');
        else reject(new Error(stderr.trim() || `git exited ${code}`));
      });
    });
  }

  requestIdKey(id) { return JSON.stringify(id); }

  serverRequest(message) {
    const { id, method, params = {} } = message;
    if (params.threadId && params.threadId !== this.threadId) {
      this.rpc.rejectRequest(id, -32602, 'Approval belongs to another conversation.');
      return;
    }
    const key = this.requestIdKey(id);
    if (this.approvals.has(key)) {
      this.rpc.rejectRequest(id, -32600, 'Duplicate approval request id.');
      this.notice('error', 'Codex repeated an approval request id; the duplicate was rejected.', false, { type: 'approval.duplicate', method });
      return;
    }
    if (method === 'item/commandExecution/requestApproval' || method === 'item/fileChange/requestApproval') {
      const file = method === 'item/fileChange/requestApproval';
      const itemInput = this.items.get(toolId(params.threadId, params.turnId, params.itemId))?.input;
      const request = {
        id: String(id), toolUseID: toolId(params.threadId, params.turnId, params.itemId),
        toolName: file ? 'File changes' : 'Bash',
        input: file ? { ...(itemInput || {}), ...(params.grantRoot ? { grantRoot: params.grantRoot } : {}) } : { command: params.command || itemInput?.command || '', cwd: params.cwd || this.config.cwd },
        decisionReason: params.reason || '', suppressAlwaysAllowRule: true,
      };
      this.approvals.set(key, { id, method, request });
      this.emit('approval.request', { request }, { ...message });
      return;
    }
    this.rpc.rejectRequest(id, -32601, `Unsupported Codex app-server request: ${method}`);
    this.notice('error', `Codex requested an unsupported operation (${method}); it was rejected.`, false,
      { type: 'app-server.request.unsupported', method, params });
  }

  permission(message) {
    const match = [...this.approvals.entries()].find(([, approval]) => String(approval.id) === String(message.id));
    if (!match) { this.notice('info', 'This Codex approval request is no longer active.'); return; }
    const [key, approval] = match;
    this.approvals.delete(key); // exactly-once even if writing the response fails
    const accepted = message.decision === 'allow';
    if (message.message) this.notice('info', 'Codex approval responses do not support feedback text; the decision was sent without it.');
    try {
      this.rpc.respond(approval.id, { decision: accepted ? 'accept' : 'decline' });
    } catch (error) {
      this.notice('error', `Could not send the Codex approval decision: ${plainError(error)}`);
      return;
    }
    this.emit('approval.cancel', { id: String(approval.id) }, { type: 'approval.resolved', decision: accepted ? 'allow' : 'deny' });
  }

  cancelApprovals() {
    for (const [, approval] of this.approvals) this.emit('approval.cancel', { id: String(approval.id) }, { type: 'approval.cancelled' });
    this.approvals.clear();
  }

  ensureItem(params, type, raw) {
    const { item, threadId, turnId } = params;
    if (!item?.id) return null;
    const id = toolId(threadId, turnId, item.id);
    let state = this.items.get(id);
    if (!state) {
      state = { id, itemId: item.id, threadId, turnId, type: item.type, kind: null, text: '', output: '', input: null, started: false, finished: false };
      this.items.set(id, state);
    }
    if (item.type) state.type = item.type;
    if (type === 'started') state.started = true;
    return state;
  }

  emitContentStart(state, kind, raw) {
    if (state.startedContent) return;
    state.startedContent = true; state.kind = kind;
    this.emit('content.start', { id: state.id, messageId: state.id, kind }, raw);
  }

  onItemLifecycle(phase, params, raw) {
    const state = this.ensureItem(params, phase, raw);
    const item = params.item;
    if (!state) { this.emit('unknown', { name: `item.${phase}`, raw: params }, raw); return; }
    if (item.type === 'userMessage') return;
    if (item.type === 'agentMessage') {
      this.emitContentStart(state, 'text', raw);
      if (phase === 'completed') {
        const text = typeof item.text === 'string' ? item.text : state.text;
        state.text = text;
        this.emit('content.snapshot', { id: state.id, messageId: state.id, kind: 'text', text, final: true }, raw);
        this.emit('content.end', { id: state.id, messageId: state.id, kind: 'text' }, raw);
        state.finished = true;
      } else if (typeof item.text === 'string' && item.text && item.text !== state.text) {
        state.text = item.text;
        this.emit('content.snapshot', { id: state.id, messageId: state.id, kind: 'text', text: item.text }, raw);
      }
      return;
    }
    if (item.type === 'reasoning') {
      this.emitContentStart(state, 'thinking', raw);
      const text = Array.isArray(item.summary) ? item.summary.join('\n') : '';
      if (phase === 'completed') {
        state.text = text;
        this.emit('content.snapshot', { id: state.id, messageId: state.id, kind: 'thinking', text, final: true }, raw);
        this.emit('content.end', { id: state.id, messageId: state.id, kind: 'thinking' }, raw);
        state.finished = true;
      } else if (text && text !== state.text) {
        state.text = text;
        this.emit('content.snapshot', { id: state.id, messageId: state.id, kind: 'thinking', text }, raw);
      }
      return;
    }
    const details = this.toolDetails(item, state);
    if (!details) {
      this.emit('unknown', { name: `item.${phase}:${item.type || 'unknown'}`, raw: item }, raw);
      return;
    }
    if (!state.toolStarted) {
      state.toolStarted = true;
      this.emit('tool.start', { id: state.id, name: details.name, input: details.input }, raw);
    } else if (details.input && JSON.stringify(details.input) !== JSON.stringify(state.input)) {
      this.emit('tool.input', { id: state.id, name: details.name, input: details.input }, raw);
    }
    if (details.input) state.input = details.input;
    if (phase === 'completed') {
      const assembled = details.output ?? (state.output || undefined);
      this.emit('tool.result', { id: state.id, name: details.name, ...(assembled !== undefined ? { output: assembled } : {}), isError: !!details.isError }, raw);
      state.finished = true;
    }
  }

  toolDetails(item, state) {
    switch (item.type) {
      case 'commandExecution': return { name: 'Bash', input: { command: item.command || '', cwd: item.cwd || this.config.cwd }, output: item.aggregatedOutput ?? undefined, isError: item.exitCode != null && item.exitCode !== 0 || item.status === 'failed' };
      case 'fileChange': return { name: 'File changes', input: { changes: item.changes || [] }, output: item.status === 'failed' ? 'File changes failed' : item.status === 'completed' ? 'File changes completed' : undefined, isError: item.status === 'failed' };
      case 'mcpToolCall': return { name: `MCP: ${item.server || ''}/${item.tool || 'tool'}`, input: item.arguments || {}, output: toText(item.result ?? item.error), isError: !!item.error || item.status === 'failed' };
      case 'dynamicToolCall': return { name: item.tool || 'Tool', input: item.arguments || {}, output: toText(item.contentItems), isError: item.success === false || item.status === 'failed' };
      case 'webSearch': return { name: 'Web search', input: { query: item.query || '', action: item.action || '' }, output: toText(item.results || item.result), isError: false };
      case 'plan': return { name: 'Plan', input: { text: item.text || '' }, output: item.text || '', isError: false };
      case 'contextCompaction': return { name: 'Context compaction', input: {}, output: 'Conversation context compacted', isError: false };
      default: return null;
    }
  }

  onNotification(message) {
    const { method, params = {} } = message;
    if (params.threadId && params.threadId !== this.threadId) return;
    switch (method) {
      case 'thread/tokenUsage/updated': this.onUsage(params, message); break;
      case 'account/rateLimits/updated':
        if (this.plan) {
          const old = this.plan;
          this.plan = this.mergeRateLimit(old, params.rateLimits);
          this.emitUsage();
        } else void this.readRateLimits(false);
        break;
      case 'turn/started': this.onTurnStarted(params, message); break;
      case 'turn/completed': this.onTurnCompleted(params, message); break;
      case 'item/started': this.onItemLifecycle('started', params, message); break;
      case 'item/completed': this.onItemLifecycle('completed', params, message); break;
      case 'item/agentMessage/delta': {
        const state = this.ensureItem({ ...params, item: { id: params.itemId, type: 'agentMessage' } }, 'delta', message);
        if (state) {
          this.emitContentStart(state, 'text', message);
          state.text += params.delta || '';
          this.emit('content.delta', { id: state.id, messageId: state.id, kind: 'text', text: params.delta || '' }, message);
        }
        break;
      }
      case 'item/reasoning/summaryTextDelta': {
        const state = this.ensureItem({ ...params, item: { id: params.itemId, type: 'reasoning' } }, 'delta', message);
        if (state) {
          this.emitContentStart(state, 'thinking', message);
          state.text += params.delta || '';
          this.emit('content.delta', { id: state.id, messageId: state.id, kind: 'thinking', text: params.delta || '' }, message);
        }
        break;
      }
      case 'item/reasoning/textDelta':
      case 'item/reasoning/rawContentDelta':
      case 'item/reasoning/summaryPartAdded':
        // The next summaryTextDelta carries the text. This structural notification
        // has no user-facing content and is routine protocol traffic.
        break;
      case 'item/commandExecution/outputDelta': {
        const state = this.ensureItem({ ...params, item: { id: params.itemId, type: 'commandExecution' } }, 'delta', message);
        if (state) state.output = (state.output + (params.delta || '')).slice(-256 * 1024);
        break;
      }
      case 'turn/plan/updated': {
        const id = toolId(params.threadId, params.turnId, 'turn-plan');
        const input = { explanation: params.explanation || '', plan: params.plan || [] };
        this.emit('tool.start', { id, name: 'Plan', input }, message);
        break;
      }
      case 'turn/diff/updated':
        this.emit('unknown', { name: method, raw: message }, message);
        break;
      case 'thread/compacted':
        this.notice('info', 'Codex conversation context was compacted.', false, message);
        break;
      case 'thread/name/updated':
        if (params.threadId === this.threadId && this.thread) this.thread.name = params.threadName || params.name || this.thread.name;
        break;
      case 'thread/settings/updated': {
        if (params.threadId !== this.threadId) break;
        const settings = params.threadSettings || {};
        this.model = this.modelsById.get(settings.model) || this.model;
        this.effort = settings.effort || this.effort;
        this.emit('model', { model: this.model?.model || settings.model }, message);
        this.emit('effort', { effort: this.effort || '' }, message);
        break;
      }
      case 'warning': this.notice('info', params.message || 'Codex app-server warning.', false, message); break;
      case 'error': this.notice('error', params.message || params.error?.message || 'Codex app-server error.', false, message); break;
      case 'serverRequest/resolved': {
        const key = this.requestIdKey(params.requestId);
        const approval = this.approvals.get(key);
        if (approval) { this.approvals.delete(key); this.emit('approval.cancel', { id: String(approval.id) }, message); }
        break;
      }
      default:
        // Preserve meaningful unhandled protocol updates for the renderer's
        // bounded unknown-event inspector; routine startup noise is ignored.
        if (!['thread/started', 'thread/status/changed', 'project/changed', 'fs/changed', 'mcpServer/startupStatus/updated'].includes(method)) {
          this.emit('unknown', { name: method || 'unnamed notification', raw: message }, message);
        }
    }
  }

  mergeRateLimit(plan, snapshot) {
    if (!snapshot) return plan;
    const limits = plan.limits.filter(limit => limit.limitId !== (snapshot.limitId || 'default'));
    for (const [kind, window] of [['primary', snapshot.primary], ['secondary', snapshot.secondary]]) {
      if (window) limits.push({ kind, limitId: snapshot.limitId || 'default', label: [snapshot.limitName || snapshot.limitId, window.windowDurationMins ? `${window.windowDurationMins / 60}h` : kind].filter(Boolean).join(' · '),
        percent: Number(window.usedPercent) || 0,
        resets_at: window.resetsAt == null ? null : Number(window.resetsAt) * (Number(window.resetsAt) < 10_000_000_000 ? 1000 : 1),
        is_active: true });
    }
    return { ...plan, available: limits.length > 0, ...(snapshot.planType ? { subscription: snapshot.planType } : {}), limits };
  }

  handleServer(event) {
    if (event.kind === 'notification') this.onNotification(event.message);
    else if (event.kind === 'serverRequest') this.serverRequest(event.message);
    else if (event.kind === 'invalid') this.notice('error', event.message, false, { type: 'app-server.protocol.invalid' });
    else if (event.kind === 'exit') this.onExit(event.error);
  }

  onExit(error) {
    if (this.failureSent || this.closing) return;
    this.failureSent = true;
    if (this.active) this.endTurn(this.active, 'error', `Codex app-server stopped: ${plainError(error)}`, { type: 'app-server.exit' });
    else this.notice('error', `Codex app-server stopped: ${plainError(error)}`, true, { type: 'app-server.exit' });
  }

  async handleControl(message) {
    if (message.type === 'start') return this.start(message);
    if (this.starting) { this.startQueue.push(message); return; }
    if (!this.started && !['user'].includes(message.type)) return;
    try {
      switch (message.type) {
        case 'user': return this.user(message.text);
        case 'interrupt': return this.interruptActive();
        case 'permission': return this.permission(message);
        case 'setModel': {
          const model = this.resolveModel(message.model || '', true);
          if (model === false) return;
          this.model = model;
          const choices = model?.supportedReasoningEfforts?.map(option => option.reasoningEffort) || [];
          if (this.effort && !choices.includes(this.effort)) this.effort = null;
          this.emit('model', { model: model?.model || '' }, { type: 'model.selected', model: model?.model || '' });
          this.emit('effort', { effort: this.effort || '' }, { type: 'effort.model-default', effort: this.effort });
          if (this.active) this.notice('info', 'Model change applies to the next turn.');
          return;
        }
        case 'setEffort': {
          const effort = this.resolveEffort(message.effort || '', this.model, true);
          if (effort === false) return;
          this.effort = effort;
          this.emit('effort', { effort: this.effort || '' }, { type: 'effort.selected', effort: this.effort });
          if (this.active) this.notice('info', 'Reasoning effort change applies to the next turn.');
          return;
        }
        case 'setPermissionMode': {
          if (!['default', 'plan'].includes(message.mode)) { this.notice('error', 'Codex supports Workspace write and Read only permission modes.'); return; }
          this.permissionMode = message.mode;
          this.emit('mode', { mode: this.permissionMode }, { type: 'permission-mode.selected', mode: this.permissionMode,
            sandbox: this.currentSandbox(), approvalPolicy: 'on-request' });
          if (this.active) this.notice('info', 'Permission mode change applies to the next turn.');
          return;
        }
        case 'setThinking':
          this.thinkingOn = !!message.on;
          this.emit('thinking', { on: this.thinkingOn, source: 'user' }, { type: 'reasoning-summary.selected', on: this.thinkingOn });
          if (this.active) this.notice('info', 'Reasoning summary change applies to the next turn.');
          return;
        case 'usage': return message.plan || !this.plan ? this.readRateLimits(true) : this.emitUsage();
        case 'git': return this.git();
        case 'sessions': return this.sessions();
        case 'history': return this.transition(() => this.history(message.sessionId));
        case 'fork': return this.transition(() => this.fork());
        case 'newConversation': return this.transition(() => this.newConversation());
        case 'compact': return this.transition(() => this.compact());
        default: this.notice('info', `Unsupported Codex control: ${message.type || 'unknown'}.`);
      }
    } catch (error) {
      this.notice('error', `Codex operation failed: ${plainError(error)}`, false, { type: 'control.error', control: message.type });
    }
  }

  async transition(operation) {
    if (this.transitioning || this.active) {
      this.notice('info', 'Wait for the current operation to finish.');
      return;
    }
    this.transitioning = true;
    this.emit('turn.start', { local: true });
    try { await operation(); }
    finally {
      this.transitioning = false;
      if (!this.active) this.emit('turn.end', { status: 'success', local: true });
    }
  }

  async shutdown() {
    if (this.closing) return;
    this.closing = true;
    process.stdin.destroy();
    if (this.active?.id) {
      try { await this.rpc.request('turn/interrupt', { threadId: this.threadId, turnId: this.active.id }, 1000); }
      catch { /* process cleanup below is authoritative */ }
    }
    await this.rpc?.stop();
  }
}

const bridge = new CodexBridge();
process.stdout.on('error', () => { void bridge.shutdown(); });
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  let message;
  try { message = JSON.parse(line); }
  catch { bridge.notice('error', 'Invalid Codex control message.'); return; }
  if (!message || typeof message !== 'object' || Array.isArray(message)) {
    bridge.notice('error', 'Invalid Codex control message.'); return;
  }
  void bridge.handleControl(message);
});
input.on('close', () => { void bridge.shutdown(); });
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { void bridge.shutdown(); });
