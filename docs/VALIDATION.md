# Release validation

This records the v1.3 release validation and preserves historical v1.2/v1.1 evidence. It is not a promise of compatibility with every macOS text editor.

## Environment

- Apple M2 Pro, 16 GB memory, macOS 14.4.1.
- Swift 5.10 and Command Line Tools.
- whisper.cpp 1.8.3 with Metal, Whisper large-v3-turbo Q8_0.
- Ollama 0.9.6 and Qwen3 4B Q4_K_M.

## v1.3 validation

Status: installed v1.3.0 build6 passed native installation, three unchanged relaunches, automated regression checks, and creator-reported Chrome normal/full-screen dictation. The creator then requested publication. Final release build8 adds the correction name-retention guard described below; the installer, indicator, shortcuts, speech worker, models, decoding, and correction prompt remain unchanged from the installed build6 checks. This section distinguishes those results from the remaining validation limits below; it does not claim universal editor or recipient-Mac compatibility.

### Permissions and signing

The unchanged installed v1.2.0 build5 was gracefully terminated and reopened three times, without rebuilding, replacing, or re-signing. Its executable SHA256 remained `37edda3dbcea9fff5bb5ecac1d4153427c4455d8451b78f7950d5b634ff02d6e`, and its designated requirement remained cdhash `aa1563d1f14b6a47b4a629f5e8503ab005a142e0`. Targeted macOS TCC logs reported matching allowed grants for Microphone, Accessibility, and ListenEvent through all three cycles, with no matching-identity failures. The creator then confirmed dictation in Chrome worked without changing permissions. The reported unchanged-relaunch failure was not reproduced in this check.

After the native DMG update, the creator approved the changed build and confirmed v1.3 said Ready. The exact installed v1.3.0 build6 was then gracefully quit and reopened three times. Each launch retained authorized Microphone, Accessibility, and Input Monitoring status with an active shortcut listener. Its executable SHA256 remained `cd990830c2af894e0fe594090ff4d835199009de27b537109b4ab63519c1205a`, and its designated requirement remained cdhash `8fb02ca406eea68f6e55897f09a75fa7ddaca34e`. These three unchanged v1.3 relaunches passed without permission resets, rebuilding, or re-signing. After the final cycle, the creator confirmed physical Fn dictation, text insertion, listening-pill visibility, and completion dismissal in Chrome in both normal and full-screen mode, without changing permissions. This is a user-reported live result, separate from the independently observed readiness metadata.

Earlier targeted logs separately showed grants referencing an older code hash. That is update-identity evidence, not proof that every restart failure has the same cause. v1.3 distinguishes permission denial, shortcut conflict, event-tap creation/enable failure, and run-loop source failure, and offers listener retry without asking users to remove valid grants.

A code-signing publisher experiment used one self-signed certificate in an isolated, locked private keychain outside Git. It did not alter certificate trust, default/search-list keychains, or TCC. macOS reported `CSSMERR_TP_NOT_TRUSTED` and zero valid code-signing identities; signing two changed tiny fixtures failed. Cross-build designated-requirement compatibility and recipient permission continuity were therefore **not verified**. The experiment identity is not used for distribution. Ad-hoc updates can still require permission renewal, and clean-recipient Gatekeeper/TCC behavior remains a separate manual check.

### Installer and models

Twenty-six native fixture groups passed: twelve model-store groups, nine injected installation-transaction groups, four atomic-publication groups, and one real ad-hoc installation group. They cover manifest safety, tiny-file migration, verified reuse, partial-download/cancellation recovery, corrupt assets, links, replacement, rollback, and running-copy rejection. Updates exchange the complete staged and installed bundles in one macOS `RENAME_SWAP` operation; fresh installs use `RENAME_EXCL` to reject a concurrently created destination. Real swap/rollback checks preserve the original inode, while injected publication and rollback failures verify preservation of the old app or its recovery path. Canonical-location selection and duplicate-copy selection in the native launcher remain separate installed-app checks. Eight thin-release and eleven existing packaging groups passed. Three additional real release-signature groups verified an inline code-hash requirement, wrong-code-hash rejection, and sealed-resource rejection. An actual inline-requirement parsing failure was caught during DMG creation and corrected in both installation and release verification. Mocked copy/signing tools in fault fixtures establish error handling, not actual macOS trust policy.

