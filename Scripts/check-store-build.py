#!/usr/bin/env python3
"""Fail closed before uploading a Mac App Store artifact.

--development checks a sandbox preview, and explicitly does not certify upload
readiness. This complements Xcode's upload validation and live acceptance tests.
"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--development', action='store_true')
args = parser.parse_args()
app = args.app.resolve()
errors = []
checks = {}

def check(name, condition, message):
    checks[name] = bool(condition)
    if not condition: errors.append(message)

def run(*command):
    result = subprocess.run(command, capture_output=True)
    if result.returncode: raise ValueError(result.stderr.decode(errors='replace').strip())
    return result

def entitlements(path):
    data = run('codesign', '-d', '--entitlements', '-', '--xml', str(path)).stdout
    return plistlib.loads(data) if data else {}

try:
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    root_entitlements = entitlements(app)
    check('signatureValid', subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], capture_output=True).returncode == 0,
          'The complete app signature does not verify.')
    expected_id = 'dev.yosef.localdictation.store.development' if args.development else 'dev.yosef.localdictation'
    check('bundleIdentifier', info.get('CFBundleIdentifier') == expected_id, f'Expected bundle identifier {expected_id}.')
    check('sandboxEnabled', root_entitlements.get('com.apple.security.app-sandbox') is True, 'The root app is not sandboxed.')
    allowed = {'com.apple.security.app-sandbox', 'com.apple.security.device.audio-input', 'com.apple.security.network.client',
               'com.apple.security.network.server', 'com.apple.application-identifier', 'com.apple.developer.team-identifier'}
    if args.development: allowed.add('com.apple.security.get-task-allow')
    check('entitlementsLimited', set(root_entitlements) <= allowed, 'Unexpected or temporary-exception entitlements require a separate review.')
    check('microphonePurpose', bool(info.get('NSMicrophoneUsageDescription')), 'The microphone purpose string is missing.')
    check('storeCategory', info.get('LSApplicationCategoryType') == 'public.app-category.productivity', 'The Store category is missing or incorrect.')
    check('privacyManifest', (app / 'Contents/Resources/PrivacyInfo.xcprivacy').is_file(), 'The app privacy manifest is missing.')
    services = info.get('NSServices', [])
    check('returnOnlyService', len(services) == 1 and services[0].get('NSMessage') == 'dictateText'
          and services[0].get('NSReturnTypes') == ['NSStringPboardType'] and not services[0].get('NSSendTypes'),
          'The Store edition must declare its return-only dictation service.')
    details = run('codesign', '-d', '--verbose=4', str(app)).stderr.decode()
    team = '2563R7W8T6'
    if not args.development:
        check('storeDistributionIdentity', any(label in details for label in ['Authority=Apple Distribution:',
            'Authority=3rd Party Mac Developer Application:', 'Authority=Mac App Distribution:']) and f'TeamIdentifier={team}' in details,
            'This artifact requires a matching Mac App Store distribution identity. Developer ID or ad-hoc signing is insufficient.')
        check('appleSigningAnchor', subprocess.run(['codesign', '--verify', '--test-requirement', '=anchor apple generic', str(app)], capture_output=True).returncode == 0,
            'The distribution signature does not chain to Apple.')
        check('noDebugSigning', root_entitlements.get('com.apple.security.get-task-allow') is not True, 'Debug signing cannot be uploaded.')
        profile_path = app / 'Contents/embedded.provisionprofile'
        check('embeddedProfile', profile_path.is_file(), 'A Mac App Store provisioning profile is required.')
        if profile_path.is_file():
            profile = plistlib.loads(run('security', 'cms', '-D', '-i', str(profile_path)).stdout)
            profile_entitlements = profile.get('Entitlements', {})
            application_id = profile_entitlements.get('com.apple.application-identifier', profile_entitlements.get('application-identifier'))
            check('profileIdentity', application_id == team + '.' + expected_id and team in profile.get('TeamIdentifier', []),
                  'The provisioning profile does not match this app and team.')
    macho_magic = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
                   b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
    binaries = []
    for path in (app / 'Contents').rglob('*'):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as stream: magic = stream.read(4)
            if magic in macho_magic: binaries.append(path)
    for path in binaries:
        relative = str(path.relative_to(app))
        check('codeLocation:' + relative, relative.startswith(('Contents/MacOS/', 'Contents/Helpers/', 'Contents/Frameworks/')),
              f'Executable code is outside a standard code directory: {relative}.')
        if relative.startswith('Contents/Helpers/'):
            check('helperInheritance:' + path.name, entitlements(path) == {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True},
                  f'{path.name} needs exactly the two sandbox inheritance entitlements.')
            if not args.development:
                helper_details = run('codesign', '-d', '--verbose=4', str(path)).stderr.decode()
                check('helperTeam:' + path.name, f'TeamIdentifier={team}' in helper_details, f'{path.name} has a different signing team.')
        if relative.startswith('Contents/MacOS/'):
            symbols = run('nm', '-u', str(path)).stdout.decode(errors='replace')
            forbidden = ['_AXUIElement', '_CGEventTapCreate', '_CGEventPost', '_AXIsProcessTrusted']
            check('noGlobalInputAPIs', not any(symbol in symbols for symbol in forbidden), 'The Store executable still links cross-app Accessibility or synthetic input APIs.')
    check('helpersPresent', all((app / 'Contents/Helpers' / name).is_file() for name in ['whisper-worker', 'ollama']), 'Speech or cleanup helpers are missing.')
    check('noBundledWeights', not any(path.suffix in {'.bin', '.gguf'} for path in (app / 'Contents').rglob('*')),
          'Model weights must be downloaded as data after explicit first-run consent.')
except (OSError, ValueError, plistlib.InvalidFileException) as error:
    errors.append(str(error))
print(json.dumps({'scope': 'sandbox-development' if args.development else 'store-distribution', 'checks': checks,
                  'passed': not errors, 'uploadReady': False,
                  'liveAcceptanceStillRequired': True, 'errors': errors}, indent=2))
sys.exit(1 if errors else 0)
