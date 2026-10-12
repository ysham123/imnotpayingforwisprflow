#!/usr/bin/env python3
"""Require real matching helper crash symbols in a Store archive."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('archive', type=Path)
args = parser.parse_args()


def uuids(path):
    output = subprocess.check_output(['dwarfdump', '--uuid', str(path)], text=True, stderr=subprocess.PIPE)
    return sorted(re.findall(r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)', output))


checks = {}
errors = []
for helper in ('whisper-worker', 'ollama'):
    binary = args.archive / 'Products/Applications/Local Dictation.app/Contents/Helpers' / helper
    symbols = args.archive / 'dSYMs' / (helper + '.dSYM')
    try:
        binary_ids, symbol_ids = uuids(binary), uuids(symbols)
        dwarf = symbols / 'Contents/Resources/DWARF' / helper
        valid = bool(binary_ids) and binary_ids == symbol_ids and dwarf.is_file() and dwarf.stat().st_size > 1024
        # Reject an empty UUID-only placeholder by requiring compile units.
        if valid:
            process = subprocess.Popen(['dwarfdump', '--debug-info', str(dwarf)], stdout=subprocess.PIPE,
                                       stderr=subprocess.DEVNULL)
            try:
                needle = b'whisper-worker.cpp' if helper == 'whisper-worker' else b'main.main'
                valid = any(needle in line for line in process.stdout)
            finally:
                process.stdout.close()
                if process.poll() is None:
                    process.terminate()
                process.wait()
        checks[helper] = valid
        if not valid:
            errors.append(f'{helper}: matching UUIDs and actual debug information are required')
    except (OSError, subprocess.CalledProcessError) as error:
        checks[helper] = False
        errors.append(f'{helper}: {type(error).__name__}')
print(json.dumps({'matchingHelperSymbols': checks, 'passed': not errors, 'errors': errors}, indent=2))
sys.exit(1 if errors else 0)
