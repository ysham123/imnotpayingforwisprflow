# Changelog

## 2.0.1 (2026-10-09)

- Keep the original verified field and caret attached to a recording when you click, scroll, or switch applications. At delivery, restore that destination when its text and window still match. The original application may come forward to receive the paste.
- Hold the transcript when the original contents changed, the window disappeared, restoration is unsupported, or new input interrupts delivery. Explicit placement and retry continue to require a freshly selected field.
- Add headless restoration-order and cancellation regressions plus native fixture cases. Live app compatibility is pending; see [validation](docs/VALIDATION.md).

### Included 2.0 improvements

- Record for up to five minutes with an elapsed timer, microphone meter, and final countdown. Quiet speech windows survive long pauses.
- Choose Clean or Verbatim mode. Long Clean transcripts use bounded passages with protected numeric phrases, identifiers, links, paths, and quoted/code spans. Use original skips cleanup while it is running.
- Retry failed recognition from one in-memory recording. Retry results wait for explicit placement; stale destinations are never reused.
- Added native Settings with General, Audio, Shortcuts, Custom Words, and Advanced sections. Select and test an input device, with a visible fallback when it is unavailable.
- Added optional open at login using macOS login-item status. Existing preferences, model weights, and shortcuts remain compatible.
- Export content-free mode, duration, retry, and cleanup fallback measurements.

- Recover local text cleanup in the background after its helper disconnects or times out, while preserving the current raw transcript. Rejected cleanup output does not trigger an engine restart.
- Protect individual quantity occurrences during cleanup, including repeated amounts and numbers outside a spoken correction. Ambiguous edits fall back to the original transcript.

## 1.2.0

- Added a compact floating dictation indicator with microphone activity, transcription/correction stages, and clear placement feedback. It leaves keyboard focus with your editor.
- Preserved unsent text when focus or the cursor changes. Select the intended field and tap Fn once to place it, or copy/discard it. Waiting text must be resolved before another recording.
- Made paste dispatch independent of clipboard restoration, allowing another recording while the previous delivery finishes. Unverified pastes are never automatically retried.
- Started microphone capture before expensive Accessibility inspection and pinned inspection to the original field.
- Kept local models warm, cached metadata for the app-owned correction service, buffered speech-worker responses, and released idle engines under memory pressure or on sleep.
- Added content-free, memory-only performance measurements with an explicit local JSON export.
- Kept Whisper large-v3-turbo, Qwen3 4B, and conservative correction validation unchanged.
- See [validation](docs/VALIDATION.md) for measured results and the status of installed-app checks.

## 1.1.1

- Improved focused-editor discovery for WebKit and Chromium applications, including rich text descendants and editable-ancestor links.
- Added one bounded discovery retry when a Chromium app has just enabled its accessibility tree.
- Rechecked the cursor and focused control after accessibility content reads, preventing insertion when either changes during inspection.
- Replaced the misleading "paste not accepted" error with **Paste sent** when insertion cannot be confirmed. The result remains available to copy, and the app never sends an automatic second paste.
- Kept the temporary clipboard available while observing asynchronous insertion, covering delayed reads by editors.
- Added isolated WebKit and Electron integration suites. The 41 local insertion checks passed; live checks in the reported Claude and ChatGPT editors are recorded separately in [validation](docs/VALIDATION.md).

## 1.1.0

Initial public release: native macOS menu-bar dictation, Fn / Globe control, bundled Whisper speech recognition, local Qwen cleanup, guarded insertion, and an installer with verified downloads and rollback.
