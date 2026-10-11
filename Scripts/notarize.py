#!/usr/bin/env python3
"""Submit a signed app/DMG, preserve resumable evidence, and verify Apple's ticket.

Authentication uses an existing notarytool Keychain profile. This tool never
accepts passwords, creates credentials, publishes assets, or installs the app.
"""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess

from package_app import hash_file_checked, read_bytes_checked, verify_developer_id, write_bytes_checked


def run(*args):
    return subprocess.run([str(arg) for arg in args], check=True, text=True,
                          capture_output=True)


def save_json(path, value):
    write_bytes_checked(path, (json.dumps(value, indent=2) + '\n').encode())


def preserve_fingerprint(path, value):
    if path.exists():
        if json.loads(read_bytes_checked(path)) != value:
            raise RuntimeError('Signed payload changed. Choose a new evidence directory; do not reuse an old submission.')
    else:
        save_json(path, value)


def notarize(payload, evidence, profile):
    record = evidence / 'submission.json'
    digest = hash_file_checked(payload)
    if record.exists():
        submission = json.loads(read_bytes_checked(record))
        if submission['payload_sha256'] != digest:
            raise RuntimeError('Upload changed after submission. Preserve the old evidence and choose a new directory.')
    else:
        result = run('xcrun', 'notarytool', 'submit', payload, '--keychain-profile', profile,
                     '--output-format', 'json')
        submission = json.loads(result.stdout)
        if not submission.get('id'):
            raise RuntimeError('Apple did not return a notarization submission ID')
        submission['payload_sha256'] = digest
        save_json(record, submission)
    submission_id = submission['id']
    print(f'Apple submission: {submission_id}. Evidence: {evidence}', flush=True)
    # A timed-out first submission is retained and can be resumed without
    # uploading another copy. Do not confuse pending with accepted.
    result = subprocess.run(['xcrun', 'notarytool', 'wait', submission_id,
                             '--keychain-profile', profile, '--timeout', '15m',
                             '--output-format', 'json'], text=True, capture_output=True)
    write_bytes_checked(evidence / 'wait-result.txt', (result.stdout + result.stderr or 'No result\n').encode())
    try:
        status = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise RuntimeError('Apple has not confirmed acceptance. Rerun this command to resume the retained submission.')
    save_json(evidence / 'status.json', status)
    if result.returncode != 0 or status.get('status') != 'Accepted':
        if status.get('status') == 'Invalid':
            run('xcrun', 'notarytool', 'log', submission_id, '--keychain-profile', profile,
                evidence / 'apple-log.json')
        raise RuntimeError(f"Apple status is {status.get('status', 'unconfirmed')}; inspect evidence before proceeding")
    run('xcrun', 'notarytool', 'log', submission_id, '--keychain-profile', profile,
        evidence / 'apple-log.json')
    log = json.loads(read_bytes_checked(evidence / 'apple-log.json'))
    if log.get('status') != 'Accepted' or str(log.get('jobId', '')).lower() != submission_id.lower():
        raise RuntimeError('Apple log does not confirm acceptance for this submission')
    issues = log.get('issues') or []
    if any(issue.get('severity') == 'error' for issue in issues):
        raise RuntimeError('Apple log contains errors despite accepted status; inspect apple-log.json')
    if issues:
        print(f'Apple reported {len(issues)} warning(s); review apple-log.json before release.', flush=True)
    return submission_id


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', type=Path)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--keychain-profile', required=True)
    parser.add_argument('--team-id', required=True)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Z0-9]{10}', args.team_id):
        raise RuntimeError('Expected a ten-character Apple Developer Team ID')
    target = args.target.resolve()
    evidence = args.evidence.resolve()
    if evidence == target or target in evidence.parents or evidence in target.parents:
        raise RuntimeError('Keep notarization evidence separate from the signed payload')
    if target.suffix not in ['.app', '.dmg']:
        raise RuntimeError('Choose a signed .app or .dmg')
    evidence.mkdir(parents=True, exist_ok=True)
    run('codesign', '--verify', '--deep', '--strict', target)
    if target.suffix == '.app':
        info = plistlib.loads(read_bytes_checked(target / 'Contents/Info.plist'))
        identifier = info['CFBundleIdentifier']
        fingerprint = {'target': str(target), 'team_id': args.team_id, 'files': {}}
        for relative, code_id in [('Contents/MacOS/LocalDictation', identifier),
                                  ('Contents/Resources/whisper-worker', identifier + '.whisper-worker'),
                                  ('Contents/Resources/ollama', identifier + '.ollama')]:
            verify_developer_id(target if relative.endswith('/LocalDictation') else target / relative,
                                code_id, args.team_id)
            fingerprint['files'][relative] = hash_file_checked(target / relative)
        for relative in ['Contents/Info.plist', 'Contents/_CodeSignature/CodeResources']:
            fingerprint['files'][relative] = hash_file_checked(target / relative)
        payload = evidence / 'Local-Dictation-app.zip'
        fingerprint_path = evidence / 'payload-fingerprint.json'
        if payload.exists() and not fingerprint_path.exists():
            raise RuntimeError('Existing ZIP has no matching app fingerprint; choose a new evidence directory')
        preserve_fingerprint(fingerprint_path, fingerprint)
        if not payload.exists():
            run('ditto', '-c', '-k', '--keepParent', '--norsrc', target, payload)
    else:
        # Disk images do not have executable hardened-runtime flags.
        requirement = ('anchor apple generic and certificate leaf[subject.OU] = "' + args.team_id +
                       '" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists')
        run('codesign', '--verify', '--strict', '--test-requirement', '=' + requirement, target)
        # Keep the exact pre-staple DMG for resumable hashing. Stapling changes
        # the distributed image; it must not change an earlier upload's hash.
        payload = evidence / 'Local-Dictation-upload.dmg'
        if not payload.exists():
            from package_app import copy_bytes
            copy_bytes(target, payload)
        else:
            original_signature = run('codesign', '--display', '--verbose=4', payload).stderr
            current_signature = run('codesign', '--display', '--verbose=4', target).stderr
            cdhash = lambda text: re.search(r'(?m)^CDHash=(.+)$', text).group(1)
            if cdhash(original_signature) != cdhash(current_signature):
                raise RuntimeError('Signed disk image changed; choose a new evidence directory')
    submission_id = notarize(payload, evidence, args.keychain_profile)
    run('xcrun', 'stapler', 'staple', target)
    run('xcrun', 'stapler', 'validate', target)
    run('codesign', '--verify', '--deep', '--strict', target)
    command = ['spctl', '--assess', '--verbose=2']
    command += ['--type', 'execute'] if target.suffix == '.app' else ['--type', 'open', '--context', 'context:primary-signature']
    assessment = run(*command, target)
    write_bytes_checked(evidence / 'gatekeeper.txt', (assessment.stdout + assessment.stderr).encode())
    save_json(evidence / 'verified.json', {'target': str(target), 'submission_id': submission_id,
                                         'status': 'Accepted', 'stapled': True, 'gatekeeper': 'accepted'})
    print(f'Apple accepted the payload; ticket and Gatekeeper checks passed: {target}')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error) if isinstance(error, RuntimeError) else (error.stderr or str(error)))
