#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/target-inspector}"
mkdir -p "$build_dir/ModuleCache"
build_dir="$(cd "$build_dir" && pwd)"
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/LocalDictation/TextInserter.swift" \
  "$source_dir/Sources/LocalDictation/TargetInspector.swift" \
  "$source_dir/Sources/LocalDictation/DeliveryCoordinator.swift" \
  "$source_dir/Tests/TargetInspectorCancellationSmoke.swift" \
  -o "$build_dir/target-inspector-smoke"
"$build_dir/target-inspector-smoke"
