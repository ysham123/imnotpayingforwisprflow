#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/setup}"
mkdir -p "$build_dir/ModuleCache"
build_dir="$(cd "$build_dir" && pwd)"
swiftc -module-cache-path "$build_dir/ModuleCache" -emit-library -emit-module -module-name DictationCore \
  "$source_dir"/Sources/DictationCore/*.swift -emit-module-path "$build_dir/DictationCore.swiftmodule" -o "$build_dir/libDictationCore.dylib"
for fixture in SetupFlowSmoke SetupUISmoke; do
  sources=("$source_dir/Tests/$fixture.swift")
  if [ "$fixture" = SetupUISmoke ]; then sources+=("$source_dir/Sources/LocalDictation/SetupController.swift"); fi
  swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" -I "$build_dir" -L "$build_dir" \
    -lDictationCore -Xlinker -rpath -Xlinker "$build_dir" "${sources[@]}" -o "$build_dir/$fixture"
done
# The native UI fixture is compiled here, never launched by CI.
"$build_dir/SetupFlowSmoke"