Production ModelStore migrated all seven model files totaling **3,371,482,865 bytes** from the installed v1.2 bundle into Application Support and verified each pinned SHA256. Source checks took 2.239 s, verified clone migration 4.338 s, and subsequent offline preparation 2.350 s on the reference machine. Those are one-run setup measurements, not latency distributions. The old installed app's executable stayed unchanged.

The production HTTPS downloader first fetched four pinned metadata blobs totaling 13,451 bytes. A seeded 64-byte partial resumed successfully; all final hashes matched and later offline reuse passed. A subsequent full fresh setup used an isolated empty cache and downloaded all seven files totaling 3,371,482,865 bytes. Its first large transfer was canceled after 4,739,072 bytes; preparation drained about 51 ms later, with zero owned downloaders, and resumption retained that partial. Complete preparation took 123.241 s, independent seven-file SHA validation 2.061 s, and offline reuse 2.008 s with a downloader that fails if invoked. Total workflow time was 127.311 s. These are single-run setup measurements on this network, not expected download times for every user or a clean-recipient Gatekeeper test. The production model folder and installed app were untouched. See [numeric setup evidence](benchmarks/v1.3/model-setup.json).

The final candidate DMG is 12,692,698 bytes (about 12.7 MB), with SHA256 `9abd660ecb839529debea48d88a27dae3c7f009d69902bce56a82230a2db58fb`. `hdiutil verify` passed. Its mounted app passed strict deep verification against the exact final designated requirement, cdhash `8fb02ca406eea68f6e55897f09a75fa7ddaca34e`. The executable, speech worker, Ollama helper, Info.plist, and model manifest matched the packaged candidate byte for byte. No Models folder is bundled, and DMG creation preserves the source signature.

The mounted final DMG was opened after the old installed service quit gracefully. Its native Update dialog selected `/Applications/Local Dictation.app`; Install & Open completed, the source process exited, and the exact installed v1.3.0 build6 opened Settings. Strict signature, exact designated requirement, all five file hashes, and the thin layout passed again after installation. Existing verified external models were reused. This is an actual native installation on the reference Mac, using a locally produced, unquarantined DMG; it does not establish the Gatekeeper experience of an Internet download on a recipient Mac.

The changed-build launch required renewed Microphone, Accessibility, and Input Monitoring approvals. Targeted TCC logs explicitly matched the old v1.2 requirement against the new code and reported the mismatch. That confirms an update-identity renewal on this machine; the creator completed all three current-build approvals, and the three unchanged v1.3 relaunches described above then retained them. No grants or trust settings were reset during installation.

The final release build8 compiled and passed strict bundle verification. Its DMG is **12,698,247 bytes**, with SHA256 `9def92a205c25615329bb308f4537c8e8059cd6d396331455ec3631830dc81b9`, and `hdiutil verify` passed. Its designated requirement is cdhash `732f5443dd73b5817a4d454f4061c67dc3099956`; its executable SHA256 is `4b2319b8770b8c950cfd400d4c9a3bc3102813133a7921b24ff9aa5cb6a91265`. The installed build6 remains unchanged to preserve its working grants. The mounted final-release byte/signature checks are recorded separately after completion.

### Indicator

Thirteen real native HUD fixture groups passed, including all nine status states, external-editor/caret preservation, real Cancel/Copy/Discard clicks, browser-like floating surfaces, near-status overlays, dialogs, original-window display anchoring, Retina/negative/vertical display geometry, stale session/Space rejection, and native full-screen Space entry/exit. The panel uses a fixed status-bar level and can join all applications while remaining nonactivating.

The creator subsequently confirmed the exact installed v1.3 build showed and dismissed the pill correctly while dictating in Chrome, both normally and full-screen. The owned AppKit surfaces independently exercise layering and editor focus. These checks do not establish live Safari, Stage Manager, physical multiple-display, VoiceOver, or Dock-reveal behavior.

