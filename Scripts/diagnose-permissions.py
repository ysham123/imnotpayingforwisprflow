#!/usr/bin/env python3
"""Read-only evidence for changed-build versus unchanged-relaunch access issues.

Reads only the app's bounded readiness log and its installed code signature.
Does not launch/quit the app, request access, read TCC databases, or reset grants.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys


def missing(readiness):
    return [name for name, allowed in (
        ('Microphone', readiness.get('microphone') == 3),
        ('Accessibility', readiness.get('accessibility') is True),
        ('Input Monitoring', readiness.get('inputMonitoring') is True),
    ) if not allowed]


def same_build(left, right):
    if left.get('bundlePath') != right.get('bundlePath'):
        return False
    for key in ('executableSHA256', 'codeHash'):
        if left.get(key) and right.get(key):
            return left[key] == right[key]
    return False  # Missing evidence is never evidence of continuity.


def summarize(records):
    launches = []
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get('readiness'), dict):
            raise ValueError('Readiness log contains an invalid record')
        if not isinstance(record.get('launch'), str) or not record.get('date'):
            raise ValueError('Readiness log has a record without a launch/date')
        if not launches or launches[-1][0]['launch'] != record['launch']:
            launches.append([])
        launches[-1].append(record)

    result = []
    previous = None
    for entries in launches:
        first, last = entries[0], entries[-1]
        observed_missing = sorted({name for row in entries for name in missing(row['readiness'])})
        unchanged = previous is not None and same_build(previous, first)
        previous_ready = previous is not None and not missing(previous['readiness'])
        if previous is None:
            observation = 'first_recorded_launch'
        elif unchanged and previous_ready:
            observation = ('unchanged_build_missing_access_observed' if observed_missing
                           else 'unchanged_build_access_retained')
        elif unchanged:
            observation = 'unchanged_build_without_prior_ready_baseline'
        elif not (previous.get('codeHash') and first.get('codeHash')):
            observation = 'build_continuity_unknown'
        else:
            observation = ('changed_build_missing_access_observed' if observed_missing
                           else 'changed_build_access_ready')
        result.append({
            'firstRecordedAt': first['date'], 'lastRecordedAt': last['date'],
            'pid': last.get('pid'), 'version': last.get('version'), 'build': last.get('build'),
            'codeHash': last.get('codeHash'), 'observation': observation,
            'missingAccessObserved': observed_missing,
            'lastRecordedMissingAccess': missing(last['readiness']),
            'lastRecordedListenerActive': last['readiness'].get('listenerActive') is True,
            'lastRecordedListenerError': last['readiness'].get('listenerError'),
        })
        previous = last
    return result


def command(arguments):
    result = subprocess.run(arguments, text=True, capture_output=True, timeout=15)
    return result.returncode, (result.stdout + result.stderr).strip()


def inspect_app(app):
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    executable_name = info.get('CFBundleExecutable')
    if not isinstance(executable_name, str) or Path(executable_name).name != executable_name:
        raise ValueError('Invalid installed executable name')
    executable = app / 'Contents/MacOS' / executable_name
    with executable.open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(stream.read()).hexdigest()
    verified, _ = command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    _, detail = command(['/usr/bin/codesign', '--display', '--verbose=4', '-r-', str(app)])
    requirement = next((line.split('designated => ', 1)[1] for line in detail.splitlines()
                        if 'designated => ' in line), None)
    code_hash = next((line.split('=', 1)[1] for line in detail.splitlines() if line.startswith('CDHash=')), None)
    return {
        'bundlePath': str(app), 'bundleIdentifier': info.get('CFBundleIdentifier'),
        'version': info.get('CFBundleShortVersionString'), 'build': info.get('CFBundleVersion'),
        'signatureValidOnDisk': verified == 0, 'adHocSigned': 'Signature=adhoc' in detail,
        'codeHash': code_hash, 'executableSHA256': digest, 'designatedRequirement': requirement,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('/Applications/Local Dictation.app'))
    parser.add_argument('--diagnostics', type=Path, default=Path.home() / 'Library/Application Support/Local Dictation/Diagnostics/readiness.json')
    parser.add_argument('--json', action='store_true', help='Print bounded metadata as JSON')
    args = parser.parse_args()
    if args.diagnostics.stat().st_size > 1_000_000:
        raise ValueError('Readiness log exceeds its expected bounded size')
    records = json.loads(args.diagnostics.read_text())
    if not isinstance(records, list) or len(records) > 64:
        raise ValueError('Expected a bounded readiness log with at most 64 records')
    installed = inspect_app(args.app)
    launches = summarize(records)
    report = {
        'installed': installed, 'launches': launches,
        'lastRecordMatchesInstalledBuild': bool(records and same_build(records[-1], installed)),
        'limits': 'Historical observations, not a live permission probe. A missing grant does not establish its cause. The log retains at most 64 readiness changes.',
    }
    if args.json:
        print(json.dumps(report, indent=2))
        return
    print(f"Installed: {installed['version']} ({installed['build']}); signature valid: {installed['signatureValidOnDisk']}; ad-hoc: {installed['adHocSigned']}")
    for row in launches:
        access = ', '.join(row['lastRecordedMissingAccess']) or 'none'
        print(f"{row['firstRecordedAt']}  {row['version']} ({row['build']})  {row['observation']}; last missing: {access}; listener: {row['lastRecordedListenerActive']}")
    print('Last record matches installed build:', report['lastRecordMatchesInstalledBuild'])
    print(report['limits'])


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'Permission diagnosis failed: {error}', file=sys.stderr)
        sys.exit(1)
