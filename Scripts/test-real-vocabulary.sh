#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" != '--compile-only' ] && [ "${1:-}" != '--run' ] && [ "${1:-}" != '--cleanup-only' ]; then
  echo 'Usage: test-real-vocabulary.sh --compile-only [build_directory]' >&2
  echo '       test-real-vocabulary.sh --run resources models fixtures_directory numeric_report.json [runs=3] [warm_short=20] [warm_long=10]' >&2
  echo '       test-real-vocabulary.sh --cleanup-only resources models fixtures_directory numeric_report.json' >&2
  echo 'Run requires an exclusive model window with Local Dictation closed. Fixtures are synthetic, never microphone recordings.' >&2
  exit 2
fi
mode="$1"; shift
build_dir="${LOCALDICTATION_VOCAB_BUILD_DIR:-$source_dir/.test-build/real-vocabulary}"
if [ "$mode" = '--compile-only' ]; then build_dir="${1:-$build_dir}"; fi
mkdir -p "$build_dir/ModuleCache"
swiftc -O -swift-version 5 -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/DictationCore/Vocabulary.swift" \
  "$source_dir/Sources/LocalDictation/WhisperTranscriber.swift" \
  "$source_dir/Sources/LocalDictation/CleanupClient.swift" \
  "$source_dir/Sources/LocalDictation/LocalCorrectionService.swift" \
  "$source_dir/Tests/VocabularyModelBenchmark.swift" -framework AVFoundation -o "$build_dir/vocabulary-model-benchmark"
if [ "$mode" = '--compile-only' ]; then
  echo "Compiled vocabulary harness: $build_dir/vocabulary-model-benchmark"
  exit 0
fi
if [ "$#" -lt 4 ] || [ "$#" -gt 7 ]; then echo 'Missing run arguments.' >&2; exit 2; fi
if pgrep -x LocalDictation >/dev/null || pgrep -x whisper-worker >/dev/null || pgrep -x ollama >/dev/null; then
  echo 'An app or model process is active. Close it and acquire an exclusive model window first.' >&2
  exit 2
fi
resources="$1"; models="$2"; fixtures="$3"; report="$4"; runs="${5:-3}"; warm_short="${6:-20}"; warm_long="${7:-10}"
if [ "$mode" = '--cleanup-only' ]; then runs=0; fi
mkdir -p "$fixtures"
python3 - "$source_dir/Tests/VocabularyFixtures.json" "$fixtures" "$runs" <<'PY'
import hashlib, json, pathlib, subprocess, sys
manifest = pathlib.Path(sys.argv[1])
fixtures = pathlib.Path(sys.argv[2])
data = json.loads(manifest.read_text())
(fixtures / 'manifest.json').write_bytes(manifest.read_bytes())
for case in data['cases'] if int(sys.argv[3]) > 0 else []:
    output = fixtures / (str(case['id']) + '.aiff')
    metadata = fixtures / (str(case['id']) + '.generation.json')
    rate = case.get('rate', data['rate'])
    fingerprint = {'voice':data['voice'], 'rate':rate, 'text_sha256':hashlib.sha256(case['text'].encode()).hexdigest()}
    try:
        old = json.loads(metadata.read_text())
    except (OSError, ValueError):
        old = None
    if not output.exists() or old != fingerprint:
        subprocess.run(['/usr/bin/say', '-v', data['voice'], '-r', str(rate), '-o', str(output), case['text']], check=True)
        metadata.write_text(json.dumps(fingerprint, sort_keys=True) + '\n')
PY
"$build_dir/vocabulary-model-benchmark" "$resources" "$models" "$fixtures" "$report" "$runs" "$warm_short" "$warm_long"
