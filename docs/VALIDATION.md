# Release validation

This records the scope of validation for version 1.1.0. It is not a promise of compatibility with every macOS text editor.

## Environment

- Apple M2 Pro, 16 GB memory, macOS 14.4.1.
- Swift 5.10 and Command Line Tools.
- whisper.cpp 1.8.3 with Metal, Whisper large-v3-turbo Q8_0.
- Ollama 0.9.6 and Qwen3 4B Q4_K_M.

## Automated coverage

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

## Real models and live use

The installed models passed exact correction checks for:

- “Thursday, sorry, Friday” → “Friday.”
- Repeated “send” and the filler “um.”
- “fifteen, actually fifty dollars” → “fifty dollars.”
- Retaining “Do not delete the file” and a person's name.

Silence produced no transcript. A 9.8-second synthetic speech sample took approximately 1.0 second for recognition and 2.1 seconds through cleanup after warmup. This is one development-machine measurement, not a cross-device benchmark. Cold startup and longer dictation take longer.

The creator confirmed the physical Fn workflow in Google search and subsequently confirmed that dictation worked in the desktop chat app after editor compatibility improvements. The native fixture provides additional insertion coverage. We have not validated every web framework, third-party editor, keyboard, or microphone.

## Distribution checks

The release process checks the complete bundle's code signature, model blob hashes, per-part SHA-256 hashes, app identity and version, and installation into a separate destination. The original working installation is preserved during release preparation. All three shipped executables target arm64 and macOS 14 or newer.

The app is ad-hoc signed, not Developer ID signed or notarized. Gatekeeper and permission behavior on a fresh Mac has not been tested across macOS versions. Permission renewal may be required after updates. No fresh-machine, Intel, Windows, or Linux support is claimed.

The local-folder installation passed. A synced-folder test failed signature verification because macOS added Finder metadata; installation stopped and removed staging. Use the default local Applications folder. Installer rollback fault tests mock signing and available disk space; the full release installation uses real hashes and code-signature verification.

## Report a useful reproduction

Include macOS version, Mac chip, application/editor name, menu status, whether a selection or caret moved, and a short synthetic phrase. State whether text appeared before trying to paste again. Avoid sharing private dictation, tokens, or documents. The app has no transcript history to export.
