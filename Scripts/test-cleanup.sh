#!/bin/sh
set -eu
source_dir=$(cd "$(dirname "$0")/.." && pwd -P)
build_dir=${1:-"$source_dir/.test-build/cleanup"}
mkdir -p "$build_dir/ModuleCache"
# Top-level Swift executable statements must reside in a file named main.swift.
cp "$source_dir/Tests/CleanupSmoke.swift" "$build_dir/main.swift"
swiftc -swift-version 5 -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/LocalDictation/CleanupClient.swift" "$build_dir/main.swift" \
  -o "$build_dir/cleanup-smoke"
"$build_dir/cleanup-smoke"
