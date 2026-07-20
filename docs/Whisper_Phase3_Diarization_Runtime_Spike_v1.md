# Whisper Phase 3 Diarization Bundled-Runtime Spike v1

Date: 2026-07-18
Decision: **FAIL — feature remains disabled**

## BLUF

The packaged Python Worker cannot run the existing `pyannote.audio`
diarization implementation. The Worker bundle deliberately excludes `torch`,
and bundle analysis confirms that neither `torch` nor `pyannote.audio` is
included. The legacy implementation launches `/usr/bin/python3`, which violates
the SwiftUI acceptance criterion prohibiting arbitrary system Python.

No diarization execution path was added to the SwiftUI app. Instead, protocol
version 1 now exposes a `capabilities` command. Both source and packaged Worker
return `available: false`, code `BUNDLED_RUNTIME_UNAVAILABLE`, with an actionable
message shown in SwiftUI.

## Evidence

- `worker.spec` excludes `torch` and the bundle-dependency guard rejects
  packaged `pyannote.audio` or `torch`.
- Rebuilt runtime: `dist/WhisperWorker`, 166 MB.
- `ci/check_bundle_deps.py build/worker/xref-worker.html`: PASS; neither
  dependency is packaged.
- Direct packaged JSONL request returned a structured `capabilities` event with
  diarization unavailable.
- Python protocol/runtime suites: 32/32 passed.
- Swift suite: 77/77 passed before the packaged rebuild.

## Revisit criteria

Reopen only with an explicitly approved bundled diarization runtime design that
includes dependency size, model licensing/download, offline behavior, code
signing, cancellation, and clean-machine evidence. Do not restore the legacy
`/usr/bin/python3` subprocess from the SwiftUI app.
