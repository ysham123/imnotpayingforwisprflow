# Development

Local Dictation is a Swift/AppKit menu-bar app for Apple Silicon Macs running macOS 14 or newer. The source package uses Swift tools 5.9 and has no remote Swift package dependencies. The release was built with Swift 5.10.

## Compile the application

Install Apple's Xcode Command Line Tools, then clone and build:

```bash
xcode-select --install
git clone https://github.com/ysham123/imnotpayingforwisprflow.git
cd imnotpayingforwisprflow
swift build -c release
```

This compiles the application executable. A runnable `.app` also needs the native Whisper worker, the bundled Ollama executable, models, notices, and `Info.plist`. Use an app bundle for normal use so macOS associates privacy grants with its bundle identity.

## Package a complete app

Prerequisites: Apple Silicon, macOS 14+, Command Line Tools, Python 3, CMake, and a downloaded release installed using the [README](../README.md#get-started).

Keep the output app in a local folder outside iCloud/other file synchronization. Synced destinations may inject Finder metadata that prevents code-signature verification. If your checkout is synced, set `LOCAL_DICTATION_BUILD_DIR` to a local directory and use an app destination there.

The build script downloads and checks the pinned whisper.cpp 1.8.3 source archive, builds its static libraries with Metal, compiles `Native/whisper-worker.cpp`, and packages the app. It takes the existing runtime and models from `LOCAL_DICTATION_RUNTIME`; it does not fetch model weights.

From the repository root:

```bash
export LOCAL_DICTATION_RUNTIME="$HOME/Applications/Local Dictation.app/Contents/Resources"
bash Scripts/build.sh "$PWD/.build-native/Local Dictation.app"
open "$PWD/.build-native/Local Dictation.app"
```

If you installed the release in `/Applications`, adjust `LOCAL_DICTATION_RUNTIME` accordingly. Quit other Local Dictation instances before launching your development copy; correction uses the fixed loopback port `127.0.0.1:11437`. Keep one app installation for daily use to avoid ambiguous permission entries.

| Variable | Purpose |
|---|---|
| `LOCAL_DICTATION_RUNTIME` | Folder containing `ollama`, `Models`, and `Licenses` |
| `LOCAL_DICTATION_BUILD_DIR` | Native and Swift build directory; defaults to `.build-native` |
| `CMAKE_BIN` | CMake executable; defaults to `cmake` |
| `CODE_SIGN_IDENTITY` | Signing identity; defaults to ad-hoc (`-`) |
| `LOCAL_DICTATION_RESOURCES` | Development-only override for the app's resource directory |

`Scripts/package_app.py` checks model blobs, stages the bundle, signs and verifies it, and uses same-volume renames with rollback when replacing an existing app. It refuses to replace a running destination. Ad-hoc rebuilds can invalidate existing Accessibility and Input Monitoring grants. A stable Developer ID identity and notarization are future release improvements; the current scripts do not perform notarization.

## Run regression checks

These checks need macOS developer tools, but do not need model downloads, microphone permission, or a logged-in GUI session:

```bash
bash Scripts/test-core.sh
bash Scripts/test-cleanup.sh
bash Scripts/test-audio.sh
bash Scripts/test-transcriber.sh
bash Scripts/test-worker-faults.sh
python3 Tests/PackagingSmoke.py
python3 Tests/InstallerSmoke.py
```

The shell scripts compile small assertion-based executables directly with `swiftc`, so they also work with Command Line Tools installations without XCTest. With full Xcode, `swift test` additionally runs the package's core XCTest target.

The insertion fixture requires an interactive desktop and Accessibility permission for its test process:

```bash
bash Scripts/test-insertion.sh
```

It creates its own synthetic text controls and exercises real cross-process Accessibility and clipboard behavior. Do not substitute a private document or chat for the fixture.

For a complete installed runtime, quit the normal app and run:

```bash
"$HOME/Applications/Local Dictation.app/Contents/MacOS/LocalDictation" --diagnostics
```

Diagnostics check model startup, correction examples, and silence. Add `--audio /path/to/synthetic-speech.wav` to measure transcription and cleanup of a supplied test file. These diagnostics print their synthetic text to the terminal. They do not verify physical Fn presses or insertion into a particular third-party editor.

## Source map

| Location | Responsibility |
|---|---|
| `Sources/DictationCore/` | Fn gesture state machine |
| `Sources/LocalDictation/AppMain.swift` | Menu, setup, state, permissions, recording lifecycle |
| `FnHotkey.swift` | Global event tap and hardware Fn/Globe events |
| `AudioRecorder.swift` | Capture, resampling, bounded memory, interruption recovery |
| `WhisperTranscriber.swift` + `Native/whisper-worker.cpp` | Persistent local speech worker, framed audio IPC, cancellation |
| `LocalCorrectionService.swift` + `CleanupClient.swift` | Bundled Ollama lifecycle, cleanup request, conservative validation |
| `TextInserter.swift` | Target validation, editable ancestors, clipboard transaction, paste verification |
| `Tests/` | Gesture, cleanup, audio, worker, insertion, and packaging regressions |
| `Distribution/` | Installer template and pinned current-release metadata |

## Produce release assets

Build and validate a complete app first. Set its version in `Resources/Info.plist` before building, then use an empty output folder:

```bash
python3 Scripts/make-release.py \
  "$PWD/.build-native/Local Dictation.app" \
  "$PWD/release-assets" --tag v1.1.0
```

The release builder copies the app, includes first- and third-party notices, signs that copy ad-hoc, verifies it, and creates two archive parts below GitHub's 2 GiB asset limit. The original app is not modified. It also creates:

- `Local-Dictation-Installer.zip`: a small, inspectable `.command` installer.
- `install.sh`: the same installer for Terminal/offline use.
- `release-manifest.json`: part sizes and SHA-256 hashes.
- `SHA256SUMS`: hashes for all release files.

The generated installer and manifest are also written to `Distribution/` for review. Upload all assets to one matching release tag. Never publish an installer before its matching parts have finished uploading. The installer embeds hashes, checks signatures, refuses implicit overwrites, and restores the previous app on failed replacement. It does not change Gatekeeper, privacy grants, or keyboard settings.

Test the complete installer with `--assets-dir` and a separate `--destination` before publishing. Model weights, archives, application bundles, caches, and test output belong outside Git history. Retain dependency licenses when changing the bundled runtime.

## Contribution scope

Keep the product focused on dictation. Useful contributions include editor compatibility, reliable input-device recovery, regression cases for spoken corrections, and simpler signed installation. Preserve raw speech-to-text output when cleanup fails. A successful paste event is not proof that an editor inserted text; maintain the distinction in status messages and tests.
