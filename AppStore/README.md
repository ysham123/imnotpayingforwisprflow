# Mac App Store edition

This is an experimental Store candidate, not a published App Store release. The website's signed and notarized 2.2.1 preview remains the available download.

The owner chose to keep insertion into other apps and approved macOS Services as the Store delivery route. The Store edition uses **Services → Dictate with Local Dictation** from a participating editor, opens a recording window, and returns the finished text to the requestor. Users may assign a Services shortcut in System Settings. Other editors can use the app's own recording window and Copy. The website edition retains Fn and Accessibility-based insertion.

## Apple record

| Field | Value |
|---|---|
| Store display name | Local Dictation: Private Voice |
| App Store Connect ID | 6821808111 |
| Platform | macOS only |
| Bundle identifier | dev.yosef.localdictation |
| Team | 2563R7W8T6 |
| SKU | local-dictation-macos |
| Internal test version / build | 2.3.0 / 17 |
| Development bundle identifier | dev.yosef.localdictation.store.development |

[App Store Connect draft](https://appstoreconnect.apple.com/apps/6821808111/distribution) is **Prepare for Submission**. Creating this record does not upload a build or publish the app.

## Build

Open `LocalDictationStore.xcodeproj` in Xcode 27 or newer and select the LocalDictationStore scheme. The project has explicit source membership: the installer, Fn event tap, Accessibility inspector, and keyboard-event text inserter are excluded. Shared speech, audio-input, model verification, vocabulary, and cleanup code remain in use.

Provide rebuilt, audited `whisper-worker` and `ollama` executables in `.build-native/store-runtime/`, or set the Xcode build setting `LOCAL_DICTATION_STORE_RUNTIME_DIR` to their directory. Do not place model weights there. The normal [source build](../docs/DEVELOPMENT.md) describes the speech-worker build and pinned Ollama runtime. For this local feasibility run, the two runtimes came from the already verified 2.2.1 app; rebuilding release dependencies from the documented versions is still required before distribution.

```sh
bash Scripts/build-store-preview.sh
python3 Scripts/check-store-build.py \
  '.build-native/store-xcode/Build/Products/Debug/Local Dictation.app' --development
```

The preview script makes an ad-hoc signed, sandboxed **development** app. It is not suitable for upload. It uses a separate app identifier, preferences, and sandbox container. Full model testing requires verified weights in that container; first-run downloads require consent through Download models.

For distribution, use the registered team and **Product → Archive → Distribute App → App Store Connect**. Xcode archives with Apple Development, then re-signs during Store export with the managed distribution identity and profile. Release archives use the production identifier and hardened runtime. Run the checker without `--development` on the signed exported app. Its result supplements Xcode validation; it does not prove App Review acceptance or complete live readiness.

The reproducible project generator is `Scripts/generate-store-project.py`. It uses Python's standard library and regenerates the checked-in project, scheme, plists, and entitlements. Update that generator when changing generated project configuration.

`ExportOptions.plist` prepares a normal Store export. `InternalTestingExportOptions.plist` uploads a development-branch build for **internal TestFlight only**, following Xcode's recommendation for development branches. Such a build cannot be used for external testing or App Store release; a later validated public candidate needs a higher build number and the normal export options.

## Sandbox implementation

- The root app has Sandbox, Microphone, network client, and network server entitlements. Cleanup binds only to loopback port 11439, separate from the website edition's 11437.
- Bundled executables live in `Contents/Helpers` with exactly App Sandbox and sandbox inheritance entitlements. Ollama's runner is launched from its same sealed executable. No executable is downloaded at runtime.
- URLSession downloads weights as data, with HTTPS-only redirects and bounded sizes. ModelStore verifies the manifest's SHA-256 before publishing a file. An interrupted Store download restarts its current file; completed verified files are reused.
- Services uses a requestor-specific pasteboard, without reading the general clipboard, capturing the selection, inspecting another process, or posting global input. The Copy button writes to the general clipboard only when explicitly pressed.
- Services requests are bounded by a ten-minute timeout, including the five-minute recording limit and processing. The provider stops its own modal before that deadline, retaining any already recognized text for Copy. Opening the service before model setup finishes returns an actionable error. Cancellation returns no text.
- Debug-only synthetic acceptance modes are excluded from Release builds.

## Verification on October 12, 2026

| Check | Result / limit |
|---|---|
| Xcode | 27.0, 27A266a; first-launch setup complete |
| Debug Xcode build | Passed |
| Release Xcode archive | Passed with managed Apple Development signing |
| Store package export | Passed; app uses Apple Distribution and package uses the Apple-issued Mac installer identity |
| Distribution preflight | Passed signature, team/profile identity, sandbox, helper inheritance/team, and API checks |
| App Store Connect upload | Xcode reported success for internal-only 2.3.0 (17); processing/availability must be verified in Connect |
| Sandbox enforcement | Existing outside synthetic marker could not be read |
| Development bundle preflight | Passed; not a distribution identity/profile check |
| Services fixture | Passed cross-process return and insertion at an owned AppKit caret |
| Chrome Services insertion | Sandboxed feasibility provider inserted fixture text into a real textarea |
| Real speech and cleanup helpers | Passed with preseeded, verified models and synthesized speech; no microphone recording |
| Speech-to-editor Services path | Passed synthesized speech, cleanup, modal completion, and AppKit caret insertion |
| Sandboxed HTTPS downloader | Passed tiny pinned public license fixture, digest publication, and oversized-response rejection |
| Microphone / mode menus | Opened correctly; microphone inventory refresh dispatched; no actual microphone test performed |
| Services setup link | Opened Keyboard Shortcuts directly on Services; registered dictation service was enabled |
| Existing shared regressions | Model setup/install groups, 5 speech worker faults, 6 correction lifecycle checks, 12 cleanup coordinator groups passed |

The test artifacts are under `.test-build/` and are not committed. Model clones used in testing are not evidence of fresh first-run download setup. The initial cold cleanup attempt timed out; subsequent real-model checks passed. Setup now retries recoverable warmup failures within a bounded budget and otherwise retains the original transcript.

The window includes the existing app logo, microphone selection, refresh, a five-second microphone test independent of model loading, and a Clean/Original selector. The microphone test requests access only when clicked, displays the level meter, and discards its audio. Its physical-microphone acceptance remains pending.

The Store description, keywords, support/marketing URLs, version, copyright, and reviewer notes are saved in App Store Connect. The public [privacy policy](https://local-dictation-psi.vercel.app/privacy.html) is deployed; the website's app download remains 2.2.1.

## Remaining release gates

- Xcode initially reported expired authentication, then refreshed its existing session. The signing team became available, a managed development identity was created, and automatic Store export succeeded. Store distribution signing uses Xcode's managed signing; private keys were not exported or placed in the repository.
- Verify that internal-only build 17 finishes App Store Connect processing and becomes available for owner testing. Upload success does not prove processing, TestFlight availability, or App Review approval.
- Xcode reported missing dSYMs for the reused whisper-worker and Ollama runtimes. Upload succeeded, but helper crash symbolication is limited. Rebuild release dependencies with matching debug symbols before the public candidate; do not substitute empty symbol files.
- Test a real microphone session and cancellation through Services, including permission denial/recovery and long dictation. Test Chrome, Safari, TextEdit, and common coding editors separately. Universal editor support is not claimed.
- Verify fresh-container full-model downloads, pause/retry, low disk space, offline reuse, sleep/wake, and memory pressure. The Store downloader restarts an interrupted file rather than resuming it byte-for-byte.
- Check target behavior if focus or the caret changes during a pending Services request. The OS requestor route differs from the website edition's destination restoration.
- Complete screenshots of the actual Store edition, App Privacy answers, age rating, export compliance, pricing/availability, reviewer contact information, and any applicable EU trader declaration. Account or legal declarations must come from the owner.
- Finish the bundled third-party privacy/API audit and dependency rebuild; app manifests declare own-container file metadata, elapsed-time timers, low-space checks, and app-only preferences.
- Submit for Apple review and verify approval before advertising an App Store download.

Apple references: [Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox), [Review guidelines](https://developer.apple.com/app-store/review/guidelines/), [Providing Services](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/providing.html), [Using Services](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/using.html), [Inherited helpers](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app), [Privacy API reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons).
