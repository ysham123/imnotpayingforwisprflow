#!/usr/bin/env python3
"""Assemble, verify, and replace a local build without touching a live install."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
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


def checked_blocks(path, block_size=4 * 1024 * 1024):
    """Reject File Provider reads that disagree with nonempty file metadata."""
    path = Path(path)
    if path.is_symlink():
        raise RuntimeError(f'Unexpected source symlink: {path}')
    before = path.stat()
    if not stat.S_ISREG(before.st_mode) or before.st_size <= 0:
        raise RuntimeError(f'Source file is missing or empty: {path}')
    def stamp(value):
        return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns)
    count = 0
    with path.open('rb') as stream:
        if stamp(os.fstat(stream.fileno())) != stamp(before):
            raise RuntimeError(f'Source file changed while opening: {path}')
        while True:
            block = stream.read(block_size)
            if not block:
                break
            count += len(block)
            if count > before.st_size:
                raise RuntimeError(f'Source file grew while reading: {path}')
            yield block
        if count != before.st_size:
            raise RuntimeError(f'Incomplete source read: {path} (expected {before.st_size} bytes, read {count})')
        if stamp(os.fstat(stream.fileno())) != stamp(before) or stamp(path.stat()) != stamp(before):
            raise RuntimeError(f'Source file changed while reading: {path}')


def read_bytes_checked(path):
    return b''.join(checked_blocks(path))


def read_text_checked(path):
    return read_bytes_checked(path).decode('utf-8')


def hash_file_checked(path):
    hasher = hashlib.sha256()
    for block in checked_blocks(path):
        hasher.update(block)
    return hasher.hexdigest()


def write_bytes_checked(path, data):
    path = Path(path)
    if path.is_symlink() or not data:
        raise RuntimeError(f'Refusing an empty or symlink output: {path}')
    if path.write_bytes(data) != len(data) or read_bytes_checked(path) != data:
        raise RuntimeError(f'Generated file failed readback verification: {path}')


def validate_executable(path):
    if not os.access(path, os.X_OK):
        raise RuntimeError(f'Executable is missing or not executable: {path}')
    # Count bytes even when no known digest exists. codesign can successfully
    # sign an app whose copied resources were silently truncated beforehand.
    hash_file_checked(path)


def validate_source_resources(source):
    for path in [source / 'Resources/Info.plist', source / 'LICENSE', source / 'THIRD_PARTY_NOTICES.txt']:
        read_bytes_checked(path)
    licenses = source / 'Licenses'
    if not licenses.is_dir() or not any(licenses.iterdir()):
        raise RuntimeError('Source license resources are missing')
    for path in licenses.rglob('*'):
        if path.is_symlink():
            raise RuntimeError(f'Unexpected source symlink: {path}')
        if path.is_file():
            read_bytes_checked(path)


def validate_runtime(runtime, *, verify_digests=True):
    validate_executable(runtime / 'ollama')
    speech = runtime / 'Models/ggml-large-v3-turbo-q8_0.bin'
    if not speech.is_file() or speech.stat().st_size < 100_000_000:
        raise RuntimeError('Bundled Whisper model is missing or incomplete')
    models = runtime / 'Models/ollama'
    manifest = json.loads(read_text_checked(models / 'manifests/registry.ollama.ai/library/qwen3/4b'))
    for entry in [manifest['config'], *manifest['layers']]:
        digest = entry['digest']
        algorithm, value = digest.split(':', 1)
        if algorithm != 'sha256' or len(value) != 64 or any(c not in '0123456789abcdef' for c in value):
            raise RuntimeError('Invalid local model digest')
        blob = models / 'blobs' / ('sha256-' + value)
        if blob.stat().st_size != entry['size']:
            raise RuntimeError('A correction model blob is incomplete')
        if verify_digests and hash_file_checked(blob) != value:
            raise RuntimeError('A correction model blob failed integrity verification')


def copy_bytes(source, target, *, verify_readback=True):
    source, target = Path(source), Path(target)
    verify_readback = verify_readback and source.name != 'Models'
    if source.is_symlink():
        raise RuntimeError(f'Unexpected runtime symlink: {source.name}')
    if source.is_dir():
        target.mkdir(parents=True, exist_ok=True)
        for child in source.iterdir():
            # Model streams are counted against their metadata during copy;
            # their known digests are checked separately by validate_runtime.
            # Avoid an additional multi-GB readback of every model copy.
            copy_bytes(child, target / child.name,
                       verify_readback=verify_readback and child.name != 'Models')
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        hasher = hashlib.sha256()
        count = 0
        try:
            with target.open('wb') as destination:
                for block in checked_blocks(source):
                    if destination.write(block) != len(block):
                        raise RuntimeError(f'Incomplete copy write: {target}')
                    count += len(block); hasher.update(block)
            if target.stat().st_size != count:
                raise RuntimeError(f'Copied file size disagrees with source: {target}')
            target.chmod(0o755 if os.access(source, os.X_OK) else 0o644)
            if verify_readback and hash_file_checked(target) != hasher.hexdigest():
                raise RuntimeError(f'Copied file failed readback verification: {target}')
        except BaseException:
            target.unlink(missing_ok=True)
            raise


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
    validate_source_resources(source)
    validate_executable(args.executable)
    validate_executable(args.worker)
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
        validate_runtime(contents / 'Resources', verify_digests=False)
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
