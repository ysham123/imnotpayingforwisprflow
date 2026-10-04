#!/usr/bin/env python3
"""Create verified, GitHub-sized app parts and an installer from a working app."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tarfile
import tempfile
import zipfile
from package_app import (copy_bytes, hash_file_checked, read_bytes_checked,
                         read_text_checked, validate_executable, validate_runtime,
                         validate_source_resources, write_bytes_checked)

class PartsWriter:
    def __init__(self, output, base, limit=1_800_000_000):
        self.output, self.base, self.limit = output, base, limit
        self.entries = []
        self.file = None
        self.size = 0
        self.archive_hash = hashlib.sha256()
    def write(self, data):
        size = len(data)
        self.archive_hash.update(data)
        while data:
            if self.file is None:
                name = f'{self.base}.part{len(self.entries)+1:03}'
                self.file = (self.output / name).open('wb')
                self.hash = hashlib.sha256(); self.size = 0; self.name = name
            block = data[:self.limit-self.size]
            if self.file.write(block) != len(block):
                raise RuntimeError('Release part write was incomplete')
            self.hash.update(block); self.size += len(block)
            data = data[len(block):]
            if self.size == self.limit: self.finish_part()
        return size
    def finish_part(self):
        if self.file:
            self.file.close()
            if (self.output / self.name).stat().st_size != self.size or self.size <= 0:
                raise RuntimeError('Release part size disagrees with written bytes')
            self.entries.append({'name': self.name, 'sha256': self.hash.hexdigest(), 'bytes': self.size})
            self.file = None
    def flush(self):
        if self.file: self.file.flush()


def read_installer_template(source):
    template = read_text_checked(source / 'Distribution/install.template.sh')
    validate_installer_structure(template)
    for marker in ['@TAG@', '@VERSION@', '@PARTS@']:
        if template.count(marker) != 1:
            raise RuntimeError(f'Installer template must contain exactly one {marker}')
    return template


def validate_installer_structure(installer):
    if not installer.startswith('#!/bin/bash\n'):
        raise RuntimeError('Installer is empty or lacks its expected bash shebang')
    for marker in ['set -euo pipefail', 'trap cleanup EXIT', "done <<'PARTS'\n",
                   'move_exact "$prepared" "$target"',
                   '/usr/bin/codesign --verify --deep --strict "$target"']:
        if marker not in installer:
            raise RuntimeError(f'Installer is missing required content: {marker}')


def render_installer(template, manifest):
    version = manifest['version']
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', version) or manifest['tag'] != 'v' + version:
        raise RuntimeError('Installer tag and numeric app version must match')
    if not manifest['parts']:
        raise RuntimeError('Installer must include release parts')
    rows = []
    for part in manifest['parts']:
        if (not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', part['name'])
                or not re.fullmatch(r'[0-9a-f]{64}', part['sha256'])
                or type(part['bytes']) is not int or part['bytes'] <= 0):
            raise RuntimeError('Installer release part metadata is invalid')
        rows.append(f'{part["name"]} {part["sha256"]} {part["bytes"]}')
    parts = '\n'.join(rows)
    installer = template.replace('@TAG@', manifest['tag']).replace('@VERSION@', version).replace('@PARTS@', parts)
    validate_installer_structure(installer)
    if any(marker in installer for marker in ['@TAG@', '@VERSION@', '@PARTS@']):
        raise RuntimeError('Installer contains unresolved template markers')
    if (f"release_tag='{manifest['tag']}'" not in installer
            or f"expected_version='{version}'" not in installer
            or "done <<'PARTS'\n" + parts + '\nPARTS\n' not in installer):
        raise RuntimeError('Installer release metadata was not rendered completely')
    return installer


def verify_installer_zip(path, installer):
    with zipfile.ZipFile(io.BytesIO(read_bytes_checked(path))) as archive:
        name = 'Local Dictation Installer/Install Local Dictation.command'
        if archive.namelist().count(name) != 1:
            raise RuntimeError('Installer ZIP does not contain exactly one command script')
        info = archive.getinfo(name)
        expected = installer.encode('utf-8')
        if info.file_size != len(expected) or archive.read(name) != expected:
            raise RuntimeError('Installer ZIP command is empty or incomplete')
        if not ((info.external_attr >> 16) & 0o111):
            raise RuntimeError('Installer ZIP command is not executable')


def write_installer(source, output, manifest, *, template=None):
    version = manifest['version']
    installer = render_installer(template if template is not None else read_installer_template(source), manifest)
    with tempfile.TemporaryDirectory(prefix='localdictation-installer-') as temp:
        kit=Path(temp)/'Local Dictation Installer'; kit.mkdir()
        write_bytes_checked(kit/'Install Local Dictation.command', installer.encode('utf-8'))
        (kit/'Install Local Dictation.command').chmod(0o755)
        copy_bytes(source/'LICENSE',kit/'LICENSE.txt')
        write_bytes_checked(kit/'READ ME FIRST.txt', ('LOCAL DICTATION '+version+'\n\nApple Silicon Mac (M1 or newer), macOS 14+, English dictation.\n\nDouble-click Install Local Dictation.command. It opens in Terminal, downloads\nabout 3.4 GB from the matching GitHub release, verifies SHA-256 hashes and the\napp signature, and installs into your personal Applications folder.\nNo Python, Homebrew, model setup, API key, or administrator password is needed.\nKeep at least 10 GB free. An internet connection is needed during installation.\n\nThe script is plain text and can be reviewed before running. To use an existing\n/Applications copy, run it with --destination /Applications --replace after\nquitting the app. See the README for setup and Gatekeeper guidance.\n\nThis community app is ad-hoc signed, not notarized by Apple. The installer does\nnot remove quarantine or change your security/keyboard/privacy settings.\n\nhttps://github.com/ysham123/imnotpayingforwisprflow\n').encode('utf-8'))
        subprocess.run(['ditto','-c','-k','--keepParent','--norsrc',str(kit),str(output/'Local-Dictation-Installer.zip')],check=True)
        verify_installer_zip(output/'Local-Dictation-Installer.zip', installer)
        for path in [source/'Distribution/install.sh',output/'install.sh']:
            write_bytes_checked(path, installer.encode('utf-8'))
            path.chmod(0o755)
            subprocess.run(['bash','-n',str(path)],check=True)
        expected_parts = {part['name']: part for part in manifest['parts']}
        rows=[]
        for path in sorted(output.iterdir()):
            if path.name == 'SHA256SUMS': continue
            digest = hash_file_checked(path)
            if path.name in expected_parts:
                expected = expected_parts[path.name]
                if path.stat().st_size != expected['bytes'] or digest != expected['sha256']:
                    raise RuntimeError(f'Release part failed readback verification: {path.name}')
            rows.append(f'{digest}  {path.name}')
        if not expected_parts.keys() <= {path.name for path in output.iterdir()}:
            raise RuntimeError('A release part is missing from the output directory')
        write_bytes_checked(output/'SHA256SUMS', ('\n'.join(rows)+'\n').encode('utf-8'))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--tag', required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    # Fail before expensive model verification/copies when synced source files
    # report bytes in stat() but return an empty or truncated content stream.
    template = read_installer_template(source)
    validate_source_resources(source)
    info = plistlib.loads(read_bytes_checked(args.app / 'Contents/Info.plist'))
    version = info['CFBundleShortVersionString']
    if args.tag != 'v' + version: raise RuntimeError('Tag must match the app version')
    for executable in [args.app / 'Contents/MacOS/LocalDictation', args.app / 'Contents/Resources/whisper-worker']:
        validate_executable(executable)
    validate_runtime(args.app / 'Contents/Resources')
    subprocess.run(['codesign','--verify','--deep','--strict',str(args.app)],check=True)
    args.output.mkdir(parents=True,exist_ok=True)
    if any(args.output.iterdir()): raise RuntimeError('Choose an empty release output directory')
    with tempfile.TemporaryDirectory(prefix='localdictation-release-') as temp:
        stage = Path(temp) / 'Local Dictation.app'
        copy_bytes(args.app,stage)
        copy_bytes(source / 'Licenses', stage / 'Contents/Resources/Licenses')
        copy_bytes(source / 'LICENSE', stage / 'Contents/Resources/Licenses/LocalDictation-MIT.txt')
        copy_bytes(source / 'THIRD_PARTY_NOTICES.txt', stage / 'Contents/Resources/THIRD_PARTY_NOTICES.txt')
        validate_runtime(stage / 'Contents/Resources', verify_digests=False)
        # Only release-copy resource notices change. The installed app is untouched.
        subprocess.run(['codesign','--force','--timestamp=none','--sign','-',str(stage)],check=True)
        subprocess.run(['codesign','--verify','--deep','--strict',str(stage)],check=True)
        writer = PartsWriter(args.output, f'Local-Dictation-{version}-macos-arm64.tar')
        def clean(info):
            if info.issym() or info.islnk(): raise RuntimeError('Unexpected app symlink')
            info.uid=0; info.gid=0; info.uname=''; info.gname=''; info.mtime=0
            info.pax_headers={}
            return info
        with tarfile.open(fileobj=writer,mode='w|',format=tarfile.PAX_FORMAT) as archive:
            archive.add(stage,arcname=stage.name,filter=clean)
        writer.finish_part()
        manifest={'tag':args.tag,'version':version,'archive_sha256':writer.archive_hash.hexdigest(),'parts':writer.entries}
        manifest_bytes = (json.dumps(manifest,indent=2)+'\n').encode('utf-8')
        write_bytes_checked(args.output/'release-manifest.json', manifest_bytes)
        write_bytes_checked(source/'Distribution/release-manifest.json', manifest_bytes)
        write_installer(source, args.output, manifest, template=template)
        print(json.dumps(manifest,indent=2))

if __name__=='__main__': main()
