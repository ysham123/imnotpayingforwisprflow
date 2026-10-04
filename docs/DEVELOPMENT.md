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

## Package a thin app and DMG

Prerequisites: Apple Silicon, macOS14+, Command Line Tools, Python3, CMake, and an existing release runtime. Keep the checkout/build output in a local folder outside iCloud or other File Provider synchronization.

The build script checks the pinned whisper.cpp1.8.3 archive, builds Metal-enabled static libraries, compiles the private protocol-2 worker, and packages the app. The bundled Ollama executable and licenses are copied from `LOCAL_DICTATION_RUNTIME`. Weights are omitted by default. On first installed launch, `ModelStore` verifies and obtains the assets described in the signed `Resources/ModelManifest.json`.

```bash
LOCAL_DICTATION_BUILD_DIR="$HOME/Library/Caches/LocalDictation-build" \
LOCAL_DICTATION_RUNTIME="/Applications/Local Dictation.app/Contents/Resources" \
bash Scripts/build.sh "$HOME/Library/Caches/LocalDictation-build/Local Dictation.app"

python3 Scripts/make-release.py \
  "$HOME/Library/Caches/LocalDictation-build/Local Dictation.app" \
  "$HOME/Library/Caches/LocalDictation-release" --tag v1.3.0
```

Choose an empty release directory. The output contains `Local-Dictation.dmg`, model/release manifests, and SHA256SUMS. DMG creation copies the already-signed bundle without re-signing. Installation also preserves that signature. Finalize every executable/resource before signing.

`RuntimePaths` supplies sealed executables and external model paths to both engines. Models live in `~/Library/Application Support/Local Dictation/Models`; saved shortcuts/words remain in local preferences. Compatible verified v1.2 weights migrate before replacement. Production downloads use system curl, HTTPS-only redirects, resumable partial files, file locks, disk-space checks, and size/SHA256 verification before atomic publication.

For development, invoke `Scripts/package_app.py` with `--development` to use `dev.yosef.localdictation.development`, separate preferences/model storage, and no self-install into the public location. A development build cannot replace the public bundle. `--include-models` is an optional legacy/offline package mode and is rejected by the thin-release generator.

Current releases use ad-hoc signing. Non-ad-hoc builds require both `CODE_SIGN_IDENTITY` and `CODE_SIGN_REQUIREMENT`; the latter must pin the exact certificate leaf hash and application identifier. Key material belongs outside Git. Never use an identifier-only requirement or re-sign a publisher-signed app with ad-hoc identity.

The isolated free self-signed experiment could not establish a system-trusted signing identity without trust changes. It does not demonstrate recipient TCC grant retention. Self-signing is therefore not adopted for distribution; ad-hoc updates may still require permission renewal. No Apple notarization, automatic updater, or trust import is included.

## Run regression checks

These checks need macOS developer tools, but do not need model downloads, microphone permission, or a logged-in GUI session:

```bash
bash Scripts/test-core.sh
bash Scripts/test-shortcuts.sh
bash Scripts/test-session.sh
bash Scripts/test-permissions.sh
bash Scripts/test-vocabulary.sh
bash Scripts/test-vocabulary-worker.sh
bash Scripts/test-native-vocabulary-worker.sh
bash Scripts/test-runtime-setup.sh
bash Scripts/test-target-inspector.sh
bash Scripts/test-cleanup.sh
bash Scripts/test-cleanup-service.sh
bash Scripts/test-correction-lifecycle.sh
bash Scripts/test-audio.sh
bash Scripts/test-transcriber.sh
bash Scripts/test-worker-faults.sh
python3 Tests/PackagingSmoke.py
python3 Tests/ThinReleaseSmoke.py
python3 Tests/RealSigningSmoke.py
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
"/Applications/Local Dictation.app/Contents/MacOS/LocalDictation" --diagnostics
```

