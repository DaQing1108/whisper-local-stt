# Whisper Phase 3 Diarization ONNX Runtime Spike v2

Date: 2026-07-22
Supersedes revisit trigger from: `Whisper_Phase3_Diarization_Runtime_Spike_v1.md`
Decision: **PASS (partial) — direction viable, not yet ready for Execute**

## BLUF

v1 (2026-07-18) rejected bundled diarization because the only known implementation
(`pyannote.audio`) requires `torch`, which PyInstaller cannot package reliably, and
the only workaround (`/usr/bin/python3` subprocess) violates AC-4 (no Homebrew/
arbitrary system Python). This spike tested a third path: **`sherpa-onnx`**, a
maintained (k2-fsa) ONNX Runtime implementation of the pyannote diarization
pipeline that has no torch dependency at all. A minimal PyInstaller `--onedir`
build importing `sherpa_onnx` succeeded cleanly inside the bundled Worker's own
packaging model — no subprocess, no system Python, no torch.

This resolves the two constraints that killed v1. It does **not** yet constitute
an approved design: code signing, cancellation, and clean-machine evidence
(required by v1's revisit criteria) have not been tested, and diarization
*quality* relative to the original `pyannote.audio` pipeline is unverified.

## Evidence

- Isolated venv (Python 3.9): `pip install sherpa-onnx soundfile librosa pyinstaller`
  succeeded; `import torch` in the same venv fails with `ModuleNotFoundError`
  (confirms no transitive torch dependency).
- `pyinstaller --onedir --name diarize_spike test_import.py`, where
  `test_import.py` imports `sherpa_onnx` and constructs
  `OfflineSpeakerDiarizationConfig` / `OfflineSpeakerSegmentationModelConfig` /
  `SpeakerEmbeddingExtractorConfig` / `FastClusteringConfig` — build exit code 0,
  no torch/pyannote warnings in `warn-diarize_spike.txt`.
- Running the frozen executable (`dist/diarize_spike/diarize_spike`) printed the
  success marker and exited 0 — import and config construction work inside the
  frozen bundle, not just in source.
- Frozen bundle size: 41 MB (`du -sh dist/diarize_spike`); no `torch` files found
  under the output directory (`find dist/diarize_spike -iname "*torch*"` empty).
- Model licensing: `sherpa-onnx-pyannote-segmentation-3-0` (segmentation) and the
  speaker embedding extractor models are distributed as public GitHub Release
  assets under the `k2-fsa/sherpa-onnx` repo — no Hugging Face gated-model
  access or `HF_TOKEN` required, per official docs and Python API example
  (`python-api-examples/offline-speaker-diarization.py`).
- This spike ran in an isolated scratch venv, not inside the whisper-swift
  Worker's actual build; no repo source files were modified.

## Open items (blocking before this can become an execution spec)

1. **Offline/first-run behavior**: model files must be fetched (bundled at build
   time, or downloaded on first use like existing Whisper model downloads) —
   mechanism not yet designed.
2. **Diarization quality**: `sherpa-onnx`'s ONNX pipeline has not been compared
   against Classic's `pyannote.audio`-based output on any real recording. Per
   `docs/Whisper_Swift_PRD` guidance, the acceptance bar for this feature is a
   usability check (≥2 distinct speaker labels, no gross mislabeling on a real
   multi-speaker recording), not a quantified DER target — but even that bar is
   still unverified for `sherpa-onnx` specifically.
3. **Code signing** of the additional `sherpa_onnx` binary/shared libraries under
   the existing `WhisperSTT Local` identity — untested.
4. **Cancellation / crash-recovery** behavior when a diarization job is running
   inside the Worker — untested; must not regress AC-5 (existing cancellation
   guarantees).
5. **Clean-machine evidence** — untested on a machine without the dev venv.

## Item 1 design direction (resolved to a proposal, not yet implemented)

The bundled Worker already has a reusable shape for exactly this problem:
`model_runtime.py`'s `ModelRuntimeManager` (`status()` / `warmup()`, backed by
`huggingface_hub.scan_cache_dir()` / `snapshot_download()`), wired into
`worker_entrypoint.py` via the `model_status` / `warmup_model` JSONL commands.
faster-whisper models are cached this way today; diarization should follow the
same *shape* (status: cached/needs_download → warmup: trigger download →
re-check status), but cannot reuse `huggingface_hub` directly, because
`sherpa-onnx`'s segmentation/embedding models are GitHub Release assets, not a
Hugging Face repo ID.

Proposed direction: a parallel `DiarizationModelManager` that checks for the
two required ONNX files under an app-owned cache directory (e.g. alongside the
existing Application Support model cache convention) and downloads them from
their fixed GitHub Release URLs when missing, exposed via new
`diarization_status` / `diarization_warmup` JSONL commands (kept separate from
`model_status`/`warmup_model` rather than overloading `model_name`, since the
two-file GitHub-asset shape doesn't fit the single-HF-repo-id shape those
commands assume). Not yet implemented — this is a design direction to carry
into the execution spec, not code.

## Revisit criteria

Do not treat this as approved for implementation. Before writing an execution
spec and starting Worker/protocol/SwiftUI changes, resolve the model
download/offline mechanism (item 1 — design direction above still needs to be
implemented and tested) and get at least one real-recording usability check
(item 2 — **requires a real multi-speaker recording from the user**; no audio
fixture with multiple speakers exists in this repo, and this is the kind of
accuracy judgment CLAUDE.md already marks as user-verified, not
Claude-automatable). Items 3–5 can be validated during implementation (Gate B
/ Gate D style evidence), not required to unblock starting the work.
