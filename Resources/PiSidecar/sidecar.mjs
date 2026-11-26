#!/usr/bin/env node
// FloatyTerm <-> pi bridge.
//
// pi speaks newline-delimited JSON-RPC on stdio (`pi --mode rpc`): commands in on
// stdin, `response` records plus agent events out on stdout. This process owns one
// persistent pi session and exposes a small, versioned stream to the native host.
//
// It deliberately does NOT translate pi's agent events: those are forwarded verbatim
// as `{type:'native', event}` and normalized by the shared renderer (`agent-pi.js`),
// so the same adapter serves live tabs and `--mode json` replays. The bridge only owns
// what needs a live process: control commands, command responses, extension UI, and
// session-level facts (models, thinking levels, usage, titles).
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

// pi requires strict LF framing (readline would split on U+2028/U+2029), so stdin
// control messages use readline (they are our own JSON, never pi's) while stdout is
// split on '\n' below.
const MAX_LINE_BYTES = 8 * 1024 * 1024;
const STDERR_BYTES = 4000;
const COMMANDS = [
  ['model', 'Choose the pi model', '[model]'],
  ['effort', 'Set the thinking level', '[off|minimal|low|medium|high|xhigh|max]'],
  ['usage', 'Show token and context usage', ''],
  ['new', 'Start a new pi conversation', ''],
  ['clear', 'Start a new pi conversation', ''],
  ['compact', 'Compact this conversation', ''],
  ['rename', 'Name this conversation', '[name]'],
  ['exit', 'Close this conversation', ''],
].map(([name, description, argumentHint]) => ({ name, description, argumentHint }));

// pi has no built-in tool-approval gate and no account plan API, so neither the
// permissions nor the plan surfaces are advertised.
const featureSet = {
  history: true, models: true, effort: true, thinking: true, usage: true,
  slashCommands: true, midTurnInput: true, images: true, shell: true, git: true,
};

const output = value => {
  try { process.stdout.write(JSON.stringify({ v: 1, agent: 'pi', t: Date.now(), ...value }) + '\n'); }
  catch { /* stdout may already be closed during host shutdown */ }
};
// pi's own agent events go up unversioned, the way the Claude sidecar forwards SDK
// messages: the renderer's `agent-pi.js` is the one place that maps them, so a live
// tab and a `--mode json` replay take exactly the same path.
const relay = event => {
  try { process.stdout.write(JSON.stringify({ type: 'native', agent: 'pi', t: Date.now(), event }) + '\n'); }
  catch { /* stdout may already be closed during host shutdown */ }
};
const plainError = error => String(error?.message || error || 'Unknown pi error').replace(/\s+/g, ' ').trim();
const toText = value => typeof value === 'string' ? value : value == null ? '' : JSON.stringify(value, null, 2);

class PiBridge {
  constructor() {
    this.proc = null;
    this.stdin = null;
    this.buffer = '';
    this.stderrTail = '';
    this.nextId = 1;
    this.pending = new Map();       // request id -> resolve(response)
    this.models = new Map();        // model.id -> Model
    this.levels = ['off'];
    this.state = null;
    this.streaming = false;
    this.starting = false;
    this.closing = false;
    this.cwd = '';
    this.shellSeq = 0;
    this.shellRuns = new Set();   // ids of host `bash` commands, so their output draws as a shell card
    this.commandRows = COMMANDS;
    this.dialogs = new Map();       // extension_ui_request id -> method
  }

  emit(type, fields = {}, raw = undefined) {
    output({ type, ...fields, ...(raw ? { raw } : {}) });
  }

  notice(kind, message, terminal = false) {
    this.emit('notice', { kind, message, ...(terminal ? { terminal: true } : {}) });
  }

