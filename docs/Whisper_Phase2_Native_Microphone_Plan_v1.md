# Whisper Phase 2 Native Microphone Plan v1

Date: 2026-07-17

## BLUF

Phase 2 moves microphone capture from WKWebView MediaRecorder to Swift AVAudioEngine,
while keeping transcription in the packaged Python Worker. The phase has six
checkpoints and closes only when long recording, chunk ordering, device recovery,
and transcription quality reach the legacy app baseline.

## Checkpoints

1. Audio domain state machine and 16 kHz mono PCM/WAV writer.
2. Microphone permission mapping and AVAudioEngine capture service.
3. Standard-mode recording, stop/finalize, and file transcription handoff.
4. Live-mode timed chunk rotation and ordered Worker submission.
5. Device change, interruption, failure recovery, and orphan-file cleanup.
6. Long-recording comparison, Gate D microphone subset, and Phase 2 closure.

## Guardrails

- Swift owns microphone permission, capture, recording state, and recovery files.
- Python Worker receives only finalized absolute file paths.
- Audio format is 16 kHz, mono, signed PCM Int16 WAV at the Worker boundary.
- A recording file is never deleted until transcription reaches a terminal state.
- Phase 2 does not include ScreenCaptureKit or mixed audio; those remain Phase 3.
- The legacy pywebview app remains the production fallback through Gate D.
