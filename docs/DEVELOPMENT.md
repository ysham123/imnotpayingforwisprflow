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
bash Scripts/test-shortcuts.sh
bash Scripts/test-session.sh
bash Scripts/test-target-inspector.sh
bash Scripts/test-cleanup.sh
bash Scripts/test-cleanup-service.sh
bash Scripts/test-correction-lifecycle.sh
bash Scripts/test-audio.sh
bash Scripts/test-transcriber.sh
bash Scripts/test-worker-faults.sh
python3 Tests/PackagingSmoke.py
python3 Tests/InstallerSmoke.py
```

The shell scripts compile small assertion-based executables directly with `swiftc`, so they also work with Command Line Tools installations without XCTest. With full Xcode, `swift test` additionally runs the package's core XCTest target.

Insertion checks require an interactive desktop and Accessibility permission for their test processes. Run one GUI suite at a time and leave its synthetic window focused:

```bash
bash Scripts/test-insertion.sh
bash Scripts/test-hud.sh
bash Scripts/test-web-insertion.sh
# Optional Chromium coverage: supply an official arm64 Electron executable.
bash Scripts/test-electron-insertion.sh \
  /path/to/Electron.app/Contents/MacOS/Electron
```

These suites create their own synthetic native, nonpersistent WebKit, or isolated Electron editors and exercise cross-process Accessibility and clipboard behavior. They abort when an unrelated app becomes frontmost. Web fixtures cover inputs, textareas, generic and ARIA contenteditable, nested spans, Unicode, selection replacement, delayed updates/clipboard reads, and protected controls. Successful cases assert a single paste event. Electron is a test dependency only and is not bundled with Local Dictation. Do not substitute a private document or chat for a fixture.

Use `--compile-only` as the second argument to `test-web-insertion.sh` to build without launching its window. The source build and headless checks remain suitable for CI; GUI fixtures require a local desktop session.

For a complete installed runtime, quit the normal app and run:

```bash
"$HOME/Applications/Local Dictation.app/Contents/MacOS/LocalDictation" --diagnostics
```

Diagnostics check model startup, correction examples, and silence. Add `--audio /path/to/synthetic-speech.wav` to measure transcription and cleanup of a supplied test file. These diagnostics print their synthetic text to the terminal. They do not verify physical Fn presses or insertion into a particular third-party editor.

## Dictation shortcuts

`bash Scripts/test-shortcuts.sh .test-build/shortcuts --registration` also exercises real exclusive Carbon registration and conflicts without opening windows. `bash Scripts/test-shortcut-recorder.sh` runs the isolated chooser-window checks with events posted only to its own AppKit queue; add `.test-build/shortcut-recorder --compile-only` on a headless runner.

Fn / Globe remains the default: double-tap starts recording, one tap stops, and one tap places waiting text after the double-tap window. A double-tap while text is waiting asks the user to resolve it rather than starting a new recording.

**Setup… → Dictation shortcut → Change…** records a custom key combination. Command, Control, or Option plus a key is accepted, with optional Shift. F1–F20 can also be used without modifiers or with Shift alone. Other bare keys, Shift-only combinations, and reserved shortcuts are rejected. Escape or switching to another app cancels recording the shortcut. One custom press starts, stops, or places waiting text according to the session phase. Held-key repeats and rapid duplicate presses are ignored. Custom mode disables Fn dictation actions; **Use Fn / Globe** restores the default gesture. Setup, menu status, and placement guidance use the selected shortcut.

`HotkeyPreferences.swift` stores the selected `ShortcutConfiguration` as JSON in local `UserDefaults` under `dictation.shortcut.v1`. Registration uses the physical virtual key code and Carbon modifier bits; the display label is presentation only. Invalid stored configurations fall back to Fn / Globe. A valid saved shortcut that cannot be registered is reported as unavailable rather than silently replaced with Fn.

`FnHotkey.configure` uses Carbon global hotkey registration and registers a replacement before releasing an existing binding. The setup recorder intentionally stops the shortcut listener and temporarily unregisters its binding so it can capture the same chord. Failure or cancellation preserves the saved choice; closing the recorder attempts to restore it. If another process has claimed that chord, Setup reports the conflict. A replacement must register successfully before its preference is saved. Global registration cannot detect every app-specific shortcut, so users still need to choose a combination they do not use elsewhere. Shortcut changes affect input control only; recording, transcription, cleanup, and protected placement retain their existing behavior.

`ShortcutConfiguration.validationError` reserves Command-A, H, Z, X, C, V, Q, W, M, Tab, Space, and backtick, including their Shift variants. Any Command-Space combination and Control-Command-Q with optional Shift are also reserved. Escape, Fn, and modifier-only keys cannot be custom bindings. `CustomHotkeyGesture` requires physical key release before another action and applies a 350 ms rearm interval. Keep these checks and phase guards when changing shortcut registration.

## Measure performance

The menu action **Export performance measurements…** saves numeric timing and outcome data from the last 100 sessions in memory. It includes microphone readiness, transcription/correction completion, paste dispatch, first observed insertion, and readiness for another capture when each stage is available. It excludes dictated text, audio, and application names. A dispatched paste and a verified visible insertion are separate measurements.

Run backend benchmarks with a synthetic audio fixture after quitting the normal app:

```bash
bash Scripts/benchmark-backend.sh \
  "/Applications/Local Dictation.app/Contents/Resources" \
  /path/to/synthetic-speech.wav /tmp/v1.2-benchmark.json 5 2 - 20
