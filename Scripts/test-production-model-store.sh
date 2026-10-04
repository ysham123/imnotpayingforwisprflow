#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:?Pass a build folder}"
mkdir -p "$build_dir/ModuleCache"
swiftc -swift-version 5 -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/LocalDictation/RuntimePaths.swift" \
  "$source_dir/Sources/LocalDictation/ModelStore.swift" \
  "$source_dir/Tests/ProductionModelStoreSmoke.swift" -o "$build_dir/production-model-store"
if [ "${2:-}" = --compile-only ]; then exit 0; fi
shift
"$build_dir/production-model-store" "$@"
