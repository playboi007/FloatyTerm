#!/usr/bin/env node
// A stand-in for `pi --mode rpc` that speaks the same LF-JSONL protocol.
// It answers state queries, streams one canned turn per prompt, and runs `bash`
// without a model call, so the bridge can be tested end to end for free.
import { createInterface } from 'node:readline';

const write = value => process.stdout.write(JSON.stringify(value) + '\n');
const models = [
  { id: 'fake/model-a', name: 'Fake Model A', provider: 'fake', reasoning: true },
  { id: 'fake/model-b', name: 'Fake Model B', provider: 'fake', reasoning: false },
];
let model = models[0];
let streaming = false;

const respond = (command, data) => write({ type: 'response', command: command.type, ...(command.id ? { id: command.id } : {}), success: true, ...(data === undefined ? {} : { data }) });

const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
input.on('line', line => {
  let command;
  try { command = JSON.parse(line); } catch { return; }
  switch (command.type) {
    case 'get_state':
      return respond(command, { model, thinkingLevel: 'medium', isStreaming: streaming, steeringMode: 'one-at-a-time', followUpMode: 'one-at-a-time', sessionId: 'fake-session-1', sessionName: 'Fake work', messageCount: 1 });
    case 'get_available_models':
      return respond(command, { models });
    case 'get_available_thinking_levels':
      return respond(command, { levels: model.reasoning ? ['off', 'low', 'medium', 'high'] : ['off'] });
    case 'get_commands':
      return respond(command, { commands: [{ name: 'demo', description: 'A demo command', source: 'extension' }] });
    case 'get_session_stats':
      return respond(command, { sessionId: 'fake-session-1', tokens: { input: 120, output: 30, cacheRead: 10, cacheWrite: 0, total: 160 }, cost: 0.012, contextUsage: { tokens: 160, contextWindow: 1000, percent: 16 } });
    case 'set_model':
      model = models.find(m => m.id === command.modelId) || model;
      return respond(command, model);
    case 'set_thinking_level':
      if (command.level === 'nope') return write({ type: 'response', command: 'set_thinking_level', ...(command.id ? { id: command.id } : {}), success: false, error: 'unsupported level' });
      return respond(command);
    case 'new_session':
      return respond(command, { cancelled: false });
    case 'set_session_name':
      return respond(command);
    case 'compact':
      return respond(command, { estimatedTokensAfter: 40 });
    case 'abort':
      streaming = false;
      return respond(command);
    case 'bash': {
      write({ type: 'bash_execution_update', id: command.id, delta: 'total 0\n' });
      write({ type: 'bash_execution_update', id: command.id, delta: 'ok\n' });
      return respond(command, { output: 'total 0\nok\n', exitCode: 0, cancelled: false, truncated: false });
    }
    case 'extension_ui_response':
      // Echo what pi received back as a plain assistant message so a test can see it.
      return write({ type: 'message_end', message: { role: 'assistant', id: 'm-dialog', content: [{ type: 'text', text: 'dialog answer: ' + (command.value ?? (command.confirmed === true ? 'yes' : command.confirmed === false ? 'no' : 'cancelled')) }] } });
    case 'prompt': {
      if (command.message === 'dialog') {
        write({ type: 'agent_start' });
        return write({ type: 'extension_ui_request', id: 'ui-7', method: 'select', title: 'Allow dangerous command?', options: ['Allow', 'Block'], timeout: 10000 });
      }
      streaming = true;
      write({ type: 'agent_start' });
      write({ type: 'turn_start' });
      write({ type: 'message_start', message: { role: 'assistant', id: 'm1', content: [] } });
      write({ type: 'message_update', usage: {}, assistantMessageEvent: { type: 'thinking_start', contentIndex: 0 } });
      write({ type: 'message_update', usage: {}, assistantMessageEvent: { type: 'thinking_delta', contentIndex: 0, delta: 'why' } });
      write({ type: 'message_update', usage: {}, assistantMessageEvent: { type: 'thinking_end', contentIndex: 0, content: 'why' } });
      write({ type: 'message_update', usage: {}, assistantMessageEvent: { type: 'text_start', contentIndex: 1 } });
      write({ type: 'message_update', usage: {}, assistantMessageEvent: { type: 'text_delta', contentIndex: 1, delta: 'Hel' } });
      write({ type: 'message_update', usage: {}, assistantMessageEvent: { type: 'text_delta', contentIndex: 1, delta: 'lo' } });
      write({ type: 'message_update', usage: {}, assistantMessageEvent: { type: 'text_end', contentIndex: 1, content: 'Hello' } });
      write({ type: 'message_update', usage: {}, assistantMessageEvent: { type: 'toolcall_start', contentIndex: 2, id: 'call_1', toolName: 'bash' } });
      write({ type: 'message_update', usage: {}, assistantMessageEvent: { type: 'toolcall_end', contentIndex: 2, toolCall: { id: 'call_1', name: 'bash', arguments: { command: 'ls' } } } });
      write({ type: 'message_end', message: { role: 'assistant', id: 'm1', content: [{ type: 'thinking', thinking: 'why' }, { type: 'text', text: 'Hello' }, { type: 'toolCall', id: 'call_1', name: 'bash', arguments: { command: 'ls' } }], usage: { input: 120, output: 30, cacheRead: 10, cacheWrite: 0, totalTokens: 160, cost: { total: 0.012 } } } });
      write({ type: 'tool_execution_start', toolCallId: 'call_1', toolName: 'bash', args: { command: 'ls' } });
      write({ type: 'tool_execution_update', toolCallId: 'call_1', toolName: 'bash', partialResult: { content: [{ type: 'text', text: 'a.txt\n' }] } });
      write({ type: 'tool_execution_end', toolCallId: 'call_1', toolName: 'bash', result: { content: [{ type: 'text', text: 'a.txt\n' }] }, isError: false });
      write({ type: 'turn_end', message: { role: 'assistant', id: 'm1', usage: { input: 120, output: 30, totalTokens: 160, cost: { total: 0.012 } } }, toolResults: [{ toolCallId: 'call_1', toolName: 'bash', content: [{ type: 'text', text: 'a.txt\n' }] }] });
      write({ type: 'agent_end', messages: [] });
      write({ type: 'agent_settled' });
      streaming = false;
      return respond(command);
    }
    default:
      return write({ type: 'response', command: command.type, ...(command.id ? { id: command.id } : {}), success: false, error: 'unknown command ' + command.type });
  }
});