# Repeat against the preceding release's source for comparison:
bash Scripts/benchmark-backend.sh \
  "/Applications/Local Dictation.app/Contents/Resources" \
  /path/to/synthetic-speech.wav /tmp/v1.1-benchmark.json 5 2 v1.1.1 20
```

The harness uses an isolated loopback service and reports numeric results without transcripts. The fourth argument is repetitions per condition; the fifth is idle seconds. The sixth selects a baseline Git ref (`-` uses the current source), and the seventh optionally overrides warm repetitions. These commands reproduce the published 20 warm / 5 other runs per length. Use more than 600 seconds to exercise the older model-retention timeout. Short idle measurements do not establish performance after that timeout. Backend benchmarks exclude microphone capture and editor delivery; use the interactive exporter for those stages.

## Source map

| Location | Responsibility |
|---|---|
| `Sources/DictationCore/` | Fn/custom gestures, shortcut validation, and protected dictation session state |
| `Sources/LocalDictation/AppMain.swift` | Menu, setup, state, permissions, recording lifecycle |
| `DictationHUD.swift` + `InteractionMetrics.swift` | Nonactivating status panel and content-free local timing export |
| `FnHotkey.swift` | Input activity event tap, Fn/Globe gestures, and custom Carbon hotkey registration |
| `ShortcutRecorder.swift` + `HotkeyPreferences.swift` | Setup shortcut capture and local preference persistence |
| `AudioRecorder.swift` | Capture, resampling, bounded memory, interruption recovery |
| `WhisperTranscriber.swift` + `Native/whisper-worker.cpp` | Persistent local speech worker, framed audio IPC, cancellation |
| `LocalCorrectionService.swift` + `CleanupClient.swift` | Bundled Ollama lifecycle, cleanup request, conservative validation |
| `TargetInspector.swift` | Pinned field identity, serialized Accessibility inspection, focus and caret validation |
| `TextInserter.swift` + `DeliveryCoordinator.swift` | Validated paste delivery, serialized clipboard leases, insertion observation, and restoration |
| `Tests/` | Gesture, cleanup, audio, worker, insertion, and packaging regressions |
| `Distribution/` | Installer template and pinned current-release metadata |

## Produce release assets

Build and validate a complete app first. Set its version in `Resources/Info.plist` before building, then use an empty output folder:

```bash
python3 Scripts/make-release.py \
  "$PWD/.build-native/Local Dictation.app" \
  "$PWD/release-assets" --tag v1.2.0
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
