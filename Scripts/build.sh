#!/bin/bash
set -euo pipefail

source_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${LOCAL_DICTATION_BUILD_DIR:-$source_dir/.build-native}"
app_path="${1:-/Applications/Local Dictation.app}"
mkdir -p "$build_dir"
if [ "$(uname -m)" != arm64 ]; then
  echo "The bundled runtime currently supports Apple Silicon Macs only." >&2
  exit 1
fi
export CLANG_MODULE_CACHE_PATH="$build_dir/ModuleCache"

swift build --package-path "$source_dir" --scratch-path "$build_dir/swift" \
  --cache-path "$build_dir/swift-cache" --config-path "$build_dir/swift-config" \
  --security-path "$build_dir/swift-security" --disable-sandbox -c release \
  -Xswiftc -module-cache-path -Xswiftc "$build_dir/ModuleCache"

cmake_bin="${CMAKE_BIN:-cmake}"
if ! command -v "$cmake_bin" >/dev/null; then
  echo "CMake is needed to rebuild the speech engine. Set CMAKE_BIN or install CMake." >&2
  exit 1
fi
archive="$build_dir/whisper-v1.8.3.tar.gz"
vendor="$build_dir/whisper.cpp-1.8.3"
if [ ! -d "$vendor" ]; then
  curl -fL --retry 2 https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.8.3.tar.gz -o "$archive"
  echo "870ba21409cdf66697dc4db15ebdb13bc67037d76c7cc63756c81471d8f1731a  $archive" | shasum -a 256 -c -
  tar -xzf "$archive" -C "$build_dir"
fi
native_build="$build_dir/whisper-build"
"$cmake_bin" -S "$vendor" -B "$native_build" -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_OPENMP=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF
"$cmake_bin" --build "$native_build" --target whisper -j 6
c++ -std=c++17 -O3 -mmacosx-version-min=14.0 \
  -I "$vendor/include" -I "$vendor/ggml/include" "$source_dir/Native/whisper-worker.cpp" \
  "$native_build/src/libwhisper.a" "$native_build/ggml/src/libggml.a" \
  "$native_build/ggml/src/libggml-cpu.a" "$native_build/ggml/src/ggml-blas/libggml-blas.a" \
  "$native_build/ggml/src/ggml-metal/libggml-metal.a" "$native_build/ggml/src/libggml-base.a" \
  -framework Accelerate -framework Foundation -framework Metal -framework MetalKit \
  -o "$build_dir/whisper-worker"
runtime_path="${LOCAL_DICTATION_RUNTIME:-$app_path/Contents/Resources}"
python3 "$source_dir/Scripts/package_app.py" "$app_path" \
  "$build_dir/swift/release/LocalDictation" "$build_dir/whisper-worker" \
  --runtime "$runtime_path"
