#!/usr/bin/env python3
"""Embed only sealed runtime executables, never model weights or installers."""
import argparse
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', type=Path, required=True)
parser.add_argument('--destination', type=Path, required=True)
parser.add_argument('--identity', required=True)
args = parser.parse_args()
source = Path(__file__).resolve().parent.parent
entitlements = source / 'AppStore/Helper.entitlements'
args.destination.mkdir(parents=True, exist_ok=True)
for name in ('whisper-worker', 'ollama'):
    original = args.runtime / name
    if original.is_symlink() or not original.is_file() or original.stat().st_size == 0:
        raise SystemExit(f'Missing verified runtime: {original}. See AppStore/README.md.')
    target = args.destination / name
    shutil.copyfile(original, target)
    target.chmod(0o755)
    command = ['codesign', '--force', '--sign', args.identity, '--entitlements', str(entitlements),
               '--identifier', f'dev.yosef.localdictation.{name}', '--options', 'runtime']
    command += ['--timestamp=none'] if args.identity == '-' else ['--timestamp']
    subprocess.run(command + [str(target)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(target)], check=True)
