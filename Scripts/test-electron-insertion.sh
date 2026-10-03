#!/bin/bash
set -euo pipefail
if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
  printf 'Usage: %s /absolute/path/to/Electron [build-directory] [--compile-only]\n' "$0" >&2
  exit 2
fi
electron="$1"
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${2:-$source_dir/.test-build/electron-insertion}"
compile_only="${3:-}"
if [[ "$electron" != /* ]] || [ ! -x "$electron" ]; then
  printf 'Pass the absolute executable path from a separately downloaded official Electron runtime.\n' >&2
  exit 2
fi
if [ -n "$compile_only" ] && [ "$compile_only" != "--compile-only" ]; then exit 2; fi
mkdir -p "$build_dir/ModuleCache"
build_dir="$(cd "$build_dir" && pwd)"
# ELECTRON_RUN_AS_NODE runs only the syntax checker and opens no GUI window.
ELECTRON_RUN_AS_NODE=1 "$electron" --check "$source_dir/Tests/ElectronInsertionFixture.cjs"
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/LocalDictation/TextInserter.swift" \
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
env -u ELECTRON_RUN_AS_NODE "$electron" "$source_dir/Tests/ElectronInsertionFixture.cjs" "$control_dir" "$test_token" >"$control_dir/electron.log" 2>&1 &
fixture_pid=$!
"$build_dir/web-insertion-smoke" "$control_dir" "$test_token"
