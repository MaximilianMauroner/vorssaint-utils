import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, mkdir, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { validateManifest, safePath, validateResult } from '../plugin-runtime/validation.mjs';
import { buildPlugin, packPlugin, createPlugin } from '../plugin-cli/cli.mjs';

const manifest = { id: 'com.example.test', name: 'Test', version: '1.0.0', apiVersion: 1, main: 'dist/index.js', commands: [{ id: 'hello', title: 'Hello', input: 'text' }], searchProviders: [{ id: 'find', title: 'Find', keyword: 'test' }], capabilities: ['clipboard.write', 'url.open', 'storage.read', 'storage.write'] };
async function folder(t) { const path = await mkdtemp(join(tmpdir(), 'vorssaint-plugin-')); t.after(() => rm(path, { recursive: true, force: true })); return path; }
async function fixture(t, source, override = {}) {
  const root = await folder(t);
  await mkdir(join(root, 'src'));
  await mkdir(join(root, 'dist'));
  await writeFile(join(root, 'plugin.json'), JSON.stringify({ ...manifest, ...override }));
  await writeFile(join(root, 'package.json'), JSON.stringify({ type: 'module', vorssaint: { source: 'src/index.js' } }));
  await writeFile(join(root, 'src/index.js'), source);
  await writeFile(join(root, 'dist/index.js'), source);
  return root;
}
async function runner(t, source, override = {}) {
  const root = await fixture(t, source, override);
  const child = spawn(process.execPath, [resolve('plugin-runtime/runner.mjs'), join(root, 'dist/index.js')], { cwd: root, stdio: ['pipe', 'pipe', 'pipe'] });
  let pending = '';
  const messages = [];
  const waiters = [];
  let logs = '';
  child.stderr.on('data', chunk => { logs += chunk; });
  child.stdout.on('data', chunk => {
    pending += chunk;
    let index;
    while ((index = pending.indexOf('\n')) !== -1) {
      const message = JSON.parse(pending.slice(0, index)); pending = pending.slice(index + 1);
      const waiterIndex = waiters.findIndex(w => w.id === message.id);
      if (waiterIndex === -1) messages.push(message);
      else { const [w] = waiters.splice(waiterIndex, 1); clearTimeout(w.timer); w.resolve(message); }
    }
  });
  t.after(() => { child.kill(); for (const waiter of waiters) clearTimeout(waiter.timer); });
  const wait = id => {
    const index = messages.findIndex(m => m.id === id);
    if (index !== -1) return Promise.resolve(messages.splice(index, 1)[0]);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`Timed out waiting for ${id}; logs: ${logs}`)), 4000);
      waiters.push({ id, resolve, timer });
    });
  };
  const send = (id, method, params) => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', ...(id === undefined ? {} : { id }), method, params })}\n`);
  return { root, child, wait, send, messages, logs: () => logs, async initialize() { send('init', 'initialize', { apiVersion: 1 }); return wait('init'); } };
}
const simple = `export default { commands: { hello: async ({argument}) => ({message: argument}) }, searchProviders: { find: async () => ({items: []}) } };`;

