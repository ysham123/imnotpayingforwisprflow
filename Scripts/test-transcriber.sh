#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/transcriber}"
mkdir -p "$build_dir/ModuleCache"
resources=$(mktemp -d "${TMPDIR:-/private/tmp}/localdictation-worker-test.XXXXXX")
trap 'rm -rf "$resources"' EXIT
mkdir -p "$resources/Models"
touch "$resources/Models/ggml-large-v3-turbo-q8_0.bin"
cat > "$resources/whisper-worker" <<'PY'
#!/usr/bin/env python3
import json, struct, sys, time
log = sys.argv[1] + '.log'
def mark(value):
    with open(log, 'a') as f:
        f.write(value + '\n')
mark('start')
time.sleep(0.4)
print(json.dumps({'ready': True}), flush=True)
while True:
    header = sys.stdin.buffer.read(4)
    if not header:
        break
    size = struct.unpack('<I', header)[0] * 4
    audio = sys.stdin.buffer.read(size)
    if len(audio) != size:
        break
    mark('infer')
    time.sleep(0.3)
    print(json.dumps({'text': 'recognized speech'}), flush=True)
PY
chmod +x "$resources/whisper-worker"
"${DICTATION_SWIFTC:-/usr/bin/swiftc}" -module-cache-path "$build_dir/ModuleCache" \
  -parse-as-library "$source_dir/Sources/DictationCore/Vocabulary.swift" "$source_dir/Sources/LocalDictation/WhisperTranscriber.swift" \
  "$source_dir/Tests/TranscriberCancellationSmoke.swift" -o "$build_dir/transcriber-smoke"
"$build_dir/transcriber-smoke" "$resources"
