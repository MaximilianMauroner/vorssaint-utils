#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Bundle the pinned runtime without relying on a user's Node installation.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
contents="${1:?Usage: bundle-plugin-runtime.sh path/to/App.app/Contents}"
node_version="24.13.1"
archive_name="node-v${node_version}-darwin-arm64.tar.gz"
archive_hash="8c039d59f2fec6195e4281ad5b0d02b9a940897b4df7b849c6fb48be6787bba6"
cache_dir="$repo_root/.build/plugin-runtime"
mkdir -p "$cache_dir"
archive="$cache_dir/$archive_name"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
if [[ ! -f "$archive" ]]; then
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 180 \
        "https://nodejs.org/dist/v${node_version}/${archive_name}" -o "$staging/runtime.tar.gz"
    actual_hash="$(shasum -a 256 "$staging/runtime.tar.gz" | awk '{print $1}')"
    [[ "$actual_hash" == "$archive_hash" ]] || { echo 'Node runtime checksum mismatch.' >&2; exit 1; }
    mv "$staging/runtime.tar.gz" "$archive"
fi
actual_hash="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual_hash" == "$archive_hash" ]] || { echo 'Cached Node runtime checksum mismatch; remove .build/plugin-runtime and retry.' >&2; exit 1; }
tar -xzf "$archive" -C "$staging" "node-v${node_version}-darwin-arm64/bin/node" "node-v${node_version}-darwin-arm64/LICENSE"
mkdir -p "$contents/Helpers" "$contents/Resources/PluginRuntime"
cp "$staging/node-v${node_version}-darwin-arm64/bin/node" "$contents/Helpers/plugin-node"
chmod 755 "$contents/Helpers/plugin-node"
cp "$staging/node-v${node_version}-darwin-arm64/LICENSE" "$contents/Resources/PluginRuntime/NODE-LICENSE"
cp "$repo_root/Packages/plugin-runtime/runner.mjs" "$repo_root/Packages/plugin-runtime/validation.mjs" "$contents/Resources/PluginRuntime/"
printf '%s\n' "$node_version" > "$contents/Resources/PluginRuntime/VERSION"
