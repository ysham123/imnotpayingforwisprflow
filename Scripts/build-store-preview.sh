#!/bin/bash
# Local sandbox test build. This is never a Store-signed upload artifact.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
build_dir="$repo_root/.build-native/store-xcode"
runtime="${LOCAL_DICTATION_STORE_RUNTIME_DIR:-$repo_root/.build-native/store-runtime-candidate}"
mkdir -p "$repo_root/.test-build"
xcodebuild -project "$repo_root/AppStore/LocalDictationStore.xcodeproj" \
  -scheme LocalDictationStore -configuration Debug -derivedDataPath "$build_dir" \
  CODE_SIGNING_ALLOWED=NO LOCAL_DICTATION_STORE_RUNTIME_DIR="$runtime" build > "$repo_root/.test-build/store-xcode-build.log" 2>&1 || {
    tail -60 "$repo_root/.test-build/store-xcode-build.log" >&2; exit 1;
  }
app="$build_dir/Build/Products/Debug/Local Dictation.app"
codesign --force --sign - --timestamp=none "$app/Contents/Frameworks/DictationCore.framework"
# Ad-hoc development builds cannot satisfy hardened runtime library validation.
# The Release configuration retains hardened runtime and same-team Store signing.
codesign --force --sign - --timestamp=none --entitlements "$repo_root/AppStore/AppStore.entitlements" "$app"
codesign --verify --deep --strict "$app"
echo "$app"
