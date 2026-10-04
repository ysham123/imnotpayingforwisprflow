#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${1:-$source_dir/.test-build/cleanup-service}"
mkdir -p "$build_dir/ModuleCache"
resources=$(mktemp -d "${TMPDIR:-/private/tmp}/localdictation-cleanup-test.XXXXXX")
trap 'rm -rf "$resources"' EXIT
cat > "$resources/server.py" <<'PY'
import http.server, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
counts = {'tags': 0, 'show': 0, 'resident': 0, 'temporary': 0, 'unload': 0}
class Server(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self): self.handle_request({})
    def do_POST(self): self.handle_request(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
    def handle_request(self, body):
        if self.path == '/api/tags':
            counts['tags'] += 1
            result = {'models': [{'name': name, 'size': 100, 'digest': 'localdigest'} for name in ('qwen3:4b', 'other:latest')]}
        elif self.path == '/api/show':
            counts['show'] += 1
            result = {'capabilities': ['completion']}
        else:
            if body.get('keep_alive') == 0: counts['unload'] += 1
            elif body.get('keep_alive') == -1: counts['resident'] += 1
            else: counts['temporary'] += 1
            malformed = (root / 'mode').exists() and (root / 'mode').read_text() == 'malformed'
            result = {'done': True, 'response': '{oops' if malformed else '{"cleaned_text":"Hello."}', 'load_duration': 1000000}
        (root / 'counts.json').write_text(json.dumps(counts))
        data = json.dumps(result).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
server = http.server.HTTPServer(('127.0.0.1', 0), Server)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
PY
swiftc -swift-version 5 -parse-as-library -module-cache-path "$build_dir/ModuleCache" \
  "$source_dir/Sources/DictationCore/Vocabulary.swift" "$source_dir/Sources/LocalDictation/CleanupClient.swift" "$source_dir/Tests/CleanupLeaseSmoke.swift" \
  -o "$build_dir/cleanup-service-smoke"
"$build_dir/cleanup-service-smoke" "$(command -v python3)" "$resources"