test('manifest rejects incompatible versions, duplicate IDs, paths and settings', () => {
  assert.equal(validateManifest(manifest).id, manifest.id);
  for (const patch of [{ apiVersion: 2 }, { main: '../index.js' }, { capabilities: ['everything'] }, { commands: [...manifest.commands, ...manifest.commands] }, { settings: [{ key: 'x', title: 'X', type: 'boolean', default: 'yes' }] }]) assert.throws(() => validateManifest({ ...manifest, ...patch }));
  for (const path of ['/tmp/a', 'a/../b', 'a\\b', 'a//b', 'a/./b', 'a:b', '\0']) assert.throws(() => safePath(path));
});
test('result schema rejects unknown actions, duplicate rows and limits', () => {
  assert.throws(() => validateResult({ items: Array.from({ length: 101 }, () => ({})) }, true, {}));
  assert.throws(() => validateResult({ items: [{ id: 'r', title: 'Row', actions: [{ id: 'unknown', title: 'Open' }] }] }, true, {}));
});
test('JavaScript build and pack carry verified files and ESM metadata', async t => {
  const root = await fixture(t, simple);
  await buildPlugin(root);
  const path = await packPlugin(root);
  const archive = JSON.parse(await readFile(path, 'utf8'));
  assert.equal(archive.formatVersion, 1);
  assert.equal(archive.manifest.id, manifest.id);
  for (const file of archive.files) assert.equal(createHash('sha256').update(Buffer.from(file.data, 'base64')).digest('hex'), file.sha256);
  assert.deepEqual(JSON.parse(Buffer.from(archive.files.find(f => f.path === 'package.json').data, 'base64')), { type: 'module' });
  await assert.rejects(packPlugin(root), /EEXIST/);
});
test('pack rejects symlink assets and native addons', async t => {
  const root = await fixture(t, simple);
  await symlink(join(root, 'src/index.js'), join(root, 'linked.js'));
  await writeFile(join(root, 'package.json'), JSON.stringify({ type: 'module', vorssaint: { source: 'src/index.js', assets: ['linked.js'] } }));
  await assert.rejects(packPlugin(root), /Symlinks/);
  await writeFile(join(root, 'src/index.js'), `import './native.node'; ${simple}`);
  await assert.rejects(buildPlugin(root), /Native add-ons/);
});
test('create makes a standalone typed starter without running installation', async t => {
  const parent = await folder(t);
  const root = await createPlugin(join(parent, 'my-plugin'));
  const pkg = JSON.parse(await readFile(join(root, 'package.json'), 'utf8'));
  assert.equal(pkg.dependencies['@vorssaint/plugin-sdk'], 'file:./sdk');
  assert.match(await readFile(join(root, 'src/index.ts'), 'utf8'), /definePlugin/);
});
test('runner handles split framing, handshake and invocation', async t => {
  const r = await runner(t, simple);
  r.child.stdin.write('{"jsonrpc":"2.0","id":"init","method":"init');
  r.child.stdin.write('ialize","params":{"apiVersion":1}}\n');
  assert.deepEqual((await r.wait('init')).result, { apiVersion: 1, pluginID: manifest.id });
  r.send('command1', 'command', { commandID: 'hello', argument: 'Hi' });
  assert.deepEqual((await r.wait('command1')).result, { message: 'Hi' });
});
test('runner rejects malformed frames, pre-handshake requests and mismatched exports', async t => {
  const r = await runner(t, simple);
  r.child.stdin.write('not json\n');
  assert.equal((await r.wait(null)).error.code, -32700);
  r.send('early', 'command', { commandID: 'hello' });
  assert.match((await r.wait('early')).error.message, /Initialize/);
  const mismatch = await runner(t, 'export default {commands: {}};');
  assert.match((await mismatch.initialize()).error.message, /exports do not match/);
});
test('host callbacks carry parent identity and search cannot use action APIs', async t => {
  const source = `export default { commands: { hello: async ({argument}, host) => { await host.clipboard.writeText(argument); return {message:'copied'}; } }, searchProviders: { find: async (_input,host) => { await host.url.open('https://example.com'); return {items:[]}; } } };`;
  const r = await runner(t, source);
  await r.initialize();
  r.send('c', 'command', { commandID: 'hello', argument: 'Example' });
  const callback = await r.wait('plugin:1');
  assert.deepEqual(callback.params, { text: 'Example', requestID: 'c' });
  r.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: callback.id, result: null })}\n`);
  assert.equal((await r.wait('c')).result.message, 'copied');
  r.send('s', 'search', { providerID: 'find', query: 'term' });
  assert.match((await r.wait('s')).error.message, /unavailable during search/);
});
test('cancellation aborts signal and prevents late result delivery', async t => {
  const source = `export default { commands: { hello: async () => ({}) }, searchProviders: { find: async ({signal}) => { await new Promise(resolve => signal.addEventListener('abort', resolve, {once:true})); return {items:[]}; } } };`;
  const r = await runner(t, source);
  await r.initialize();
  r.send('s', 'search', { providerID: 'find', query: 'term' });
  r.send(undefined, 'cancel', { requestID: 's' });
  assert.equal((await r.wait('s')).error.code, -32800);
  r.send('c', 'command', { commandID: 'hello' });
  assert.deepEqual((await r.wait('c')).result, {});
  assert.equal(r.messages.filter(m => m.id === 's').length, 0);
});
test('oversized frame terminates runner', async t => {
  const r = await runner(t, simple);
  await r.initialize();
  r.child.stdin.on('error', () => {});
  const exit = new Promise(resolve => r.child.once('exit', resolve));
  r.child.stdin.write('x'.repeat(1024 * 1024 + 1));
  assert.equal(await exit, 1);
});
test('logs stay off stdout and are bounded', async t => {
  const source = `console.log('x'.repeat(100000)); ${simple}`;
  const r = await runner(t, source);
  assert.ok((await r.initialize()).result);
  assert.ok(Buffer.byteLength(r.logs()) < 65536);
});
test('native fetch works', async t => {
  const server = createServer((_request, response) => response.end('available'));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  const port = server.address().port;
  const source = `export default { commands: { hello: async ({signal}) => ({message: await (await fetch('http://127.0.0.1:${port}', {signal})).text()}) }, searchProviders: {find: async () => ({items:[]})} };`;
  const r = await runner(t, source);
  await r.initialize();
  r.send('fetch', 'command', { commandID: 'hello' });
  const response = await r.wait('fetch');
  assert.deepEqual(response.result, {message: 'available'}, JSON.stringify(response) + r.logs());
});

test('runner conforms to the version 1 compatibility fixture', async t => {
  const fixture = JSON.parse(await readFile(new URL('../protocol-v1.json', import.meta.url), 'utf8'));
  const r = await runner(t, `export default {commands:{uppercase:async ({argument},host)=>{await host.clipboard.writeText(argument.toUpperCase());return {message:'Copied uppercase text'};}}};`, { ...fixture.manifest, searchProviders: [] });
  for (const step of fixture.messages) {
    if (step.direction === 'hostToPlugin') r.child.stdin.write(`${JSON.stringify(step.message)}\n`);
    else assert.deepEqual(await r.wait(step.message.id), step.message);
  }
});
test('packer rejects bundled dependencies that require install scripts', async t => {
  const root = await fixture(t, `import value from 'scripted'; ${simple}`);
  await mkdir(join(root, 'node_modules/scripted'), { recursive: true });
  await writeFile(join(root, 'node_modules/scripted/package.json'), JSON.stringify({ name: 'scripted', main: 'index.js', scripts: { install: 'node install.js' } }));
  await writeFile(join(root, 'node_modules/scripted/index.js'), 'console.log("dependency"); export default 1;');
  await assert.rejects(buildPlugin(root), /requires install scripts/);
});
test('runner rejects undeclared capabilities and non-Error throws', async t => {
  const source = `export default {commands:{hello:async ({argument},host)=>{if(argument==='null') throw null; await host.clipboard.writeText('text');}},searchProviders:{find:async()=>({items:[]})}};`;
  const r = await runner(t, source, { capabilities: [] });
  await r.initialize();
  r.send('denied', 'command', { commandID: 'hello' });
  assert.match((await r.wait('denied')).error.message, /Capability not declared/);
  r.send('null', 'command', { commandID: 'hello', argument: 'null' });
  assert.match((await r.wait('null')).error.message, /Plugin request failed/);
});
test('runner validates result actions and executes their arguments', async t => {
  const source = `export default {commands:{hello:async()=>({})},searchProviders:{find:async()=>({items:[{id:'r',title:'Result',actions:[{id:'open',title:'Open',arguments:{value:'selected'}}]}]})},actions:{open:async ({arguments:args})=>({message:args.value})}};`;
  const r = await runner(t, source);
  await r.initialize();
  r.send('s', 'search', { providerID: 'find', query: 'term' });
  const action = (await r.wait('s')).result.items[0].actions[0];
  r.send('a', 'action', { actionID: action.id, arguments: action.arguments });
  assert.deepEqual((await r.wait('a')).result, { message: 'selected' });
});

test('late host responses after cancellation cannot revive a request', async t => {
  const source = `export default {commands:{hello:async ({argument},host)=>{if(argument) await host.clipboard.writeText(argument);return {message:'done'};}},searchProviders:{find:async()=>({items:[]})}};`;
  const r = await runner(t, source);
  await r.initialize();
  r.send('c', 'command', { commandID: 'hello', argument: 'copy' });
  const callback = await r.wait('plugin:1');
  r.send(undefined, 'cancel', { requestID: 'c' });
  assert.equal((await r.wait('c')).error.code, -32800);
  r.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: callback.id, result: null })}\n`);
  r.send('next', 'command', { commandID: 'hello' });
  assert.deepEqual((await r.wait('next')).result, { message: 'done' });
  assert.equal(r.messages.length, 0);
});

