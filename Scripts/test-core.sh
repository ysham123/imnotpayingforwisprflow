#!/bin/sh
set -eu

if [ "$#" -gt 1 ]; then
    printf 'Usage: %s [build-directory]\n' "$0" >&2
    exit 2
fi

script_dir=$(cd "$(dirname "$0")" && pwd -P)
source_dir=$(cd "$script_dir/.." && pwd -P)
build_dir=${1:-"$source_dir/.test-build"}
mkdir -p "$build_dir"
build_dir=$(cd "$build_dir" && pwd -P)
module_cache="$build_dir/ModuleCache"
mkdir -p "$module_cache"
dictation_swiftc=${DICTATION_SWIFTC:-/usr/bin/swiftc}

"$dictation_swiftc" \
    -module-cache-path "$module_cache" \
    -emit-library -emit-module -module-name DictationCore \
    "$source_dir"/Sources/DictationCore/*.swift \
    -emit-module-path "$build_dir/DictationCore.swiftmodule" \
    -o "$build_dir/libDictationCore.dylib"

"$dictation_swiftc" \
    -module-cache-path "$module_cache" \
    -parse-as-library \
    -I "$build_dir" -L "$build_dir" -lDictationCore \
    -Xlinker -rpath -Xlinker "$build_dir" \
    "$source_dir/Tests/GestureSmoke.swift" \
    -o "$build_dir/gesture-smoke"

"$build_dir/gesture-smoke"
