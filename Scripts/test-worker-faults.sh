#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/worker-faults}"
mkdir -p "$build_dir/ModuleCache"
resources=$(mktemp -d "${TMPDIR:-/private/tmp}/localdictation-fault-test.XXXXXX")
trap 'rm -rf "$resources"' EXIT
mkdir -p "$resources/Models"
touch "$resources/Models/ggml-large-v3-turbo-q8_0.bin"
cat > "$resources/whisper-worker" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, signal, struct, sys, time
root = pathlib.Path(sys.argv[1]).parent.parent
mode = (root / 'mode').read_text()
(root / 'pid').write_text(str(os.getpid()))
signal.signal(signal.SIGTERM, signal.SIG_IGN)
if mode == 'startup':
    time.sleep(20)
print(json.dumps({'ready': True}), flush=True)
if mode == 'stall':
    time.sleep(20)
while True:
    header = sys.stdin.buffer.read(4)
    if len(header) != 4:
        break
    size = struct.unpack('<I', header)[0] * 4
    if len(sys.stdin.buffer.read(size)) != size:
        break
    if mode == 'oversized':
        print('x' * 128002, flush=True)
    elif mode == 'malformed':
        print('{oops', flush=True)
    elif mode == 'eof':
        sys.exit(0)
    else:
        print(json.dumps({'text': 'recovered'}), flush=True)
PY
chmod +x "$resources/whisper-worker"
swiftc -parse-as-library -module-cache-path "$build_dir/ModuleCache" "$source_dir/Sources/DictationCore/Vocabulary.swift" "$source_dir/Sources/DictationCore/RecordingPolicy.swift" "$source_dir/Sources/LocalDictation/WhisperTranscriber.swift" "$source_dir/Tests/TranscriberFaultSmoke.swift" -o "$build_dir/fault-smoke"
"$build_dir/fault-smoke" "$resources"
