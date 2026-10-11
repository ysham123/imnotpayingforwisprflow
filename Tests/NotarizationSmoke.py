#!/usr/bin/env python3
"""Check resumable notarization without credentials, uploads, or signing keys."""
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Scripts'))
import notarize


def rejects(action, fragment):
    try:
        action()
    except RuntimeError as error:
        assert fragment in str(error), str(error)
    else:
        raise AssertionError('Expected rejection: ' + fragment)


with tempfile.TemporaryDirectory(prefix='localdictation-notary-test-') as temp:
    root = Path(temp)
    payload = root / 'payload.zip'; payload.write_bytes(b'synthetic signed payload')
    evidence = root / 'evidence'; evidence.mkdir()
    uploads = []
    issues = []
    def command(*arguments):
        assert '--password' not in arguments and '--apple-id' not in arguments
        if 'submit' in arguments:
            uploads.append(arguments)
            return SimpleNamespace(stdout=json.dumps({'id': 'submission-1'}))
        assert 'log' in arguments
        Path(arguments[-1]).write_text(json.dumps({'issues': issues, 'status': 'Accepted', 'jobId': 'submission-1'}))
        return SimpleNamespace(stdout='')
    pending = SimpleNamespace(stdout='Apple still processing', stderr='', returncode=1)
    accepted = SimpleNamespace(stdout=json.dumps({'status': 'Accepted'}), stderr='', returncode=0)
    invalid = SimpleNamespace(stdout=json.dumps({'status': 'Invalid'}), stderr='', returncode=1)
    with patch.object(notarize, 'run', side_effect=command), patch.object(notarize.subprocess, 'run', return_value=pending):
        rejects(lambda: notarize.notarize(payload, evidence, 'test-profile'), 'resume the retained submission')
    assert len(uploads) == 1 and json.loads((evidence / 'submission.json').read_text())['id'] == 'submission-1'
    with patch.object(notarize, 'run', side_effect=command), patch.object(notarize.subprocess, 'run', return_value=accepted):
        assert notarize.notarize(payload, evidence, 'test-profile') == 'submission-1'
    assert len(uploads) == 1
    print('PASS pending submissions resume with the original ID and no second upload')
    with patch.object(notarize, 'run', side_effect=command), patch.object(notarize.subprocess, 'run', return_value=invalid):
        rejects(lambda: notarize.notarize(payload, evidence, 'test-profile'), 'Apple status is Invalid')
    assert (evidence / 'apple-log.json').exists()
    print('PASS rejection retains Apple diagnostics and never claims acceptance')
    issues.append({'severity': 'error', 'message': 'Synthetic error'})
    with patch.object(notarize, 'run', side_effect=command), patch.object(notarize.subprocess, 'run', return_value=accepted):
        rejects(lambda: notarize.notarize(payload, evidence, 'test-profile'), 'log contains errors')
    print('PASS unexpected errors in an accepted log block completion')
    payload.write_bytes(b'changed payload')
    with patch.object(notarize, 'run', side_effect=command), patch.object(notarize.subprocess, 'run') as external:
        rejects(lambda: notarize.notarize(payload, evidence, 'test-profile'), 'Upload changed')
        external.assert_not_called()
    print('PASS changed artifacts cannot reuse earlier notarization evidence')
    fingerprint = root / 'fingerprint.json'
    notarize.preserve_fingerprint(fingerprint, {'seal': 'first'})
    notarize.preserve_fingerprint(fingerprint, {'seal': 'first'})
    rejects(lambda: notarize.preserve_fingerprint(fingerprint, {'seal': 'changed'}), 'Signed payload changed')
    print('PASS changed signed app cannot reuse an earlier upload')

print('Passed 5 notarization regressions; no Apple credentials or network used')
