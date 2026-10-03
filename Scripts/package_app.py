#!/usr/bin/env python3
"""Assemble, verify, and replace a local build without touching a live install."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile


def run(*args):
    subprocess.run(args, check=True)


def clean_finder_metadata(app):
    # File Provider folders may add metadata forbidden by codesign. Preserve
    # quarantine and all other attributes; only remove the two offending types.
    for attribute in ['com.apple.FinderInfo', 'com.apple.ResourceFork']:
        subprocess.run(['xattr', '-dr', attribute, str(app)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def validate_runtime(runtime):
    if not os.access(runtime / 'ollama', os.X_OK):
        raise RuntimeError('Bundled Ollama helper is missing or not executable')
    speech = runtime / 'Models/ggml-large-v3-turbo-q8_0.bin'
    if not speech.is_file() or speech.stat().st_size < 100_000_000:
        raise RuntimeError('Bundled Whisper model is missing or incomplete')
    models = runtime / 'Models/ollama'
    manifest = json.loads((models / 'manifests/registry.ollama.ai/library/qwen3/4b').read_text())
    for entry in [manifest['config'], *manifest['layers']]:
        digest = entry['digest']
        algorithm, value = digest.split(':', 1)
        if algorithm != 'sha256' or len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
            raise RuntimeError('Invalid local model digest')
        blob = models / 'blobs' / ('sha256-' + value)
        if blob.stat().st_size != entry['size']:
            raise RuntimeError('A correction model blob is incomplete')
        hasher = hashlib.sha256()
        with blob.open('rb') as stream:
            for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
                hasher.update(block)
        if hasher.hexdigest() != value:
            raise RuntimeError('A correction model blob failed integrity verification')


def copy_bytes(source, target):
    if source.is_symlink():
        raise RuntimeError(f'Unexpected runtime symlink: {source.name}')
    if source.is_dir():
        target.mkdir(parents=True, exist_ok=True)
        for child in source.iterdir():
            copy_bytes(child, target / child.name)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        target.chmod(0o755 if os.access(source, os.X_OK) else 0o644)


def main():
    def interrupted(signum, frame):
        raise InterruptedError(f'Installation interrupted by signal {signum}')
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser()
    parser.add_argument('destination', type=Path)
    parser.add_argument('executable', type=Path)
    parser.add_argument('worker', type=Path)
    parser.add_argument('--runtime', type=Path)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    destination = args.destination.absolute()
    if destination.is_symlink() or destination.suffix != '.app':
        raise RuntimeError('Choose a real .app path, not a symlink')
    runtime = args.runtime or destination / 'Contents/Resources'
    identity = os.environ.get('CODE_SIGN_IDENTITY', '-')
    if destination.exists() and identity == '-':
        info = subprocess.run(['codesign', '-dv', '--verbose=4', str(destination)], capture_output=True, text=True)
        if 'Authority=' in info.stderr:
            raise RuntimeError('Set CODE_SIGN_IDENTITY to the existing persistent signing identity; refusing an ad-hoc downgrade')
    expected_process = str(destination / 'Contents/MacOS/LocalDictation')
    running = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
    if expected_process in [line.strip() for line in running]:
        raise RuntimeError('Quit Local Dictation before replacing the installed app')
    validate_runtime(runtime)
    destination.parent.mkdir(parents=True, exist_ok=True)
    stage_root = Path(tempfile.mkdtemp(prefix='.localdictation-install-', dir=destination.parent))
    stage, backup = stage_root / destination.name, stage_root / 'previous.app'
    installed = False
    preserve_backup = False
    try:
        contents = stage / 'Contents'
        copy_bytes(args.executable, contents / 'MacOS/LocalDictation')
        copy_bytes(args.worker, contents / 'Resources/whisper-worker')
        copy_bytes(source / 'Resources/Info.plist', contents / 'Info.plist')
        for name in ['Models', 'ollama', 'Licenses']:
            copy_bytes(runtime / name, contents / 'Resources' / name)
        copy_bytes(source / 'Licenses', contents / 'Resources/Licenses')
        copy_bytes(source / 'LICENSE', contents / 'Resources/Licenses/LocalDictation-MIT.txt')
        copy_bytes(source / 'THIRD_PARTY_NOTICES.txt', contents / 'Resources/THIRD_PARTY_NOTICES.txt')
        clean_finder_metadata(stage)
        for path in [contents / 'Resources/whisper-worker', contents / 'Resources/ollama', stage]:
            run('codesign', '--force', '--timestamp=none', '--sign', identity, str(path))
        run('codesign', '--verify', '--deep', '--strict', str(stage))
        running = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
        if expected_process in [line.strip() for line in running]:
            raise RuntimeError('Local Dictation opened during packaging. Quit it and retry.')
        # Same-volume renames preserve the fully verified staging bundle. No
        # compile, model copy, or signing operation writes into the old app.
        if destination.exists():
            os.rename(destination, backup)
        os.rename(stage, destination)
        installed = True
        clean_finder_metadata(destination)
        run('codesign', '--verify', '--deep', '--strict', str(destination))
    except BaseException:
        if backup.exists():
            try:
                if installed:
                    os.rename(destination, stage_root / 'failed.app')
                os.rename(backup, destination)
            except BaseException:
                preserve_backup = True
                print(f'Rollback needs attention. Previous app preserved at: {backup}', flush=True)
        elif installed:
            os.rename(destination, stage_root / 'failed.app')
        raise
    finally:
        if not preserve_backup:
            shutil.rmtree(stage_root)
    print(f'Installed and signature verified: {destination}')
    if identity == '-':
        print('Ad-hoc signing: macOS may require Accessibility and Input Monitoring approval again after this update.')


if __name__ == '__main__':
    main()
