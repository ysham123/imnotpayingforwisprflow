import importlib.util
import contextlib
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile
from types import SimpleNamespace
from unittest.mock import patch

source = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('package_app', source / 'Scripts/package_app.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)
sys.modules['package_app'] = package
release_spec = importlib.util.spec_from_file_location('make_release', source / 'Scripts/make-release.py')
release = importlib.util.module_from_spec(release_spec)
release_spec.loader.exec_module(release)

for fault in ['copy', 'stage-sign', 'final-verify', None]:
    with tempfile.TemporaryDirectory(prefix='localdictation-packaging-test-') as temp:
        root = Path(temp)
        destination = root / 'Local Dictation.app'
        destination.mkdir()
        (destination / 'old-build').write_text('original')
        runtime = root / 'runtime'
        (runtime / 'Models').mkdir(parents=True)
        (runtime / 'Licenses').mkdir()
        (runtime / 'ollama').write_text('fake helper')
        executable = root / 'executable'
        executable.write_text('new build')
        executable.chmod(0o755)
        original_copy = package.copy_bytes
        def copy(src, dst, **kwargs):
            if fault == 'copy' and src.name == 'ollama':
                raise OSError('injected copy failure')
            original_copy(src, dst, **kwargs)
        def run(args, **kwargs):
            if fault == 'stage-sign' and '--sign' in args:
                raise subprocess.CalledProcessError(1, args)
            if fault == 'final-verify' and '--verify' in args and args[-1] == str(destination):
                raise subprocess.CalledProcessError(1, args)
            return SimpleNamespace(stderr='', returncode=0)
        arguments = ['package_app.py', str(destination), str(executable), str(executable), '--runtime', str(runtime)]
        with patch.object(sys, 'argv', arguments), patch.dict(os.environ, {'CODE_SIGN_IDENTITY': '-'}), \
             patch.object(package, 'validate_runtime'), patch.object(package, 'copy_bytes', side_effect=copy), \
             patch.object(package.subprocess, 'run', side_effect=run), \
             patch.object(package.subprocess, 'check_output', return_value=''):
            try:
                package.main()
                assert fault is None, 'injected failure did not occur'
            except (OSError, subprocess.CalledProcessError):
                assert fault is not None
        if fault:
            assert (destination / 'old-build').read_text() == 'original', 'original app was not preserved'
        else:
            assert (destination / 'Contents/MacOS/LocalDictation').read_text() == 'new build'
        assert not list(root.glob('.localdictation-install-*')), 'staging leak'
        print(f'PASS packaging {fault or "success"}')
print('Passed 4 package replacement/rollback regressions (signing and runtime verification mocked)')


@contextlib.contextmanager
def incomplete_read(path, *, prefix=0):
    """Keep real, nonempty stat/fstat metadata while injecting a short read."""
    original_open = Path.open
    class ShortReader:
        def __init__(self, stream): self.stream, self.first = stream, True
        def __enter__(self): return self
        def __exit__(self, *args): return self.stream.__exit__(*args)
        def fileno(self): return self.stream.fileno()
        def read(self, count):
            if not self.first: return b''
            self.first = False
            return self.stream.read(min(count, prefix))
    def open_with_fault(self, mode='r', *args, **kwargs):
        stream = original_open(self, mode, *args, **kwargs)
        return ShortReader(stream) if self == path and mode == 'rb' else stream
    with patch.object(Path, 'open', new=open_with_fault):
        yield


def rejects(action, reason):
    try:
        action()
    except RuntimeError as error:
        assert reason in str(error), (reason, error)
    else:
        raise AssertionError('Invalid packaging input was accepted: ' + reason)


with tempfile.TemporaryDirectory(prefix='localdictation-incomplete-read-test-') as temp:
    root = Path(temp)
    original, target = root / 'resource', root / 'copied-resource'
    original.write_bytes(b'nonempty fixture resource')
    for prefix in [0, 3]:
        assert original.stat().st_size > prefix
        with incomplete_read(original, prefix=prefix):
            rejects(lambda: package.read_bytes_checked(original), 'Incomplete source read')
            rejects(lambda: package.copy_bytes(original, target), 'Incomplete source read')
        assert not target.exists(), 'A failed copy left a truncated resource'
        assert original.read_bytes() == b'nonempty fixture resource'
    print('PASS nonempty stat metadata with empty/truncated reads is rejected')

    with incomplete_read(target):
        rejects(lambda: package.copy_bytes(original, target), 'Incomplete source read')
    assert not target.exists(), 'Failed readback left an incomplete copied resource'
    print('PASS copied non-model resource readback failure is rejected')

    empty = root / 'empty-executable'
    empty.write_bytes(b''); empty.chmod(0o755)
    rejects(lambda: package.validate_executable(empty), 'missing or empty')
    original.chmod(0o755)
    with incomplete_read(original):
        rejects(lambda: package.validate_executable(original), 'Incomplete source read')
    print('PASS empty and incompletely read executable rejection')

    fixture_source, output = root / 'source', root / 'output'
    (fixture_source / 'Distribution').mkdir(parents=True); output.mkdir()
    template_path = fixture_source / 'Distribution/install.template.sh'
    template_bytes = package.read_bytes_checked(source / 'Distribution/install.template.sh')
    template_path.write_bytes(template_bytes)
    (fixture_source / 'LICENSE').write_text('Synthetic license\n')
    part = output / 'fixture.tar.part001'; part.write_bytes(b'synthetic archive bytes\n')
    manifest = {'version': '1.2.0', 'tag': 'v1.2.0', 'parts': [{
        'name': part.name, 'sha256': hashlib.sha256(part.read_bytes()).hexdigest(),
        'bytes': part.stat().st_size}]}

    with incomplete_read(template_path):
        rejects(lambda: release.write_installer(fixture_source, output, manifest), 'Incomplete source read')
    assert not (output / 'install.sh').exists()
    assert not (fixture_source / 'Distribution/install.sh').exists()
    print('PASS incomplete template fails before generating installer outputs')

    for payload, reason in [(b'', 'missing or empty'),
                            (template_bytes.replace(b'#!/bin/bash', b'#!/bin/sh'), 'shebang'),
                            (template_bytes.replace(b'@PARTS@', b''), 'exactly one @PARTS@')]:
        template_path.write_bytes(payload)
        rejects(lambda: release.write_installer(fixture_source, output, manifest), reason)
    template_path.write_bytes(template_bytes)
    print('PASS empty, wrong-shebang, and missing-marker template rejection')

    release.write_installer(fixture_source, output, manifest)
    installer = package.read_text_checked(output / 'install.sh')
    assert installer.startswith('#!/bin/bash\n')
    assert '@PARTS@' not in installer
    assert package.read_text_checked(fixture_source / 'Distribution/install.sh') == installer
    release.verify_installer_zip(output / 'Local-Dictation-Installer.zip', installer)
    print('PASS tiny real installer ZIP contains complete executable command')

    bad_zip = root / 'empty-installer.zip'
    member = zipfile.ZipInfo('Local Dictation Installer/Install Local Dictation.command')
    member.external_attr = 0o100755 << 16
    with zipfile.ZipFile(bad_zip, 'w') as archive:
        archive.writestr(member, b'')
    # Reproduce why shell syntax alone could not detect the original failure.
    empty_script = root / 'empty.sh'; empty_script.write_bytes(b'')
    subprocess.run(['bash', '-n', str(empty_script)], check=True)
    rejects(lambda: release.verify_installer_zip(bad_zip, installer), 'empty or incomplete')
    print('PASS empty ZIP command rejected even though bash -n accepts empty script')

print('Passed 7 packaging read/content integrity regression groups (tiny fixtures only)')
