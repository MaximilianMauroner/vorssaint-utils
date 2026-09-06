import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { format } from 'node:util';
import { LIMITS, object, text, validateManifest, validateExports, validateResult } from './validation.mjs';

const write = process.stdout.write.bind(process.stdout);
let logBytes = 0;
function log(...args) {
  const line = `${format(...args)}\n`;
  const remaining = 64 * 1024 - logBytes;
  if (remaining > 0) {
    const bytes = Buffer.from(line).subarray(0, Math.min(remaining, 4096));
    logBytes += bytes.length;
    process.stderr.write(bytes);
  }
}
for (const method of ['log', 'info', 'warn', 'error', 'debug', 'dir', 'trace']) console[method] = log;
function errorMessage(error) { return error instanceof Error ? error.message : 'Plugin request failed'; }
function send(message) {
  const data = `${JSON.stringify(message)}\n`;
  if (Buffer.byteLength(data) > LIMITS.frame) throw new Error('Response exceeds the 1 MiB limit');
  if (process.stdout.writableLength > LIMITS.frame) { process.exit(1); }
  write(data);
}
function fail(id, code, message) { send({ jsonrpc: '2.0', id, error: { code, message: String(message).slice(0, 1024) } }); }
const requests = new Map();
const callbacks = new Map();
let sequence = 0;
let initialized = false;
let plugin;
let manifest;
let initializationError;
try {
  manifest = validateManifest(JSON.parse(await readFile(resolve('plugin.json'), 'utf8')));
  const entry = resolve(manifest.main);
  if (entry !== resolve(process.argv[2] ?? '')) throw new Error('Entry path does not match the manifest');
  plugin = validateExports((await import(pathToFileURL(entry).href)).default, manifest);
} catch (error) { initializationError = errorMessage(error); }

