# WhisperApp Phase 1 Shell

Open this directory in Xcode or run:

```bash
swift test
swift run WhisperApp
```

Checkpoint 1 establishes the SwiftUI shell and a `WorkerSupervisor` vertical
slice for Python Worker startup, JSONL `ready`, `ping`/`pong`, and shutdown.

Checkpoint 2 adds audio file selection, model selection, `transcribe` and
`cancel` commands, progress state, and completed transcript rendering.

Checkpoint 3 adds stderr diagnostics, unexpected-exit detection, and up to two
automatic Worker restart attempts.

Checkpoint 4 has a reusable real-model harness at
`scripts/phase1_real_worker_smoke.py` for completed and cancelled terminal-event
verification against the production Python Worker.

Checkpoint 5 packages a standalone `WhisperWorker` runtime with Python,
faster-whisper, and ffmpeg. Frozen inference uses the same bundled executable's
`--inference-child` mode, preserving hard cancellation without system Python.
Models download to the user cache on first use instead of inflating the app.
