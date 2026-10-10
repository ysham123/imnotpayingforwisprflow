#!/bin/bash
set -euo pipefail
if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo 'Usage: diagnose-upgrade-cleanup.sh resources models generated-fixtures [build-directory]' >&2
  echo 'Prints only hash-verified public synthetic fixture 101 and its pre-validation Qwen response.' >&2
  echo 'Requires an exclusive model window; does not generate or read personal recordings.' >&2
  exit 2
fi
if pgrep -x LocalDictation >/dev/null || pgrep -x whisper-worker >/dev/null || pgrep -x ollama >/dev/null; then
  echo 'An app or model process is active. Wait for the exclusive model window before running.' >&2
  exit 2
fi
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${4:-$source_dir/.test-build/synthetic-diagnostic}"
mkdir -p "$build_dir/ModuleCache"
swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/DictationCore/RecordingPolicy.swift" \
  "$source_dir/Sources/DictationCore/Vocabulary.swift" \
  "$source_dir/Sources/LocalDictation/WhisperTranscriber.swift" \
  "$source_dir/Sources/LocalDictation/CleanupClient.swift" \
  "$source_dir/Sources/LocalDictation/LocalCorrectionService.swift" \
  "$source_dir/Tests/CleanupSyntheticDiagnostic.swift" \
  -framework AVFoundation -o "$build_dir/cleanup-synthetic-diagnostic"
port=$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    print(sock.getsockname()[1])
PY
)
active_pid=''
cleanup() {
  if [ -n "$active_pid" ]; then kill -TERM "$active_pid" 2>/dev/null || true; wait "$active_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM
"$build_dir/cleanup-synthetic-diagnostic" "$1" "$2" "$3" "$source_dir" "$port" &
active_pid=$!
wait "$active_pid"
active_pid=''
