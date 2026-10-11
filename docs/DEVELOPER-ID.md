# Developer ID distribution

The public download is still v2.0.1. A local v2.1.0 candidate is Developer ID signed with secure timestamps and hardened runtime. Both signed helpers initialized their cached models on the creator's Mac. Apple accepted the app and DMG with no reported issues; tickets are stapled and Gatekeeper checks pass. The new drag-to-Applications disk image was visually checked in Finder. A real copy into an isolated temporary folder preserved the notarized app. A fresh-Mac permission/download/practice run and publication remain pending. Do not change public download links until the final artifact is published and verified.

## Signing

Use a Developer ID Application certificate from the Apple Developer account. Preserve its private key securely outside Git. The creator uses a dedicated, automatically locking signing keychain; the signing tool is its only allowed application. Builds temporarily make that keychain searchable, then restore the search list and lock it. No default-keychain or certificate-trust change is required.

Compile the Swift executable and native worker first. Package into a separate candidate path:

```bash
CODE_SIGN_IDENTITY='<certificate SHA-1>' python3 Scripts/package_app.py \
  '/path/to/Local Dictation.app' \
  '.build-native/swift/release/LocalDictation' '.build-native/whisper-worker' \
  --runtime '/path/to/existing/runtime' \
  --developer-id --team-id '<Apple Team ID>' --keychain '/path/to/signing.keychain-db'
```

The keychain must be unlocked for signing. Unset `CODE_SIGN_REQUIREMENT` for this mode: Apple generates a designated requirement that ties the app to its Developer ID policy, bundle ID, and team. Keeping that requirement supports certificate renewal. The packager verifies the expected team and Apple Developer ID policy for the app and both helpers. It enables hardened runtime and secure timestamps for all three, and grants only the main app's microphone entitlement. It rejects an ad-hoc identity, weak publisher requirements, missing timestamps, or the wrong team.

Local ad-hoc and creator self-signed workflows retain their existing behavior. The first transition from those identities may require new macOS privacy approvals. Signing does not remove the need for Microphone, Accessibility, and Input Monitoring.

## Notarization

The account owner creates an app-specific password in [Apple Account](https://account.apple.com/) under Sign-In and Security → App-Specific Passwords. Store it through the hidden Terminal prompt, never in a command argument, source file, or chat:

```bash
xcrun notarytool store-credentials LocalDictationNotary \
  --apple-id '<Apple account email>' --team-id '<Apple Team ID>'
```

Use the stored profile to submit the signed app. Evidence lives outside the bundle and public release directory:

```bash
python3 Scripts/notarize.py '/path/to/Local Dictation.app' \
  --evidence '/path/to/private/app-notarization-evidence' \
  --keychain-profile LocalDictationNotary --team-id '<Apple Team ID>'
```

The tool creates a ZIP, preserves its digest and Apple's submission ID, waits for an explicit Accepted status, reviews Apple's log, staples the ticket, and verifies Gatekeeper. A pending upload can be resumed with the same command. Changed signed content requires a new evidence directory; it cannot reuse an earlier submission. No credentials are accepted by this script, and no release is published automatically.

After the app ticket and Gatekeeper checks pass, package its stapled bytes:

```bash
python3 -m venv .build-native/dmg-tools
.build-native/dmg-tools/bin/python -m pip install -r Scripts/dmg-requirements.txt
.build-native/dmg-tools/bin/python Scripts/make-release.py '/path/to/Local Dictation.app' \
  '/path/to/empty/release-directory' --tag v2.1.0 \
  --notarized-app --team-id '<Apple Team ID>'
```

This verifies the notarized app before packaging, requires the bundled app icon, and creates the standard drag-to-Applications Finder layout. The build-only packages and artwork regeneration are documented in [DEVELOPMENT.md](DEVELOPMENT.md). It uses opening guidance for the trusted app. The manifest explicitly records that the disk image's own notarization is pending. Sign the resulting DMG with the same Developer ID identity and a secure timestamp, then invoke `Scripts/notarize.py` on that DMG with a separate evidence directory. Disk images do not need executable hardened-runtime flags.

Signing and stapling change the DMG bytes. Recompute the DMG asset size and SHA-256 in `release-manifest.json`, mark disk-image notarization Accepted only after ticket/Gatekeeper checks, and regenerate all `SHA256SUMS` entries from the final files. Verify the app installed from that final DMG, permissions, model download or reuse, shortcut detection, practice, and external insertion. A fixture render does not establish fresh-Mac readiness.

Before publication verify the source commit, CI, clean release tree, final signatures, both tickets, manifest/checksum consistency, and installation behavior. After publishing verify GitHub's release is public and the downloaded asset matches the local digest. Update the website and stable documentation only then.

Apple's [notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) documents submission, app-specific authentication, ticket stapling, and log review.
