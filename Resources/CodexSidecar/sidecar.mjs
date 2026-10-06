import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { randomUUID } from 'node:crypto';
import { readFile, stat } from 'node:fs/promises';
import { extname } from 'node:path';
import { StringDecoder } from 'node:string_decoder';
import { hostToolSpecs, hostToolArguments, toolResult } from './host-tools.mjs';
import { eventRoutes, safePayload } from './event-routes.mjs';

// FloatyTerm <-> Codex app-server bridge. App-server speaks newline-delimited
// JSON-RPC on stdio; this process owns one persistent connection and exposes a
// small, versioned event stream to the native host.
const MAX_LINE_BYTES = 8 * 1024 * 1024;
const STDERR_BYTES = 4000;
const REQUEST_TIMEOUT_MS = 30_000;
const HISTORY_TURN_LIMIT = 300;
const HISTORY_ITEM_LIMIT = 5000;
const SHELL_MAX = 1 << 20;

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
  slashCommands: true, midTurnInput: true, images: true, mentions: true, rename: true, shell: true,
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
    this.catalog = { skills: [], apps: [], plugins: [], mcp: [] };
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
    this.childParents = new Map();
    this.tasks = new Map();
    this.shells = new Map();
    this.processStreams = new Map();
    this.hostCalls = new Map();
    this.hostRequests = new Map();
    this.hostToolsEnabled = false;
    this.nativeAudio = false;
    this.voice = null;
    this.voiceStop = null;
    this.voiceStarting = null;
    this.voiceBlocked = false;
    this.accountBusy = false;
    this.loginId = null;
    this.loginEpoch = 0;
    this.authMode = null;
    this.latestUsage = null;
    this.plan = null;
    this.failureSent = false;
    this.transitioning = false;
  }

  emit(type, fields = {}, raw = undefined) {
    output({ type, ...this.eventScope, ...fields, raw: safePayload(raw ?? { type: 'codex.app-server', event: type }) });
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
    this.hostToolsEnabled = message.hostTools === true;
    this.nativeAudio = message.nativeAudio === true;
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
      await this.readAccount(false);
      void this.loadCatalog();
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
    const features = { ...featureSet, realtimeVoice: this.nativeAudio, credentials: true, models: this.models.length > 0, effort: this.models.length > 0 };
    this.emit('capabilities', {
      features, commands: COMMANDS, models: this.modelRows(), mode: this.permissionMode,
      permissionModes: ['default', 'plan'],
      hostTools: this.hostToolsEnabled ? hostToolSpecs : [],
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
    await this.stopRealtime();
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
      response = await this.rpc.request('thread/start', { ...common, ...(this.hostToolsEnabled ? { dynamicTools: hostToolSpecs } : {}) });
    }
    this.applyThread(response, { emitSession: true });
    if (this.hostToolsEnabled) this.surfaceEvent('item/tool/call', { threadId: this.threadId, status: 'available', hostTools: hostToolSpecs.map(tool => ({ name: tool.name, description: tool.description })), registration: message.resume || message.fork ? 'Tools are advertised on thread/start only. Resume/fork do not add this catalog; use a new conversation.' : 'Registered with this new conversation.' });
  }

  applyThread(response, { emitSession = true } = {}) {
    const thread = response?.thread;
    if (!thread?.id) throw new Error('Codex app-server did not return a thread id.');
    if (this.threadId !== thread.id) { this.cancelHostTools('Conversation changed.'); this.items.clear(); this.childParents.clear(); this.tasks.clear(); this.processStreams.clear(); this.latestUsage = null; this.cancelApprovals(); }
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

  /** @-mention suggestions: Codex's own fuzzy file search over the session folder. */
  async files(message) {
    const query = String(message.query || '');
    let suggestions = [];
    try {
      const result = await this.rpc.request('fuzzyFileSearch', { query: query || '.', roots: [this.config.cwd] });
      suggestions = (result?.files || []).slice().sort((a, b) => (b.score || 0) - (a.score || 0)).slice(0, 30).map(file => ({ path: file.path }));
    } catch (error) { this.emit('files', { id: message.id, query, suggestions: [], error: plainError(error) }, { type: 'files.error' }); return; }
    this.emit('files', { id: message.id, query, suggestions }, { type: 'files.result' });
  }

  async title() {
    try {
      const result = await this.rpc.request('thread/read', { threadId: this.threadId, includeTurns: false });
      const thread = result?.thread || this.thread || {};
      this.emit('title', { sessionId: this.threadId, title: thread.name || thread.preview || '', custom: !!thread.name }, { type: 'title.read' });
    } catch (error) { this.notice('info', `Could not read the conversation name: ${plainError(error)}`); }
  }

  async rename(message) {
    const name = String(message.title || '').trim();
    if (!name || !this.threadId) return;
    try {
      await this.rpc.request('thread/name/set', { threadId: this.threadId, name });
      if (this.thread) this.thread.name = name;
      this.emit('title', { sessionId: this.threadId, title: name, custom: true }, { type: 'title.set' });
    } catch (error) { this.notice('error', `Rename failed: ${plainError(error)}`); }
  }

  /** `!command` in the composer: runs in the session folder; output streams back to the page. */
  runShell(message) {
    const id = String(message.id || ''), command = String(message.command || '').trim();
    const done = fields => this.emit('shell', { id, done: true, code: null, ...fields }, { type: 'shell.done' });
    if (!id || !command) return done({ error: 'no command' });
    let child;
    try { child = spawn(process.env.SHELL || '/bin/zsh', ['-lc', command], { cwd: this.config.cwd, env: process.env, stdio: ['ignore', 'pipe', 'pipe'], detached: true }); }
    catch (error) { return done({ error: error.message }); }
    this.shells.set(id, child);
    const sizes = { stdout: 0, stderr: 0 };
    for (const stream of ['stdout', 'stderr']) child[stream].on('data', data => {
      if (sizes[stream] >= SHELL_MAX) return;
      const chunk = data.toString('utf8').slice(0, SHELL_MAX - sizes[stream]);
      sizes[stream] += chunk.length;
      this.emit('shell', { id, stream, chunk }, { type: 'shell.output' });
    });
    child.on('error', error => { this.shells.delete(id); done({ error: error.message }); });
    child.on('close', (code, signal) => { if (this.shells.delete(id)) done({ code, signal: signal || null }); });
  }

  killShell(id) {
    const child = this.shells.get(String(id));
    if (!child) return;
    try { process.kill(-child.pid, 'SIGTERM'); } catch { try { child.kill('SIGTERM'); } catch { /* already gone */ } }
  }

  /** Skills, apps, plugins and MCP servers: what `/` and `$` offer, and what the integrations panel lists. */
  async loadCatalog() {
    if (!this.rpc || this.rpc.dead || !this.config) return;
    const cwd = this.config.cwd;
    const [skills, apps, plugins, mcp] = await Promise.allSettled([
      this.rpc.request('skills/list', { cwds: [cwd] }),
      this.rpc.request('app/list', { limit: 100, ...(this.threadId ? { threadId: this.threadId } : {}) }),
      this.rpc.request('plugin/installed', { cwds: [cwd] }),
      this.rpc.request('mcpServerStatus/list', { limit: 100 }),
    ]);
    const ok = r => r.status === 'fulfilled' ? r.value || {} : {};
    this.catalog = {
      skills: (ok(skills).data || []).flatMap(entry => entry.skills || []).filter(skill => skill?.name && skill.path && skill.enabled !== false)
        .map(skill => ({ name: skill.name, description: skill.interface?.shortDescription || skill.shortDescription || skill.description || '',
          displayName: skill.interface?.displayName || null, path: skill.path, scope: skill.scope || null, pluginId: skill.pluginId || null })),
      apps: (ok(apps).data || []).filter(app => app?.id && app.isEnabled !== false && app.isAccessible !== false)
        .map(app => ({ id: app.id, name: app.name, description: app.description || '', path: 'app://' + app.id })),
      plugins: (ok(plugins).marketplaces || []).flatMap(market => (market.plugins || []).filter(plugin => plugin.installed && plugin.enabled)
        .map(plugin => ({ id: plugin.id, name: plugin.interface?.displayName || plugin.name, description: plugin.interface?.shortDescription || '',
          marketplace: market.name, path: 'plugin://' + plugin.id }))),
      mcp: (ok(mcp).data || []).map(server => ({ name: server.name, status: server.runtimeStatus || 'notStarted', auth: server.authStatus || null,
        tools: Object.keys(server.tools || {}), resources: (server.resources || []).length, error: server.toolsError || null, pluginId: server.pluginId || null })),
    };
    this.emit('catalog', this.catalog, { type: 'catalog.snapshot' });
  }

  /** `$name` in the text becomes a structured skill, app or plugin input, as the Codex TUI does. */
  mentionInputs(text) {
    const out = [], seen = new Set();
    for (const match of text.matchAll(/(^|\s)\$([A-Za-z0-9][\w.:-]*)/g)) {
      const name = match[2].toLowerCase();
      if (seen.has(name)) continue;
      seen.add(name);
      const skill = this.catalog.skills.find(item => item.name.toLowerCase() === name);
      if (skill) { out.push({ type: 'skill', name: skill.name, path: skill.path }); continue; }
      const slug = value => String(value || '').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
      const hit = this.catalog.apps.find(item => slug(item.name) === name) || this.catalog.plugins.find(item => slug(item.name) === name);
      if (hit) out.push({ type: 'mention', name: hit.name, path: hit.path });
    }
    return out;
  }

  async user(text, images = []) {
    if (!this.started || !this.threadId) { this.notice('error', 'Codex app-server is not ready.', true); return; }
    if (this.transitioning) { this.notice('info', 'Wait for the conversation operation to finish.'); return; }
    const pictures = (Array.isArray(images) ? images : []).filter(image => image && /^image\/(png|jpeg|gif|webp)$/.test(image.mediaType) && typeof image.data === 'string' && image.data)
      .map(image => ({ type: 'image', url: `data:${image.mediaType};base64,${image.data}` }));
    if (typeof text !== 'string' || (!text.trim() && !pictures.length)) return;
    const input = [...pictures, ...(text.trim() ? [{ type: 'text', text, text_elements: [] }] : []), ...this.mentionInputs(text)];
    if (this.active) {
      // A message while it works joins the running turn (turn/steer), as in the Codex TUI.
      if (!this.active.id || this.active.ended) { this.notice('info', 'Codex is still starting this turn. Try again in a moment.'); return; }
      try { await this.rpc.request('turn/steer', { threadId: this.threadId, expectedTurnId: this.active.id, input, clientUserMessageId: randomUUID() }); }
      catch (error) { this.notice('warn', `Could not add to this turn: ${plainError(error)}`, false, { type: 'turn/steer.error' }); }
      return;
    }
    this.items.clear();
    const turn = { id: null, started: false, ended: false, interruptRequested: false, usage: null };
    this.active = turn;
    try {
      const model = this.model?.model;
      const effort = this.effort || this.modelsById.get(model)?.defaultReasoningEffort || this.configEffort || undefined;
      const summary = this.thinkingOn ? (this.configSummary && this.configSummary !== 'none' ? this.configSummary : 'detailed') : 'none';
      const params = {
        threadId: this.threadId,
        input,
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
    this.cancelHostTools('Host tool cancelled by interruption.');
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
    this.cancelHostTools('Turn ended before the host tool completed.', this.threadId, turn.id);
    this.emit('turn.end', {
      threadId: this.threadId, turnId: turn.id,
      status,
      ...(message ? { message } : {}),
      ...(serverTurn?.durationMs != null ? { durationMs: serverTurn.durationMs } : {}),
      ...(turn.usage ? { usage: turn.usage } : {}),
    }, raw);
    if (this.closing) void this.rpc?.stop();
  }

  onUsage(params, raw) {
    if (params.threadId !== this.threadId) { this.surfaceEvent('thread/tokenUsage/updated', params); return; }
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
          const events = [{ type: 'turn.start', threadId: sessionId, turnId: turn.id }];
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
    const details = this.toolDetails(item, { output: '' });
    const route = eventRoutes[item.type];
    const result = details ? [
      { type: 'tool.start', id, name: details.name, input: details.input },
      { type: 'tool.result', id, name: details.name, output: details.output || '', isError: !!details.isError },
    ] : [];
    if (route) result.push({ type: 'surface.snapshot', id: 'history:' + id, surface: route.surface, title: route.title, method: item.type,
      threadId, turnId, ownerId: details ? id : null, data: { item: safePayload(item) } });
    else result.push({ type: 'unknown', name: `history:${item.type}`, raw: safePayload(item) });
    return result;
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
    const key = this.requestIdKey(id);
    const parentId = this.childParents.get(params.threadId);
    if (params.threadId && params.threadId !== this.threadId && !parentId) {
      this.rpc.rejectRequest(id, -32602, 'Request belongs to another conversation.'); return;
    }
    if (this.hostRequests.has(key)) { this.notice('error', 'Duplicate pending host tool request ignored.'); return; }
    if (this.approvals.has(key)) {
      this.rpc.rejectRequest(id, -32600, 'Duplicate request id.'); return;
    }
    if (parentId) params.parentId = parentId;
    if (method === 'currentTime/read') {
      this.rpc.respond(id, { currentTimeAt: Math.floor(Date.now() / 1000) });
      this.surfaceEvent(method, { status: 'completed', message: 'Host time supplied.' }); return;
    }
    if (method === 'item/tool/call') { this.startHostTool(message); return; }
    if (method === 'account/chatgptAuthTokens/refresh') {
      this.rpc.rejectRequest(id, -32601, 'FloatyTerm uses Codex-managed sign-in, not externally supplied tokens.');
      this.accountState({ status: 'reauthenticationRequired', message: 'Sign in with ChatGPT to use Codex-managed credential renewal.' }); return;
    }
    if (method === 'attestation/generate') {
      this.rpc.rejectRequest(id, -32601, 'This host does not supply external authentication or attestation.');
      this.surfaceEvent(method, { status: 'unavailable', message: 'A host attestation provider is not configured.' }); return;
    }
    const supported = ['item/commandExecution/requestApproval', 'item/fileChange/requestApproval', 'item/tool/requestUserInput',
      'item/permissions/requestApproval', 'mcpServer/elicitation/request', 'execCommandApproval', 'applyPatchApproval'];
    if (!supported.includes(method)) {
      this.rpc.rejectRequest(id, -32601, `Unsupported operation: ${method}`);
      this.notice('error', `Codex requested an unsupported operation (${method}); it was rejected.`, false, { method }); return;
    }
    const uiId = 'rpc:' + encodeURIComponent(key);
    const itemId = params.itemId || params.callId;
    const itemInput = this.items.get(toolId(params.threadId || this.threadId, params.turnId, itemId))?.input;
    const kind = method === 'item/tool/requestUserInput' ? 'questions' : method === 'item/permissions/requestApproval' ? 'permissions'
      : method === 'mcpServer/elicitation/request' ? 'elicitation' : 'approval';
    const request = { id: uiId, nativeId: id, kind, method, threadId: params.threadId || this.threadId, turnId: params.turnId,
      toolUseID: itemId ? toolId(params.threadId || this.threadId, params.turnId, itemId) : null,
      toolName: kind === 'approval' ? (method.includes('fileChange') || method === 'applyPatchApproval' ? 'File changes' : 'Bash') : kind,
      input: kind === 'approval' ? { ...(itemInput || {}), ...safePayload(params), ...(params.fileChanges ? { changes: params.fileChanges } : {}) } : safePayload(params),
      decisionReason: params.reason || params.message || '', blocking: params.isBlocking !== false, suppressAlwaysAllowRule: true };
    this.approvals.set(key, { id, method, request, params });
    // Secret questions must never be copied into diagnostic provenance.
    this.emit('approval.request', { request, ...(parentId ? { parentId } : {}) }, { method, requestId: uiId });
  }

  startHostTool(message) {
    const { id, params = {} } = message;
    const key = this.requestIdKey(id);
    if (this.hostRequests.has(key)) { this.notice('error', 'Duplicate host tool request ignored.'); return; }
    const ownerId = toolId(params.threadId, params.turnId, params.callId);
    const scope = { threadId: params.threadId, turnId: params.turnId, ...(this.childParents.get(params.threadId) ? { parentId: this.childParents.get(params.threadId) } : {}) };
    let argumentsValue;
    try {
      if (!this.hostToolsEnabled) throw new Error('Native host tools are not connected.');
      if (typeof params.callId !== 'string' || !params.callId || !params.turnId) throw new Error('Host tool call identity is missing.');
      argumentsValue = hostToolArguments(params.tool, params.namespace, params.arguments);
    } catch (error) {
      const result = toolResult(false, plainError(error));
      this.rpc.respond(id, result);
      this.emit('tool.start', { ...scope, id: ownerId, name: params.tool || 'Host tool', input: safePayload(params.arguments) }, { method: 'item/tool/call' });
      this.emit('tool.result', { ...scope, id: ownerId, name: params.tool || 'Host tool', output: result.contentItems[0].text, isError: true }, { method: 'item/tool/call' });
      return;
    }
    const requestId = randomUUID();
    const call = { requestId, nativeId: id, key, ownerId, scope, tool: params.tool, expiresAt: Date.now() + 10000 };
    this.hostCalls.set(requestId, call); this.hostRequests.set(key, requestId);
    call.timer = setTimeout(() => this.finishHostTool(requestId, toolResult(false, 'Native host tool timed out.')), 10000);
    call.timer.unref();
    this.emit('tool.start', { ...scope, id: ownerId, name: params.tool, input: argumentsValue }, { method: 'item/tool/call' });
    this.emit('host.tool.request', { ...scope, requestId, rootThreadId: this.threadId, expiresAt: call.expiresAt, model: this.model?.model || null, permissionMode: this.permissionMode, tool: params.tool, arguments: argumentsValue }, { type: 'host.tool.dispatch' });
  }

  finishHostTool(requestId, result, respond = true) {
    const call = this.hostCalls.get(requestId); if (!call) return;
    this.hostCalls.delete(requestId); this.hostRequests.delete(call.key); clearTimeout(call.timer);
    if (respond && !this.rpc.dead) {
      try { this.rpc.respond(call.nativeId, result); }
      catch (error) { result = toolResult(false, 'Host action finished but its result could not be delivered: ' + plainError(error)); this.notice('error', result.contentItems[0].text); }
    }
    this.emit('tool.result', { ...call.scope, id: call.ownerId, name: call.tool, output: result.contentItems[0]?.text || '', isError: !result.success }, { type: 'host.tool.result' });
  }

  hostToolResult(message) {
    if (!this.hostCalls.has(message.requestId)) return; // stale, cancelled or duplicate native result
    if (typeof message.success !== 'boolean' || typeof message.text !== 'string' || message.text.length > 64000) {
      this.finishHostTool(message.requestId, toolResult(false, 'Invalid native host tool result.')); return;
    }
    this.finishHostTool(message.requestId, toolResult(message.success, message.text));
  }

  cancelHostTools(reason, threadId = null, turnId = null, respond = true) {
    for (const [id, call] of this.hostCalls) {
      if (threadId && call.scope.threadId !== threadId || turnId && call.scope.turnId !== turnId) continue;
      this.finishHostTool(id, toolResult(false, reason), respond);
    }
  }

  permission(message) {
    const match = [...this.approvals.entries()].find(([, approval]) => approval.request.id === message.id);
    if (!match) { this.notice('info', 'This request is no longer active.'); return; }
    const [key, approval] = match;
    const { method, params } = approval;
    let result;
    try {
      if (method === 'item/tool/requestUserInput') {
        const answers = message.response?.answers;
        if (!answers || typeof answers !== 'object') throw new Error('Answers are required.');
        for (const q of params.questions || []) {
          if (!Array.isArray(answers[q.id]?.answers) || !answers[q.id].answers.every(v => typeof v === 'string')) throw new Error('Each question needs text answers.');
        }
        result = { answers };
      } else if (method === 'item/permissions/requestApproval') {
        const allowed = message.decision === 'allow';
        result = { permissions: allowed ? params.permissions : {}, scope: message.response?.scope === 'session' ? 'session' : 'turn' };
      } else if (method === 'mcpServer/elicitation/request') {
        const action = message.response?.action;
        if (!['accept', 'decline', 'cancel'].includes(action)) throw new Error('Invalid elicitation action.');
        if (params.mode === 'openai/userVerification' && action === 'accept') throw new Error('Device verification requires a host authenticator.');
        result = { action, ...(action === 'accept' ? { content: message.response?.content ?? null } : {}) };
      } else {
        const legacy = method === 'execCommandApproval' || method === 'applyPatchApproval';
        let decision = message.response?.decision ?? (message.decision === 'allow' ? 'accept' : 'decline');
        const offered = params.availableDecisions || ['accept', 'acceptForSession', 'decline', 'cancel'];
        if (!offered.some(d => JSON.stringify(d) === JSON.stringify(decision))) throw new Error('That decision was not offered by Codex.');
        if (legacy) decision = ({ accept: 'approved', acceptForSession: 'approved_for_session', decline: { denied: { rejection: 'User declined.' } }, cancel: 'abort' })[decision];
        result = { decision };
      }
      if (typeof message.message === 'string' && message.message.trim()) this.notice('info', 'Codex approval feedback is not supported by this request; the decision was sent.');
      this.rpc.respond(approval.id, result);
      this.approvals.delete(key);
      this.emit('approval.cancel', { id: approval.request.id }, { type: 'request.resolved' });
    } catch (error) {
      this.notice('error', `Could not answer request: ${plainError(error)}`);
      this.emit('approval.request', { request: approval.request }, { type: 'request.retry' });
    }
  }

  cancelApprovals() {
    for (const [, approval] of this.approvals) this.emit('approval.cancel', { id: approval.request.id }, { type: 'approval.cancelled' });
    this.approvals.clear();
  }

  /** Child agents as tasks: the page draws their avatars and panel from task.start, task.progress and task.end. */
  emitTasks(item, state, raw) {
    const ended = { completed: 'completed', errored: 'failed', interrupted: 'stopped', shutdown: 'stopped', notFound: 'failed' };
    for (const child of item.receiverThreadIds || []) {
      const agent = item.agentsStates?.[child] || {};
      const task = this.tasks.get(child) || { started: false, ended: false };
      this.tasks.set(child, task);
      const base = { taskId: child, toolId: state.id, description: String(item.prompt || '').replace(/\s+/g, ' ').slice(0, 160) };
      if (!task.started) { task.started = true; this.emit('task.start', { ...base, taskType: 'agent', subagentType: item.tool === 'spawnAgent' ? 'agent' : String(item.tool || 'agent') }, raw); }
      if (agent.status && ended[agent.status] && !task.ended) {
        task.ended = true;
        this.emit('task.end', { ...base, status: ended[agent.status], summary: agent.message || '' }, raw);
      } else if (!task.ended && agent.message && agent.message !== task.message) {
        task.message = agent.message;
        this.emit('task.progress', { ...base, summary: agent.message }, raw);
      }
    }
  }

  ensureItem(params, type, raw) {
    const { item, threadId, turnId } = params;
    if (!item?.id) return null;
    const id = toolId(threadId, turnId, item.id);
    let state = this.items.get(id);
    if (!state) {
      state = { id, itemId: item.id, threadId, turnId, parentId: this.childParents.get(threadId), type: item.type, kind: null, text: '', output: '', input: null, started: false, finished: false };
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
    if (item.type === 'userMessage') return; // The optimistic prompt already owns this user message.
    if (item.type === 'collabAgentToolCall') {
      for (const child of item.receiverThreadIds || []) this.childParents.set(child, state.id);
      this.emitTasks(item, state, raw);
    }
    if (item.type === 'imageView' || (item.type === 'imageGeneration' && phase === 'completed')) void this.emitImage(item, state, raw);
    if (['mcpToolCall','dynamicToolCall','webSearch','collabAgentToolCall','functionCallOutput','hookPrompt','enteredReviewMode','exitedReviewMode'].includes(item.type)) this.surfaceEvent(item.type, { ...params, item: safePayload(item) }, { method: item.type });
    if (item.type === 'subAgentActivity') this.surfaceEvent(item.type, { ...params, ...item }, raw);
    if (item.type === 'agentMessage' && (item.memoryCitation || item.questions || item.phase)) {
      this.surfaceEvent(item.type, { ...params, item: { memoryCitation: item.memoryCitation, questions: item.questions, phase: item.phase } }, raw);
    }
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
      raw = { method: 'item/' + phase, threadId: params.threadId, turnId: params.turnId, itemId: item.id, summaryOnly: true };
      this.emitContentStart(state, 'thinking', raw);
      const text = Array.isArray(item.summary) ? item.summary.map(p => typeof p === 'string' ? p : p?.text || '').join('\n') : state.text;
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
      this.surfaceEvent(item.type || `item.${phase}`, { ...params, item, status: phase }, raw);
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
      case 'collabAgentToolCall': return { name: 'Agent', input: { subagent_type: item.tool || 'Agent', description: 'Child agent activity', prompt: item.prompt || '', model: item.model, agentsStates: item.agentsStates, receiverThreadIds: item.receiverThreadIds }, output: toText(item.agentsStates), isError: item.status === 'failed' };
      case 'functionCallOutput': return { name: item.name || 'Tool output', input: { namespace: item.namespace }, output: toText(item.output), isError: false };
      case 'hookPrompt': return { name: 'Hook prompt', input: { fragments: item.fragments }, output: toText(item.fragments), isError: false };
      case 'sleep': return { name: 'Wait', input: { durationMs: item.durationMs }, output: `Waited ${item.durationMs || 0} ms`, isError: false };
      case 'enteredReviewMode': case 'exitedReviewMode': return { name: 'Review', input: { review: item.review }, output: toText(item.review), isError: false };
      case 'imageView': case 'imageGeneration': return { name: item.type === 'imageView' ? 'View image' : 'Generate image', input: { path: item.path || item.savedPath, prompt: item.revisedPrompt }, output: toText(item.failure || item.status), isError: !!item.failure || item.status === 'failed' };
      default: return null;
    }
  }

  surfaceEvent(method, params, raw = { method }) {
    if (method === 'thread/realtime/outputAudio/delta') params = { ...params, audio: { sampleRate: params.audio?.sampleRate, numChannels: params.audio?.numChannels, samplesPerChannel: params.audio?.samplesPerChannel, playback: this.nativeAudio ? 'Native FloatyTerm audio' : 'Audio transport is not connected in this host.' } };
    const route = eventRoutes[method];
    if (!route) { this.emit('unknown', { name: method }, { method, params: safePayload(params) }); return; }
    const scope = params.threadId || this.threadId || 'account';
    const owner = method.startsWith('thread/realtime/transcript/') ? 'transcript:' + (params.role || 'assistant') : params.itemId || params.item?.id || params.reviewId || params.run?.id || params.processHandle || params.processId || params.subscriptionId || params.importId || params.name || params.providerId || params.attachmentId || (route.surface === 'realtime' && !method.endsWith('/delta') ? 'session' : ['thread/goal/updated','thread/goal/cleared','thread/queue/changed'].includes(method) ? '' : method);
    const id = JSON.stringify([scope, route.surface, owner, ['goal','queue'].includes(route.surface) ? '' : params.turnId || '']);
    this.emit('surface.snapshot', { ...(this.childParents.get(params.threadId) ? { parentId: this.childParents.get(params.threadId) } : {}), id, surface: route.surface, title: route.title, method, threadId: params.threadId,
      turnId: params.turnId, itemId: params.itemId || params.item?.id, ownerId: (params.itemId || params.item?.id) ? toolId(params.threadId || this.threadId, params.turnId, params.itemId || params.item.id) : null, placement: ['status','session','goal','queue','account','environment','integrations','realtime'].includes(route.surface) && !params.itemId ? 'session' : 'turn', data: safePayload(params), clear: method === 'thread/goal/cleared' }, { method });
  }

  async emitImage(item, state, raw) {
    const path = item.path || item.savedPath;
    const types = { '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp' };
    let url = null, error = null;
    try {
      if (path && types[extname(path).toLowerCase()] && (await stat(path)).size <= 8 * 1024 * 1024) {
        url = `data:${types[extname(path).toLowerCase()]};base64,${(await readFile(path)).toString('base64')}`;
      } else if (item.result && /^[A-Za-z0-9+/=]+$/.test(item.result) && item.result.length <= 11 * 1024 * 1024) url = 'data:image/png;base64,' + item.result;
      else error = 'Image preview is not available.';
    } catch { error = 'Image could not be loaded.'; }
    this.emit('media.snapshot', { id: state.id, threadId: state.threadId, turnId: state.turnId, parentId: state.parentId,
      url, path, caption: item.revisedPrompt || path || 'Image', error }, { type: 'media' });
  }

  onNotification(message) {
    const params = message.params || {};
    const parentId = this.childParents.get(params.threadId);
    if (params.threadId && params.threadId !== this.threadId && !parentId) return;
    const previous = this.eventScope;
    this.eventScope = { ...(params.threadId ? { threadId: params.threadId } : {}), ...(params.turnId ? { turnId: params.turnId } : {}), ...(parentId ? { parentId } : {}) };
    try { this.dispatchNotification(message); } finally { this.eventScope = previous; }
  }

  dispatchNotification(message) {
    const { method, params = {} } = message;
    if (method.startsWith('thread/realtime/') && params.threadId === this.threadId) {
      const voice = this.voice;
      if (method === 'thread/realtime/started' && voice && !voice.ready) {
        clearTimeout(voice.timer); voice.ready = true;
        this.emit('native.realtime', { requestId: voice.id, threadId: voice.threadId, state: 'active' });
        this.voiceState('active');
      }
      if (voice?.ready && params.role === 'user' && method === 'thread/realtime/transcript/delta' && !voice.userTranscriptOpen) {
        voice.userTranscriptOpen = true;
        this.emit('native.realtime', { requestId: voice.id, threadId: voice.threadId, state: 'clearPlayback' });
      }
      if (voice && params.role === 'user' && method === 'thread/realtime/transcript/done') voice.userTranscriptOpen = false;
      if (method === 'thread/realtime/outputAudio/delta') {
        if (voice?.ready && !voice.stopping) this.emit('native.realtime', { requestId: voice.id, threadId: voice.threadId, state: 'audio', audio: params.audio });
        // Keep bytes entirely in native IPC; the DOM receives metadata at most once/second.
        if (voice && Date.now() - (voice.lastOutput || 0) > 1000) { voice.lastOutput = Date.now(); this.surfaceEvent(method, params); }
        return;
      }
      if (method === 'thread/realtime/closed' || method === 'thread/realtime/error') {
        if (voice) this.retireVoice(voice, method.endsWith('/error') ? 'error' : 'closed', params.message || params.error || params.reason);
      }
    }
    switch (method) {
      case 'account/updated':
        this.authMode = params.authMode; void this.readAccount(false); this.surfaceEvent(method, params); break;
      case 'account/login/completed':
        this.loginEpoch++;
        if (params.loginId === this.loginId) this.loginId = null;
        this.accountState({ status: params.success ? 'signedIn' : 'error', message: params.success ? 'Signed in.' : params.error || 'Sign-in failed.' });
        if (params.success) { void this.readAccount(false); void this.readRateLimits(false); }
        break;
      case 'thread/tokenUsage/updated': this.onUsage(params, message); break;
      case 'account/rateLimits/updated':
        if (this.plan) {
          const old = this.plan;
          this.plan = this.mergeRateLimit(old, params.rateLimits);
          this.emitUsage();
        } else void this.readRateLimits(false);
        break;
      case 'turn/started':
        if (params.threadId !== this.threadId) this.emit('turn.start', { threadId: params.threadId, turnId: params.turn?.id }, { method });
        else this.onTurnStarted(params, message); break;
      case 'turn/completed':
        if (params.threadId !== this.threadId) this.emit('turn.end', { threadId: params.threadId, turnId: params.turn?.id, status: params.turn?.status === 'completed' ? 'success' : 'error' }, { method });
        else this.onTurnCompleted(params, message);
        this.cancelHostTools('Child turn ended before the host tool completed.', params.threadId, params.turn?.id); break;
      case 'item/plan/delta': {
        const state = this.ensureItem({ ...params, item: { id: params.itemId, type: 'plan' } }, 'delta', message);
        if (!state) break;
        state.text += params.delta || '';
        this.emit('tool.input', { id: state.id, name: 'Plan', input: { text: state.text } }, { method }); break;
      }
      case 'item/fileChange/patchUpdated': {
        const id = toolId(params.threadId, params.turnId, params.itemId);
        const state = this.items.get(id); if (state) state.input = { changes: params.changes || [] };
        this.emit('tool.input', { id, name: 'File changes', input: { changes: params.changes || [] } }, { method }); break;
      }
      case 'item/fileChange/outputDelta':
        this.emit('tool.output.delta', { id: toolId(params.threadId, params.turnId, params.itemId), name: 'File changes', text: params.delta || '' }, { method }); break;
      case 'item/mcpToolCall/progress':
        this.emit('tool.progress', { id: toolId(params.threadId, params.turnId, params.itemId), message: params.message || '' }, { method }); break;
      case 'command/exec/outputDelta': case 'process/outputDelta': {
        const handle = params.processHandle || params.processId;
        const key = JSON.stringify([handle, params.stream]);
        let decoder = this.processStreams.get(key); if (!decoder) { decoder = new StringDecoder('utf8'); this.processStreams.set(key, decoder); }
        this.emit('tool.output.delta', { id: 'process:' + handle, name: 'Process', stream: params.stream,
          text: decoder.write(Buffer.from(params.deltaBase64 || '', 'base64')), capped: !!params.capReached, processHandle: params.processHandle }, { method }); break;
      }
      case 'process/exited': {
        for (const stream of ['stdout','stderr']) {
          const key = JSON.stringify([params.processHandle, stream]);
          const tail = this.processStreams.get(key)?.end();
          if (tail) this.emit('tool.output.delta', { id: 'process:' + params.processHandle, name: 'Process', stream, text: tail }, { method });
          this.processStreams.delete(key);
        }
        // Empty final captures mean output was already streamed; retain it.
        const output = (params.stdout || '') + (params.stderr ? '\n[stderr]\n' + params.stderr : '');
        this.emit('tool.result', { id: 'process:' + params.processHandle, name: 'Process', ...(output ? { output } : {}), isError: params.exitCode !== 0 }, { method }); break;
      }
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
          state.summaryParts ||= new Map();
          const index = params.summaryIndex || 0;
          state.summaryParts.set(index, (state.summaryParts.get(index) || '') + (params.delta || ''));
          state.text = [...state.summaryParts].sort((a,b) => a[0] - b[0]).map(([,text]) => text).join('\n');
          this.emit('content.snapshot', { id: state.id, messageId: state.id, kind: 'thinking', text: state.text }, { method });
        }
        break;
      }
      case 'item/reasoning/textDelta':
      case 'item/reasoning/rawContentDelta':
        // Only the presence of this stream is shown; its text is never retained.
        this.surfaceEvent('item/reasoning/textDelta', { threadId: params.threadId, turnId: params.turnId, itemId: params.itemId,
          contentIndex: params.contentIndex, availability: 'Raw reasoning omitted. Reasoning summaries are shown in the Thinking fold.' }); break;
      case 'item/reasoning/summaryPartAdded':
        this.surfaceEvent(method, { ...params, message: 'Reasoning summary part ' + (params.summaryIndex + 1) }); break;
      case 'item/commandExecution/outputDelta': {
        const state = this.ensureItem({ ...params, item: { id: params.itemId, type: 'commandExecution' } }, 'delta', message);
        if (state) {
          state.output = (state.output + (params.delta || '')).slice(-256 * 1024);
          this.emit('tool.output.delta', { id: state.id, name: 'Bash', text: params.delta || '' }, { method });
        }
        break;
      }
      case 'turn/plan/updated': {
        const id = toolId(params.threadId, params.turnId, 'turn-plan');
        const input = { explanation: params.explanation || '', plan: params.plan || [] };
        this.emit('plan.snapshot', { id, threadId: params.threadId, turnId: params.turnId, ...input }, message);
        break;
      }
      case 'turn/diff/updated':
        this.emit('turn.diff.snapshot', {
          threadId: params.threadId, turnId: params.turnId, diff: params.diff || '',
        }, message);
        break;
      case 'thread/compacted':
        this.notice('info', 'Codex conversation context was compacted.', false, message);
        break;
      case 'thread/name/updated':
        if (params.threadId === this.threadId && this.thread) this.thread.name = params.threadName || params.name || this.thread.name;
        this.emit('title', { title: params.threadName || params.name || '', sessionId: params.threadId, custom: true }, { method }); break;
      case 'thread/settings/updated': {
        this.surfaceEvent(method, params);
        if (params.threadId !== this.threadId) break;
        const settings = params.threadSettings || {};
        this.model = this.modelsById.get(settings.model) || this.model;
        this.effort = settings.effort || this.effort;
        this.emit('model', { model: this.model?.model || settings.model }, message);
        this.emit('effort', { effort: this.effort || '' }, message);
        break;
      }
      case 'warning': this.notice('info', params.message || 'Codex app-server warning.', false, message); break;
      case 'error': this.notice(params.willRetry ? 'warn' : 'error', params.error?.message || params.message || 'Codex app-server error.', false, { method });
        this.surfaceEvent(method, params); break;
      case 'serverRequest/resolved': {
        const key = this.requestIdKey(params.requestId);
        const hostId = this.hostRequests.get(key);
        if (hostId) this.finishHostTool(hostId, toolResult(false, 'Host tool request was resolved by the server.'), false);
        const approval = this.approvals.get(key);
        if (approval) { this.approvals.delete(key); this.emit('approval.cancel', { id: approval.request.id }, message); }
        break;
      }
      default:
        this.surfaceEvent(method || 'unnamed notification', params);
        if (method === 'thread/queue/changed' || method === 'thread/attachment/updated') void this.refreshSurface(method, params);
        if (['skills/changed', 'app/list/updated', 'mcpServer/startupStatus/updated'].includes(method)) this.refreshCatalogSoon();
    }
  }

  refreshCatalogSoon() {
    clearTimeout(this.catalogTimer);
    this.catalogTimer = setTimeout(() => void this.loadCatalog(), 400);
    this.catalogTimer.unref?.();
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

  async refreshSurface(method, params) {
    try {
      const attachment = method === 'thread/attachment/updated';
      const result = await this.rpc.request(attachment ? 'thread/attachment/list' : 'thread/queue/list', { threadId: params.threadId || this.threadId, limit: 100 });
      this.surfaceEvent(method, { ...params, ...result });
    } catch (error) { this.surfaceEvent(method, { ...params, status: 'unavailable', message: plainError(error) }); }
  }

  accountState(data) {
    this.emit('surface.snapshot', { id: 'codex:account:credentials', surface: 'account', title: 'Codex account', method: 'floaty/account', placement: 'session', data: { ...data, loginPending: !!this.loginId } });
  }

  async readAccount(refresh) {
    if (this.accountBusy) return;
    this.accountBusy = true;
    this.accountState({ status: refresh ? 'refreshing' : 'checking', message: refresh ? 'Refreshing credentials…' : 'Checking sign-in…' });
    try {
      if (refresh && this.authMode === 'chatgptAuthTokens') throw new Error('External tokens cannot be refreshed here. Sign in with ChatGPT first.');
      const result = await this.rpc.request('account/read', { refreshToken: refresh });
      const account = result.account ? Object.fromEntries(["type", "email", "planType", "credentialSource"].filter(key => typeof result.account[key] === "string").map(key => [key, result.account[key]])) : null;
      // account/read exposes identity only. Never request or export access tokens.
      this.accountState({ status: account ? 'signedIn' : result.requiresOpenaiAuth ? 'signedOut' : 'notRequired',
        account, requiresOpenaiAuth: result.requiresOpenaiAuth,
        message: refresh ? account?.type === 'chatgpt' ? 'Managed credentials refreshed.' : 'Account checked; refresh applies to managed ChatGPT credentials.' : account ? 'Signed in.' : 'No Codex account is signed in.' });
    } catch (error) { this.accountState({ status: 'reauthenticationRequired', message: plainError(error) }); }
    finally { this.accountBusy = false; }
  }

  async login() {
    if (this.accountBusy || this.loginId) return;
    this.accountBusy = true;
    const epoch = this.loginEpoch;
    try {
      const result = await this.rpc.request('account/login/start', { type: 'chatgpt' });
      if (epoch !== this.loginEpoch) return;
      if (typeof result.loginId !== 'string' || !result.loginId) throw new Error('Invalid Codex login response.');
      let url;
      try { url = new URL(result.authUrl); } catch { throw new Error('Invalid Codex sign-in URL.'); }
      if (url.protocol !== 'https:' || !['auth.openai.com', 'auth0.openai.com'].includes(url.hostname) || url.username || url.password) throw new Error('Unexpected Codex sign-in URL.');
      this.loginId = result.loginId;
      this.accountState({ status: 'signingIn', message: 'Complete sign-in in your browser.' });
      this.emit('native.account.login', { url: url.href, loginId: this.loginId });
    } catch (error) { this.accountState({ status: 'error', message: plainError(error) }); }
    finally { this.accountBusy = false; }
  }

  voiceState(status, message) {
    this.emit('surface.snapshot', { id: 'codex:voice:' + this.threadId, surface: 'realtime', title: 'Voice conversation', method: 'floaty/realtime', threadId: this.threadId, placement: 'session', data: { status, message } });
  }

  retireVoice(voice, state, message) {
    clearTimeout(voice.timer);
    if (this.voice !== voice) return;
    this.voice = null;
    this.emit('native.realtime', { requestId: voice.id, threadId: voice.threadId, state, message: typeof message === 'string' ? message : undefined });
    this.voiceState(state, typeof message === 'string' ? message : undefined);
  }

  async startRealtime(message) {
    if (!/^[0-9a-f-]{36}$/i.test(message.requestId || '')) return;
    if (!this.nativeAudio || !this.threadId || this.voice || this.voiceStop || this.voiceStarting || this.voiceBlocked || this.transitioning) {
      this.emit('native.realtime', { requestId: message.requestId, state: 'error', message: 'Voice is not ready. Wait or reopen this conversation.' });
      this.voiceState('error', 'Voice is not ready. Wait or reopen this conversation.'); return;
    }
    const voice = { id: message.requestId, threadId: this.threadId, ready: false, pending: 0 };
    this.voice = voice;
    this.voiceState('starting', 'Connecting voice…');
    voice.timer = setTimeout(() => { if (this.voice === voice) void this.stopRealtime('error', 'Voice did not start in time.'); }, 15000);
    const starting = this.rpc.request('thread/realtime/start', { threadId: voice.threadId, outputModality: 'audio', transport: { type: 'websocket' }, version: 'v1' }, 15000);
    this.voiceStarting = starting;
    try { await starting; }
    catch (error) { if (this.voice === voice) void this.stopRealtime('error', plainError(error)); }
    finally { if (this.voiceStarting === starting) this.voiceStarting = null; }
  }

  async stopRealtimeRPC(threadId) {
    try { await this.rpc.request('thread/realtime/stop', { threadId }, 3000); }
    catch (error) { this.voiceBlocked = true; if (!this.closing) this.notice('error', 'Voice stop could not be confirmed. Reopen the conversation before starting voice again. ' + plainError(error)); }
  }

  async stopRealtime(state = 'closed', message) {
    if (this.voiceStop) return this.voiceStop;
    const voice = this.voice;
    if (!voice) return;
    this.retireVoice(voice, state, message);
    const starting = this.voiceStarting;
    this.voiceStop = (async () => {
      // Local capture is already stopped. Settle startup before stopping its remote session.
      if (starting) { try { await starting; } catch { /* stop remains necessary after timeout */ } }
      await this.stopRealtimeRPC(voice.threadId);
    })();
    try { await this.voiceStop; } finally { this.voiceStop = null; }
  }

  async appendRealtimeAudio(message) {
    const voice = this.voice, audio = message.audio;
    if (!voice?.ready || voice.id !== message.requestId || voice.stopping) return;
    if (!audio || audio.sampleRate !== 24000 || audio.numChannels !== 1 || typeof audio.data !== 'string' || audio.data.length > 16000 || !/^[A-Za-z0-9+/]+={0,2}$/.test(audio.data)) return;
    const bytes = Buffer.from(audio.data, 'base64');
    if (!bytes.length || bytes.length % 2 || bytes.length / 2 !== audio.samplesPerChannel) return;
    if (voice.pending >= 8) { await this.stopRealtime('error', 'Audio connection fell behind. Start voice again.'); return; }
    voice.pending++;
    try { await this.rpc.request('thread/realtime/appendAudio', { threadId: voice.threadId, audio }, 3000); }
    catch (error) { if (this.voice === voice) await this.stopRealtime('error', plainError(error)); }
    finally { voice.pending--; }
  }

  async surfaceAction(message) {
    const { action, id, text } = message;
    try {
      if (action === 'processInput') {
        await this.rpc.request('process/writeStdin', { processHandle: id, deltaBase64: Buffer.from(text || '', 'utf8').toString('base64') });
      } else if (action === 'queueRemove' || action === 'queueStart') {
        await this.rpc.request(action === 'queueRemove' ? 'thread/queue/delete' : 'thread/queue/start', { threadId: this.threadId, queuedSubmissionId: id });
        await this.refreshSurface('thread/queue/changed', { threadId: this.threadId });
      } else if (action === 'realtimeStop') {
        await this.stopRealtime();
      } else if (action === 'accountRead' || action === 'accountRefresh') {
        await this.readAccount(action === 'accountRefresh');
      } else if (action === 'accountLogin') {
        await this.login();
      } else if (action === 'accountLoginCancel' && this.loginId) {
        const loginId = this.loginId;
        await this.rpc.request('account/login/cancel', { loginId });
        if (this.loginId === loginId) this.loginId = null;
        this.accountState({ status: 'cancelled', message: 'Sign-in cancelled.' });
      } else throw new Error('Unsupported surface action.');
    } catch (error) { this.notice('error', plainError(error)); }
  }

  onExit(error) {
    if (this.failureSent || this.closing) return;
    this.failureSent = true;
    if (this.voice) this.retireVoice(this.voice, 'error', 'Codex disconnected.');
    this.cancelHostTools('Codex app-server disconnected.', null, null, false);
    if (this.active) this.endTurn(this.active, 'error', `Codex app-server stopped: ${plainError(error)}`, { type: 'app-server.exit' });
    else this.notice('error', `Codex app-server stopped: ${plainError(error)}`, true, { type: 'app-server.exit' });
  }

  async handleControl(message) {
    if (message.type === 'start') return this.start(message);
    if (this.starting) { this.startQueue.push(message); return; }
    if (!this.started && !['user'].includes(message.type)) return;
    try {
      switch (message.type) {
        case 'user': return this.user(message.text, message.images);
        case 'catalog': return this.loadCatalog();
        case 'files': return this.files(message);
        case 'title': return this.title();
        case 'rename': return this.rename(message);
        case 'shell': return this.runShell(message);
        case 'shellKill': return this.killShell(message.id);
        case 'interrupt': return this.interruptActive();
        case 'permission': return this.permission(message);
        case 'realtimeStart': return this.startRealtime(message);
        case 'realtimeAudio': return this.appendRealtimeAudio(message);
        case 'realtimeStop': return this.stopRealtime();
        case 'realtimeState':
          if (this.voice?.id === message.requestId) this.voiceState(message.muted === true ? 'muted' : 'active');
          return;
        case 'hostToolResult': return this.hostToolResult(message);
        case 'surfaceAction': return this.surfaceAction(message);
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
    await this.stopRealtime();
    this.cancelHostTools('Host is shutting down.');
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
