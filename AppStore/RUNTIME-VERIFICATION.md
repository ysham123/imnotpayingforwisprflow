# Store runtime verification

Build 18 uses source-rebuilt helpers. These checks support internal testing; they do not establish public release readiness or App Review acceptance.

## Source and license coverage

- Whisper 1.8.3 archive matches SHA-256 `870ba21409cdf66697dc4db15ebdb13bc67037d76c7cc63756c81471d8f1731a`.
- Ollama 0.9.6 is pinned to revision `43107b15b9bcff51ef1c5391c273fd1a747f6d0a`; its source archive matches the checked-in digest.
- The official Go 1.24.5 Apple Silicon archive matches its published SHA-256. The toolchain is extracted into a private build directory and is not installed globally.
- `go mod verify` passed after compilation. The 47 dependencies in the rebuilt executable's Go build information all match exact-version entries in `Licenses/ThirdParty/Ollama/inventory.json`.
- The build records the local speech worker's source hash, each helper's binary hash, Mach-O UUIDs, source pins, and Xcode version in an uncommitted `provenance.json`. Release embedding checks those hashes before signing.

## Crash symbols and signing

Whisper is compiled with optimization and source debug information. Its worker object remains available until `dsymutil` finishes. Go's external linker already merges Go and native DWARF into its executable and removes the debug map. Building with uncompressed DWARF allows `dsymutil --update` to read that actual information into a standalone dSYM. No empty UUID-only symbol files are used.

Both helpers have matching arm64 UUIDs and actual debug information for the worker source or Ollama's `main.main`. `archive-store.sh` puts both dSYMs in the archive's `dSYMs` directory. Xcode's normal target symbol generation covers the Swift app and framework.

Build 18 passed managed Apple Development archive signing and Store export. The exported app uses the registered team's Apple Distribution identity; the PKG uses its Apple-issued Mac installer identity. The exported artifact passed sandbox, helper inheritance/team, profile, signature, code location, and cross-app input API checks. This is a local result, not evidence of an accepted upload.

## Runtime checks

The source-rebuilt Whisper worker transcribed the owned synthesized phrase, and the source-rebuilt Ollama helper cleaned it inside the development app sandbox. Models were preseeded and verified; no microphone was recorded. The first cold cleanup warmup exceeded its 20-second request budget while the model loaded. A second run passed. The product's setup already makes bounded recoverable warmup retries and retains original text if cleanup is unavailable.

Seven transport checks passed against small public HTTPS fixture data: cancellation before start, cancellation after transfer began without publication, verified retry, subsequent offline reuse, wrong-digest rejection, HTTP-source rejection, and oversized-response rejection. Those tests run outside the sandbox. A separate tiny public HTTPS/digest test previously passed inside the sandbox. Neither proves fresh-container full-model setup.

## Privacy and remaining audit

Compiled helper imports include file metadata APIs and timing APIs. The root app manifest declares own-container file metadata, elapsed-time measurements, low-space checks, and app-only preferences. The cleanup helper receives an explicit loopback address and container model path. This static inspection does not establish every reachable Go/native call path or complete the privacy review.

The Go binary includes TLS and other cryptography; export compliance must not be described as exclusively Apple operating-system encryption. The source version pins also need a dependency security review before public distribution. Physical microphone behavior, permission denial/recovery, first-run full downloads, editor compatibility, focus changes during Services, sleep/wake, memory pressure, Apple's build processing, and App Review remain separate release gates.
