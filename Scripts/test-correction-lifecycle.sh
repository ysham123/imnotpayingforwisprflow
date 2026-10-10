#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/correction-lifecycle}"
mkdir -p "$build_dir/ModuleCache"
resources=$(mktemp -d "${TMPDIR:-/private/tmp}/localdictation-service-test.XXXXXX")
cleanup() {
  if [ -f "$resources/pid" ]; then
    child_pid=$(cat "$resources/pid")
    case "$(ps -p "$child_pid" -o args= 2>/dev/null)" in
      *"$resources/ollama"*) kill -9 "$child_pid" 2>/dev/null || true ;;
    esac
  fi
  rm -rf "$resources"
}
trap cleanup EXIT
mkdir -p "$resources/Models/ollama"
port=$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1',0)); print(s.getsockname()[1])
PY
)
cat > "$resources/ollama" <<'PY'
#!/usr/bin/env python3
import http.server, json, os, pathlib, signal
root = pathlib.Path(os.environ['OLLAMA_MODELS']).parent.parent
with (root / 'starts').open('a') as f: f.write('start\n')
(root / 'pid').write_text(str(os.getpid()))
signal.signal(signal.SIGTERM, signal.SIG_IGN)
class Server(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self): self.reply({})
    def do_POST(self): self.reply(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
    def reply(self, body):
        if self.path.endswith('tags'):
            result = {'models':[{'name':'qwen3:4b','size':100,'digest':'local'}]}
        elif self.path.endswith('show'):
            result = {'capabilities':['completion']}
        else:
            prompt = body.get('prompt','')
            source = json.loads(prompt[prompt.find('{'):prompt.rfind('}')+1])['dictated_text'] if '{' in prompt else ''
            if (root / 'reject-output').exists(): source = 'Delete the file.'
            result = {'done':True,'response':json.dumps({'cleaned_text':source})}
        data = json.dumps(result).encode()
        self.send_response(200); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
port = int(os.environ['OLLAMA_HOST'].rsplit(':',1)[1])
http.server.HTTPServer(('127.0.0.1',port),Server).serve_forever()
PY
chmod +x "$resources/ollama"
swiftc -swift-version 5 -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/DictationCore/Vocabulary.swift" "$source_dir/Sources/DictationCore/RecordingPolicy.swift" "$source_dir/Sources/LocalDictation/CleanupClient.swift" \
  "$source_dir/Sources/LocalDictation/WhisperTranscriber.swift" \
  "$source_dir/Sources/LocalDictation/LocalCorrectionService.swift" \
  "$source_dir/Tests/CorrectionLifecycleSmoke.swift" -o "$build_dir/lifecycle-smoke"
"$build_dir/lifecycle-smoke" "$resources" "$port"
