"""Tiny fixture coverage; never signs an app, creates a real DMG, or downloads models."""
import contextlib
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

source = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('package_app', source / 'Scripts/package_app.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)
sys.modules['package_app'] = package
spec = importlib.util.spec_from_file_location('make_release', source / 'Scripts/make-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def rejects(action, reason):
    try:
        action()
    except RuntimeError as error:
        assert reason in str(error), (reason, error)
    else:
        raise AssertionError('Invalid input was accepted: ' + reason)


@contextlib.contextmanager
def empty_read(path):
    original_open = Path.open
    class EmptyReader:
        def __init__(self, stream): self.stream = stream
        def __enter__(self): return self
        def __exit__(self, *args): return self.stream.__exit__(*args)
        def fileno(self): return self.stream.fileno()
        def read(self, count): return b''
    def open_with_fault(self, mode='r', *args, **kwargs):
        stream = original_open(self, mode, *args, **kwargs)
        return EmptyReader(stream) if self == path and mode == 'rb' else stream
    with patch.object(Path, 'open', new=open_with_fault):
        yield


def fixture_app(root):
    app = root / 'Local Dictation.app'
    resources = app / 'Contents/Resources'
    resources.mkdir(parents=True)
    info = plistlib.loads(package.read_bytes_checked(source / 'Resources/Info.plist'))
    package.write_bytes_checked(app / 'Contents/Info.plist', plistlib.dumps(info))
    for name in ['MacOS/LocalDictation', 'Resources/whisper-worker', 'Resources/ollama']:
        path = app / 'Contents' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(('signed fixture ' + name).encode()); path.chmod(0o755)
    package.copy_bytes(source / 'Resources/ModelManifest.json', resources / 'ModelManifest.json')
    (resources / 'Licenses').mkdir()
    (resources / 'Licenses/license.txt').write_text('fixture license\n')
    (app / 'Contents/_CodeSignature').mkdir()
    (app / 'Contents/_CodeSignature/CodeResources').write_bytes(b'unchanged signature fixture')
    return app, info


with tempfile.TemporaryDirectory(prefix='localdictation-thin-release-') as temp:
    root = Path(temp)
    app, info = fixture_app(root)
    requirement = 'identifier "dev.yosef.localdictation" and certificate leaf = H"' + 'a' * 40 + '"'
    calls = []
    original_bytes = {path.relative_to(app): package.read_bytes_checked(path)
                      for path in app.rglob('*') if path.is_file()}
    def run(arguments, **kwargs):
        calls.append(list(arguments))
        assert '--sign' not in arguments, 'Release creation must never change the app signature'
        if arguments[0] == 'codesign' and '--display' in arguments:
            return SimpleNamespace(stdout='', stderr='designated => ' + requirement + '\n', returncode=0)
        if arguments[0] == 'codesign' and '--verify' in arguments:
            checked = Path(arguments[-1])
            actual = {path.relative_to(checked): package.read_bytes_checked(path)
                      for path in checked.rglob('*') if path.is_file()}
            assert actual == original_bytes, 'Signed app bytes changed during staging'
            if checked != app:
                assert arguments[arguments.index('--test-requirement') + 1] == '=' + requirement
        if arguments[:2] == ['hdiutil', 'create']:
            content = Path(arguments[arguments.index('-srcfolder') + 1])
            assert (content / 'Local Dictation.app').is_dir()
            assert package.read_text_checked(content / 'READ ME FIRST.txt').startswith('LOCAL DICTATION ')
            Path(arguments[-1]).write_bytes(b'synthetic complete DMG fixture\n')
        return SimpleNamespace(stdout='', stderr='', returncode=0)

    output = root / 'release'
    with patch.object(sys, 'argv', ['make-release.py', str(app), str(output), '--tag', 'v' + info['CFBundleShortVersionString']]), \
         patch.object(release.subprocess, 'run', side_effect=run), \
         contextlib.redirect_stdout(None):
        release.main()
    manifest = json.loads(package.read_text_checked(output / 'release-manifest.json'))
    assert manifest['distribution'] == 'thin-dmg'
    assert manifest['designated_requirement'] == requirement
    assert manifest['model_manifest_sha256'] == hashlib.sha256(original_bytes[Path('Contents/Resources/ModelManifest.json')]).hexdigest()
    assert {path.name for path in output.iterdir()} == {'Local-Dictation.dmg', 'model-manifest.json', 'release-manifest.json', 'SHA256SUMS'}
    for line in package.read_text_checked(output / 'SHA256SUMS').splitlines():
        digest, name = line.split('  ', 1)
        assert package.hash_file_checked(output / name) == digest
    assert any(call[:2] == ['hdiutil', 'verify'] for call in calls)
    print('PASS thin release preserves signed app bytes and exact designated requirement')
    print('PASS thin release emits verified manifests and complete checksums')

    plist_path = app / 'Contents/Info.plist'
    development_info = dict(info, CFBundleIdentifier=info['CFBundleIdentifier'] + '.development')
    plist_path.write_bytes(plistlib.dumps(development_info))
    rejects(lambda: release.validate_release_app(app), 'Only the public')
    plist_path.write_bytes(plistlib.dumps(info))
    (app / 'Contents/Resources/Models').mkdir()
    rejects(lambda: release.validate_release_app(app), 'Package a thin app')
    (app / 'Contents/Resources/Models').rmdir()
    print('PASS development and model-containing bundles cannot become public thin releases')

    bad_output = root / 'empty-image'
    def empty_image(arguments, **kwargs):
        if arguments[:2] == ['hdiutil', 'create']:
            Path(arguments[-1]).write_bytes(b'')
            return SimpleNamespace(stdout='', stderr='', returncode=0)
        assert arguments[:2] != ['hdiutil', 'verify'], 'Empty DMG reached verification'
        return run(arguments, **kwargs)
    with patch.object(sys, 'argv', ['make-release.py', str(app), str(bad_output), '--tag', 'v' + info['CFBundleShortVersionString']]), \
         patch.object(release.subprocess, 'run', side_effect=empty_image):
        rejects(release.main, 'missing or empty')
    assert not (bad_output / 'release-manifest.json').exists()
    print('PASS empty image fails before release manifest publication')

    short_output = root / 'short-image'
    with empty_read(short_output / 'Local-Dictation.dmg'), \
         patch.object(sys, 'argv', ['make-release.py', str(app), str(short_output), '--tag', 'v' + info['CFBundleShortVersionString']]), \
         patch.object(release.subprocess, 'run', side_effect=run):
        rejects(release.main, 'Incomplete source read')
    assert (short_output / 'Local-Dictation.dmg').stat().st_size > 0
    assert not (short_output / 'release-manifest.json').exists()
    print('PASS nonempty image metadata with empty reads is rejected')

    helper = root / 'helper'; helper.write_text('tiny executable'); helper.chmod(0o755)
    runtime = root / 'runtime'; (runtime / 'Licenses').mkdir(parents=True)
    (runtime / 'Licenses/license.txt').write_text('tiny license')
    (runtime / 'ollama').write_text('tiny ollama'); (runtime / 'ollama').chmod(0o755)
    (runtime / 'Models').mkdir(); (runtime / 'Models/do-not-copy').write_text('unused model fixture')
    destination = root / 'packaged' / 'Local Dictation.app'
    with patch.object(sys, 'argv', ['package_app.py', str(destination), str(helper), str(helper), '--runtime', str(runtime)]), \
         patch.dict(os.environ, {'CODE_SIGN_IDENTITY': '-', 'CODE_SIGN_REQUIREMENT': ''}), \
         patch.object(package.subprocess, 'check_output', return_value=''), \
         patch.object(package.subprocess, 'run', return_value=SimpleNamespace(stderr='', returncode=0)), \
         contextlib.redirect_stdout(None):
        package.main()
    assert not (destination / 'Contents/Resources/Models').exists()
    assert (destination / 'Contents/Resources/ModelManifest.json').is_file()
    assert plistlib.loads(package.read_bytes_checked(destination / 'Contents/Info.plist'))['CFBundleIdentifier'] == info['CFBundleIdentifier']
    print('PASS default package is thin and includes its sealed model manifest')

    destination_bytes = package.read_bytes_checked(destination / 'Contents/Info.plist')
    with patch.object(sys, 'argv', ['package_app.py', str(destination), str(helper), str(helper), '--runtime', str(runtime), '--development']), \
         patch.dict(os.environ, {'CODE_SIGN_IDENTITY': '-', 'CODE_SIGN_REQUIREMENT': ''}):
        rejects(package.main, 'separate app location')
    assert package.read_bytes_checked(destination / 'Contents/Info.plist') == destination_bytes
    print('PASS development build cannot replace public app identity')

    weak = 'identifier "dev.yosef.localdictation"'
    rejects(lambda: package.signing_options('Publisher', info['CFBundleIdentifier'], weak), 'exact certificate-leaf')
    rejects(lambda: package.signing_options('-', info['CFBundleIdentifier'], requirement), 'cannot use ad-hoc')
    helper_id = info['CFBundleIdentifier'] + '.ollama'
    options = package.signing_options('Publisher', helper_id, requirement)
    assert options[-1].startswith('=designated => ')
    assert 'identifier "' + helper_id + '"' in options[-1]
    assert 'certificate leaf = H"' + 'a' * 40 + '"' in options[-1]
    print('PASS persistent signing requires exact certificate pin for app and helpers')

print('Passed 8 thin-package/release regression groups (external signing and DMG tools mocked)')
