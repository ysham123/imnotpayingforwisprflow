#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
build_dir="${1:-$source_dir/.test-build/permissions}"
mkdir -p "$build_dir/ModuleCache"
build_dir="$(cd "$build_dir" && pwd -P)"
swiftc -module-cache-path "$build_dir/ModuleCache" -emit-library -emit-module -module-name DictationCore \
  "$source_dir"/Sources/DictationCore/*.swift -emit-module-path "$build_dir/DictationCore.swiftmodule" \
  -o "$build_dir/libDictationCore.dylib"
swiftc -module-cache-path "$build_dir/ModuleCache" -parse-as-library \
  -I "$build_dir" -L "$build_dir" -lDictationCore -Xlinker -rpath -Xlinker "$build_dir" \
  "$source_dir/Sources/LocalDictation/FnHotkey.swift" \
  "$source_dir/Sources/LocalDictation/PermissionDiagnostics.swift" \
  "$source_dir/Tests/PermissionSmoke.swift" -o "$build_dir/permission-smoke"
"$build_dir/permission-smoke"
