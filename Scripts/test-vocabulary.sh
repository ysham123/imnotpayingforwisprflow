#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/vocabulary}"
mkdir -p "$build_dir/ModuleCache"
swiftc -swift-version 5 -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/DictationCore/Vocabulary.swift" \
  "$source_dir/Sources/LocalDictation/VocabularyPreferences.swift" \
  "$source_dir/Sources/LocalDictation/CleanupClient.swift" \
  "$source_dir/Tests/VocabularySmoke.swift" -o "$build_dir/vocabulary-smoke"
"$build_dir/vocabulary-smoke"
