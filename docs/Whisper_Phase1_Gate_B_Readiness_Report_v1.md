# Whisper Phase 1 Gate B Readiness Report v1

Date: 2026-07-17

## BLUF

Phase 1 establishes a SwiftUI shell and a standalone bundled Python Worker. Gate B
requires a locally signed `.app`, deep signature verification, isolated-environment
Worker startup, real development-mode transcription/cancellation, and packaged
cancellation. Apple notarization and first-model download on a physically clean Mac
remain external release checks.

## Gate B criteria

- SwiftUI App discovers the Worker under `Contents/Resources/WhisperWorker`.
- App bundle contains Python runtime, faster-whisper, CTranslate2, ONNX Runtime,
  Silero VAD assets, and ffmpeg.
- Frozen inference self-spawns with `--inference-child`; it does not probe system Python.
- Local ad-hoc signing and `codesign --verify --deep --strict` pass.
- Bundled Worker emits `ready` with an isolated HOME and minimal PATH.
- Development Worker completes a real Traditional Chinese tiny-model transcription.
- Development and packaged Worker cancellation reach `cancelled`.

## External release exceptions

- Developer ID Application signing is unavailable without the owner's certificate.
- Apple notarization and stapling require Apple credentials and network access.
- A physical clean Mac must still validate first-run model download and user-facing
  recovery for offline/download failure.
- Frozen CPU tiny-model completion exceeded the 120-second architecture smoke window;
  performance optimization or a packaged MLX strategy is required before production.

## Local execution result

- Release Swift executable build: PASS.
- `.app` assembly with bundled 166 MB Worker: PASS.
- Swift App Resources Worker discovery: PASS (6 Swift tests).
- Isolated `HOME` and minimal `PATH` bundled Worker startup: PASS (`ready`).
- Outer `.app` ad-hoc signing: PASS. Verbose diagnosis identified an invisible
  `com.apple.FinderInfo` bundle bit automatically maintained on `.app` directories.
  Signing under a temporary non-`.app` staging name, then renaming to `.app`, preserves
  the valid code seal; `codesign --verify --deep --strict` succeeds after the rename.

## Gate decision

**PASS WITH RELEASE EXCEPTIONS.** Architecture, local bundle, ad-hoc signing, strict
signature verification, and isolated startup are complete. Production release remains
conditional on Developer ID signing/notarization, physical clean-Mac model download,
and resolving frozen CPU inference performance.
