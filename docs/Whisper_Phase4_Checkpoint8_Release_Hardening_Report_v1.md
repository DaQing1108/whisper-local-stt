# Whisper Phase 4 Checkpoint 8 Release Hardening Report v1

Date: 2026-07-18
Status: **PIPELINE READY / EXTERNAL CREDENTIAL EVIDENCE BLOCKED**

## BLUF

The release pipeline now fails closed unless an installed `Developer ID
Application` identity and a notarization Keychain profile are explicitly
provided. It signs nested Mach-O code before the app, enables Hardened Runtime
and secure timestamping, verifies staging and final artifacts, submits with
`notarytool --wait`, staples, validates the ticket, and runs Gatekeeper.

This Mac has only the self-signed `WhisperSTT Local` identity. The current local
artifact has no Team ID and Gatekeeper rejects it. No notarization submission was
attempted and no release success is claimed.

## Automated evidence

- `release_swiftui_app.sh` syntax and 3/3 pipeline regression tests pass.
- Missing environment and a fabricated Developer ID both fail preflight with
  exit code 2.
- A temporary local-identity build verifies nested signatures and reports the
  Hardened Runtime flag, but has no Team ID and is rejected by `spctl`.
- The local-identity Worker stops during dynamic loading. This is not a release
  runtime result: PyInstaller documents that hardened runtime/library validation
  requires an Apple-issued identity with a Team ID and does not work with a
  self-signed certificate.
- Independent code/security review approved with no remaining Critical/High.

## External completion evidence required

1. Install the authorized Developer ID Application certificate.
2. Store authorized notarization credentials in a named Keychain profile.
3. Run the release script without `--preflight`.
4. Preserve the accepted notarization submission ID/log, stapler validation,
   Gatekeeper acceptance, and packaged Worker startup/capability smoke output.

Do not substitute `WhisperSTT Local`, ad-hoc signing, or a manually edited status
for these missing artifacts.
