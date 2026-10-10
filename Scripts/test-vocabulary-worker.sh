#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/vocabulary-worker}"
mkdir -p "$build_dir/ModuleCache"
resources=$(mktemp -d "${TMPDIR:-/private/tmp}/localdictation-vocab-worker.XXXXXX")
trap 'rm -rf "$resources"' EXIT
mkdir -p "$resources/ExternalModels"
touch "$resources/ExternalModels/ggml-large-v3-turbo-q8_0.bin"
cat > "$resources/whisper-worker" <<'PY'
#!/usr/bin/env python3
import json, pathlib, struct, sys, uuid
root = pathlib.Path(__file__).parent
requests = []
print(json.dumps({'ready':True,'protocol':2}),flush=True)
while True:
    header = sys.stdin.buffer.read(8)
    if len(header) != 8: break
    count, hints = struct.unpack('<II',header)
    ids, terms = [], []
    for _ in range(hints):
        ids.append(sys.stdin.buffer.read(36).decode())
        length = struct.unpack('<I',sys.stdin.buffer.read(4))[0]
        terms.append(sys.stdin.buffer.read(length).decode())
    audio = sys.stdin.buffer.read(count*4)
    requests.append({'terms':terms,'samples':list(struct.unpack('<'+'f'*count,audio)),
                     'external_model':pathlib.Path(sys.argv[1]).parent.name=='ExternalModels'})
    (root/'requests.json').write_text(json.dumps(requests))
    bad = (root/'mode').exists() and (root/'mode').read_text()=='badid'
    overflow = [str(uuid.uuid4())] if bad else ids[-1:]
    print(json.dumps({'text':'recognized','vocabulary_overflow':overflow}),flush=True)
PY
chmod +x "$resources/whisper-worker"
swiftc -swift-version 5 -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/DictationCore/Vocabulary.swift" "$source_dir/Sources/DictationCore/RecordingPolicy.swift" \
  "$source_dir/Sources/LocalDictation/WhisperTranscriber.swift" \
  "$source_dir/Tests/VocabularyWorkerSmoke.swift" -o "$build_dir/worker-smoke"
"$build_dir/worker-smoke" "$resources"