Latest-source insertion suites then passed sequentially: Native 15/15, WebKit 16/16, and Electron 44.5.1 16/16. They checked target/caret changes, protected fields, pinned asynchronous capture, exactly-once delivery, delayed Accessibility updates, 1.6-second delayed clipboard consumption, queued/canceled delivery, clipboard ownership, and restoration. Each suite exited successfully, restored its saved clipboard, and closed all owned fixtures. No source or permission changes were needed. These owned fixture results do not replace live tests in the named user apps.

### Vocabulary

The headless suites passed 40 normalization/persistence/adversarial checks, 8 client protocol/external-path/recovery checks, and 10 native worker framing/token-budget/silence/no-sticky-hint checks. Native decoder stubs establish protocol and budget behavior, not recognition accuracy. Existing 32 cleanup, 6 cancellation, 5 worker-fault, 9 metadata-cache, 4 correction-lifecycle, 30 gesture, 123 shortcut, 30 session, 8 audio, and 2 target-inspector groups passed. Nineteen additional listener-fault/recovery and bounded-private-diagnostics checks passed.

The final direct Qwen check with saved vocabulary matched all nine expected sentences literally and all eight target-bearing cases with exact preferred spelling, including accented names, identifiers, numbers, negation, repetition, weekday correction, and instruction-like dictated content. The empty snapshot matched the ordinary-speech control (1/9 sentences, 0/8 preferred-term cases). All eighteen outputs passed the conservative validator. The [final spelling diagnostics](benchmarks/v1.3/vocabulary-spelling-diagnostics.json) separate literal sentence equality, normalized sentence equality, and case-sensitive preferred-term spelling. The [earlier direct report](benchmarks/v1.3/vocabulary-direct-quality.json) measures normalized sentence equality; its timing overlapped setup work and is excluded from performance claims.

Seven short synthetic speech clips covered saved phrases, NeurIPS, José, userId, two quantities, negation, and an ordinary-speech control. A 32.462-second clip placed its saved term across a Whisper decoding-window boundary. Both vocabulary modes used the same audio and model settings; their order alternated on each repeat. All 96 speech requests produced accepted cleanup, preserved the checked quantities/negations, and needed no raw fallback. Exact preferred spelling appeared in 32/35 short target-bearing requests with saved vocabulary, versus 0/35 with it disabled. Most of those requests repeated the short timing clip, so this count is not a broad recognition-accuracy estimate.

Saved words were still missed in two fixtures. A combined short sentence preserved OpenAI but missed Wispr Flow despite a matching cleanup hint. The long clip missed Wispr Flow in all ten measured repetitions; its recognized variant did not match a saved alias, so no spelling edit was authorized. A focused rerun confirmed both misses while normalized surrounding text, quantities, negation, and validated order remained intact. The ordinary-speech control stayed unchanged, and real-worker silence and overflow checks passed. These findings establish useful short-clip behavior and remaining spelling limits, not guaranteed saved-word recognition or universal correctness.

Final review found that the older retention/subsequence validator could accept deleting an unrelated capitalized recipient, including when a vocabulary alias elsewhere was authorized. Build8 now retains ordinary capitalized-name and identifier occurrences, except contiguous stutters and an immediate explicit name correction. Unicode capitalized names and full-name corrections are covered; comma-separated recipients are not treated as one removable name. All **45** cleanup and **42** vocabulary checks passed, including unrelated-name deletion, a correction elsewhere, repeated occurrences, multiword names, and local “no” repairs. The nine previously verified literal Qwen outputs passed replay through the final guard, and nine new Qwen requests to the already-running, verified app-owned loopback service again matched all expected sentences. This quality-only check started no engines, captured no microphone audio, and makes no latency claim. See [numeric final-guard results](benchmarks/v1.3/final-cleanup-guard.json). The safeguard remains conservative; lowercase or ambiguous names and general semantic equivalence are not guaranteed.

### v1.3 warm processing measurements

