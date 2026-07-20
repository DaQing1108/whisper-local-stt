# Whisper Phase 4 Gate E Readiness Report v1

Date: 2026-07-18  
Scope: SwiftUI shell plus bundled Python Worker, Phase 3–4 checkpoints 1–10  
Decision: **NOT READY for production replacement**

## BLUF

The implementation and locally automatable checkpoints are complete. The
packaged Worker now completes a real `tiny` transcription under isolated
`HOME`, `HF_HOME`, minimal `PATH`, and a newly downloaded 89 MB model cache.
The legacy pywebview application remains installed and independently
addressable, while the SwiftUI application uses a distinct bundle identifier
and data namespace.

Gate E cannot pass on this machine. There is no Apple Developer ID Application
identity or notarization profile, no configured signed Sparkle feed/public key,
and no separate clean Apple Silicon Mac. Consequently Developer ID signing,
notarization/stapling, Gatekeeper acceptance, real signed Sparkle update and
rollback, and physical clean-machine validation remain unexecuted external
evidence. The SwiftUI app must not replace the production app.

## Checkpoint 9 — isolated first-run evidence

The smoke used the packaged executable, not a source Python environment:

```text
HOME=/tmp/whisper-clean-home.1krKzX/home
HF_HOME=/tmp/whisper-clean-home.1krKzX/huggingface
PATH=/usr/bin:/bin
Worker=dist/WhisperWorker/WhisperWorker
Audio=/tmp/whisper-clean-home.1krKzX/first-run.wav
Model=tiny
```

Observed evidence:

- the first attempt populated a fresh 89 MB
  `models--Systran--faster-whisper-tiny` cache;
- a repeatable smoke exited `0` in 3.4 seconds using that isolated cache;
- protocol sequence was `ready → accepted → progress → status → completed`;
- completed payload returned Chinese text, language `zh`, duration `2.1465`,
  and a segment from `0.0` to `2.24` seconds;
- the smoke script reported `PASS: real Worker reached completed with
  model=tiny`.

This proves isolated first-model acquisition/cache plus packaged inference on
the current machine. It does **not** prove installation on a physically clean
Mac and is not presented as such.

## Checkpoint 10 — migration and rollback boundary

No production replacement or destructive migration was performed. Local
coexistence checks passed:

| Artifact | Bundle identifier | Result |
|---|---|---|
| `/Applications/Whisper STT.app` | `com.via.whisper-ai` | Legacy fallback remains installed; deep strict signature verification passed |
| `~/Applications/Whisper SwiftUI.app` | `com.via.whisper-swiftui` | Separate candidate remains installed; deep strict signature verification passed |
| `dist/Whisper SwiftUI.app` | `com.via.whisper-swiftui` | Separate build artifact; deep strict signature verification passed |

The legacy `app.py`, `gui.py`, `routes.py`, and `whisper_core.py` entrypoints
also pass `python3 -m py_compile`. SwiftUI preferences use its own bundle ID and
history is stored under `Application Support/WhisperSwiftUI`; no legacy settings
or credentials are silently imported. This makes fallback possible without a
data migration, but it is not a substitute for a real update rollback test.

Rollback policy until Gate E passes:

1. Do not overwrite or remove `/Applications/Whisper STT.app`.
2. Keep the SwiftUI candidate under its distinct app name and bundle ID.
3. If candidate validation fails, quit it and launch the existing legacy app;
   do not copy SwiftUI history/settings into the legacy data store.
4. Preserve recovery WAV files and transcription history for manual export.
5. Test signed Sparkle rollback only after two notarized versions and a signed
   appcast exist on an HTTPS release channel.

## Locked acceptance-criteria mapping

| AC | Local result | Gate interpretation |
|---|---|---|
| AC-1 microphone standard/live, long recording, ordering, device recovery | Implemented and automated tests passed; repeated real device-change evidence collected during Phase 2 | Locally complete; clean-machine permission path remains part of external matrix |
| AC-2 system/mixed audio, settings/history, Obsidian/Notion, diarization, Sparkle/UI parity | Implemented; diarization and updater fail closed when runtime/release prerequisites are absent | Feature code complete; real TCC, private Notion append, and signed Sparkle evidence remain external |
| AC-3 Developer ID, Hardened Runtime, notarization/stapling, clean Mac, first download, update/rollback | Release pipeline and isolated first-download smoke complete | **FAIL/BLOCKED**: required external release evidence is missing |
| AC-4 no Homebrew/arbitrary system Python; JSONL-only stdout | Bundled Worker verification and real packaged transcription passed | Pass locally |
| AC-5 cancellation/crash/recovery/terminal-state safety | Automated Worker and Swift tests passed | Pass locally |
| AC-6 no production replacement before Phase 4 gates | Legacy app remains installed and distinct | Pass; replacement remains prohibited |

## External evidence still required

1. Developer ID Application signing with a valid Team ID.
2. Hardened Runtime execution of the final signed nested Worker and outer app.
3. Apple notarization acceptance, ticket stapling, and offline stapler validation.
4. `spctl` Gatekeeper acceptance of the distributed artifact.
5. Installation and first-run test on a separate clean Apple Silicon Mac,
   including microphone and Screen Recording Transparency, Consent, and Control
   (TCC) prompts.
6. Real private Notion destination append with credential redaction.
7. Two notarized releases, HTTPS appcast, EdDSA key, successful Sparkle update,
   failed-update recovery, and rollback evidence.

## Final decision

Phase 3–4 implementation checkpoints are exhausted within the authorized local
scope, but Locked AC-3 is not satisfied. Gate E is **NOT READY**, the SwiftUI
candidate is **not deliverable as a production replacement**, and the legacy
pywebview app remains the production fallback. No commit, stage, push, merge,
external publish, or production replacement was performed.