Diagnostics resolve external installed models through RuntimePaths and check model startup, correction examples, and silence. LOCAL_DICTATION_RESOURCES and LOCAL_DICTATION_MODELS are explicit fixture overrides. Add `--audio /path/to/synthetic-speech.wav` to measure transcription and cleanup of a supplied test file. These diagnostics print their synthetic text to the terminal. They do not verify physical Fn presses or insertion into a particular third-party editor.

## Dictation shortcuts

`bash Scripts/test-shortcuts.sh .test-build/shortcuts --registration` also exercises real exclusive Carbon registration and conflicts without opening windows. `bash Scripts/test-shortcut-recorder.sh` runs the isolated chooser-window checks with events posted only to its own AppKit queue; add `.test-build/shortcut-recorder --compile-only` on a headless runner.

Fn / Globe remains the default: double-tap starts recording, one tap stops, and one tap places waiting text after the double-tap window. A double-tap while text is waiting asks the user to resolve it rather than starting a new recording.

**Settings… → Dictation shortcut → Change…** records a custom key combination. Command, Control, or Option plus a key is accepted, with optional Shift. F1–F20 can also be used without modifiers or with Shift alone. Other bare keys, Shift-only combinations, and reserved shortcuts are rejected. Escape or switching to another app cancels recording the shortcut. One custom press starts, stops, or places waiting text according to the session phase. Held-key repeats and rapid duplicate presses are ignored. Custom mode disables Fn dictation actions; **Use Fn / Globe** restores the default gesture. Settings, menu status, and placement guidance use the selected shortcut.

`HotkeyPreferences.swift` stores the selected `ShortcutConfiguration` as JSON in local `UserDefaults` under `dictation.shortcut.v1`. Registration uses the physical virtual key code and Carbon modifier bits; the display label is presentation only. Invalid stored configurations fall back to Fn / Globe. A valid saved shortcut that cannot be registered is reported as unavailable rather than silently replaced with Fn.

`FnHotkey.configure` uses Carbon global hotkey registration and registers a replacement before releasing an existing binding. The setup recorder intentionally stops the shortcut listener and temporarily unregisters its binding so it can capture the same chord. Failure or cancellation preserves the saved choice; closing the recorder attempts to restore it. If another process has claimed that chord, Settings reports the conflict. A replacement must register successfully before its preference is saved. Global registration cannot detect every app-specific shortcut, so users still need to choose a combination they do not use elsewhere. Shortcut changes affect input control only; recording, transcription, cleanup, and protected placement retain their existing behavior.

`ShortcutConfiguration.validationError` reserves Command-A, H, Z, X, C, V, Q, W, M, Tab, Space, and backtick, including their Shift variants. Any Command-Space combination and Control-Command-Q with optional Shift are also reserved. Escape, Fn, and modifier-only keys cannot be custom bindings. `CustomHotkeyGesture` requires physical key release before another action and applies a 350 ms rearm interval. Keep these checks and phase guards when changing shortcut registration.

## Measure performance

The menu action **Export performance measurements…** saves numeric timing and outcome data from the last 100 sessions in memory. It includes microphone readiness, transcription/correction completion, paste dispatch, first observed insertion, and readiness for another capture when each stage is available. It excludes dictated text, audio, and application names. A dispatched paste and a verified visible insertion are separate measurements.

Run backend benchmarks with a synthetic audio fixture after quitting the normal app:

```bash
LOCAL_DICTATION_MODELS="$HOME/Library/Application Support/Local Dictation/Models" \
bash Scripts/benchmark-backend.sh \
  "/Applications/Local Dictation.app/Contents/Resources" \
  /path/to/synthetic-speech.wav /tmp/v1.3-benchmark.json 5 2 - 20
# Repeat against the preceding release's source for comparison:
bash Scripts/benchmark-backend.sh \
  "/Applications/Local Dictation.app/Contents/Resources" \
  /path/to/synthetic-speech.wav /tmp/v1.1-benchmark.json 5 2 v1.1.1 20
```

