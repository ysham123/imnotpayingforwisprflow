#!/usr/bin/env python3
"""Prepare a private local-build identity or sign a separate app candidate.

Never installs certificates into trust settings, replaces an installed app,
changes TCC permissions, or changes the user's default keychain.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PRIVATE = Path.home() / 'Library/Application Support/Local Dictation/Signing'
KEYCHAIN = PRIVATE / 'local-builds.keychain-db'
HELPER = ROOT / '.test-build/local-signing/keychain-tool'


def run(*args, capture=False):
    return subprocess.run([str(a) for a in args], check=True, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None, timeout=120)


def helper():
    HELPER.parent.mkdir(parents=True, exist_ok=True)
    run('/usr/bin/swiftc', '-suppress-warnings', ROOT / 'Scripts/LocalSigningKeychain.swift', '-o', HELPER)


def identity():
    certificate = PRIVATE / 'certificate.der'
    fingerprint = hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
    return fingerprint


def search_list():
    return shlex.split(run('/usr/bin/security', 'list-keychains', '-d', 'user', capture=True).stdout)


@contextmanager
def unlocked_identity():
    # codesign's --keychain limits identity lookup, but chain construction still
    # uses the user's search list. Add this chain only for the signing operation.
    # This does not modify the certificate's approved trust constraints.
    original = search_list()
    added = str(KEYCHAIN) not in original
    if added:
        run('/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *original, KEYCHAIN)
    try:
        run(HELPER, 'unlock', KEYCHAIN, PRIVATE)
        yield
    finally:
        try:
            run(HELPER, 'lock', KEYCHAIN, PRIVATE)
        finally:
            if added:
                current = search_list()
                # Preserve any concurrent changes made by other apps/users.
                run('/usr/bin/security', 'list-keychains', '-d', 'user', '-s',
                    *(path for path in current if path != str(KEYCHAIN)))


def prepare():
    if PRIVATE.exists():
        raise RuntimeError(f'Signing directory already exists. Preserve it; never regenerate an adopted identity: {PRIVATE}')
    PRIVATE.mkdir(mode=0o700, parents=True)
    os.umask(0o077)
    (PRIVATE / 'keychain-password').write_text(secrets.token_urlsafe(48))
    config = PRIVATE / 'certificate.cnf'
    config.write_text('''[req]
distinguished_name = name
x509_extensions = signing
prompt = no
[name]
CN = Local Dictation Local Builds
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
''')
    key = PRIVATE / 'temporary-private-key.pem'
    archive = PRIVATE / 'identity.p12'
    imported = False
    try:
        run('/usr/bin/openssl', 'req', '-new', '-newkey', 'rsa:3072', '-nodes', '-x509', '-sha256', '-days', '3650',
            '-config', config, '-keyout', key, '-out', PRIVATE / 'certificate.pem', capture=True)
        run('/usr/bin/openssl', 'x509', '-in', PRIVATE / 'certificate.pem', '-outform', 'DER', '-out', PRIVATE / 'certificate.der')
        run('/usr/bin/openssl', 'pkcs12', '-export', '-inkey', key, '-in', PRIVATE / 'certificate.pem',
            '-out', archive, '-passout', 'file:' + str(PRIVATE / 'keychain-password'))
        helper()
        run(HELPER, 'create', KEYCHAIN, PRIVATE)
        imported = True
        (PRIVATE / 'identity.json').write_text(json.dumps({
            'certificateSHA1': identity(),
            'purpose': 'Local Dictation local builds on this Mac only',
            'trustInstalledByThisTool': False,
        }, indent=2) + '\n')
        print('Prepared certificate:', identity())
        print('No trust or app installation changes made.')
    finally:
        # Retain the encrypted archive only if importing failed, for recovery.
        key.unlink(missing_ok=True)
        if imported:
            archive.unlink(missing_ok=True)


def sign(source, destination):
    source, destination = source.resolve(), destination.absolute()
    if destination.exists() or destination.is_symlink() or destination.suffix != '.app':
        raise RuntimeError('Choose a new, separate .app candidate path')
    if any(p in destination.parents for p in [Path('/Applications'), Path.home() / 'Applications']):
        raise RuntimeError('Build a candidate outside Applications; install only after verification')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', source)
    helper()
    destination.parent.mkdir(parents=True, exist_ok=True)
    fingerprint = identity()
    with tempfile.TemporaryDirectory(prefix='.local-signing-', dir=destination.parent) as temp:
        stage = Path(temp) / destination.name
        run('/usr/bin/ditto', source, stage)
        with unlocked_identity():
            # No helper receives a broader identity than the main app.
            import plistlib
            info = plistlib.loads((stage / 'Contents/Info.plist').read_bytes())
            identifier = info['CFBundleIdentifier']
            if identifier != 'dev.yosef.localdictation':
                raise RuntimeError('This identity is reserved for Local Dictation')
            for path, suffix in [(stage / 'Contents/Resources/whisper-worker', '.whisper-worker'),
                                 (stage / 'Contents/Resources/ollama', '.ollama'), (stage, '')]:
                code_id = identifier + suffix
                requirement = f'identifier "{code_id}" and certificate leaf = H"{fingerprint}"'
                run('/usr/bin/codesign', '--force', '--timestamp=none', '--keychain', KEYCHAIN,
                    '--sign', fingerprint, '--identifier', code_id, '--requirements', '=designated => ' + requirement, path)
            run('/usr/bin/codesign', '--verify', '--deep', '--strict', '-R', '=identifier "' + identifier + '" and certificate leaf = H"' + fingerprint + '"', stage)
            if destination.exists():
                raise RuntimeError('Candidate appeared during signing; preserving both copies')
            # Exclusive publish avoids replacing a concurrently created app.
            destination.mkdir()
            try:
                for item in stage.iterdir():
                    shutil.move(str(item), destination / item.name)
            except BaseException:
                shutil.rmtree(destination)
                raise
    print('Signed candidate:', destination)
    print('Installed app unchanged. Permission retention still needs an installed-app test.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('prepare')
    commands.add_parser('identity')
    signing = commands.add_parser('sign')
    signing.add_argument('source', type=Path)
    signing.add_argument('destination', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'prepare': prepare()
        elif args.command == 'identity': print(identity())
        else: sign(args.source, args.destination)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        # Do not print subprocess arguments: the helper keeps secrets out of them,
        # but future tooling changes must not accidentally expose key material.
        raise SystemExit('Local signing failed: ' + (str(error) if not isinstance(error, subprocess.SubprocessError) else type(error).__name__))
