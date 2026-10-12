#!/bin/bash
# Prepare an archive and matching helper symbols; never upload automatically.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
runtime="${LOCAL_DICTATION_STORE_RUNTIME_DIR:-$repo_root/.build-native/store-runtime-candidate}"
archive="${1:-$repo_root/.build-native/store-candidate/LocalDictation.xcarchive}"
if [ -e "$archive" ]; then
  echo "Choose a new archive path to preserve previous builds: $archive" >&2
  exit 1
fi
if [ ! -f "$runtime/provenance.json" ]; then
  echo "Rebuild the pinned helpers first: python3 Scripts/build-store-runtime.py" >&2
  exit 1
fi
mkdir -p "$repo_root/.test-build"
xcodebuild -project "$repo_root/AppStore/LocalDictationStore.xcodeproj" \
  -scheme LocalDictationStore -configuration Release \
  -derivedDataPath "$repo_root/.build-native/store-candidate-xcode" \
  -archivePath "$archive" -allowProvisioningUpdates \
  LOCAL_DICTATION_STORE_RUNTIME_DIR="$runtime" archive \
  > "$repo_root/.test-build/store-candidate-archive.log" 2>&1 || {
    tail -60 "$repo_root/.test-build/store-candidate-archive.log" >&2; exit 1;
  }
# Xcode does not infer dSYMs for executables supplied by a script build phase.
mkdir -p "$archive/dSYMs"
for helper in whisper-worker ollama; do
  ditto "$runtime/$helper.dSYM" "$archive/dSYMs/$helper.dSYM"
done
python3 "$repo_root/Scripts/check-store-symbols.py" "$archive"
echo "Store archive prepared: $archive"
