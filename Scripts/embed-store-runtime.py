#!/usr/bin/env python3
"""Embed only sealed runtime executables, never model weights or installers."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--runtime', type=Path, required=True)
parser.add_argument('--destination', type=Path, required=True)
parser.add_argument('--identity', required=True)
parser.add_argument('--configuration', default='Debug')
parser.add_argument('--symbols', type=Path)
args = parser.parse_args()
source = Path(__file__).resolve().parent.parent
entitlements = source / 'AppStore/Helper.entitlements'
provenance_path = args.runtime / 'provenance.json'
provenance = json.loads(provenance_path.read_text()) if provenance_path.is_file() else None
if args.configuration == 'Release':
    if not provenance or provenance.get('sources') != json.loads((source / 'AppStore/RuntimeSources.json').read_text()):
        raise SystemExit('Release helpers must be rebuilt from the pinned sources with Scripts/build-store-runtime.py.')
    if provenance.get('workerSourceSHA256') != hashlib.sha256((source / 'Native/whisper-worker.cpp').read_bytes()).hexdigest():
        raise SystemExit('The speech worker changed after its runtime build. Rebuild the Store helpers.')
    if not args.symbols:
        raise SystemExit('Release helper crash symbols need an output directory.')

def uuids(path):
    output = subprocess.check_output(['dwarfdump', '--uuid', str(path)], text=True)
    return sorted(re.findall(r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)', output))

args.destination.mkdir(parents=True, exist_ok=True)
for name in ('whisper-worker', 'ollama'):
    original = args.runtime / name
    if original.is_symlink() or not original.is_file() or original.stat().st_size == 0:
        raise SystemExit(f'Missing verified runtime: {original}. See AppStore/README.md.')
    target = args.destination / name
    shutil.copyfile(original, target)
    if provenance:
        if hashlib.sha256(target.read_bytes()).hexdigest() != provenance['helpers'][name]['sha256']:
            raise SystemExit(f'{name} does not match its build provenance. Rebuild the Store helpers.')
        symbols = args.runtime / (name + '.dSYM')
        if not symbols.is_dir() or not uuids(target) or uuids(target) != uuids(symbols):
            raise SystemExit(f'{name} is missing matching crash symbols.')
        if args.symbols:
            args.symbols.mkdir(parents=True, exist_ok=True)
            shutil.copytree(symbols, args.symbols / symbols.name, dirs_exist_ok=True)
    target.chmod(0o755)
    command = ['codesign', '--force', '--sign', args.identity, '--entitlements', str(entitlements),
               '--identifier', f'dev.yosef.localdictation.{name}', '--options', 'runtime']
    command += ['--timestamp=none'] if args.identity == '-' else ['--timestamp']
    subprocess.run(command + [str(target)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(target)], check=True)
