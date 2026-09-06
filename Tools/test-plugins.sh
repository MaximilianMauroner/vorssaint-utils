#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Native tests use temporary directories and never install or launch the app.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "$(uname -s)" == Darwin ]] || { echo 'Native plugin tests require macOS and Swift.' >&2; exit 1; }
contents="${1:-build/stage/Vorssaint.app/Contents}"
contents="$(cd "$contents" && pwd)"
plugin_node="$contents/Helpers/plugin-node"
plugin_runner="$contents/Resources/PluginRuntime/runner.mjs"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
codesign --verify --strict "$plugin_node"
[[ "$("$plugin_node" --version)" == v24.13.1 ]]
# Exercise V8 and fetch in the actual signed helper, including its Wasm HTTP parser.
"$plugin_node" --input-type=module -e '
import { createServer } from "node:http";
const server = createServer((_, response) => response.end("ready"));
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
try {
  const response = await fetch(`http://127.0.0.1:${server.address().port}`);
  if (await response.text() !== "ready") throw new Error("Bundled fetch failed");
} finally { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); }
'
swiftc -Onone Sources/Vorssaint/Core/Plugins/PluginModels.swift \
    Sources/Vorssaint/Services/Plugins/PluginStore.swift Tests/PluginTests.swift \
    -o "$test_dir/package-tests"
"$test_dir/package-tests"
swiftc -Onone Sources/Vorssaint/Core/Plugins/PluginModels.swift \
    Sources/Vorssaint/Services/Plugins/PluginProcess.swift Tests/PluginProcessTests.swift \
    -o "$test_dir/process-tests"
"$test_dir/process-tests" "$plugin_node" "$plugin_runner"