test('packed TypeScript examples execute their distributed entry files', async t => {
  const output = await folder(t);
  for (const name of ['text-tools', 'web-search', 'alpha-test']) {
    const archivePath = await packPlugin(resolve('examples', name), join(output, `${name}.vorssaint-plugin`));
    const archive = JSON.parse(await readFile(archivePath, 'utf8'));
    const entry = archive.files.find(file => file.path === archive.manifest.main);
    const r = await runner(t, Buffer.from(entry.data, 'base64').toString('utf8'), { ...archive.manifest, commands: archive.manifest.commands ?? [], searchProviders: archive.manifest.searchProviders ?? [] });
    assert.equal((await r.initialize()).result.pluginID, archive.manifest.id);
    if (name === 'text-tools') {
      r.send('invoke', 'command', { commandID: 'uppercase', argument: 'example' });
      const callback = await r.wait('plugin:1');
      assert.equal(callback.params.text, 'EXAMPLE');
      r.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: callback.id, result: null })}\n`);
      assert.equal((await r.wait('invoke')).result.message, 'Copied uppercase text');
    } else if (name === 'web-search') {
      r.send('search', 'search', { providerID: 'wikipedia', query: '' });
      assert.deepEqual((await r.wait('search')).result, { items: [] });
    }
  }
});

test('alpha test plugin exercises every host capability and result field', async t => {
  const output = await folder(t);
  const archivePath = await packPlugin(resolve('examples', 'alpha-test'), join(output, 'alpha-test.vorssaint-plugin'));
  const archive = JSON.parse(await readFile(archivePath, 'utf8'));
  assert.deepEqual(new Set(archive.manifest.capabilities), new Set([
    'clipboard.write', 'url.open', 'settings.read', 'storage.read', 'storage.write', 'status.show',
  ]));
  assert.deepEqual(archive.manifest.settings.map(setting => setting.type), ['string', 'boolean', 'number']);
  assert.equal(archive.manifest.minimumHostVersion, '0.0.0');
  assert.ok(archive.files.some(file => file.path === 'TESTING.md'));

  const entry = archive.files.find(file => file.path === archive.manifest.main);
  const r = await runner(t, Buffer.from(entry.data, 'base64').toString('utf8'), archive.manifest);
  await r.initialize();
  r.send('all', 'command', { commandID: 'run-all', argument: 'alpha argument' });
  const expectedCalls = [
    ['settings.get', { key: 'label', requestID: 'all' }, 'changed label'],
    ['settings.get', { key: 'enabled', requestID: 'all' }, false],
    ['settings.get', { key: 'count', requestID: 'all' }, 12],
    ['storage.get', { key: 'lastRun', requestID: 'all' }, { prior: true }],
    ['storage.set', undefined, null],
    ['clipboard.write', undefined, null],
    ['status.show', { message: 'All capability checks completed', requestID: 'all' }, null],
  ];
  for (let index = 0; index < expectedCalls.length; index += 1) {
    const [method, params, result] = expectedCalls[index];
    const callback = await r.wait(`plugin:${index + 1}`);
    assert.equal(callback.method, method);
    if (params) assert.deepEqual(callback.params, params);
    if (method === 'storage.set') {
      assert.equal(callback.params.key, 'lastRun');
      assert.equal(callback.params.value.argument, 'alpha argument');
      assert.deepEqual(callback.params.value.previous, { prior: true });
    }
    if (method === 'clipboard.write') {
      assert.match(callback.params.text, /"changed label"/);
      assert.equal(callback.params.requestID, 'all');
    }
    r.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: callback.id, result })}\n`);
  }
  assert.match((await r.wait('all')).result.message, /storage round-tripped/);

  r.send('open', 'command', { commandID: 'open-docs', argument: '' });
  const open = await r.wait('plugin:8');
  assert.equal(open.method, 'url.open');
  assert.match(open.params.url, /\/alpha\/docs\/PLUGINS\.md$/);
  r.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: open.id, result: null })}\n`);
  assert.equal((await r.wait('open')).result.message, 'Opened plugin documentation');

  r.send('search', 'search', { providerID: 'all-options', query: 'all fields' });
  const search = (await r.wait('search')).result;
  assert.equal(search.items.length, 2);
  assert.equal(search.items[0].subtitle, 'Subtitle, SF Symbol, and three actions');
  assert.equal(search.items[0].symbol, 'puzzlepiece.extension.fill');
  assert.deepEqual(search.items[0].actions[0].arguments.array, ['one', 2, false, null]);
  assert.equal(search.items[1].subtitle, undefined);
  assert.equal(search.items[1].symbol, undefined);

  r.send('action', 'action', {
    actionID: search.items[0].actions[0].id,
    arguments: search.items[0].actions[0].arguments,
  });
  const status = await r.wait('plugin:9');
  assert.equal(status.method, 'status.show');
  assert.match(status.params.message, /"all fields"/);
  r.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id: status.id, result: null })}\n`);
  assert.equal((await r.wait('action')).result.message, 'Displayed action arguments');

  r.send('void', 'command', { commandID: 'no-message', argument: '' });
  assert.deepEqual((await r.wait('void')).result, {});
  r.send('error', 'command', { commandID: 'expected-error', argument: '' });
  assert.match((await r.wait('error')).error.message, /Expected alpha test error/);
});
