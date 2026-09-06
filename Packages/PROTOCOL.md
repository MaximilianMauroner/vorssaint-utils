# Plugin protocol version 1

Transport is JSON-RPC 2.0 over stdin/stdout, one UTF-8 JSON object per newline. IDs are nonempty strings of at most 128 characters. Stdout is reserved for RPC; `console` methods write bounded diagnostics to stderr. Do not log user queries, settings, tokens, or secrets.

A frame is at most 1 MiB, excluding its newline. The runner handles partial frames, rejects malformed JSON, and exits on oversized frames. Each process accepts at most 8 active invocations and 64 pending host callbacks. Console output is limited to 64 KiB per process, with 4 KiB per call. The host also bounds raw stdout and stderr from trusted code that bypasses console.

| Host request method | Params | Result |
| --- | --- | --- |
| `initialize` | `{ apiVersion: 1 }` | `{ apiVersion: 1, pluginID }` |
| `command` | `{ commandID, argument }` | `{ message? }` |
| `search` | `{ providerID, query }` | `{ items: [...] }` |
| `action` | `{ actionID, arguments }` | `{ message? }` |

Initialize once before invocation. Exported command and search IDs must exactly match the manifest. A search result's action IDs must be exported in `actions`. The host binds selected actions to the validated results it received.

A cancellation notification has no ID: `{ "jsonrpc": "2.0", "method": "cancel", "params": { "requestID": "search-1" } }`. It aborts the handler signal, rejects pending callbacks, and responds to the original request with error code `-32800`. Late completion does not send another response. Cancellation is cooperative; the host enforces deadlines and terminates unresponsive code. Never replay commands after a crash.

Host callbacks use IDs `plugin:1`, `plugin:2`, and so on. Their params always include `requestID`, the active command/search/action request that caused the callback. The host uses this parent ID to verify deadline, cancellation, and whether an action API is permitted.

| Callback method | Additional params | Result |
| --- | --- | --- |
| `clipboard.write` | `{ text }` | `null` |
| `url.open` | `{ url }` | `null` |
| `settings.get` | `{ key }` | JSON value or `null` |
| `storage.get` | `{ key }` | JSON value or `null` |
| `storage.set` | `{ key, value }` | `null` |
| `status.show` | `{ message }` | `null` |

Errors use `{ code, message }`. Standard parse/request/method/params errors use `-32700`, `-32600`, `-32601`, and `-32602`. Handler errors use `-32000`; busy uses `-32001`. Hosts must tolerate any structured error without a crash. Error text is for display, not control flow.

The archive is `{ formatVersion: 1, manifest, files: [{ path, data, sha256 }] }`. `data` is standard base64. `sha256` is lowercase hexadecimal over decoded bytes. Limits are 30 MiB serialized, 20 MiB decoded, and 512 files. The importer rejects duplicate paths, including filesystem case collisions, unsafe paths, unsupported file types, invalid hashes, and a missing main file. The manifest lives at top level; the importer writes it as `plugin.json`. The packer includes a hashed `package.json` containing only `{ "type": "module" }` so `.js` uses ESM.

IDs use letters, digits, dots, underscores, or hyphens, start with a letter or digit, and have at most 128 characters. Plugin IDs contain a dot. Command/provider IDs are globally unique with 1–100 entries combined. Keywords use lowercase letters, digits, or hyphens and have at most 32 characters. Settings support only string, boolean, and finite number defaults.

Names and static titles are at most 120 characters. Search rows are capped at 100, titles at 512 characters, subtitles at 2048, symbols at 120, and actions at 10 per row. Arguments and query text are at most 16384 characters. Clipboard text is at most 256 Ki characters, URLs at 8192, and status/completion messages at 4096. The native host may apply additional storage and URL rules.

The compatibility fixture records one complete invocation and callback. Keep it stable within API major 1. Both the Swift and JavaScript implementations must reject unsupported majors before loading plugin code.
