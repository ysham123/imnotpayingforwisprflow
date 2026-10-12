#!/usr/bin/env python3
"""Rebuild pinned Store helpers with matching dSYMs, without a global Go install."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def run(command, **kwargs):
    subprocess.run([str(part) for part in command], check=True, **kwargs)


def download(pin, target):
    if not target.is_file() or digest(target) != pin['sha256']:
        partial = target.with_suffix(target.suffix + '.partial')
        run(['curl', '-fL', '--retry', '2', '--proto', '=https', '--proto-redir', '=https',
             pin['url'], '-o', partial])
        if digest(partial) != pin['sha256']:
            raise RuntimeError(f'Source digest mismatch: {target.name}')
        partial.replace(target)


def extract(archive, destination):
    with tarfile.open(archive, 'r:gz') as bundle:
        # Reject paths and links escaping even a verified source archive.
        for member in bundle.getmembers():
            path = destination / member.name
            if not path.resolve().is_relative_to(destination.resolve()):
                raise RuntimeError('Source archive contains an escaping path')
            if member.issym() or member.islnk():
                link = (path.parent if member.issym() else destination) / member.linkname
                if not link.resolve().is_relative_to(destination.resolve()):
                    raise RuntimeError('Source archive contains an escaping link')
        bundle.extractall(destination)


def uuids(path):
    output = subprocess.check_output(['dwarfdump', '--uuid', str(path)], text=True)
    return sorted(re.findall(r'UUID: ([A-Fa-f0-9-]+) \(([^)]+)\)', output))


def has_source_debug_info(path, needle):
    process = subprocess.Popen(['dwarfdump', '--debug-info', str(path)], stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL)
    try:
        return any(needle in line for line in process.stdout)
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.terminate()
        process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / '.build-native/store-runtime-candidate')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('The Store runtime supports Apple Silicon macOS only')
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('Choose an empty output directory to preserve previous runtimes')
    pins = json.loads((ROOT / 'AppStore/RuntimeSources.json').read_text())
    cache = ROOT / '.build-native/store-dependencies'
    downloads = cache / 'downloads'
    downloads.mkdir(parents=True, exist_ok=True)
    archives = {
        'whisper': downloads / 'whisper-v1.8.3.tar.gz',
        'ollama': downloads / 'ollama-43107b15.tar.gz',
        'go': downloads / 'go1.24.5.darwin-arm64.tar.gz',
    }
    for name, archive in archives.items():
        download(pins[name], archive)
    cmake = os.environ.get('CMAKE_BIN') or shutil.which('cmake')
    if not cmake:
        parser.error('CMake is required; set CMAKE_BIN or install it')
    env = dict(os.environ)
    env['DEVELOPER_DIR'] = env.get('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    env['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
    env['GOTOOLCHAIN'] = 'local'
    env['GOMODCACHE'] = str(cache / 'go-modules')
    env['GOCACHE'] = str(cache / 'go-build')
    output.mkdir(parents=True, exist_ok=True)
    # Re-extract immutable sources each time instead of trusting an edited checkout.
    with tempfile.TemporaryDirectory(prefix='sources-', dir=cache) as temp:
        sources = Path(temp)
        for archive in archives.values():
            extract(archive, sources)
        whisper = sources / 'whisper.cpp-1.8.3'
        ollama = sources / ('ollama-' + pins['ollama']['revision'])
        go = sources / 'go/bin/go'
        native = sources / 'whisper-build'
        run([cmake, '-S', whisper, '-B', native, '-DCMAKE_BUILD_TYPE=Release',
             '-DCMAKE_C_FLAGS_RELEASE=-O3 -DNDEBUG -g', '-DCMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG -g',
             '-DCMAKE_POLICY_VERSION_MINIMUM=3.5', '-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0',
             '-DBUILD_SHARED_LIBS=OFF', '-DGGML_METAL=ON', '-DGGML_METAL_EMBED_LIBRARY=ON',
             '-DGGML_OPENMP=OFF', '-DWHISPER_BUILD_TESTS=OFF', '-DWHISPER_BUILD_EXAMPLES=OFF'], env=env)
        run([cmake, '--build', native, '--target', 'whisper', '-j', '4'], env=env)
        worker = output / 'whisper-worker'
        worker_object = native / 'whisper-worker.o'
        libraries = ['src/libwhisper.a', 'ggml/src/libggml.a', 'ggml/src/libggml-cpu.a',
                     'ggml/src/ggml-blas/libggml-blas.a', 'ggml/src/ggml-metal/libggml-metal.a',
                     'ggml/src/libggml-base.a']
        run(['xcrun', 'clang++', '-std=c++17', '-O3', '-g', '-mmacosx-version-min=14.0',
             '-I', whisper / 'include', '-I', whisper / 'ggml/include', '-c', ROOT / 'Native/whisper-worker.cpp',
             '-o', worker_object], env=env)
        run(['xcrun', 'clang++', '-g', '-mmacosx-version-min=14.0', worker_object,
             *[native / item for item in libraries], '-framework', 'Accelerate', '-framework', 'Foundation',
             '-framework', 'Metal', '-framework', 'MetalKit', '-o', worker], env=env)
        env['CGO_ENABLED'] = '1'
        env['CGO_CFLAGS'] = '-O2 -g -mmacosx-version-min=14.0'
        env['CGO_CXXFLAGS'] = env['CGO_CFLAGS']
        env['CGO_LDFLAGS'] = '-mmacosx-version-min=14.0'
        run([go, 'mod', 'verify'], cwd=ollama, env=env)
        run([go, 'build', '-p', '4', '-ldflags',
             '-linkmode=external -compressdwarf=false -X github.com/ollama/ollama/version.Version=0.9.6',
             '-o', output / 'ollama', '.'], cwd=ollama, env=env)
        run([go, 'mod', 'verify'], cwd=ollama, env=env)
        info = subprocess.check_output([str(go), 'version', '-m', str(output / 'ollama')], text=True, env=env)
        (output / 'ollama-build-info.txt').write_text(info)
        # Native Go and C++ debug information is preserved, never fabricated.
        helpers = {}
        for name in ('whisper-worker', 'ollama'):
            binary = output / name
            symbols = output / (name + '.dSYM')
            # Go already combines native and Go DWARF into its executable and
            # removes the debug map. Read that real, uncompressed DWARF directly.
            command = ['xcrun', 'dsymutil'] + (['--update'] if name == 'ollama' else [])
            run(command + [binary, '-o', symbols], env=env)
            binary_uuids, symbol_uuids = uuids(binary), uuids(symbols)
            if not binary_uuids or binary_uuids != symbol_uuids:
                raise RuntimeError(f'Mismatched crash symbols for {name}')
            dwarf = symbols / 'Contents/Resources/DWARF' / name
            expected_source = b'whisper-worker.cpp' if name == 'whisper-worker' else b'main.main'
            if not has_source_debug_info(dwarf, expected_source):
                raise RuntimeError(f'{name} is missing its own source debug information')
            # Capture symbols before stripping native symbol-table debug entries.
            run(['xcrun', 'strip', '-S', binary], env=env)
            if uuids(binary) != symbol_uuids:
                raise RuntimeError(f'Stripping changed the crash identity for {name}')
            helpers[name] = {'sha256': digest(binary), 'uuids': binary_uuids}
        report = {'sources': pins, 'helpers': helpers,
                  'workerSourceSHA256': digest(ROOT / 'Native/whisper-worker.cpp'),
                  'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True, env=env).strip()}
        (output / 'provenance.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'Pinned runtimes and matching symbols: {output}')


if __name__ == '__main__':
    main()
