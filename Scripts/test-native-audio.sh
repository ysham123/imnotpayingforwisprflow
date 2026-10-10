#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/native-audio}"
mkdir -p "$build_dir/ModuleCache"
c++ -std=c++17 -Wall -Wextra -Werror -I "$source_dir/Native" \
  "$source_dir/Tests/NativeAudioActivitySmoke.cpp" -o "$build_dir/native-audio-smoke"
"$build_dir/native-audio-smoke"
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/DictationCore/RecordingPolicy.swift" \
  "$source_dir/Tests/NativeRecordingPolicyCheck.swift" -o "$build_dir/swift-recording-policy"
if [ "$("$build_dir/native-audio-smoke" --policy)" != "$("$build_dir/swift-recording-policy")" ]; then
  echo 'Swift and native recording policies disagree.' >&2
  exit 1
fi
echo 'PASS Swift and C++ sample rates and five-minute limits agree'
