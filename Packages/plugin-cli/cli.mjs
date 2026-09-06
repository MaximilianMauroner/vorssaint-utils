#!/usr/bin/env node
import { build as bundle } from 'esbuild';
import { readFile, writeFile, mkdir, lstat, readdir, realpath, copyFile } from 'node:fs/promises';
import { resolve, dirname, relative, join, extname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { LIMITS, validateManifest, safePath } from '../plugin-runtime/validation.mjs';

async function json(path) { return JSON.parse(await readFile(path, 'utf8')); }
async function regularFile(root, path) {
  safePath(path);
  const file = resolve(root, path);
  const rootPath = await realpath(root);
  let cursor = root;
  for (const part of path.split('/')) {
    cursor = join(cursor, part);
    if ((await lstat(cursor)).isSymbolicLink()) throw new Error(`Symlinks are not supported: ${path}`);
  }
  if (!(await lstat(file)).isFile() || !relative(rootPath, await realpath(file)) || relative(rootPath, await realpath(file)).startsWith('..')) throw new Error(`Not a package file: ${path}`);
  return file;
}
async function expandAssets(root, patterns) {
  const files = [];
  async function visit(path) {
    safePath(path);
    const info = await lstat(resolve(root, path));
    if (info.isSymbolicLink()) throw new Error(`Symlinks are not supported: ${path}`);
    if (info.isDirectory()) {
      for (const child of (await readdir(resolve(root, path))).sort()) await visit(`${path}/${child}`);
    } else if (info.isFile()) {
      if (extname(path) === '.node') throw new Error('Native add-ons are not supported');
      files.push(path);
      if (files.length > LIMITS.files) throw new Error('Too many assets');
    } else throw new Error(`Unsupported asset: ${path}`);
  }
  for (const pattern of patterns) await visit(safePath(pattern));
  return files;
}
async function inspectDependencies(root, inputs) {
  const packages = new Map();
  for (const input of inputs) {
    let folder = dirname(resolve(root, input));
    while (folder !== dirname(folder)) {
      const packagePath = join(folder, 'package.json');
      try {
        const pkg = await json(packagePath);
        if (['preinstall', 'install', 'postinstall'].some(key => pkg.scripts?.[key]) || pkg.gypfile) throw new Error(`Dependency ${pkg.name ?? folder} requires install scripts or native code`);
        if (folder !== root && pkg.name) packages.set(folder, pkg);
        break;
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      folder = dirname(folder);
    }
  }
  let notices = 'Bundled dependency notices\n\n';
  for (const [folder, pkg] of packages) {
    notices += `${pkg.name} ${pkg.version ?? ''}\nLicense: ${pkg.license ?? 'See package license'}\n`;
    for (const file of (await readdir(folder)).filter(name => /^(license|copying|notice)(\.|$)/i.test(name))) {
      if ((await lstat(join(folder, file))).isFile()) notices += `${await readFile(join(folder, file), 'utf8')}\n`;
    }
    notices += '\n';
  }
  return notices;
}
export async function buildPlugin(directory) {
  const root = await realpath(directory);
  const manifest = validateManifest(await json(join(root, 'plugin.json')));
  const pkg = await json(join(root, 'package.json'));
  const source = pkg.vorssaint?.source ?? 'src/index.ts';
  await regularFile(root, source);
  if (!manifest.main.startsWith('dist/')) throw new Error('CLI output main must be inside dist/');
  const result = await bundle({ absWorkingDir: root, entryPoints: [source], bundle: true, platform: 'node', target: 'node24', format: 'esm', logLevel: 'silent', outfile: manifest.main, write: false, metafile: true,
    banner: { js: "import { createRequire as __vorssaintCreateRequire } from 'node:module'; const require = __vorssaintCreateRequire(import.meta.url);" },
    plugins: [{ name: 'no-native-addons', setup(build) { build.onResolve({ filter: /\.node$/ }, () => ({ errors: [{ text: 'Native add-ons are not supported' }] })); } }],
  });
  const notices = await inspectDependencies(root, Object.keys(result.metafile.inputs));
  const output = resolve(root, manifest.main);
  await mkdir(dirname(output), { recursive: true });
  // Reject existing links before writing output or notices.
  for (const path of [manifest.main, 'dist/THIRD_PARTY_NOTICES.txt']) {
    let cursor = root;
    for (const part of path.split('/')) {
      cursor = join(cursor, part);
      try { if ((await lstat(cursor)).isSymbolicLink()) throw new Error('Build output cannot contain symlinks'); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
  }
  await writeFile(output, result.outputFiles[0].contents);
  await writeFile(join(root, 'dist/THIRD_PARTY_NOTICES.txt'), notices);
  return manifest;
}
export async function packPlugin(directory, destination) {
  const root = await realpath(directory);
  const manifest = await buildPlugin(root);
  const pkg = await json(join(root, 'package.json'));
  const assets = pkg.vorssaint?.assets ?? [];
  if (!Array.isArray(assets) || assets.some(p => typeof p !== 'string')) throw new Error('vorssaint.assets must be an array of paths');
  const paths = [...new Set([manifest.main, 'dist/THIRD_PARTY_NOTICES.txt', ...(await expandAssets(root, assets))])].sort();
  if (new Set(paths.map(path => path.toLowerCase())).size !== paths.length) throw new Error('Package paths must be unique without case sensitivity');
  if (paths.length > LIMITS.files) throw new Error('Too many package files');
  let size = 0;
  const files = [];
  for (const path of paths) {
    if (['plugin.json', 'package.json'].includes(path.toLowerCase()) || path.toLowerCase().split('/').includes('node_modules')) throw new Error(`Reserved package asset: ${path}`);
    const file = await regularFile(root, path);
    size += (await lstat(file)).size;
    if (size + Buffer.byteLength('{"type":"module"}\n') > LIMITS.decodedBytes) throw new Error('Package exceeds 20 MiB');
    const data = await readFile(file);
    files.push({ path, data: data.toString('base64'), sha256: createHash('sha256').update(data).digest('hex') });
  }
  // ESM mode is generated by the packer; end users never run package installation.
  const esm = Buffer.from('{"type":"module"}\n');
  files.push({ path: 'package.json', data: esm.toString('base64'), sha256: createHash('sha256').update(esm).digest('hex') });
  if (files.length > LIMITS.files) throw new Error('Too many package files');
  const archive = JSON.stringify({ formatVersion: 1, manifest, files });
  if (Buffer.byteLength(archive) > LIMITS.archiveBytes) throw new Error('Archive exceeds 30 MiB');
  const output = resolve(destination ?? join(root, `${manifest.id}-${manifest.version}.vorssaint-plugin`));
  await writeFile(output, archive, { flag: 'wx' });
  return output;
}
export async function createPlugin(directory) {
  const root = resolve(directory);
  await mkdir(root, { recursive: false });
  await mkdir(join(root, 'src'));
  await mkdir(join(root, 'sdk'));
  const sdk = resolve(dirname(fileURLToPath(import.meta.url)), '../plugin-sdk');
  for (const file of ['package.json', 'index.js', 'index.d.ts', 'LICENSE']) await copyFile(join(sdk, file), join(root, 'sdk', file));
  const name = basename(root).toLowerCase().replace(/[^a-z0-9-]/g, '-');
  await writeFile(join(root, 'package.json'), JSON.stringify({ name, private: true, type: 'module', dependencies: { '@vorssaint/plugin-sdk': 'file:./sdk' }, vorssaint: { source: 'src/index.ts', assets: [] } }, null, 2) + '\n');
  await writeFile(join(root, 'plugin.json'), JSON.stringify({ id: `com.example.${name}`, name: 'My plugin', version: '0.1.0', apiVersion: 1, main: 'dist/index.js', commands: [{ id: 'hello', title: 'Say hello', input: 'text' }], capabilities: [] }, null, 2) + '\n');
  await writeFile(join(root, 'src/index.ts'), `import { definePlugin } from '@vorssaint/plugin-sdk';\n\nexport default definePlugin({\n  commands: { hello: async ({ argument }) => ({ message: \`Hello \${argument || 'world'}\` }) },\n});\n`);
  return root;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [command, directory, destination] = process.argv.slice(2);
  try {
    if (!directory || !['create', 'build', 'pack', 'validate'].includes(command)) throw new Error('Usage: vorssaint-plugin <create|build|pack|validate> <directory> [archive-path]');
    const result = command === 'create' ? await createPlugin(directory) : command === 'build' ? await buildPlugin(directory) : command === 'pack' ? await packPlugin(directory, destination) : validateManifest(await json(resolve(directory, 'plugin.json')));
    console.log(typeof result === 'string' ? result : `Validated ${result.id} ${result.version}`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
