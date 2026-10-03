import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from unittest.mock import patch

source = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('package_app', source / 'Scripts/package_app.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)

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
        original_copy = package.copy_bytes
        def copy(src, dst):
            if fault == 'copy' and src.name == 'ollama':
                raise OSError('injected copy failure')
            original_copy(src, dst)
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
