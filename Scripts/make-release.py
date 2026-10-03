#!/usr/bin/env python3
"""Create verified, GitHub-sized app parts and an installer from a working app."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
from package_app import copy_bytes, validate_runtime

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
            self.file.write(block); self.hash.update(block); self.size += len(block)
            data = data[len(block):]
            if self.size == self.limit: self.finish_part()
        return size
    def finish_part(self):
        if self.file:
            self.file.close()
            self.entries.append({'name': self.name, 'sha256': self.hash.hexdigest(), 'bytes': self.size})
            self.file = None
    def flush(self):
        if self.file: self.file.flush()


def write_installer(source, output, manifest):
    version = manifest['version']
    with tempfile.TemporaryDirectory(prefix='localdictation-installer-') as temp:
        parts='\n'.join(f'{p["name"]} {p["sha256"]} {p["bytes"]}' for p in manifest['parts'])
        template=(source/'Distribution/install.template.sh').read_text()
        installer=template.replace('@TAG@',manifest['tag']).replace('@VERSION@',version).replace('@PARTS@',parts)
        (output/'install.sh').write_text(installer)
        (source/'Distribution/install.sh').write_text(installer)
        (output/'install.sh').chmod(0o755)
        (source/'Distribution/install.sh').chmod(0o755)
        kit=Path(temp)/'Local Dictation Installer'; kit.mkdir()
        (kit/'Install Local Dictation.command').write_text(installer)
        (kit/'Install Local Dictation.command').chmod(0o755)
        shutil.copyfile(source/'LICENSE',kit/'LICENSE.txt')
        (kit/'READ ME FIRST.txt').write_text('LOCAL DICTATION '+version+'\n\nApple Silicon Mac (M1 or newer), macOS 14+, English dictation.\n\nDouble-click Install Local Dictation.command. It opens in Terminal, downloads\nabout 3.4 GB from the matching GitHub release, verifies SHA-256 hashes and the\napp signature, and installs into your personal Applications folder.\nNo Python, Homebrew, model setup, API key, or administrator password is needed.\nKeep at least 10 GB free. An internet connection is needed during installation.\n\nThe script is plain text and can be reviewed before running. To use an existing\n/Applications copy, run it with --destination /Applications --replace after\nquitting the app. See the README for setup and Gatekeeper guidance.\n\nThis community app is ad-hoc signed, not notarized by Apple. The installer does\nnot remove quarantine or change your security/keyboard/privacy settings.\n\nhttps://github.com/ysham123/imnotpayingforwisprflow\n')
        subprocess.run(['ditto','-c','-k','--keepParent','--norsrc',str(kit),str(output/'Local-Dictation-Installer.zip')],check=True)
        for path in [source/'Distribution/install.sh',output/'install.sh']:
            subprocess.run(['bash','-n',str(path)],check=True)
        rows=[]
        for path in sorted(output.iterdir()):
            if path.name == 'SHA256SUMS': continue
            hasher=hashlib.sha256()
            with path.open('rb') as stream:
                for block in iter(lambda:stream.read(4*1024*1024),b''):hasher.update(block)
            rows.append(f'{hasher.hexdigest()}  {path.name}')
        (output/'SHA256SUMS').write_text('\n'.join(rows)+'\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--tag', required=True)
    args = parser.parse_args()
    source = Path(__file__).resolve().parent.parent
    info = plistlib.loads((args.app / 'Contents/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    if args.tag != 'v' + version: raise RuntimeError('Tag must match the app version')
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
        (args.output/'release-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        (source/'Distribution/release-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        write_installer(source, args.output, manifest)
        print(json.dumps(manifest,indent=2))

if __name__=='__main__': main()
