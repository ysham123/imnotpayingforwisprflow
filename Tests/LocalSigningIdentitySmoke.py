"""Disposable signing checks. Run only after approving the local trust change.

No installed apps are replaced or launched; no TCC grants are changed.
"""
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('local_signing', ROOT / 'Scripts/local-signing.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


def run(*args, success=True):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=30)
    assert (result.returncode == 0) == success, result.stderr
    return result.stdout + result.stderr


signing.helper()
fingerprint = signing.identity()
identifier = 'dev.yosef.localdictation.signing-fixture'
requirement = f'identifier "{identifier}" and certificate leaf = H"{fingerprint}"'
with signing.unlocked_identity():
    with tempfile.TemporaryDirectory(prefix='localdictation-identity-', dir='/private/tmp') as temp:
        root = Path(temp)
        apps = []
        for version in (1, 2):
            app = root / f'Build{version}.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/Resources').mkdir()
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'fixture',
                'CFBundlePackageType': 'APPL', 'CFBundleVersion': str(version),
            }))
            (app / 'Contents/Resources/sealed.txt').write_text('Original resource')
            code = root / f'build{version}.c'
            code.write_text(f'int main(void) {{ return {version}; }}\n')
            run('/usr/bin/clang', code, '-o', app / 'Contents/MacOS/fixture')
            run('/usr/bin/codesign', '--force', '--timestamp=none', '--keychain', signing.KEYCHAIN,
                '--sign', fingerprint, '--identifier', identifier,
                '--requirements', '=designated => ' + requirement, app)
            run('/usr/bin/codesign', '--verify', '--deep', '--strict', '-R', '=' + requirement, app)
            apps.append(app)
        first = run('/usr/bin/codesign', '--display', '--verbose=4', '-r-', apps[0])
        second = run('/usr/bin/codesign', '--display', '--verbose=4', '-r-', apps[1])
        def line(output, prefix):
            return next(row for row in output.splitlines() if row.startswith(prefix))
        assert line(first, 'CDHash=') != line(second, 'CDHash=')
        assert line(first, 'designated =>') == line(second, 'designated =>')
        print('PASS different compiled builds satisfy the same exact certificate-and-identifier requirement')
        run('/usr/bin/codesign', '--verify', '--strict', '-R', '=identifier "unrelated.app" and certificate leaf = H"' + fingerprint + '"', apps[1], success=False)
        print('PASS wrong bundle identifier is rejected')
        run('/usr/bin/codesign', '--force', '--sign', '-', apps[0])
        run('/usr/bin/codesign', '--verify', '--strict', '-R', '=' + requirement, apps[0], success=False)
        print('PASS ad-hoc impersonation with the same bundle identifier is rejected')
        (apps[1] / 'Contents/Resources/sealed.txt').write_text('Changed resource')
        run('/usr/bin/codesign', '--verify', '--strict', apps[1], success=False)
        print('PASS resource tampering is rejected')
print('Passed 4 signing identity groups. Actual TCC persistence still needs an installed-app test.')
