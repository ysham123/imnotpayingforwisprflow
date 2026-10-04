#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/web-insertion}"
compile_only="${2:-}"
if [ -n "$compile_only" ] && [ "$compile_only" != "--compile-only" ]; then
  printf 'Usage: %s [build-directory] [--compile-only]\n' "$0" >&2
  exit 2
fi
mkdir -p "$build_dir/ModuleCache"
build_dir="$(cd "$build_dir" && pwd)"
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Tests/WebInsertionFixture.swift" -o "$build_dir/WebFixture"
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/LocalDictation/TextInserter.swift" "$source_dir/Sources/LocalDictation/TargetInspector.swift" "$source_dir/Sources/LocalDictation/DeliveryCoordinator.swift" \
  "$source_dir/Tests/WebInsertionSmoke.swift" -o "$build_dir/web-insertion-smoke"
if [ "$compile_only" == "--compile-only" ]; then exit 0; fi
"$build_dir/web-insertion-smoke" --check-permission
control_dir=$(mktemp -d "$build_dir/control.XXXXXX")
test_token=$(/usr/bin/uuidgen)
fixture_pid=""
cleanup() {
  if [ -n "$fixture_pid" ]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  rm -rf "$control_dir"
}
trap cleanup EXIT
"$build_dir/WebFixture" "$control_dir" "$test_token" &
fixture_pid=$!
"$build_dir/web-insertion-smoke" "$control_dir" "$test_token"
