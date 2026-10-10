# Guided setup candidate (2.1.0)

The candidate replaces the crowded first-run window with one step at a time: welcome, three privacy approvals, verified model preparation, shortcut selection and detection, a real practice dictation, and completion. The public stable release remains 2.0.1 until a new release is published.

New installations start the model download after Start setup. Existing caches load automatically; size/existence is only a UI hint, and the model store still verifies pinned SHA-256 hashes before loading files. Download progress includes bytes, speed, and an estimated remaining time when measured progress is available. Paused and failed downloads retain the existing resumable model store behavior.

Setup confirms actual macOS permission probes. It never approves permissions itself, changes Fn settings, or removes/re-adds TCC entries. Returning from System Settings advances only the approved step. Quitting and reopening starts from a new welcome and skips grants already confirmed by macOS.

Control-Shift-Space is offered as an optional preset; existing shortcuts remain unchanged until the user selects it. Setup requires an actual detected key press before practice. Fn remains available with Keyboard Settings guidance.

Practice uses the production recorder, transcription, selected mode, and cleanup pipeline. Its session token owns the result. The result is displayed inside setup and never sent to TextInserter or stored as Copy last result. Canceled/stale results cannot finish setup. Closing setup cancels active practice, discards retained practice audio, and clears the displayed transcript. Recognition failures retain audio for retry while setup stays open. The test demonstrates local recognition, not compatibility with every external editor.

The DMG includes START HERE.html so opening/installing guidance is accessible before the app can launch. The public v2.0.1 website guide remains accurate for the current public build.

## Validation

- `bash Scripts/test-setup.sh`: permission gates, model readiness, real shortcut detection, changed shortcut, stale/canceled/empty practice results, permission revocation, and download estimates. Compiles the native UI fixture.
- `.test-build/setup/SetupUISmoke --render-only .test-build/setup/previews`: isolated native view actions and normal/minimum-size previews for every step, recording, processing, and result. Does not record, run models, or request access.
- Release Swift executable compilation plus session, model/installer, packaging, and thin-release regressions.

A fresh Mac end-to-end permission/download/dictation run is still needed. The creator's installed app and existing permissions were not replaced for these checks. Public signing and notarization require the approved Apple Developer membership and Developer ID certificate.
