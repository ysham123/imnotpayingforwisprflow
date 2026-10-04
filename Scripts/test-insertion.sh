#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/insertion}"
compile_only="${2:-}"
if [ -n "$compile_only" ] && [ "$compile_only" != "--compile-only" ]; then
  printf 'Usage: %s [build-directory] [--compile-only]\n' "$0" >&2
  exit 2
fi
mkdir -p "$build_dir/ModuleCache" "$build_dir/NativeFixture.app/Contents/MacOS"
build_dir="$(cd "$build_dir" && pwd)"
fixture_app="$build_dir/NativeFixture.app"
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" "$source_dir/Tests/InsertionFixture.swift" -o "$fixture_app/Contents/MacOS/Fixture"
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" "$source_dir/Sources/LocalDictation/TextInserter.swift" "$source_dir/Sources/LocalDictation/TargetInspector.swift" "$source_dir/Sources/LocalDictation/DeliveryCoordinator.swift" "$source_dir/Tests/InsertionSmoke.swift" -o "$build_dir/insertion-smoke"
cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>org.localdictation.tests.nativefixture</string>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundleName</key><string>Local Dictation Native Fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$fixture_app"
xattr -d com.apple.FinderInfo "$fixture_app" 2>/dev/null || true
codesign --force --sign - "$fixture_app"
if [ "$compile_only" == "--compile-only" ]; then exit 0; fi
"$build_dir/insertion-smoke" --check-permission
# LaunchServices-launched fixtures need shared, uncached control files. A
# Documents File Provider can hide freshly created files from the application.
control_dir=$(mktemp -d "${TMPDIR:-/tmp/}/local-dictation-native-control.XXXXXX")
test_token=$(/usr/bin/uuidgen)
launcher_pid=""
cleanup() {
  # The fixture publishes its own PID and token. Never kill applications found
  # through a name search or accessibility traversal.
  local identity="$control_dir/fixture.json" fixture_pid="" reported_token=""
  if [ -f "$identity" ]; then
    reported_token=$(/usr/bin/plutil -extract token raw -o - "$identity" 2>/dev/null || true)
    fixture_pid=$(/usr/bin/plutil -extract pid raw -o - "$identity" 2>/dev/null || true)
    if [ "$reported_token" == "$test_token" ] && [[ "$fixture_pid" =~ ^[0-9]+$ ]]; then
      kill "$fixture_pid" 2>/dev/null || true
    fi
  fi
  if [ -n "$launcher_pid" ]; then
    kill "$launcher_pid" 2>/dev/null || true
    wait "$launcher_pid" 2>/dev/null || true
  fi
  rm -rf "$control_dir"
}
trap cleanup EXIT
open -n -W "$fixture_app" --args "$control_dir" "$test_token" &
launcher_pid=$!
"$build_dir/insertion-smoke" "$control_dir" "$test_token"