The harness uses an isolated loopback service and reports numeric results without transcripts. The fourth argument is repetitions per condition; the fifth is idle seconds. The sixth selects a baseline Git ref (`-` uses the current source), and the seventh optionally overrides warm repetitions. These commands reproduce the published 20 warm / 5 other runs per length. Use more than 600 seconds to exercise the older model-retention timeout. Short idle measurements do not establish performance after that timeout. Backend benchmarks exclude microphone capture and editor delivery; use the interactive exporter for those stages.

## Verify custom words with real models

The opt-in harness uses synthetic speech from `Tests/VocabularyFixtures.json`, never microphone recordings. Quit the normal app and use an exclusive model window:

```bash
bash Scripts/test-real-vocabulary.sh --run \
  "/Applications/Local Dictation.app/Contents/Resources" \
  "$HOME/Library/Application Support/Local Dictation/Models" \
  "$HOME/Library/Caches/LocalDictation-vocabulary-fixtures" \
  /tmp/vocabulary-report.json 3 20 10
```

It alternates vocabulary off/on, measures20 repeats per mode for one short utterance and10 for one passage longer than30seconds, and reports per-case stage medians/p95. Reports contain numeric flags/timings, not transcripts or vocabulary contents. Test case definitions use synthetic public example terms. `--compile-only` prepares the harness without running models, and `--cleanup-only` checks direct saved-alias corrections.

For explicit production model-storage integration, `Scripts/test-production-model-store.sh` supports verified migration or a tiny pinned metadata download. It requires supplied resources/model/legacy paths and never launches engines. Do not point an integration download check at existing production storage.

## Source map

| Location | Responsibility |
|---|---|
| `Sources/DictationCore/` | Fn/custom gestures, shortcut validation, and protected dictation session state |
| `Sources/LocalDictation/AppMain.swift` | Menu, Settings, session state, permission/model setup, recording lifecycle |
| `DictationHUD.swift` + `InteractionMetrics.swift` | Nonactivating status panel and content-free local timing export |
| `FnHotkey.swift` | Input activity event tap, Fn/Globe gestures, and custom Carbon hotkey registration |
| `ShortcutRecorder.swift` + `HotkeyPreferences.swift` | Shortcut capture and local preference persistence |
| `AudioRecorder.swift` | Capture, resampling, bounded memory, interruption recovery |
| `WhisperTranscriber.swift` + `Native/whisper-worker.cpp` | Persistent local speech worker, framed audio IPC, cancellation |
| `LocalCorrectionService.swift` + `CleanupClient.swift` | Bundled Ollama lifecycle, cleanup request, conservative validation |
| `TargetInspector.swift` | Pinned field identity, serialized Accessibility inspection, focus and caret validation |
| `TextInserter.swift` + `DeliveryCoordinator.swift` | Validated paste delivery, serialized clipboard leases, insertion observation, and restoration |
| `Tests/` | Gesture, cleanup, audio, worker, insertion, and packaging regressions |
| `InstallController.swift` + `RuntimePaths.swift` + `ModelStore.swift` | Canonical installation, rollback, sealed executables, verified external weights |
| `Vocabulary.swift` + `VocabularyPreferences.swift` + `CustomWordsController.swift` | Validated words, immutable snapshots, local persistence, native editor |
| `PermissionDiagnostics.swift` | Bounded local installation/readiness records |
| `Distribution/` | Historical v1.2 Terminal installer and release metadata |

## Release gates

Use the thin-app/DMG packaging command above only after the installed app passes its checks. Record unchanged relaunches separately from changed-build updates; macOS privacy grants may behave differently. Test the actual DMG and production installation transaction, not only mocked rollback cases.

Upload all assets to one matching tag only after installed-app testing and the published validation record are complete. The v1.2 scripts under `Distribution/` are historical compatibility tools; the v1.3 primary installer is the native app in the DMG. Model weights, app bundles, signing keys, caches, and audio fixtures stay outside Git. Retain third-party licenses when changing the runtime.

## Contribution scope

Keep the product focused on dictation. Useful contributions include editor compatibility, reliable input-device recovery, regression cases for spoken corrections, and simpler signed installation. Preserve raw speech-to-text output when cleanup fails. A successful paste event is not proof that an editor inserted text; maintain the distinction in status messages and tests.
