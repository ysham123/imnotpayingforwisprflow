#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/settings}"
mode="${2:-}"
if [ "$#" -gt 2 ] || { [ -n "$mode" ] && [ "$mode" != "--compile-only" ]; }; then
  printf 'Usage: %s [build-directory] [--compile-only]\n' "$0" >&2
  exit 2
fi
mkdir -p "$build_dir/ModuleCache"
build_dir="$(cd "$build_dir" && pwd)"
swiftc -module-cache-path "$build_dir/ModuleCache" \
  -emit-library -emit-module -module-name DictationCore \
  "$source_dir"/Sources/DictationCore/*.swift \
  -emit-module-path "$build_dir/DictationCore.swiftmodule" -o "$build_dir/libDictationCore.dylib"
sources=("$source_dir/Sources/LocalDictation/DictationPreferences.swift"
  "$source_dir/Sources/LocalDictation/SettingsController.swift"
  "$source_dir/Sources/LocalDictation/AudioInputProvider.swift"
  "$source_dir/Sources/LocalDictation/AudioRecorder.swift")
for fixture in SettingsSmoke SettingsUISmoke; do
  swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
    -I "$build_dir" -L "$build_dir" -lDictationCore -Xlinker -rpath -Xlinker "$build_dir" \
    "${sources[@]}" "$source_dir/Tests/$fixture.swift" -o "$build_dir/$fixture"
done
# The UI fixture is compiled, never launched by this script. The headless suite
# injects login operations and uses an isolated UserDefaults suite.
if [ "$mode" != "--compile-only" ]; then "$build_dir/SettingsSmoke"; fi
