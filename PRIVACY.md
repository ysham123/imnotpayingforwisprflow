# Local Dictation privacy policy

Updated October 12, 2026.

Local Dictation processes speech recognition and text cleanup on your Mac. It does not send your recordings, transcripts, or custom vocabulary to the developer or an AI provider. It has no account system, advertising, tracking service, or cloud transcription fallback.

## Voice and text

The microphone is used only when you start recording or a microphone test. Normal recordings stay in memory and are not saved as audio files. The website edition may keep one failed recording in memory so you can retry it. A current transcript, a waiting result, and a copy backup can remain in memory until replaced, discarded, or the app quits. There is no saved transcript history.

The Store edition, currently in development, returns a finished transcript to a participating editor through a macOS Services pasteboard. Copy writes the text shown in the app to the macOS clipboard. Clipboard syncing, and the storage or transmission of text by another app, follow your macOS settings and that app's privacy practices.

## Local settings and models

Microphone choices, dictation preferences, and custom vocabulary are stored locally. Speech and cleanup model weights are stored in Application Support. The Store edition uses its own sandbox container. App updates do not require uploading these files.

First-time setup downloads model files from Hugging Face and Ollama over HTTPS. Those hosts receive ordinary download-request information, including your IP address. Your speech and transcripts are not part of those requests. Files are checked against bundled sizes and SHA-256 digests before use. Dictation can run offline after setup.

## macOS permissions

The website edition requests Microphone access to capture speech, Accessibility to place text into other apps, and Input Monitoring to handle its keyboard shortcut. These permissions are used for those features.

The Store edition uses Microphone access and macOS Services for delivery. It does not inspect another app through Accessibility or install a global keyboard event tap. You choose any Services keyboard shortcut in System Settings.

## Diagnostics

The app can write operational messages, such as timing and engine errors, to macOS logging facilities. It does not automatically upload diagnostics. Developer test builds can generate synthetic audio and diagnostic files during explicit tests; these are not transcript history and are excluded from the Store release build. If you choose to share a bug report or attach files to a GitHub issue, that information is sent to GitHub and may be public.

## Website and downloads

The product website is hosted by Vercel. Hosting and download providers may process ordinary web-request information under their own privacy policies. This policy's on-device speech-processing commitments describe the Mac app, not websites or apps where you place text.

## Control and contact

You can revoke permissions in System Settings, discard a waiting recording or result, clear copied text from your clipboard, and remove local settings or model files. Removing the app alone may leave settings and downloaded models on your Mac.

For questions, use the project's [support issues](https://github.com/ysham123/imnotpayingforwisprflow/issues). Avoid including private recordings, transcripts, passwords, or API keys in a public issue.
