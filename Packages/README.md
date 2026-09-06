# External plugins

Write commands and scoped search providers in TypeScript or JavaScript. The app runs a bundled Node.js 24.13.1 process when a plugin is used. Users do not install Node, npm dependencies, or build tools.

Plugins are trusted local code. Node can read files, use the network, and start processes with the user's access. Bridge capabilities restrict the app API only. They are not a sandbox. Install code only from an author you trust.

## Build the examples

From the repository root, with Node 24 and pnpm installed:

```sh
pnpm --dir Packages install --frozen-lockfile --ignore-scripts
pnpm --dir Packages check
pnpm --dir Packages test
pnpm --dir Packages build:examples
node Packages/plugin-cli/cli.mjs pack Packages/examples/text-tools
node Packages/plugin-cli/cli.mjs pack Packages/examples/web-search
```

Import each generated `.vorssaint-plugin` file in Vorssaint settings and review its trust warning. The text example adds **Uppercase text**. The search example uses the `wiki` keyword and opens an article only when its result action is selected.

The `alpha-test` example declares every version 1 option and capability. A ready-to-import archive lives at `Tests/Fixtures/VorssaintAlphaTest.vorssaint-plugin`; its [manual checklist](examples/alpha-test/TESTING.md) covers install trust, all three setting types, every bridge API, command inputs, search result fields and actions, errors, cancellation, updates, rollback, removal, retained data, and the Command Bar source switch.

`pack` builds from source and refuses to overwrite an existing archive. Supply a new output path as a fourth argument, or remove your old generated archive before packing the same version again.

## Create a plugin

The SDK and CLI ship in this repository. They are not published to npm yet. The starter copies the SDK into the new project so it does not depend on an unpublished registry package.

```sh
node Packages/plugin-cli/cli.mjs create /tmp/my-plugin
pnpm --dir /tmp/my-plugin install --ignore-scripts
node Packages/plugin-cli/cli.mjs build /tmp/my-plugin
node Packages/plugin-cli/cli.mjs pack /tmp/my-plugin
```

Use a folder that does not exist. Replace the starter's `com.example.*` ID with your own stable reverse-domain ID. Keep that ID for updates. Bump the semantic version for each release.

For JavaScript, rename `src/index.ts` to `src/index.js` and set `package.json`'s `vorssaint.source` to `src/index.js`. No compiler syntax is required. The same `definePlugin` import works in both languages.

The SDK currently follows this repository's GPL-3.0-or-later license. Its license file is copied with the starter and bundled notices. Review licensing before distributing your plugin and its dependencies.

## Author contract

`plugin.json` declares the public surface. The default JavaScript export supplies handlers with matching IDs.

```json
{
  "id": "com.example.text-tools",
  "name": "Text tools",
  "version": "0.1.0",
  "apiVersion": 1,
  "main": "dist/index.js",
  "commands": [{ "id": "uppercase", "title": "Uppercase text", "input": "text" }],
  "capabilities": ["clipboard.write"]
}
```

```ts
import { definePlugin } from '@vorssaint/plugin-sdk';

export default definePlugin({
  commands: {
    uppercase: async ({ argument, signal }, host) => {
      signal.throwIfAborted();
      await host.clipboard.writeText(argument.toUpperCase());
      return { message: 'Copied uppercase text' };
    },
  },
});
```

Search providers declare `{ id, title, keyword }` in `searchProviders`. Only matching keyword queries reach the provider. A `searchProviders` handler receives `{ query, signal }` and returns `{ items }`. Each row has a stable local `id`, `title`, optional `subtitle` and SF Symbol `symbol`, and 1–10 `actions`. An action has an exported action `id`, a `title`, and optional JSON `arguments`.

Action handlers receive `{ arguments, signal }`. Command and action handlers return `{ message? }` or no value. See `examples/web-search/src/index.ts` for a complete HTTP search and action pair. Pass `signal` to `fetch` and other cancellable work. Do not start persistent background work. Disabling a plugin and idle expiry terminate its process.

| SDK method | Capability | Notes |
| --- | --- | --- |
| `host.clipboard.writeText(text)` | `clipboard.write` | Command/action only |
| `host.url.open(url)` | `url.open` | Command/action only; host validates URL scheme |
| `host.settings.get(key)` | `settings.read` | Key must be declared in the manifest |
| `host.storage.get(key)` | `storage.read` | Missing values return `null` |
| `host.storage.set(key, value)` | `storage.write` | JSON values; keep stored data compatible with rollback |
| `host.status.show(message)` | `status.show` | Native status feedback |

Settings declarations use `{ key, title, type, default? }`, where `type` is `string`, `number`, or `boolean`. The optional `minimumHostVersion` is a semantic version. Unsupported API versions fail before code runs. The host derives identity from its process record; a plugin cannot select another plugin's storage namespace through the bridge.

Await host calls before returning. Calls after a handler has completed or been cancelled fail. Search cannot write the clipboard or open a URL through the bridge. This applies even when the manifest declares those capabilities.

## Dependencies and assets

Install pure JavaScript dependencies during development. The CLI uses esbuild to bundle imports and compatible npm dependencies into one ESM file. It rejects bundled dependencies with install hooks or native add-ons. It does not run dependency installation. Built-in Node modules and the global `fetch` function are available. Packages with unresolved dynamic imports or runtime file discovery need explicit assets and testing of the packed result. Compatibility with every npm package is not guaranteed.

Declare asset files or folders in `package.json`:

```json
{ "vorssaint": { "source": "src/index.ts", "assets": ["assets", "LICENSE"] } }
```

Paths are relative to the plugin root. Read assets from `process.cwd()`, which is the installed package root. Assets must be ordinary files; symlinks, traversal, native `.node` files, `node_modules`, and author package metadata are rejected. The packer generates an ESM-only `package.json`. It includes license notices for bundled dependencies. Check that all license obligations are met before release.

## Package and process protocol

See [PROTOCOL.md](PROTOCOL.md) and [protocol-v1.json](protocol-v1.json) for the wire contract. `.vorssaint-plugin` is a UTF-8 JSON archive, not a ZIP file. This avoids archive extraction behavior and permits validation before writing files. SHA-256 hashes detect changed bytes; they do not verify a publisher.

The host launches `runner.mjs` with the absolute entry path and installed root as its working directory. The runner imports the adjacent `validation.mjs`. Both files must ship in `Resources/PluginRuntime`. The dedicated Node helper is signed separately with its JIT entitlement. Signing, notarization, clean-Mac launch, and runtime performance require macOS release checks.

Do not enable `--jitless`: Node 24's built-in `fetch` uses WebAssembly in its HTTP parser and fails with that flag. The test suite exercises `fetch` against a local HTTP server with the normal runtime.

The app release maintainer owns the pinned Node version and security updates. Update the runtime pin, hashes, and CI checks together; verify the oldest supported macOS version before shipping.
