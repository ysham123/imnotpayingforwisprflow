#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
vendor="${1:-$source_dir/.build-native/whisper.cpp-1.8.3}"
build_dir="${2:-$source_dir/.test-build/native-vocabulary}"
if [ ! -f "$vendor/include/whisper.h" ]; then
  echo 'Pass the pinned whisper.cpp1.8.3 source folder as argument1 (no model required).' >&2
  exit 2
fi
mkdir -p "$build_dir"
c++ -std=c++17 -I "$vendor/include" -I "$vendor/ggml/include" \
  "$source_dir/Native/whisper-worker.cpp" "$source_dir/Tests/NativeWorkerVocabularyStub.cpp" \
  -o "$build_dir/worker-stub"
python3 "$source_dir/Tests/NativeWorkerVocabularySmoke.py" "$build_dir/worker-stub"
