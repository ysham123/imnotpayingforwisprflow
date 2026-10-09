# Local signing investigation

2026-10-09. This is an optional local-build route for the creator's own Mac, not
the signing policy for public releases. The scoped trust entry is **approved
and applied**, and the signed 2.0.1 build 11 is installed. **Permission retention
after one unchanged-build restart is verified; retention across a later signed
build update has not been tested.**

The previous 2.0.1 build 11 was validly ad-hoc signed. Its designated requirement
pinned its code hash. The bounded readiness log shows missing grants after the
2.0.0 and 2.0.1 replacements, while seven recorded unchanged 1.3.0 relaunches
after completed setup retained all grants. This supports an update-identity
cause for the earlier missing grants.
The signature migration changes the previous identity once: macOS still
matched the old `8294378...` code-hash requirement for Accessibility, while the
new app carries the exact certificate-and-identifier requirement. Input
Monitoring worked after its stale entry was replaced and the app relaunched.
Accessibility was then added again for the signed app. The bounded readiness
record now shows all three permissions and an active listener for this
certificate-signed build. After setup, one quit-and-reopen launched a new
process with all three permissions and the listener still active. This verifies
ordinary restart behavior for build 11; a later signed build update still needs
its own continuity check.

Use this read-only report without reinstalling:

```sh
python3 Scripts/diagnose-permissions.py
```

The report reads only code-signing metadata and the app's bounded readiness log.
It distinguishes listener failures from missing grants and reports historical
observations. It does not probe current permissions, read the TCC database,
launch apps, or reset anything.

## Prepared local identity

`Scripts/local-signing.py prepare` creates an RSA 3072-bit certificate with only
the digital-signature key usage and code-signing extended key usage. It puts the
identity in a separate keychain under the current user's Application Support
folder, outside Git. The directory is mode 0700 and its files are mode 0600.
The plaintext temporary key and encrypted import archive are removed after a
successful import. The keychain locks after import, on sleep, and after five
minutes. Its access list names `/usr/bin/codesign`; the default keychain is not
changed and the prior search list is restored.

The prepared certificate's SHA-256 fingerprint is:

```text
424F911736B76983877C7C18077DFBF907B863D0979DAE373E16012020EE0BF9
```

Preparation does not modify trust. The separately approved trust entry is restricted to
the current user, the code-signing policy, and `/usr/bin/codesign`. It allows
that tool to accept signatures from this local key. It does not grant
Microphone, Accessibility, Input Monitoring, or TLS trust. The user approved
that exact change after an explanation; it was then applied successfully.
Readback through Apple's Security API verified one user-level CodeSigning
rule whose application constraint matches `/usr/bin/codesign`.

The four disposable signing groups passed. The installed copy matches all 74
files of the verified candidate; its previous ad-hoc copy is preserved under
`release-assets/v2.0.1-before-local-signing/`. Installation used an atomic
`RENAME_SWAP` and preserved the candidate's signature. See
[signing verification](benchmarks/v2.0.1/local-signing-verification.json) and
[installation](benchmarks/v2.0.1/local-signing-installation.json).

Signing temporarily adds the private keychain to the search list because
`codesign --keychain` limits identity lookup but still uses the search list to
construct the certificate chain. The wrapper locks the keychain and removes
that temporary entry afterward, preserving other search-list entries. The
default keychain and the certificate trust constraints are unchanged.

## Verification status

1. The reviewed certificate-specific user trust entry is applied.
2. `python3 Tests/LocalSigningIdentitySmoke.py` compiled two disposable
   apps and checks common identity despite changed code, wrong-identifier
   rejection, ad-hoc impersonation rejection, and sealed-resource tampering.
   All four fixture groups passed. These fixtures are not launched and did
   not request TCC grants.
3. `Scripts/local-signing.py sign SOURCE DEST` created a separate candidate.
   Signing uses an exact certificate-leaf hash plus each executable's bundle
   identifier. The script refuses to replace existing apps or sign directly
   into Applications. It does not reset access or install the candidate.
4. The verified candidate is installed. One quit-and-reopen preserved all
   three permissions. Test a changed signed build before claiming update
   continuity.

## Future local updates

Keep the tested private identity. Package the new build into a separate staging
directory, then create its final candidate using:

```sh
python3 Scripts/local-signing.py sign /path/to/staged/Local\ Dictation.app /path/to/new/Local\ Dictation.app
```

Install only the final signed candidate. Replacing this installed app with an
ad-hoc release creates another identity change and can require fresh grants.
The packaging tool already refuses an ad-hoc downgrade when building directly
over a certificate-signed installation. Do not regenerate the local certificate
or substitute an identifier-only signing requirement.

Preserve an adopted private keychain and password file. Recreating them would
create another identity transition. Never commit or distribute them. Removing
the certificate-specific trust entry reverses the trust change; replacing a
signed app with its ad-hoc backup can itself require renewed permissions.

Apple explains designated requirements, self-signed identities, and the fact
that each subsystem sets its own trust policy in
[TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).
Passing a signature test alone does not prove TCC continuity.
