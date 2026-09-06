# External plugins

External plugins add TypeScript or JavaScript commands and keyword searches to the Command Bar. Manage them in **Settings → Features → Plugins**. The list and detail view uses the same native controls as the built-in feature settings.

Import a `.vorssaint-plugin` file, review its name and version, then import it disabled. Select the plugin and enable it after reviewing the trust notice. Plugins run local code with your user account's access. They can access files, network services, and other programs. The displayed capabilities limit the Vorssaint API bridge; they do not sandbox Node.js.

Use the command's title followed by its text argument, such as `Uppercase text hello`. For a search provider, type its keyword followed by a space and the query, such as `wiki Swift`. Other text in the Command Bar is not sent to that provider. Selecting an additional result action uses its separate native row. Commands report completion or errors in the bar.

Disable stops the managed plugin process and removes its commands. Updates install disabled and require a new trust review. Restore Previous Version also restores disabled code. Settings and stored data remain available across these operations. Removal keeps data unless you select its separate deletion option.

## Write a plugin

The [author guide](../Packages/README.md) covers the SDK, CLI, manifest, dependency support, settings, package creation, and examples. The [protocol](../Packages/PROTOCOL.md) defines the process messages and archive format.

The SDK and CLI are included in this repository; they have not been published to npm. Authors need Node and pnpm. End users need neither. Rebuild and import a package to test changes in the app. A live folder reload workflow is not included in this first version.

## Runtime and release checks

The build downloads Node.js 24.13.1 for Apple Silicon and checks a pinned SHA-256 digest. Code lives in `Contents/Helpers/plugin-node`; the host runner and Node license live in `Contents/Resources/PluginRuntime`. Only the separate Node executable receives `allow-jit`. The main app's entitlements are unchanged. Normal Node execution is required: `--jitless` breaks built-in `fetch` in this Node release.

The downloaded runtime archive is approximately 49 MiB; its executable is approximately 114 MiB unpacked. These are file sizes measured in Linux, not Mac memory measurements. Launch is on demand, with at most two managed plugin processes. Search has a two-second deadline, commands ten seconds, and idle processes stop after thirty seconds. The Node heap budget is not a hard total-memory limit. The host does not sandbox or control detached programs started by trusted plugin code.

Run the following in an isolated macOS checkout. The existing `--test` command removes its `build` directory.

```sh
./build.sh
./build/Vorssaint --selftest
./Tools/test-plugins.sh
./Tools/make-dmg.sh
./build.sh --test
```

`test-plugins.sh` checks the signed runtime's version and native `fetch`, then compiles and runs standalone package and subprocess tests. CI runs it before the existing test command removes the staged app. The SDK tests run separately on Linux.

Before a release, verify Developer ID signing and notarization, clean installation on macOS 14, and both example plugins through the actual Settings and Command Bar views. Measure cold and warm launch latency, process RSS, and idle CPU on the minimum supported Mac. Check disable, update, rollback, removal, app exit, and source toggles while requests are active. Do not add broader signing entitlements to bypass a failed runtime check.

The current workspace is Linux. TypeScript checks and 18 SDK/package/process tests passed. Runtime download checks, shell syntax, property lists, CI YAML, and Swift source parsing passed. macOS compilation, native tests, actual UI rendering, signed runtime launch, and notarization have not been run here. The new plugin labels currently use English; reviewed translations remain release work.