function hostFor(requestID, signal, search) {
  function call(method, params) {
    if (signal.aborted || !requests.has(requestID)) return Promise.reject(new Error('Request cancelled or completed'));
    if (search && ['clipboard.write', 'url.open'].includes(method)) return Promise.reject(new Error('Action APIs are unavailable during search'));
    const capability = { 'settings.get': 'settings.read', 'storage.get': 'storage.read', 'storage.set': 'storage.write' }[method] ?? method;
    if (!manifest.capabilities.includes(capability)) return Promise.reject(new Error(`Capability not declared: ${capability}`));
    if (callbacks.size >= 64) return Promise.reject(new Error('Too many pending host requests'));
    const id = `plugin:${++sequence}`;
    return new Promise((resolve, reject) => {
      const onAbort = () => { callbacks.delete(id); reject(new Error('Request cancelled')); };
      callbacks.set(id, { requestID, resolve, reject, signal, onAbort });
      signal.addEventListener('abort', onAbort, { once: true });
      try { send({ jsonrpc: '2.0', id, method, params: { ...params, requestID } }); }
      catch (error) { callbacks.delete(id); signal.removeEventListener('abort', onAbort); reject(error); }
    });
  }
  return {
    clipboard: { writeText: value => call('clipboard.write', { text: text(value, 'Clipboard text', 256 * 1024) }) },
    url: { open: url => call('url.open', { url: text(url, 'URL', 8192) }) },
    settings: { get: key => call('settings.get', { key: text(key, 'Setting key', 128) }) },
    storage: { get: key => call('storage.get', { key: text(key, 'Storage key', 128) }), set: (key, value) => call('storage.set', { key: text(key, 'Storage key', 128), value }) },
    status: { show: message => call('status.show', { message: text(message, 'Status', 4096) }) },
  };
}
function cleanup(requestID) {
  for (const [id, callback] of callbacks) {
    if (callback.requestID !== requestID) continue;
    callbacks.delete(id);
    callback.signal.removeEventListener('abort', callback.onAbort);
    callback.reject(new Error('Parent request completed'));
  }
}
async function receive(message) {
  const m = object(message, 'RPC message');
  if (m.jsonrpc !== '2.0') throw new Error('Expected JSON-RPC 2.0');
  if (m.method === undefined) {
    if (typeof m.id !== 'string') throw new Error('Invalid host response ID');
    // A reply can cross cancellation on the two pipes. Ignore replies whose parent has ended.
    if (!callbacks.has(m.id)) return;
    const callback = callbacks.get(m.id);
    callbacks.delete(m.id);
    callback.signal.removeEventListener('abort', callback.onAbort);
    if (m.error) callback.reject(new Error(text(object(m.error).message, 'Host error', 4096)));
    else if (Object.hasOwn(m, 'result')) callback.resolve(m.result);
    else callback.reject(new Error('Malformed host response'));
    return;
  }
  if (m.method === 'cancel' && m.id === undefined) {
    const requestID = text(object(m.params).requestID, 'Request ID', 128);
    const state = requests.get(requestID);
    if (state) { requests.delete(requestID); state.abort(); cleanup(requestID); fail(requestID, -32800, 'Request cancelled'); }
    return;
  }
  if (typeof m.id !== 'string' || m.id.length > 128 || !m.id) throw new Error('Requests require a string ID');
  if (requests.has(m.id)) { fail(m.id, -32600, 'Duplicate active request ID'); return; }
  if (m.method === 'initialize') {
    if (initialized) { fail(m.id, -32600, 'Already initialized'); return; }
    if (initializationError) { fail(m.id, -32000, initializationError); return; }
    if (m.params?.apiVersion !== 1) { fail(m.id, -32602, 'Unsupported API version'); return; }
    initialized = true;
    send({ jsonrpc: '2.0', id: m.id, result: { apiVersion: 1, pluginID: manifest.id } });
    return;
  }
  if (!initialized) { fail(m.id, -32000, 'Initialize before invoking a plugin'); return; }
  if (requests.size >= 8) { fail(m.id, -32001, 'Plugin is busy'); return; }
  if (!['command', 'search', 'action'].includes(m.method)) { fail(m.id, -32601, 'Unknown method'); return; }
  const controller = new AbortController();
  requests.set(m.id, controller);
  try {
    const params = object(m.params, 'Request params');
    const search = m.method === 'search';
    const group = plugin[search ? 'searchProviders' : m.method === 'command' ? 'commands' : 'actions'] ?? {};
    const handlerID = params[search ? 'providerID' : m.method === 'command' ? 'commandID' : 'actionID'];
    if (typeof handlerID !== 'string' || !Object.hasOwn(group, handlerID)) throw new Error('Unknown handler');
    const input = search ? { query: text(params.query, 'Query', 16384) } : m.method === 'command' ? { argument: text(params.argument ?? '', 'Argument', 16384) } : { arguments: params.arguments ?? null };
    const result = await group[handlerID]({ ...input, signal: controller.signal }, hostFor(m.id, controller.signal, search));
    if (requests.get(m.id) === controller) send({ jsonrpc: '2.0', id: m.id, result: validateResult(result, search, plugin) });
  } catch (error) {
    if (requests.get(m.id) === controller) fail(m.id, -32000, errorMessage(error));
  } finally {
    if (requests.get(m.id) === controller) { requests.delete(m.id); cleanup(m.id); }
  }
}
let pending = Buffer.alloc(0);
process.stdin.on('data', chunk => {
  pending = Buffer.concat([pending, chunk]);
  let newline;
  while ((newline = pending.indexOf(10)) !== -1) {
    const frame = pending.subarray(0, newline);
    pending = pending.subarray(newline + 1);
    if (frame.length > LIMITS.frame) { process.exitCode = 1; process.stdin.destroy(); break; }
    try {
      const parsed = JSON.parse(frame.toString('utf8'));
      receive(parsed).catch(error => fail(null, -32600, errorMessage(error)));
    } catch { fail(null, -32700, 'Invalid JSON frame'); }
  }
  if (pending.length > LIMITS.frame) { process.exitCode = 1; process.stdin.destroy(); }
});
function shutdown() {
  for (const state of requests.values()) state.abort();
  requests.clear();
  process.exit(process.exitCode ?? 0);
}
process.stdin.on('end', shutdown);
process.stdin.on('close', shutdown);
process.on('SIGTERM', shutdown);
