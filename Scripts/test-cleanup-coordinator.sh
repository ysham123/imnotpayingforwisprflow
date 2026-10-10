#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/cleanup-coordinator}"
mkdir -p "$build_dir/ModuleCache"
swiftc -swift-version 5 -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/DictationCore/Vocabulary.swift" \
  "$source_dir/Sources/LocalDictation/CleanupClient.swift" \
  "$source_dir/Sources/LocalDictation/CleanupCoordinator.swift" \
  "$source_dir/Tests/CleanupCoordinatorSmoke.swift" -o "$build_dir/cleanup-coordinator-smoke"
"$build_dir/cleanup-coordinator-smoke"
