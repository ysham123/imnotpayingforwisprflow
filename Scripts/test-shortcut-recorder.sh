#!/bin/bash
set -euo pipefail
if [ "$#" -gt 2 ]; then
  printf 'Usage: %s [build-directory] [--compile-only]\n' "$0" >&2
  exit 2
fi
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/shortcut-recorder}"
compile_only="${2:-}"
if [ -n "$compile_only" ] && [ "$compile_only" != "--compile-only" ]; then exit 2; fi
mkdir -p "$build_dir/ModuleCache"
build_dir="$(cd "$build_dir" && pwd)"
swiftc -module-cache-path "$build_dir/ModuleCache" \
  -emit-library -emit-module -module-name DictationCore \
  "$source_dir"/Sources/DictationCore/*.swift \
  -emit-module-path "$build_dir/DictationCore.swiftmodule" \
  -o "$build_dir/libDictationCore.dylib"
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  -I "$build_dir" -L "$build_dir" -lDictationCore \
  -Xlinker -rpath -Xlinker "$build_dir" \
  "$source_dir/Sources/LocalDictation/ShortcutRecorder.swift" \
  "$source_dir/Tests/ShortcutRecorderSmoke.swift" \
  -o "$build_dir/shortcut-recorder-smoke"
if [ "$compile_only" == "--compile-only" ]; then exit 0; fi
# All input is posted only to this process's own AppKit event queue. This
# fixture does not require Accessibility, Input Monitoring, or microphone.
"$build_dir/shortcut-recorder-smoke"
