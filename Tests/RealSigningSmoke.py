"""Real codesign checks on tiny temporary apps; no installed app or keys are changed."""
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

source = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('package_app', source / 'Scripts/package_app.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)
sys.modules['package_app'] = package
spec = importlib.util.spec_from_file_location('make_release', source / 'Scripts/make-release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

with tempfile.TemporaryDirectory(prefix='localdictation-real-signing-', dir='/private/tmp') as temp:
    app = Path(temp) / 'Local Dictation.app'
    resources = app / 'Contents/Resources'
    resources.mkdir(parents=True)
    info = plistlib.loads(package.read_bytes_checked(source / 'Resources/Info.plist'))
    identifier = info['CFBundleIdentifier']
    package.write_bytes_checked(app / 'Contents/Info.plist', plistlib.dumps(info))
    package.copy_bytes(source / 'Resources/ModelManifest.json', resources / 'ModelManifest.json')
    evidence = resources / 'fixture.txt'; evidence.write_text('real sealed resource\n')
    for relative, code_id in [('MacOS/LocalDictation', identifier),
                              ('Resources/whisper-worker', identifier + '.whisper-worker'),
                              ('Resources/ollama', identifier + '.ollama')]:
        target = app / 'Contents' / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        package.copy_bytes(Path('/bin/echo'), target)
        subprocess.run(['/usr/bin/codesign', '--force', '--timestamp=none', '--sign', '-', '--identifier', code_id, str(target)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(['/usr/bin/codesign', '--force', '--timestamp=none', '--sign', '-', '--identifier', identifier, str(app)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    original = hashlib.sha256(package.read_bytes_checked(app / 'Contents/MacOS/LocalDictation')).hexdigest()
    release.validate_release_app(app)
    requirement = release.designated_requirement(app)
    assert requirement.startswith('cdhash H"'), 'Ad-hoc fixture needs a real CDHash requirement'
    release.validate_release_app(app, requirement)
    assert hashlib.sha256(package.read_bytes_checked(app / 'Contents/MacOS/LocalDictation')).hexdigest() == original
    print('PASS real ad-hoc release app validates its inline exact CDHash requirement')

    try:
        release.validate_release_app(app, 'cdhash H"' + '0' * 40 + '"')
    except subprocess.CalledProcessError:
        pass
    else:
        raise AssertionError('A different CDHash was accepted')
    print('PASS real designated requirement rejects a different app hash')

    evidence.write_text('tampered resource\n')
    try:
        release.validate_release_app(app, requirement)
    except subprocess.CalledProcessError:
        pass
    else:
        raise AssertionError('A changed sealed resource was accepted')
    print('PASS real release verification rejects a changed sealed resource')

print('Passed 3 real ad-hoc signing regression groups; no DMG, key, trust, or installed-app changes')
