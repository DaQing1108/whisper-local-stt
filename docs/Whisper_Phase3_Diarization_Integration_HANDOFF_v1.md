# HANDOFF — Whisper Swift Speaker Diarization Integration

**Handoff date:** 2026-07-22
**From:** Claude Code session (this conversation)
**To:** A fresh Claude Code session/account picking this up cold
**Branch:** `whisper-swift` (this is the active development branch; `main` = Whisper Classic, frozen)
**Starting commit:** `6a2a54e` (`docs: record passing real-recording diarization quality check`)
**Repo:** `whisper-local-stt` — this worktree lives at `.worktrees/swiftui-python-poc` off the main repo checkout

---

## Read this first, in this order

1. `CLAUDE.md` (this worktree's root) — technical invariants, especially the PyInstaller/torch constraint and the Gatekeeper/iCloud diagnostic tree
2. `docs/Whisper_Phase3_Diarization_Runtime_Spike_v1.md` (2026-07-18) — **why the subprocess approach was rejected.** Do not re-propose `/usr/bin/python3` subprocess for diarization; it violates AC-4 ("no Homebrew/arbitrary system Python", see `docs/Whisper_Phase4_Gate_E_Readiness_Report_v1.md`).
3. `docs/Whisper_Phase3_Diarization_ONNX_Runtime_Spike_v2.md` (2026-07-22) — the sherpa-onnx direction that replaced it, including the real download/model-loading verification and the real-recording quality check the user confirmed correct.
4. `diarization_model_runtime.py` + `tests/unit/test_diarization_model_runtime.py` (commit `b69fe3e`) — already implemented and merged. Read this before writing any new download/cache code; do not duplicate it.

## BLUF

Whisper Swift's PRD claims Goal G3 ("功能 parity 與 Classic 等價") is complete, but Speaker Diarization is currently hardcoded disabled in `worker_entrypoint.py`. Two blocking research questions have already been answered with real evidence (not assumptions):

- **Can this be bundled without violating AC-4 or the torch-packaging constraint?** Yes — `sherpa-onnx` (ONNX Runtime, no torch) packages cleanly with PyInstaller (verified: 41MB, no torch leakage) and needs no system Python subprocess.
- **Is the diarization quality actually usable?** Yes — tested against a real ~34s two-speaker recording the user provided; 2 speakers detected with a correct transition at 19.12s, user-confirmed accurate. This is the "user-verified accuracy" bar per this project's CLAUDE.md (transcription/diarization accuracy is explicitly not Claude-automatable — it already got a real yes/no from the actual product owner).

What remains is **integration work**, not further research: wire the already-working `DiarizationModelManager` and a new `sherpa_onnx`-based diarization call into the Worker's JSONL protocol, expose it in SwiftUI, and verify nothing regresses.

## What NOT to do (already tried / already rejected)

- Do NOT use `/usr/bin/python3` subprocess for diarization in the SwiftUI app's Worker. Tried, rejected 2026-07-18 (AC-4 violation).
- Do NOT try to bundle `torch`/`pyannote.audio` directly into the PyInstaller Worker. This is the same packaging failure Classic already hit (CLAUDE.md technical constraint #4).
- Do NOT modify `_start_transcription`, `TranscriptionService`, or `TranscriptionRequest` to add diarization inline. The design below deliberately keeps diarization as a separate, independently-triggered command so the existing transcription path (P0/P1/P2, already APPROVE'd) is provably untouched.
- Do NOT treat diarization quality as something you can self-certify past the usability bar already confirmed. If you change the embedding/segmentation model or clustering parameters, that resets the "user-verified" status and needs a fresh confirmation from the user with real audio — you cannot approve that yourself.

---

## The execution spec

**Risk level:** L2
**ESAEV entry point:** Approve → Execute (this spec has been through spec-writer's two-round diagnosis and quality review; the one open item below has been resolved by the handing-off session)

### Problem background & goal

PRD Goal G3 claims parity is complete; Diarization is the gap. Completing this closes that gap for real, not just in the document.

**Target end-state:** a user can trigger Speaker Diarization on a completed transcription; resulting segments carry `speaker` labels (Speaker A/B/...); `capabilities` reports diarization availability based on real model-cache state, not a hardcoded `false`.

**Explicitly not this task's goal:** Timeline UI, recording playback/proofreading (separate PRD candidates), Gate E/notarization work, or improving diarization quality beyond the already-confirmed usability bar.

### Scope

**Allowed to modify:**
- `worker_entrypoint.py`:
  - `capabilities` command: replace the hardcoded `{"available": False, ...}` diarization block with a call to `DiarizationModelManager().status()`
  - new `diarization_warmup` command: calls `DiarizationModelManager().warmup()`, following the exact `WORKER_BUSY` rejection pattern already used by `_warmup_model` (reject if `self._registry.active_count`)
  - new `diarize` command: takes `audio_path` + the `segments` array already produced by a prior `transcribe` call, runs `sherpa_onnx.OfflineSpeakerDiarization` (models from `DiarizationModelManager`), merges speaker labels into the segments by time overlap, returns the augmented segments
- new `diarization_service.py` (or similarly-scoped module): wraps the `sherpa_onnx.OfflineSpeakerDiarization` construction (see the config shape verified in the spike: `OfflineSpeakerDiarizationConfig` / `OfflineSpeakerSegmentationModelConfig` with a `pyannote=OfflineSpeakerSegmentationPyannoteModelConfig(model=...)` / `SpeakerEmbeddingExtractorConfig` / `FastClusteringConfig`) and the segment-merge-by-overlap logic
- `macos/WhisperApp/Sources/WhisperApp/WorkerSupervisor.swift`: add sending/handling for the new `diarize`/`diarization_warmup` commands and their events. Note: the existing capabilities-parsing code (`diarizationAvailable`/`diarizationCapabilityMessage`, reads `event.payload["diarization"]["available"]`/`["message"]`) is already generic and does **not** need to change — it will start reflecting real state automatically once the Python side stops hardcoding `false`.
- Minimal SwiftUI: a way for the user to trigger diarization on a completed transcript (explicit button, not an automatic toggle — see rationale below), and rendering of `speaker` labels against transcript segments
- Matching tests in `tests/unit/` and `macos/WhisperApp/Tests/WhisperAppTests/`
- Dependency manifest (`requirements.txt` or equivalent) to add `sherpa-onnx`, `soundfile`, `librosa`
- `worker.spec`/`gui.spec` if the bundle-exclusion list needs a note that these three are intentionally included (unlike torch/pyannote)

**Forbidden to modify:**
- `_start_transcription`, `TranscriptionService`, `TranscriptionRequest` internals or the `transcribe` command's existing payload/response shape
- Any P0/P1/P2 already-APPROVE'd feature logic (History, Vocabulary, Notion/Obsidian, AI summary)
- Existing JSONL protocol command/event field semantics (additive only)
- Bundle ID, code-signing identity

**Needs explicit human approval before proceeding if encountered:**
- Any new external dependency beyond `sherpa-onnx`/`soundfile`/`librosa`
- Any change to `_start_transcription`'s behavior (should not be needed — if you find yourself wanting to touch it, stop and ask, the design above was deliberately chosen to avoid this)

### Why diarization is a separate `diarize` command, not part of `transcribe`

The 2026-07-22 spike measured sherpa-onnx diarization at roughly **0.4x realtime** (13.3s to process 33.8s of audio). For a 2-hour meeting that's ~47 minutes. Blocking the existing `transcribe` completion on that would be a serious regression for every user of the app, diarization or not. Keeping it as a separate, user-triggered follow-up command means:
- `transcribe` behavior and timing are provably unchanged (trivially satisfies the "no regression to existing transcription flow" requirement)
- The user sees their transcript immediately and opts into the slower diarization pass only when they want it
- If diarization fails or the models aren't downloaded yet, the transcript itself is never at risk

Do not "optimize" this into a single combined call without re-confirming this tradeoff with the user first — it was a deliberate design decision, not an oversight.

### System constraints

- `diarize` and `diarization_warmup` must both reject with `WORKER_BUSY` when `self._registry.active_count` is non-zero (same guard as existing `warmup_model`)
- Model download (~44MB total) requires network; `diarize` called before models are cached should fail clearly (`MODEL_NOT_READY` or similar code) so the UI can prompt the user to run warmup first
- Diarization failure (corrupt model, sherpa_onnx exception) must degrade gracefully: emit a `failed` event, leave the existing plain transcript fully intact and usable
- No new auth/token requirements — model downloads are unauthenticated public GitHub Release assets (already verified, see spike v2)

### Acceptance criteria

**Positive (must pass):**
- [ ] `capabilities` reports `diarization.available` based on real `DiarizationModelManager.status()`, not a hardcoded value
- [ ] `diarization_warmup` triggers a real download; `capabilities` reflects `available: true` afterward
- [ ] Running `diarize` against the same real recording used in the 2026-07-22 spike still produces a 2-speaker result with the transition near 19.12s (regression check against the already-confirmed-correct baseline — if this drifts, something in the integration broke the verified pipeline)
- [ ] SwiftUI surfaces speaker labels against the correct transcript segments after the user triggers diarization
- [ ] Bundle smoke test (clean env → launch app → call capabilities/diarization_warmup/diarize → verify responses → clean env) passes

**Negative (must not break):**
- [ ] Full existing suite still green: `make test` (281 passing as of this handoff, includes the 5 `DiarizationModelManager` tests) and `swift test` (108+ passing)
- [ ] Existing `transcribe` flow (timing, response shape, behavior) is unaffected when diarization is never triggered
- [ ] `ci/check_bundle_deps.py` shows no torch/pyannote leakage after adding the new dependencies

**Quality gates:**
- [ ] Unit + integration tests passing (Python + Swift)
- [ ] `ci/check_bundle_deps.py` clean

### Verification commands

```bash
# Python unit + integration tests
make test
make test-integration

# Swift tests
cd macos/WhisperApp && swift test

# Bundle dependency leakage check
python3 ci/check_bundle_deps.py <bundle analysis output path>

# Bundle smoke test (manual, per this project's CLAUDE.md discipline)
pkill -f "WhisperApp" 2>/dev/null; sleep 2
# launch .app -> call capabilities -> diarization_warmup -> diarize -> verify responses -> clean up
```

### Stop conditions — escalate to the user, do not push through

- Any need to modify code in the "forbidden" list above
- `ci/check_bundle_deps.py` flags torch/pyannote after adding the new dependencies
- Two consecutive failed attempts at the same test
- **Total Worker bundle size grows by more than 100MB from this change.** (This threshold was set by the handing-off session as a reasonable default, not confirmed by the user against a hard requirement — if you're near it, surface the actual number and ask before proceeding rather than assuming 100MB was rigorously chosen.)
- Re-running the spike's reference recording through the integrated pipeline gives a different (worse) result than the already-confirmed 2-speaker/19.12s-transition baseline — this means the integration introduced a regression in the verified pipeline, not that you should re-tune parameters until it looks right again

### Completion report format

When done, report:
1. Summary of changes (files touched, approach taken)
2. Verification evidence (actual output of the test commands above)
3. Scope confirmation (changes stayed within the allowed list)
4. Known residual risk (e.g., long-recording performance has only been measured on a 34s sample, not a real multi-hour meeting)
5. Anything left undone, and why

---

## Prior art / commit trail (for orientation, not required reading in full)

- `f5e6b7e` — initial ONNX runtime spike (sherpa-onnx packages cleanly, no torch)
- `2643311` — model-download design direction added to spike doc
- `b69fe3e` — `DiarizationModelManager` implemented + tested (real download + real model load verified)
- `6a2a54e` — real-recording quality check passed, user-confirmed

All of the above are already committed and pushed to `origin/whisper-swift`. This handoff document is being added on top as an uncommitted file — commit it yourself once you've reviewed it, or ask the user first if unsure.