The reference machine ran twenty repetitions of the 2.670-second short clip and ten of the 32.462-second long clip per vocabulary mode, after unmeasured priming. No other dictation, model, GUI, or compilation work ran during timing. The five-entry test dictionary and voice/rates are defined in the synthetic fixtures; actual audio duration is recorded in each numeric row. The long clip was generated at 145 words per minute to cross thirty seconds, and fixture-generation fingerprints prevent silently reusing audio from a different voice/rate/text setting.

| Audio | Runs per mode | Vocabulary off median / p95 | Vocabulary on median / p95 |
|---|---:|---:|---:|
| Short, 2.670 s | 20 | 1.31 / 1.33 s | 1.39 / 1.46 s |
| Long, 32.462 s | 10 | 4.98 / 6.06 s | 5.37 / 5.68 s |

These times were collected on build6, before the final build8 name-retention guard. Speech decoding and the correction prompt/model are unchanged; the full timing distributions were not rerun after that guard. The measurements include recognition and cleanup, excluding microphone startup, model warming, installation, and editor delivery. p95 uses nearest rank; with ten long runs it is the maximum. All outliers are retained. Saved vocabulary added about 0.08 s to the short median in this sample. The short speech stage was nearly unchanged (0.723 s without hints, 0.725 s with them); most extra time was cleanup. The long medians were 1.829/2.204 s for speech and 3.156/3.169 s for cleanup, without/with vocabulary. These fixtures differ from the historical v1.2 timing sample and do not establish a version-to-version speedup. Cold, post-sleep, and memory-pressure behavior with vocabulary remain unmeasured.

See [all paired numeric measurements and per-case summaries](benchmarks/v1.3/vocabulary-paired-models.json). Reports contain numeric flags and timings, not audio or transcript contents. Per-term spelling diagnostics were collected in a subsequent quality run; they do not replace the completed warm timing samples.

### Remaining validation limits

The creator confirmed the installed Chrome workflow and requested publication after three unchanged v1.3 relaunches. Live Safari, Stage Manager, physical multiple displays, VoiceOver, Dock reveal, reboot, recipient-Mac Gatekeeper/TCC behavior, and a quarantined Internet-downloaded DMG remain unverified. Vocabulary serialization and reload pass their native tests; Add/Edit/Remove and vocabulary persistence through an installed-app restart still need a manual check. Actual normal app Quit during an active production download is not established by the downloader cancellation/drain integration test. Cold, idle, post-cancellation, post-sleep, and memory-pressure performance with vocabulary have not been measured. No blanket permission-continuity, compatibility, saved-spelling accuracy, or physical-feedback latency claim is made for those cases.

## v1.2 candidate validation

The release executable compiles with Swift 5.10. A complete candidate bundle has passed model integrity checks and strict code-signature verification. Its bundled models and native recognition settings are unchanged.

| Area | Result |
|---|---|
| Fn gestures | 30 regressions, including delayed pending placement, double-tap refusal, interruption, and synthetic paste events |
| Session state and timing export | 30 assertions covering protected pending results, new capture before prior delivery completes, stale receipts, cancellation, discard, content-free JSON, and completion feedback that cannot reopen after dismissal passed |
| Target-inspection cancellation | 2 groups passed: canceled queued and already-canceled requests skip Accessibility work without poisoning the next request |
| Correction validation | 32 existing conservative-cleanup cases passed |
| Owned-service caching | 9 metadata, ownership, invalidation, retention, and unload checks passed |
| Correction lifecycle | 4 shared-start, bounded-shutdown, immediate-rewarm, and canceled-start recovery checks passed |
| Audio | 8 conversion, recovery, and microphone-level checks passed |
| Transcriber | 6 cancellation/recovery and 5 worker-fault cases passed |
| Native insertion | 15 groups passed, including pinned identity capture, off-main inspection, away-and-return invalidation, queued delivery and cancellation |
| WebKit insertion | 16 cases passed, including async pinned input/rich-editor capture and explicit placement |
| Electron insertion | 16 cases passed in the final isolated run |
| Floating indicator | 7 checks passed: compact capsule geometry, all states and real action clicks preserve editor focus; changed guidance is announced and level updates stay silent |
| Custom shortcuts | 123 validation, preference, gesture, and input-filter checks; native exclusive Carbon registration, conflict preservation, release/reacquisition, and reset checks passed |
| Shortcut chooser | 8 isolated AppKit groups passed: posted-key routing, invalid/repeated input, Escape/Cancel, rejected/accepted choices, outside-window typing, actual deactivation, and reopening |
| Packaging/installer | 4 package rollback, 7 source/output integrity, and 8 installer failure/replacement checks passed; rollback fault tests mock signing |

