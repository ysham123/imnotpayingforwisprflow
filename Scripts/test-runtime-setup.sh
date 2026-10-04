#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/runtime-setup}"
mkdir -p "$build_dir/ModuleCache"
swiftc -swift-version 5 -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/LocalDictation/RuntimePaths.swift" \
  "$source_dir/Sources/LocalDictation/ModelStore.swift" \
  "$source_dir/Sources/LocalDictation/InstallController.swift" \
  "$source_dir/Tests/RuntimeSetupSmoke.swift" -o "$build_dir/runtime-setup-smoke"
if [ "${2:-}" = --compile-only ]; then exit 0; fi
"$build_dir/runtime-setup-smoke"
