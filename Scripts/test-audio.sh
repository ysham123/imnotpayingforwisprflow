#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/audio}"
mkdir -p "$build_dir/ModuleCache"
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" "$source_dir/Sources/LocalDictation/AudioRecorder.swift" "$source_dir/Tests/AudioSmoke.swift" -o "$build_dir/audio-smoke"
"$build_dir/audio-smoke"
