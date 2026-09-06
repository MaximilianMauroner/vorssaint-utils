export const LIMITS = Object.freeze({ frame: 1024 * 1024, rows: 100, files: 512, decodedBytes: 20 * 1024 * 1024, archiveBytes: 30 * 1024 * 1024 });
const identifier = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/;
const version = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;
export const capabilities = new Set(['clipboard.write', 'url.open', 'settings.read', 'storage.read', 'storage.write', 'status.show']);
export function object(value, label = 'value') {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label} must be an object`);
  return value;
}
export function text(value, label, max = 4096) {
  if (typeof value !== 'string' || value.length > max) throw new Error(`${label} must be text of at most ${max} characters`);
  return value;
}
export function id(value, label = 'ID') {
  if (typeof value !== 'string' || !identifier.test(value)) throw new Error(`Invalid ${label}`);
  return value;
}
export function safePath(value) {
  text(value, 'File path', 512);
  if (!value || value.includes('\\') || /[\u0000-\u001f]/.test(value) || value.startsWith('/') || value.split('/').some(p => !p || p === '.' || p === '..' || p.includes(':'))) throw new Error(`Unsafe package path: ${value}`);
  return value;
}
export function validateManifest(value) {
  const m = object(value, 'Manifest');
  id(m.id, 'plugin ID');
  if (!m.id.includes('.')) throw new Error('Plugin ID must use reverse-domain notation');
  if (!text(m.name, 'Plugin name', 120).trim()) throw new Error('Plugin name is required');
  if (m.apiVersion !== 1) throw new Error('Unsupported plugin API version; this host supports version 1');
  if (typeof m.version !== 'string' || !version.test(m.version)) throw new Error('Version must be a semantic version');
  if (m.minimumHostVersion !== undefined && (typeof m.minimumHostVersion !== 'string' || !version.test(m.minimumHostVersion))) throw new Error('Invalid minimumHostVersion');
  safePath(m.main);
  if (!/\.(?:m?js)$/.test(m.main)) throw new Error('main must be an ESM JavaScript file');
  if (!Array.isArray(m.capabilities) || m.capabilities.some(c => !capabilities.has(c)) || new Set(m.capabilities).size !== m.capabilities.length) throw new Error('Unknown or duplicate capability');
  const all = new Set();
  for (const [key, search] of [['commands', false], ['searchProviders', true]]) {
    const entries = m[key] ?? [];
    if (!Array.isArray(entries) || entries.length > 100) throw new Error(`Invalid ${key}`);
    const keywords = new Set();
    for (const entry of entries) {
      object(entry); id(entry.id); text(entry.title, 'Title', 120);
      if (!entry.title.trim() || all.has(entry.id)) throw new Error('Command/provider IDs must be unique and titles nonempty');
      all.add(entry.id);
      if (search) {
        if (typeof entry.keyword !== 'string' || !/^[a-z0-9][a-z0-9-]{0,31}$/.test(entry.keyword) || keywords.has(entry.keyword)) throw new Error('Invalid or duplicate search keyword');
        keywords.add(entry.keyword);
      } else if (entry.input !== undefined && !['text', 'none'].includes(entry.input)) throw new Error('Invalid command input');
    }
  }
  if (!all.size || all.size > 100) throw new Error('Manifest requires 1–100 commands and search providers combined');
  const settings = m.settings ?? [];
  if (!Array.isArray(settings) || settings.length > 100) throw new Error('Invalid settings');
  const keys = new Set();
  for (const setting of settings) {
    object(setting); id(setting.key, 'setting key'); text(setting.title, 'Setting title', 120);
    if (!setting.title.trim()) throw new Error('Setting title is required');
    if (keys.has(setting.key) || !['string', 'number', 'boolean'].includes(setting.type)) throw new Error('Invalid or duplicate setting');
    keys.add(setting.key);
    if (setting.default !== undefined && (typeof setting.default !== setting.type || (setting.type === 'number' && !Number.isFinite(setting.default)))) throw new Error('Setting default has the wrong type');
  }
  return m;
}
export function validateExports(plugin, manifest) {
  object(plugin, 'Default plugin export');
  for (const key of ['commands', 'searchProviders', 'actions']) {
    const handlers = object(plugin[key] ?? {}, key);
    for (const [name, handler] of Object.entries(handlers)) {
      id(name);
      if (typeof handler !== 'function') throw new Error(`${key}.${name} must be a function`);
    }
    if (key !== 'actions') {
      const expected = (manifest[key] ?? []).map(x => x.id).sort();
      if (JSON.stringify(Object.keys(handlers).sort()) !== JSON.stringify(expected)) throw new Error(`${key} exports do not match the manifest`);
    }
  }
  return plugin;
}
export function validateResult(result, search, plugin) {
  const value = result ?? {};
  object(value, 'Handler result');
  if (!search) {
    if (value.message !== undefined) text(value.message, 'Message', 4096);
    return value.message === undefined ? {} : { message: value.message };
  }
  if (!Array.isArray(value.items) || value.items.length > LIMITS.rows) throw new Error('Search must return at most 100 items');
  const ids = new Set();
  for (const row of value.items) {
    object(row); id(row.id, 'result ID'); text(row.title, 'Result title', 512);
    if (!row.title.trim() || ids.has(row.id)) throw new Error('Result IDs must be unique and titles nonempty');
    ids.add(row.id);
    if (row.subtitle !== undefined) text(row.subtitle, 'Subtitle', 2048);
    if (row.symbol !== undefined) text(row.symbol, 'Symbol', 120);
    if (!Array.isArray(row.actions) || row.actions.length < 1 || row.actions.length > 10) throw new Error('Each result requires 1–10 actions');
    const actions = new Set();
    for (const action of row.actions) {
      object(action); id(action.id, 'action ID'); text(action.title, 'Action title', 120);
      if (!action.title.trim()) throw new Error('Action title is required');
      if (!Object.hasOwn(plugin.actions ?? {}, action.id) || actions.has(action.id)) throw new Error('Unknown or duplicate result action');
      actions.add(action.id);
    }
  }
  return value;
}
