#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-}"
if [ "$mode" != '--compile-only' ] && [ "$mode" != '--run' ]; then
  echo 'Usage: benchmark-upgrade.sh --compile-only [build-directory] [baseline-source]' >&2
  echo '       benchmark-upgrade.sh --run baseline-resources candidate-resources models fixtures report-directory [short-runs=20] [long-runs=5] [case-ids=all]' >&2
  echo 'Real model runs require an exclusive model window. Audio is generated from public synthetic recipes.' >&2
  exit 2
fi
shift
build_dir="${LOCAL_DICTATION_UPGRADE_BUILD_DIR:-$source_dir/.test-build/upgrade-benchmark}"
baseline="${LOCAL_DICTATION_UPGRADE_BASELINE:-$source_dir/.test-build/v2-baseline}"
if [ "$mode" = '--compile-only' ]; then
  if [ "$#" -gt 2 ]; then exit 2; fi
  build_dir="${1:-$build_dir}"; baseline="${2:-$baseline}"
else
  if [ "$#" -lt 5 ] || [ "$#" -gt 8 ]; then echo 'Missing benchmark run arguments.' >&2; exit 2; fi
fi
mkdir -p "$build_dir/ModuleCache"
for variant in baseline candidate; do
  flags=(-swift-version 5); sources=()
  if [ "$variant" = baseline ]; then
    selected="$baseline"; flags+=(-D BASELINE)
  else
    selected="$source_dir"
    sources+=("$selected/Sources/DictationCore/RecordingPolicy.swift" "$selected/Sources/LocalDictation/CleanupCoordinator.swift")
  fi
  sources+=("$selected/Sources/DictationCore/Vocabulary.swift"
    "$selected/Sources/LocalDictation/WhisperTranscriber.swift"
    "$selected/Sources/LocalDictation/CleanupClient.swift"
    "$selected/Sources/LocalDictation/LocalCorrectionService.swift")
  swiftc -O -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
    "${flags[@]}" "${sources[@]}" "$source_dir/Tests/UpgradeModelBenchmark.swift" \
    -framework AVFoundation -o "$build_dir/$variant-benchmark"
  python3 - "$build_dir/$variant-source.sha256" "${sources[@]}" <<'PY'
import hashlib, pathlib, sys
digest = hashlib.sha256()
for source in sys.argv[2:]:
    digest.update(pathlib.Path(source).name.encode() + b'\0')
    digest.update(pathlib.Path(source).read_bytes())
pathlib.Path(sys.argv[1]).write_text(digest.hexdigest())
PY
done
python3 "$source_dir/Scripts/generate-upgrade-fixtures.py" --validate-only
if [ "$mode" = '--compile-only' ]; then
  echo "Compiled baseline and candidate upgrade harnesses in $build_dir; no models or speech generation were started."
  exit 0
fi
if pgrep -x LocalDictation >/dev/null || pgrep -x whisper-worker >/dev/null || pgrep -x ollama >/dev/null; then
  echo 'An app or model process is active. Acquire an exclusive model window before running.' >&2
  exit 2
fi
baseline_resources="$1"; candidate_resources="$2"; models="$3"; fixtures="$4"; reports="$5"
short_runs="${6:-20}"; long_runs="${7:-5}"; selected_cases="${8:-all}"
python3 "$source_dir/Scripts/generate-upgrade-fixtures.py" "$fixtures"
mkdir -p "$reports"
case_ids=$(python3 - "$fixtures/manifest.json" "$selected_cases" <<'PY'
import json, sys
available = [case['id'] for case in json.load(open(sys.argv[1]))['cases']]
selected = available if sys.argv[2] == 'all' else [int(x) for x in sys.argv[2].split(',')]
assert selected and len(set(selected)) == len(selected) and all(x in available for x in selected)
print(' '.join(map(str, selected)))
PY
)
active_pid=''
cleanup() {
  if [ -n "$active_pid" ]; then kill -TERM "$active_pid" 2>/dev/null || true; wait "$active_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT INT TERM
case_index=0
for case_id in $case_ids; do
  # Alternate build order across cases. Both builds always receive the same
  # hashed audio, each with its own warmup and fully stopped owned engines.
  order='baseline candidate'
  if [ $((case_index % 2)) -eq 1 ]; then order='candidate baseline'; fi
  for variant in $order; do
    resources="$candidate_resources"
    if [ "$variant" = baseline ]; then resources="$baseline_resources"; fi
    port=$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0)); print(sock.getsockname()[1])
PY
)
    source_hash=$(cat "$build_dir/$variant-source.sha256")
    "$build_dir/$variant-benchmark" "$resources" "$models" "$fixtures" "$reports/$variant-$case_id.json" \
      "$short_runs" "$long_runs" "$case_id" "$port" "$source_hash" &
    active_pid=$!
    wait "$active_pid"
    active_pid=''
  done
  case_index=$((case_index + 1))
done
python3 - "$reports" "$case_ids" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1]); combined = {'schema': 1, 'rows': [], 'summaries': [], 'skipped': [], 'paired': []}
for case in sys.argv[2].split():
    reports = {variant: json.loads((root / f'{variant}-{case}.json').read_text()) for variant in ('baseline', 'candidate')}
    for variant, report in reports.items():
        combined['rows'].extend(report['rows'])
        combined['summaries'].extend(dict(row, variant=variant) for row in report['summary'])
        combined['skipped'].extend(dict(row, variant=variant) for row in report['skipped'])
    for mode in ('clean', 'verbatim'):
        pairs = [next((x for x in reports[v]['summary'] if x['mode'] == mode), None) for v in ('baseline', 'candidate')]
        if any(x is None for x in pairs): continue
        baseline, candidate = pairs
        assert baseline['audio_sha256'] == candidate['audio_sha256'], 'Unpaired audio hashes'
        row = {'case': int(case), 'mode': mode, 'audio_sha256': baseline['audio_sha256'],
               'baseline_samples': baseline['samples'], 'candidate_samples': candidate['samples']}
        for metric in ('total_seconds_median', 'total_seconds_p95'):
            if metric in baseline and metric in candidate:
                row[metric + '_candidate_minus_baseline'] = candidate[metric] - baseline[metric]
        combined['paired'].append(row)
combined['measurement'] = 'warm_backend_excluding_microphone_and_delivery'
combined['quality_scope'] = 'synthetic_categorical_markers_not_accuracy_or_semantic_equivalence'
combined['percentile_method'] = 'nearest_rank; with five successful samples p95 is their maximum'
(root / 'paired-report.json').write_text(json.dumps(combined, indent=2, sort_keys=True) + '\n')
print(f'Wrote paired numeric benchmark report to {root / "paired-report.json"}')
PY
