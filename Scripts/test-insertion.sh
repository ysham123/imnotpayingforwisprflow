#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/insertion}"
mkdir -p "$build_dir/ModuleCache"
build_dir="$(cd "$build_dir" && pwd)"
control_dir=$(mktemp -d "$build_dir/control.XXXXXX")
fixture_pid=""
cleanup() {
  if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; fi
  rm -rf "$control_dir"
}
trap cleanup EXIT
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" "$source_dir/Tests/InsertionFixture.swift" -o "$build_dir/Fixture"
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" "$source_dir/Sources/LocalDictation/TextInserter.swift" "$source_dir/Tests/InsertionSmoke.swift" -o "$build_dir/insertion-smoke"
"$build_dir/Fixture" "$control_dir" &
fixture_pid=$!
"$build_dir/insertion-smoke" "$control_dir"