One earlier Electron run, overlapping other test/model activity, produced an unexplained textarea selection mismatch. The complete isolated repeat passed without a product-code change. A further 12 focused selection replacements (six asynchronous anchors and six legacy captures, including Unicode/emoji and multiline text) also matched DOM/Accessibility ranges, delivered one paste each, and restored the clipboard. This remains a validation limitation; the repeat does not establish a root cause or a fix for that initial result.

The identity anchor reads no field text. Full target inspection runs on a serial worker with request-local deadlines. A paste dispatch releases recording readiness, while the clipboard lease and insertion observation continue separately. The delivery fixture waits for the first insertion to be observed before moving its field, still within the clipboard read window; it does not claim that a posted global keyboard event is synchronously consumed.

UI fixtures verify nonactivation across all nine HUD states and actual action-button clicks preserving an external synthetic editor's focus and caret. Multi-display geometry is bounded to the selected screen. Physical Fn use, six-app compatibility, full-screen Spaces, and VoiceOver still require installed-candidate live checks; the previous release's user reports below do not validate v1.2.

The shortcut chooser fixture sends keyboard events only through its own AppKit event queue. Native Carbon checks reserve synthetic test combinations without posting global keyboard input. These verify registration and chooser behavior separately. Build 5 was installed through the final offline installer and relaunched with Setup; its version, strict signature, main executable, helpers, and Info.plist matched the signed candidate. After being asked to test a custom shortcut for dictation and click-away placement in the installed build, the creator reported that everything worked and requested publication on October 4, 2026. This is a user-reported live check; the fixture separately verifies saved-setting reload, but an installed-app restart with the custom binding was not independently observed. Invalid and canceled choices preserve the saved configuration. While choosing a key, the prior chord is temporarily unregistered so it can be captured; restoration can report a conflict if another app claims it in the meantime.

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

### Packaging integrity

During release preparation, a source file reported a nonzero size but returned an empty content read in the Documents checkout. The resulting empty installer was caught before publication. Packaging now uses counted reads, source/output verification, required installer markers, and ZIP command-byte/executable checks. Empty and truncated reads are covered by regression tests, and release preparation continues from a local checkout outside Documents. No invalid installer was published.

The final compact-indicator bundle passed the real offline installer on October 4, 2026, in a separate local destination. Both release-part hashes passed, and the installed executable, speech worker, Ollama helper, and Info.plist matched the verified candidate byte for byte. The installed bundle passed strict signature verification and identity/version checks. The temporary test copy was removed afterward; the candidate and release files remain available.

The creator confirmed that the earlier installed v1.2 candidate dictated successfully, then reported that both setup and completion UI stayed visible. After installing the compact-indicator revision through the verified release installer in /Applications, the creator confirmed that the design looked better and both windows disappeared correctly. A subsequent report identified a rectangular outline outside the capsule. The visual-effect material now has its own capsule mask, since clipping its content layer alone did not mask the backdrop and window shadow. The release build and seven HUD regressions passed with this change. After the masked build was installed through the verified offline installer, the creator confirmed that the rectangular outline was gone and the app was working correctly. Cached-view previews cannot verify the WindowServer shadow. Desktop-control calls timed out for TextEdit, app inventory, and the installed setup window, so no automated six-app live-compatibility result is claimed.

### Remaining validation limits

The creator approved publication after the installed custom-shortcut check. The six-app live matrix, full-screen/multiple-display use, live VoiceOver behavior, physical-display/microphone latency distributions, and an installed-app restart with a custom binding have not been independently verified. These limits remain separate from the automated fixture and user-reported checks above.

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
