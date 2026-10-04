#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/session}"
mkdir -p "$build_dir/ModuleCache"
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/DictationCore/DictationSessionState.swift" \
  "$source_dir/Sources/LocalDictation/InteractionMetrics.swift" \
  "$source_dir/Tests/SessionSmoke.swift" -o "$build_dir/session-smoke"
"$build_dir/session-smoke"
