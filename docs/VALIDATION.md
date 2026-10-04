# Release validation

This records v1.2 validation and preserves the historical v1.1.1/v1.1.0 evidence. It is not a promise of compatibility with every macOS text editor.

## Environment

- Apple M2 Pro, 16 GB memory, macOS 14.4.1.
- Swift 5.10 and Command Line Tools.
- whisper.cpp 1.8.3 with Metal, Whisper large-v3-turbo Q8_0.
- Ollama 0.9.6 and Qwen3 4B Q4_K_M.

## v1.2 candidate validation

The release executable compiles with Swift 5.10. A complete candidate bundle has passed model integrity checks and strict code-signature verification. Its bundled models and native recognition settings are unchanged.

| Area | Result |
|---|---|
| Fn gestures | 30 regressions, including delayed pending placement, double-tap refusal, interruption, and synthetic paste events |
| Session state and timing export | 22 assertions covering protected pending results, new capture before prior delivery completes, stale receipts, cancellation, discard, and content-free JSON passed |
| Target-inspection cancellation | 2 groups passed: canceled queued and already-canceled requests skip Accessibility work without poisoning the next request |
| Correction validation | 32 existing conservative-cleanup cases passed |
| Owned-service caching | 9 metadata, ownership, invalidation, retention, and unload checks passed |
| Correction lifecycle | 4 shared-start, bounded-shutdown, immediate-rewarm, and canceled-start recovery checks passed |
| Audio | 8 conversion, recovery, and microphone-level checks passed |
| Transcriber | 6 cancellation/recovery and 5 worker-fault cases passed |
| Native insertion | 15 groups passed, including pinned identity capture, off-main inspection, away-and-return invalidation, queued delivery and cancellation |
| WebKit insertion | 16 cases passed, including async pinned input/rich-editor capture and explicit placement |
| Electron insertion | 16 cases passed in the final isolated run |
| Floating indicator | 6 checks passed: all states and real action clicks preserve editor focus; changed guidance is announced and level updates stay silent |
| Packaging/installer | 4 package rollback and 8 installer failure/replacement checks passed; these fault tests mock signing |

One earlier Electron run, overlapping other test/model activity, produced an unexplained textarea selection mismatch. The complete isolated repeat passed without a product-code change. A further 12 focused selection replacements (six asynchronous anchors and six legacy captures, including Unicode/emoji and multiline text) also matched DOM/Accessibility ranges, delivered one paste each, and restored the clipboard. This remains a validation limitation; the repeat does not establish a root cause or a fix for that initial result.

The identity anchor reads no field text. Full target inspection runs on a serial worker with request-local deadlines. A paste dispatch releases recording readiness, while the clipboard lease and insertion observation continue separately. The delivery fixture waits for the first insertion to be observed before moving its field, still within the clipboard read window; it does not claim that a posted global keyboard event is synchronously consumed.

UI fixtures verify nonactivation across all nine HUD states and actual action-button clicks preserving an external synthetic editor's focus and caret. Multi-display geometry is bounded to the selected screen. Physical Fn use, six-app compatibility, full-screen Spaces, and VoiceOver still require installed-candidate live checks; the previous release's user reports below do not validate v1.2.

### Performance evidence

Content-free interaction measurements are kept only in memory and exported explicitly. `indicatorRequested` measures when AppKit was asked to show the panel, not when the display physically presented it. `verifiedVisible` is the first observed Accessibility insertion; an editor may visibly update earlier. Stop-to-dispatch, observed insertion, and next-capture readiness are reported separately.

The M2 Pro comparison used the same bundled models and synthetic audio, with 20 warm runs and 5 runs in each other condition per length: 70 runs per version. Short audio is about 9.8 seconds; the long sample repeats it three times. All 140 runs produced nonempty recognition and accepted cleanup. These repeated fixtures measure timing, not general recognition accuracy. Baseline ran first, then the candidate, without other dictation/model or GUI tests running. This is a single-machine sequential comparison, not a randomized performance study.

| Condition | Audio | Runs per version | v1.1.1 median / p95 | v1.2 median / p95 |
|---|---|---:|---:|---:|
| Warm | Short | 20 | 1.85 / 2.00 s | 1.77 / 1.95 s |
| Cold | Short | 5 | 6.45 / 7.36 s | 6.12 / 6.52 s |
| After 2 s idle | Short | 5 | 2.02 / 2.26 s | 2.07 / 3.65 s |
| Immediately after cancel | Short | 5 | 2.57 / 16.98 s | 2.47 / 2.56 s |
| Warm | Long | 20 | 2.18 / 2.38 s | 2.15 / 2.22 s |
| Cold | Long | 5 | 6.74 / 6.86 s | 5.99 / 7.06 s |
| After 2 s idle | Long | 5 | 2.50 / 2.76 s | 3.64 / 6.47 s |
| Immediately after cancel | Long | 5 | 3.00 / 3.28 s | 2.89 / 3.34 s |

Times include recognition and correction, excluding microphone startup and editor delivery. p95 uses nearest rank; with only five runs it is the maximum, so tail estimates outside the warm condition are especially uncertain. All outliers are retained. The baseline short post-cancellation outlier included 13.30 seconds of recognition. The candidate's slower long idle runs spent up to 3.70 seconds evaluating the correction prompt while reported model-load time stayed below 0.08 seconds. This does not establish a cause or a fix, and v1.2 is not faster in every condition.

The two-second idle condition does not exercise the previous ten-minute retention timeout. The immediate post-cancellation condition measures the first request after cancellation without scheduling the app controller's background rewarming. Cold runs unload correction and terminate speech first, then include both model reloads in the timed request; they do not include application launch. Warm median and p95 did not regress in this sample.

Raw numeric data: [v1.1.1 baseline](benchmarks/backend-baseline-v1.1.1.json), [v1.2 candidate](benchmarks/backend-candidate-v1.2.0.json). No audio or transcript contents are included. Actual microphone readiness, stop-to-visible insertion, and the 100 ms physical-display feedback goal still need installed-app measurements; fixture timing and backend timing do not establish those results.

### Correction quality

The unchanged real models and cleanup rules passed the same 11 exact text-correction cases in both v1.1.1 and v1.2. Coverage includes “Add 3, I mean 2 items,” explicit weekday/time revisions across a sentence boundary, names with accents, identifiers, negation, repeated words, and prompt-like dictated content. These are direct cleanup tests, not a broad speech-recognition accuracy benchmark or proof of accented-name recognition. The [baseline](benchmarks/real-cleanup-baseline-v1.1.1.json) and [candidate](benchmarks/real-cleanup-candidate-v1.2.0.json) reports contain only pass flags and timings. The synthetic case definitions are in `Tests/CleanupModelSmoke.swift`.

### Remaining release gates

- Install and test the candidate's physical Fn and explicit placement flow in real applications.
- Verify the generated split release through the real offline installer before publishing stable v1.2.

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
