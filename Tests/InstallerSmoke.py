"""Exercise the real installer transaction with tiny local parts and mock signing.

SHA-256, tar extraction, plist checks, staging, renames and shell traps are real.
Only code signing and the disk-space check are replaced for the synthetic app.
No installed application, privacy permission, or network service is touched.
"""
import hashlib
from pathlib import Path
import plistlib
import shlex
import subprocess
import tarfile
import tempfile

source = Path(__file__).resolve().parents[1]
template = (source / 'Distribution/install.template.sh').read_text()
scenarios = ['fresh', 'replace', 'refuse-existing', 'stage-failure',
             'final-failure', 'fresh-final-failure', 'corrupt-part', 'interrupt']
for scenario in scenarios:
    with tempfile.TemporaryDirectory(prefix='localdictation-installer-test-') as temp:
        root = Path(temp).resolve()
        destination = root / 'Applications'
        destination.mkdir()
        target = destination / 'Local Dictation.app'
        had_previous = scenario not in ['fresh', 'fresh-final-failure']
        if had_previous:
            target.mkdir()
            (target / 'old-build').write_text('original')
        fixture = root / 'fixture/Local Dictation.app'
        contents = fixture / 'Contents'
        contents.mkdir(parents=True)
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'dev.yosef.localdictation',
            'CFBundleShortVersionString': '1.1.0',
        }))
        (contents / 'synthetic-build').write_text('new build')
        assets = root / 'assets'
        assets.mkdir()
        part = assets / 'fixture.tar.part001'
        with tarfile.open(part, 'w') as archive:
            archive.add(fixture, arcname=fixture.name)
        digest = hashlib.sha256(part.read_bytes()).hexdigest()
        size = part.stat().st_size
        if scenario == 'corrupt-part':
            part.write_bytes(b'corrupted download')
        signer = root / 'codesign-mock'
        signer.write_text('#!/bin/bash\n' +
            ('exit 1\n' if scenario == 'stage-failure' else
             'if [ "${@: -1}" = ' + shlex.quote(str(target)) + ' ]; then\n' +
             ('kill -TERM "$PPID"; exit 1\n' if scenario == 'interrupt' else 'exit 1\n') +
             'fi\nexit 0\n' if scenario in ['final-failure', 'fresh-final-failure', 'interrupt'] else
             'exit 0\n'))
        signer.chmod(0o755)
        script = template.replace('@TAG@', 'v1.1.0').replace('@VERSION@', '1.1.0')
        script = script.replace('@PARTS@', f'{part.name} {digest} {size}')
        script = script.replace('/usr/bin/codesign', shlex.quote(str(signer)))
        space_check = 'available_kb=$(/bin/df -Pk "$destination" | /usr/bin/awk \'NR==2 {print $4}\')'
        assert space_check in script
        script = script.replace(space_check, 'available_kb=20971520')
        installer = root / 'install.sh'
        installer.write_text(script)
        arguments = ['/bin/bash', str(installer), '--destination', str(destination),
                     '--assets-dir', str(assets)]
        if scenario != 'refuse-existing':
            arguments.append('--replace')
        result = subprocess.run(arguments, text=True, capture_output=True, timeout=30)
        success = scenario in ['fresh', 'replace']
        assert (result.returncode == 0) == success, (scenario, result.stdout, result.stderr)
        if success:
            assert (target / 'Contents/synthetic-build').read_text() == 'new build'
            assert not (target / 'old-build').exists()
        elif had_previous:
            assert (target / 'old-build').read_text() == 'original', scenario
            assert not (target / 'Contents').exists(), scenario
        else:
            assert not target.exists(), 'Failed fresh install left an unverified app'
        assert not list(destination.glob('.localdictation-*')), 'Staging or lock leak'
        print(f'PASS installer {scenario}')
print('Passed 8 installer regressions (signing and disk-space checks mocked)')
