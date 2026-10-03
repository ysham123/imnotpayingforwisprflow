# Changelog

## 1.1.1

- Improved focused-editor discovery for WebKit and Chromium applications, including rich text descendants and editable-ancestor links.
- Added one bounded discovery retry when a Chromium app has just enabled its accessibility tree.
- Rechecked the cursor and focused control after accessibility content reads, preventing insertion when either changes during inspection.
- Replaced the misleading "paste not accepted" error with **Paste sent** when insertion cannot be confirmed. The result remains available to copy, and the app never sends an automatic second paste.
- Kept the temporary clipboard available while observing asynchronous insertion, covering delayed reads by editors.
- Added isolated WebKit and Electron integration suites. The 41 local insertion checks passed; live checks in the reported Claude and ChatGPT editors are recorded separately in [validation](docs/VALIDATION.md).

## 1.1.0

Initial public release: native macOS menu-bar dictation, Fn / Globe control, bundled Whisper speech recognition, local Qwen cleanup, guarded insertion, and an installer with verified downloads and rollback.
