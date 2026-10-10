#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo 'Usage: test-real-cleanup.sh runtime_resources numeric_report.json [baseline_git_ref]' >&2
  echo 'Requires an exclusive model window; launches isolated loopback service11439.' >&2
  exit 2
fi
build_dir="$source_dir/.test-build/real-cleanup"
mkdir -p "$build_dir/ModuleCache"
flags=(-swift-version 5)
sources=("$source_dir/Sources/DictationCore/Vocabulary.swift" "$source_dir/Sources/DictationCore/RecordingPolicy.swift"
         "$source_dir/Sources/LocalDictation/CleanupClient.swift"
         "$source_dir/Sources/LocalDictation/WhisperTranscriber.swift"
         "$source_dir/Sources/LocalDictation/LocalCorrectionService.swift"
         "$source_dir/Tests/CleanupModelSmoke.swift")
if [ -n "${3:-}" ]; then
  git -C "$source_dir" show "$3:Sources/LocalDictation/CleanupClient.swift" > "$build_dir/LegacyCleanupClient.swift"
  python3 - "$build_dir/LegacyCleanupClient.swift" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
text = p.read_text()
for name in ('CleanupClient', 'CleanupError', 'LocalOnlyRedirectDelegate'):
    text = re.sub(r'\b' + name + r'\b', 'Legacy' + name, text)
p.write_text(text)
PY
  flags+=(-D BASELINE)
  sources+=("$build_dir/LegacyCleanupClient.swift")
fi
swiftc -O "${flags[@]}" -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "${sources[@]}" -o "$build_dir/real-cleanup-smoke"
"$build_dir/real-cleanup-smoke" "$1" "$2"