  /** Sends an RPC command and resolves with its `response` record. */
  request(command, timeoutMs = 30_000) {
    if (!this.stdin) return Promise.reject(new Error('pi is not running.'));
    // A caller-supplied id (a host shell) is the correlation key pi echoes back.
    const id = command.id || 'req-' + this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`pi did not answer ${command.type} in time.`)); }, timeoutMs);
      this.pending.set(id, response => { clearTimeout(timer); resolve(response); });
      this.write({ ...command, id });
    });
  }

  /** Fire-and-forget: a failed optional command must not surface as a session error. */
  async quietly(command) {
    try { return await this.request(command); } catch { return null; }
  }

  write(message) {
    try { this.stdin?.write(JSON.stringify(message) + '\n'); } catch { /* pi exited */ }
  }

  async start(message) {
    if (this.proc || this.starting) return;
    if (typeof message.cwd !== 'string' || !message.cwd) { this.notice('error', 'Invalid pi configuration.', true); return; }
    this.starting = true;
    this.cwd = message.cwd;
    try {
      const args = ['--mode', 'rpc'];
      if (typeof message.model === 'string' && message.model) args.push('--model', message.model);
      if (typeof message.effort === 'string' && message.effort) args.push('--thinking', message.effort);
      if (typeof message.resume === 'string' && message.resume) args.push('--session', message.resume);
      if (typeof message.name === 'string' && message.name) args.push('--name', message.name);
      const proc = spawn(message.piPath || 'pi', args, { cwd: message.cwd, env: this.environment() });
      this.proc = proc;
      this.stdin = proc.stdin;
      proc.stdout.on('data', chunk => this.ingest(chunk));
      proc.stderr.on('data', chunk => { this.stderrTail = (this.stderrTail + String(chunk)).slice(-STDERR_BYTES); });
      proc.on('error', error => { this.notice('error', `pi did not start: ${plainError(error)}`, true); this.shutdown(); });
      proc.on('exit', code => this.onExit(code));
      await this.bootstrap();
    } finally {
      this.starting = false;
    }
  }

  environment() {
    const env = { ...process.env };
    const extra = ['/opt/homebrew/bin', '/usr/local/bin', `${process.env.HOME || ''}/.local/bin`, '/usr/bin', '/bin'];
    const current = (env.PATH || '').split(':').filter(Boolean);
    env.PATH = [...current, ...extra.filter(p => !current.includes(p))].join(':');
    return env;
  }

  /** One round of state queries; the responses paint the tab's header and pickers. */
  async bootstrap() {
    const [state, models, levels, commands] = await Promise.all([
      this.quietly({ type: 'get_state' }),
      this.quietly({ type: 'get_available_models' }),
      this.quietly({ type: 'get_available_thinking_levels' }),
      this.quietly({ type: 'get_commands' }),
    ]);
    this.applyState(state);
    for (const model of models?.data?.models || []) if (model?.id) this.models.set(model.id, model);
    this.levels = levels?.data?.levels || this.levels;
    this.emitCapabilities(commands?.data?.commands || []);
    await this.refreshUsage();
  }

  bootstrapCommands(commands) {
    const rows = commands.map(command => ({ name: command.name, description: command.description || '', argumentHint: command.argumentHint || '' }));
    return [...rows, ...COMMANDS];
  }
  modelRows() {
    const supportsEffort = this.levels.filter(level => level !== 'off').length > 0;
    return [...this.models.values()].map(model => ({
      value: model.id,
      displayName: model.name || model.id,
      description: [model.provider, model.reasoning ? 'reasoning' : null].filter(Boolean).join(' · '),
      resolvedModel: model.id,
      supportsEffort,
      supportedEffortLevels: supportsEffort ? this.levels : [],
      defaultEffort: this.state?.thinkingLevel || null,
      supportsAutoMode: false,
    }));
  }

  emitCapabilities(commands = this.commandRows) {
    this.commandRows = commands.length ? commands : this.commandRows;
    this.emit('capabilities', {
      features: { ...featureSet, models: this.models.size > 0, effort: this.levels.filter(l => l !== 'off').length > 0 },
      commands: this.bootstrapCommands(commands),
      models: this.modelRows(),
      mode: this.state?.steeringMode || 'default',
    }, { type: 'pi.capabilities', methods: ['get_state', 'get_available_models', 'get_available_thinking_levels', 'get_commands'] });
  }

  /** get_state is the single source of truth for identity, model and thinking level. */
  applyState(response) {
    const data = response?.data;
    if (!data) return;
    this.state = data;
    if (data.sessionId) this.emit('session', { sessionId: data.sessionId, cwd: this.cwd, model: data.model?.id || null, info: { provider: 'pi' } });
    if (data.model?.id) {
      if (!this.models.has(data.model.id)) this.models.set(data.model.id, data.model);
      this.emit('model', { model: data.model.id });
    }
    if (data.thinkingLevel) this.emit('effort', { effort: data.thinkingLevel === 'off' ? null : data.thinkingLevel });
    if (data.sessionName) this.emit('title', { title: data.sessionName, custom: true, sessionId: data.sessionId });
  }

  /** Session totals from get_session_stats; the panel reads modelUsage and context. */
  async refreshUsage() {
    const response = await this.quietly({ type: 'get_session_stats' });
    const data = response?.data;
    if (!data) return;
    const tokens = data.tokens || {};
    const model = this.state?.model?.id || 'pi';
    const fields = {
      modelUsage: { [model]: {
        inputTokens: tokens.input || 0, outputTokens: tokens.output || 0,
        cacheReadInputTokens: tokens.cacheRead || 0, cacheCreationInputTokens: tokens.cacheWrite || 0,
        costUSD: data.cost || 0,
      } },
    };
    if (data.contextUsage) fields.context = { totalTokens: data.contextUsage.tokens || 0, maxTokens: data.contextUsage.contextWindow || 0, percentage: data.contextUsage.percent || 0, model };
    this.emit('usage', fields);
  }

  /** Splits stdout on LF only, per pi's strict framing rules. */
  ingest(chunk) {
    this.buffer += chunk;
    if (this.buffer.length > MAX_LINE_BYTES) { this.notice('error', 'pi sent an oversized line; the connection was closed.', true); this.shutdown(); return; }
    let index;
    while ((index = this.buffer.indexOf('\n')) !== -1) {
      let line = this.buffer.slice(0, index);
      this.buffer = this.buffer.slice(index + 1);
      if (line.endsWith('\r')) line = line.slice(0, -1);
      if (!line) continue;
      let record;
      try { record = JSON.parse(line); }
      catch { this.notice('error', 'pi sent a line that was not JSON.'); continue; }
      this.route(record);
    }
  }

  route(record) {
    if (!record || typeof record !== 'object') return;
    if (record.type === 'response') {
      const resolve = this.pending.get(record.id);
      if (resolve) { this.pending.delete(record.id); resolve(record); }
      else if (record.success === false) this.notice('error', `pi rejected ${record.command || 'a command'}: ${record.error || 'unknown error'}.`);
      return;
    }
    if (record.type === 'extension_ui_request') { this.extensionUI(record); return; }
    // A direct host `bash` command draws as a shell card, not as conversation output.
    if (record.type === 'bash_execution_update' && this.shellRuns.has(record.id)) {
      this.emit('shell', { id: record.id, stream: 'stdout', chunk: record.delta || '' });
      return;
    }
    // pi's agent events: relay them untouched for the renderer's pi adapter. The
    // bridge only tracks whether a turn is live, so a mid-turn message steers.
    if (record.type === 'agent_start' || record.type === 'turn_start') this.streaming = true;
    if (record.type === 'agent_end' || record.type === 'agent_settled') this.streaming = false;
    relay(record);
    if (record.type === 'agent_settled') void this.refreshUsage();
  }

  /** Extension dialogs block pi; everything else is display-only. */
  extensionUI(request) {
    switch (request.method) {
      case 'notify':
        this.notice(request.notifyType === 'warning' ? 'warn' : request.notifyType === 'error' ? 'error' : 'info', request.message || '');
        return;
      case 'setTitle':
        if (request.title) this.emit('title', { title: request.title, custom: true, sessionId: this.state?.sessionId });
        return;
      case 'confirm':
      case 'select': {
        // A confirm is an allow/deny and a select is one of pi's options, so both ride the
        // approval card. The decisions live in `input`, which is where the card reads them.
        this.dialogs.set(request.id, request.method);
        const decisions = request.method === 'select' ? (request.options || ['accept', 'decline']) : ['accept', 'decline'];
        this.emit('approval.request', { request: {
          id: request.id, kind: 'permission', toolName: request.title || 'pi extension',
          input: { availableDecisions: decisions }, decisionReason: request.message || null,
          blocking: true, timeout: request.timeout || null,
        } });
        return;
      }
      // Free-form input and multi-line editors have no card that can answer them yet.
      case 'input':
      case 'editor':
        this.notice('warn', `${request.title || 'pi extension'} needs typed input, which this build cannot provide yet.`);
        this.write({ type: 'extension_ui_response', id: request.id, cancelled: true });
        return;
      default:
        // setStatus / setWidget / set_editor_text have no surface in the chat view.
        return;
    }
  }

  /** Answers a dialog that the approval card resolved. */
  answerDialog(id, decision, response) {
    const method = this.dialogs.get(id);
    if (!method) return false;
    this.dialogs.delete(id);
    const denied = decision === 'deny' || response?.decision === 'decline' || response?.decision === 'cancel';
    if (method === 'confirm') this.write({ type: 'extension_ui_response', id, confirmed: !denied });
    else this.write({ type: 'extension_ui_response', id, ...(denied ? { cancelled: true } : { value: response?.decision ?? response?.value ?? 'accept' }) });
    return true;
  }

  onExit(code) {
    this.proc = null;
    this.stdin = null;
    for (const resolve of this.pending.values()) resolve({ success: false, error: 'pi exited.' });
    this.pending.clear();
    if (this.closing) return;
    const detail = this.stderrTail.trim() ? ` ${this.stderrTail.trim().split('\n').slice(-3).join(' ')}` : '';
    this.notice('error', `pi exited${code ? ` with code ${code}` : ''}.${detail}`, true);
  }

  async handleControl(message) {
    try {
      switch (message.type) {
        case 'start': return await this.start(message);
        case 'send': case 'user': return this.prompt(message);
        case 'interrupt': return void this.write({ type: 'abort' });
        case 'setModel': return await this.setModel(message.model);
        case 'setEffort': return await this.setEffort(message.effort);
        case 'setThinking': return await this.setEffort(message.on === false ? 'off' : (this.state?.thinkingLevel || 'medium'));
        case 'usage': return await this.refreshUsage();
        case 'newConversation': case 'clear': return await this.newSession();
        case 'compact': return await this.compact();
        case 'rename': return await this.rename(message.title ?? message.name);
        case 'title': return await this.rename(message.title ?? message.name);
        case 'permission': if (!this.answerDialog(message.id, message.decision, message.response)) this.notice('info', 'That permission request is no longer waiting.');
          return;
        case 'shell': return this.shell(message);
        case 'setPermissionMode':
          this.notice('info', 'pi has no permission modes in this build; tools run as configured.');
          return;
        case 'sessions': this.notice('info', 'Resuming pi conversations from the tab is not wired up yet. Run pi --resume in a terminal.');
          return;
        default:
          this.notice('info', `Unsupported pi control: ${message.type || 'unknown'}.`);
      }
    } catch (error) {
      this.notice('error', `pi operation failed: ${plainError(error)}.`);
    }
  }

  prompt(message) {
    const text = message.text;
    if (typeof text !== 'string' || !text.trim()) return;
    // A quiet context injection has no pi equivalent: it would start a real turn.
    if (message.shouldQuery === false) { this.notice('info', 'pi has no quiet-context channel; that note is not stored.'); return; }
    const command = { type: 'prompt', message: text };
    // While pi streams, a new message steers the turn in progress instead of starting one.
    if (this.streaming) command.streamingBehavior = 'steer';
    const images = (Array.isArray(message.images) ? message.images : []).map(image => ({ type: 'image', data: image.data, mimeType: image.mimeType || image.mediaType || 'image/png' })).filter(image => image.data);
    if (images.length) command.images = images;
    void this.request(command);
  }

  async setModel(value) {
    if (!value) return;
    const model = this.models.get(value);
    if (!model) { this.notice('error', `pi model is unavailable: ${value}.`); return; }
    const response = await this.request({ type: 'set_model', provider: model.provider, modelId: model.id });
    if (response.success === false) { this.notice('error', `pi could not switch model: ${response.error || 'unknown error'}.`); return; }
    const levels = await this.quietly({ type: 'get_available_thinking_levels' });
    if (levels?.data?.levels) this.levels = levels.data.levels;
    this.applyState(await this.quietly({ type: 'get_state' }));
    this.emitCapabilities();
  }

  async setEffort(effort) {
    const level = effort || 'off';
    const response = await this.request({ type: 'set_thinking_level', level });
    if (response.success === false) { this.notice('error', `pi could not set the thinking level: ${response.error || 'unknown error'}.`); return; }
    this.emit('effort', { effort: level === 'off' ? null : level });
  }

  async newSession() {
    const response = await this.request({ type: 'new_session' });
    if (response?.data?.cancelled) { this.notice('info', 'An extension kept the current pi conversation open.'); return; }
    this.applyState(await this.quietly({ type: 'get_state' }));
    await this.refreshUsage();
  }

  async compact() {
    this.notice('info', 'Compacting the pi conversation…');
    const response = await this.request({ type: 'compact' }, 300_000);
    if (response.success === false) { this.notice('error', `pi could not compact: ${response.error || 'unknown error'}.`); return; }
    await this.refreshUsage();
  }

  async rename(title) {
    const name = typeof title === 'string' ? title.trim() : '';
    const response = await this.request({ type: 'set_session_name', name });
    if (response.success === false) { this.notice('error', `pi could not name the conversation: ${response.error || 'unknown error'}.`); return; }
    this.emit('title', { title: name, custom: !!name, sessionId: this.state?.sessionId });
  }

  /** Direct shell command: pi streams bash_execution_update, which draws as a shell card. */
  shell(message) {
    if (typeof message.command !== 'string' || !message.command.trim()) return;
    const id = 'shell-' + ++this.shellSeq;
    this.shellRuns.add(id);
    void this.request({ id, type: 'bash', command: message.command }, 600_000).then(response => {
      this.shellRuns.delete(id);
      if (response.success === false) { this.emit('shell', { id, done: true, code: null, error: response.error || 'the command did not run' }); return; }
      if (response.data?.truncated && response.data?.fullOutputPath) this.notice('info', `Output was truncated; the full log is at ${response.data.fullOutputPath}.`);
      this.emit('shell', { id, done: true, code: response.data?.exitCode ?? null, signal: response.data?.cancelled ? 'SIGTERM' : null });
    });
  }

  shutdown() {
    if (this.closing) return;
    this.closing = true;
    process.stdin.destroy();
    const proc = this.proc;
    if (!proc) return;
    this.write({ type: 'abort' });
    try { this.stdin?.end(); } catch { /* already closed */ }
    setTimeout(() => { if (proc.exitCode === null) proc.kill('SIGTERM'); }, 1500).unref();
    setTimeout(() => { if (proc.exitCode === null) proc.kill('SIGKILL'); }, 4000).unref();
  }
}

const bridge = new PiBridge();
process.stdout.on('error', () => bridge.shutdown());
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  let message;
  try { message = JSON.parse(line); }
  catch { bridge.notice('error', 'Invalid pi control message.'); return; }
  if (!message || typeof message !== 'object' || Array.isArray(message)) { bridge.notice('error', 'Invalid pi control message.'); return; }
  void bridge.handleControl(message);
});
input.on('close', () => bridge.shutdown());
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => bridge.shutdown());
