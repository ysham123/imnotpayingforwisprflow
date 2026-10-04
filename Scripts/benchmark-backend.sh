#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$#" -lt 3 ]; then
  echo 'Usage: benchmark-backend.sh runtime_resources fixture.wav report.json [runs=5] [idle_seconds=2] [baseline_git_ref|-] [warm_runs=20]' >&2
  echo 'Run in an exclusive model window. Idle >600 seconds tests the previous 10-minute eviction policy.' >&2
  exit 2
fi
runtime="$1"; fixture="$2"; report="$3"; runs="${4:-5}"; idle_seconds="${5:-2}"
warm_runs="${7:-20}"
build_dir="$source_dir/.test-build/benchmark"
mkdir -p "$build_dir/ModuleCache"
source_path="$source_dir/Sources/LocalDictation"
flags=(-swift-version 5)
if [ -n "${6:-}" ] && [ "$6" != '-' ]; then
  source_path="$build_dir/baseline"
  mkdir -p "$source_path"
  git -C "$source_dir" show "$6:Sources/LocalDictation/WhisperTranscriber.swift" > "$source_path/WhisperTranscriber.swift"
  git -C "$source_dir" show "$6:Sources/LocalDictation/CleanupClient.swift" > "$source_path/CleanupClient.swift"
  flags+=(-D BASELINE)
fi
swiftc -O -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "${flags[@]}" "$source_dir/Sources/DictationCore/Vocabulary.swift" "$source_path/WhisperTranscriber.swift" "$source_path/CleanupClient.swift" \
  "$source_dir/Tests/BackendBenchmark.swift" -framework AVFoundation -o "$build_dir/backend-benchmark"
"$build_dir/backend-benchmark" "$runtime" "$fixture" "$report" "$runs" "$idle_seconds" "$warm_runs"
