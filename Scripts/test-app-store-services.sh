#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
probe_root="${1:-$repo_root/.test-build/app-store-services}"
mkdir -p "$probe_root/ModuleCache"
probe_root="$(cd "$probe_root" && pwd)"
mkdir -p "$HOME/Applications"
probe_install_root="$(mktemp -d "$HOME/Applications/LocalDictation-StoreProbe.XXXXXX")"
provider_app="$probe_install_root/Local Dictation Services Probe.app"
cleanup_probe() {
    if [[ "${LOCAL_DICTATION_KEEP_SERVICES_PROBE:-0}" == "1" ]]; then
        printf 'Synthetic provider retained for live checks: %s\n' "$provider_app"
        return
    fi
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$provider_app" >/dev/null 2>&1 || true
    rm -rf "$probe_install_root"
}
trap cleanup_probe EXIT
mkdir -p "$provider_app/Contents/MacOS"
python3 - "$probe_root" "$provider_app" <<'PY'
from pathlib import Path
import os, plistlib, sys
root, app = map(Path, sys.argv[1:])
marker = root / 'outside-marker.txt'
marker.write_text('Synthetic sandbox probe marker. No user data.\n')
name = f'Local Dictation Sandbox Probe {os.getpid()}'
port = f'LocalDictationServicesProbe.p{os.getpid()}'
info = {
    'CFBundleName': port,
    'CFBundleIdentifier': f'dev.yosef.localdictation.servicesprobe.p{os.getpid()}',
    'CFBundleExecutable': 'ServicesProbe', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': '0.0.1', 'CFBundleVersion': '1',
    'LSMinimumSystemVersion': '14.0', 'LSUIElement': True,
    'NSServices': [{'NSMenuItem': {'default': name}, 'NSMessage': 'provideProbeText',
        'NSPortName': port, 'NSReturnTypes': ['NSStringPboardType'],
        'NSRequiredContext': {}, 'NSRestricted': False, 'NSTimeout': '10000',
        'NSUserData': str(marker)}],
}
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
(root / 'sandbox.entitlements.plist').write_bytes(plistlib.dumps({'com.apple.security.app-sandbox': True}))
PY
swiftc -swift-version 5 -parse-as-library -module-cache-path "$probe_root/ModuleCache" \
    "$repo_root/Tests/AppStoreServicesProbe.swift" -framework AppKit -framework CoreServices \
    -o "$probe_root/services-consumer"
cp "$probe_root/services-consumer" "$provider_app/Contents/MacOS/ServicesProbe"
codesign --force --sign - --entitlements "$probe_root/sandbox.entitlements.plist" "$provider_app"
"$probe_root/services-consumer" --consumer "$provider_app" | tee "$probe_root/result.json"
