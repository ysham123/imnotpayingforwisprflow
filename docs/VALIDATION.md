# Release validation

This records the v1.1.1 patch's fixture results and live checks, and preserves the historical v1.1.0 release evidence. It is not a promise of compatibility with every macOS text editor.

## Environment

- Apple M2 Pro, 16 GB memory, macOS 14.4.1.
- Swift 5.10 and Command Line Tools.
- whisper.cpp 1.8.3 with Metal, Whisper large-v3-turbo Q8_0.
- Ollama 0.9.6 and Qwen3 4B Q4_K_M.

## v1.1.1 insertion and live checks

The following local GUI suites passed against the current product code on October 3, 2026, using the environment above. Each suite ran separately in its own synthetic application.

| Fixture | Passing regressions |
|---|---:|
| Native AppKit | 13 |
| WKWebView | 14 |
| Electron 44.5.1 | 14 |

The web suites cover input, textarea, plain and ARIA contenteditable editors, generic groups, nested spans, Unicode, multiline text, selection replacement, and identical replacements. Successful insertions assert exactly one paste event; read-only and password controls receive none. Changed-editor targets are rejected. Native checks also cover clipboard ownership, cancellation, and overlapping transactions.

Two deterministic native cases change the focused editor or move the same editor's caret during the final `AXValue` read after clipboard staging. Both reject insertion without a paste and restore every seeded clipboard item and byte. Temporary copies with the final focus check removed or the cursor check restored to its earlier order each failed the corresponding regression and delivered a paste to the wrong fixture editor or caret position.

Both web engines passed delayed DOM updates and an actual native clipboard read 1.6 seconds after paste dispatch, with clipboard restoration afterward. These are separate cases: saving DOM `clipboardData` immediately does not test delayed consumption of the system clipboard.

Cold Electron accessibility activation initially exposed no focused editor. Three isolated cold probes passed with a 100 ms settling delay. The candidate now retries discovery once after fresh accessibility activation in a recognized Chromium runtime, within the existing inspection deadline and with the original foreground application still required. The complete Electron suite passed with this product change. Paste dispatch is never automatically retried.

After installing the verified v1.1.1 bundle, the creator manually tested the Fn dictation workflow in Claude and ChatGPT and confirmed that text appeared in both on October 3, 2026. This is a user-reported live check, separate from the automated fixture results. It does not establish compatibility with every editor or app version.

Both fixture engines exposed editor elements under the fixture application's PID on this machine, so remote-process accessibility paths were not exercised end to end. The generic WKWebView editor had a writable `AXValue`, and Electron exposed a writable text area; the generic-group path with a non-settable `AXValue` was also not exercised end to end.

## v1.1.1 distribution checks

The final release was regenerated from the verified app containing the focus and cursor guards. Its archive has two parts: 1,800,000,000 and 1,603,120,640 bytes, each below GitHub's 2 GiB asset limit. Every entry in `SHA256SUMS` passed, and the concatenated archive matched the full SHA-256 hash in the [release manifest](../Distribution/release-manifest.json).

The installer ZIP passed integrity and executable-permission checks. Its command file matches the generated installer, which passed macOS Bash 3.2 syntax and help checks. The real installer completed with exit status 0 using local release parts in an isolated temporary destination, with actual disk-space and code-signature checks. Both staged and installed bundles passed strict signature verification. The installed test copy's main executable, speech worker, Ollama helper, and Info.plist matched the verified candidate byte for byte. That temporary installation was removed after verification; release assets and the candidate were preserved.

## v1.1.0 automated coverage

| Area | Checked behavior |
|---|---|
| Fn gesture | 19 cases including double-tap start, single-tap stop, held keys, modifier chords, and macOS Globe companion events |
| Cleanup validation | 32 cases including fillers, repeated words, explicit corrections, numbers, identifiers, word order, and anchored negation |
| Audio conversion | Six cases covering stereo resampling, buffer limits, input changes, interrupted capture, empty input, and cancellation |
| Transcriber cancellation | Cancellation before startup, queued/running requests, worker termination, and recovery |
| Worker faults | Startup stall, unread input, oversized output, malformed JSON, and unexpected EOF; bounded failure and recovery |
| Native insertion fixture | Cross-process Unicode insertion, selected text, identical replacement, cursor/focus changes, secure/read-only controls, refused paste, external clipboard copies, cancellation overlap, and quit during clipboard restoration |
| App packaging | Four replacement/rollback cases; code signing and model verification are mocked in these fault tests |
| Public installer | Eight synthetic cases covering fresh install, update, overwrite refusal, stage/final verification failure, bad checksum, and interruption; actual split-release installation into an isolated local directory |

The GitHub Actions workflow runs the source build and checks that do not require a GUI or model downloads. Native insertion and real-model diagnostics are separate local checks. See [development commands](DEVELOPMENT.md#run-regression-checks).

## v1.1.0 real models and live use

The installed models passed exact correction checks for:

- “Thursday, sorry, Friday” → “Friday.”
- Repeated “send” and the filler “um.”
- “fifteen, actually fifty dollars” → “fifty dollars.”
- Retaining “Do not delete the file” and a person's name.

Silence produced no transcript. A 9.8-second synthetic speech sample took approximately 1.0 second for recognition and 2.1 seconds through cleanup after warmup. This is one development-machine measurement, not a cross-device benchmark. Cold startup and longer dictation take longer.

The creator confirmed the physical Fn workflow in Google search and subsequently confirmed that dictation worked in the desktop chat app after editor compatibility improvements. The native fixture provides additional insertion coverage. We have not validated every web framework, third-party editor, keyboard, or microphone.

## v1.1.0 distribution checks

The release process checks the complete bundle's code signature, model blob hashes, per-part SHA-256 hashes, app identity and version, and installation into a separate destination. The original working installation is preserved during release preparation. All three shipped executables target arm64 and macOS 14 or newer.

The app is ad-hoc signed, not Developer ID signed or notarized. Gatekeeper and permission behavior on a fresh Mac has not been tested across macOS versions. Permission renewal may be required after updates. No fresh-machine, Intel, Windows, or Linux support is claimed.

The local-folder installation passed. A synced-folder test failed signature verification because macOS added Finder metadata; installation stopped and removed staging. Use the default local Applications folder. Installer rollback fault tests mock signing and available disk space; the full release installation uses real hashes and code-signature verification.

## Report a useful reproduction

Include macOS version, Mac chip, application/editor name, menu status, whether a selection or caret moved, and a short synthetic phrase. State whether text appeared before trying to paste again. Avoid sharing private dictation, tokens, or documents. The app has no transcript history to export.
