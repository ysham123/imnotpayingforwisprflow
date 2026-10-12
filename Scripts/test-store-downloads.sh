#!/bin/bash
# Uses small public HTTPS fixtures; does not download or execute model weights.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$repo_root/.test-build/store-downloads}"
mkdir -p "$build_dir/ModuleCache"
swiftc -swift-version 5 -parse-as-library -D APP_STORE \
  -module-cache-path "$build_dir/ModuleCache" \
  "$repo_root/Sources/LocalDictation/RuntimePaths.swift" \
  "$repo_root/Sources/LocalDictation/ModelStore.swift" \
  "$repo_root/AppStore/StoreModelDownloader.swift" \
  "$repo_root/Tests/StoreDownloadSmoke.swift" -o "$build_dir/store-download-smoke"
if [ "${2:-}" = --compile-only ]; then exit 0; fi
"$build_dir/store-download-smoke"
