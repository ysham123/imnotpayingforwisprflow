#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/destination-restoration}"
mkdir -p "$build_dir/ModuleCache"
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/LocalDictation/DeliveryCoordinator.swift" \
  "$source_dir/Tests/DestinationRestorationSmoke.swift" \
  -o "$build_dir/destination-restoration-smoke"
"$build_dir/destination-restoration-smoke"
