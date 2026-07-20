# Whisper Phase 3–4 Execution Plan v1

Date: 2026-07-18
Risk: L3 (user-facing capture, external integrations, signing and release)

## BLUF

Complete the SwiftUI + bundled Python Worker path without replacing the legacy
production app until all applicable gates pass. Work remains uncommitted and
must preserve the existing dirty worktree. App Store, App Sandbox, Universal
Binary, and a full Swift inference rewrite remain out of scope.

## Locked acceptance criteria

1. System audio and mixed audio produce finalized 16 kHz mono Int16 WAV files
   before the Worker receives an absolute path.
2. Settings, history, Obsidian/Notion destinations, diarization, update UX, and
   core interaction parity are reachable from the SwiftUI entrypoint.
3. JSONL stdout remains protocol-only; no binary audio or diagnostics are sent
   through stdout.
4. Capture/runtime/write failures cannot be reported as successful recordings,
   and stale callbacks/errors cannot contaminate a new generation.
5. The SwiftUI app does not depend on Homebrew or an arbitrary system Python.
6. Release readiness requires Developer ID, Hardened Runtime, notarization,
   stapling, clean Apple Silicon Mac, first-model download, update, and rollback
   evidence. Missing external credentials or hardware are reported, not inferred.

## Checkpoints

1. System-audio code path and Worker handoff — implemented; automated gate
   passed, packaged real TCC/capture evidence remains external.
2. Mixed-audio capture orchestration and ordered WAV/Worker handoff —
   implemented; 2026-07-18 independent review approved.
3. Settings persistence and transcription history — implemented; local
   UserDefaults plus atomic JSON history, 69/69 Swift tests and independent
   review approved on 2026-07-18.
4. Obsidian local-file integration with path validation and atomic writes —
   implemented for the scoped non-sandbox Developer ID app; canonical root,
   symlink rejection, 72/72 Swift tests, independent review approved on
   2026-07-18. No real user Vault was modified during automated verification.
5. Notion integration with explicit credential handling and failure reporting —
   implemented with Keychain token storage, API 2026-03-11, single-request
   preflight, and persistent ambiguous-outcome lock; 77/77 Swift tests and
   independent security review approved on 2026-07-18. Real private-account
   append evidence remains external and was not attempted automatically.
6. Diarization runtime spike — completed with FAIL decision on 2026-07-18.
   Packaged Worker capability and bundle analysis prove `torch`/`pyannote.audio`
   are absent; feature remains disabled and the legacy `/usr/bin/python3` route
   was not copied. See `Whisper_Phase3_Diarization_Runtime_Spike_v1.md`.
7. Sparkle/update UI and core SwiftUI interaction parity — Phase 3 seam
   completed on 2026-07-18. Update UI is reachable and fail-closed unless an
   HTTPS `SUFeedURL`, EdDSA `SUPublicEDKey`, and Sparkle framework are present.
   The 2.9.2 binary artifact fetch stalled at 0 B, so no dependency or fake
   release metadata was retained. 79/79 Swift tests, production bundle build,
   local signature verification, and independent review passed. Signed appcast
   update/rollback remains Phase 4 evidence.
8. Developer ID, Hardened Runtime, notarization, and stapling pipeline — code,
   fail-closed preflight, local structural evidence, and independent review
   completed on 2026-07-18. Formal evidence is blocked by missing Developer ID
   Application identity and notarization Keychain profile. See
   `Whisper_Phase4_Checkpoint8_Release_Hardening_Report_v1.md`.
9. Clean-machine and first-model-download validation — same-machine isolated
   `HOME`/`HF_HOME` first-model download and packaged Worker transcription
   passed on 2026-07-18. A separate clean Apple Silicon Mac remains external
   release evidence and is not inferred from this smoke.
10. Sparkle update, rollback, migration, full AC mapping, and Gate report —
    local coexistence/fallback and AC mapping completed on 2026-07-18. A real
    signed Sparkle update/rollback is blocked by the same missing Developer ID,
    feed/key, published artifacts, and external clean Mac. Gate E is therefore
    `NOT READY`; see `Whisper_Phase4_Gate_E_Readiness_Report_v1.md`.

## Verification boundary

Automatically verifiable: unit/integration tests, Python Worker protocol,
production build, bundle contents, code-signature structure, local smoke tests,
failure/recovery invariants, and artifact read-back.

External verification: real Screen Recording TCC audio, private Notion account,
Developer ID/notarization credentials, a separate clean Apple Silicon Mac, and
real Sparkle update/rollback between signed published artifacts.

## Rollback and stop conditions

- No commit, stage, push, merge, production replacement, or external publish.
- Preserve recovery WAV files and the legacy production fallback.
- Stop a checkpoint after three repeated failures or when an L4 credential,
  hardware, or irreversible external action is required.
