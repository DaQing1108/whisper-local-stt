# HANDOFF v2 — Whisper Swift Speaker Diarization: Verification & Follow-up

**Handoff date:** 2026-07-22
**From:** Claude Code session (implemented HANDOFF v1)
**To:** A fresh Claude Code session/account picking this up cold
**Branch:** `whisper-swift`
**Starting commit:** `dc4fe04` (`feat(diarization): wire sherpa-onnx speaker diarization into Worker + SwiftUI`) — already pushed to `origin/whisper-swift`
**Repo:** `whisper-local-stt` — this worktree lives at `.worktrees/swiftui-python-poc` off the main repo checkout

---

## Read this first, in this order

1. `docs/Whisper_Phase3_Diarization_Integration_HANDOFF_v1.md` — the original execution spec (scope, forbidden list, AC-1 through AC-9). **v1 is now implemented** (commit `dc4fe04`); this v2 document only covers what's left.
2. `CLAUDE.md` (this worktree's root) — read the new `### 4. PyInstaller bundle 不能直接 import 重量級 ML 依賴` exception note (2026-07-22) explaining why sherpa-onnx is allowed to bundle directly despite the general subprocess rule.
3. `worker_entrypoint.py`, `diarization_service.py`, `worker_protocol.py`, `WorkerSupervisor.swift`, `ContentView+Results.swift` — read the actual implementation before touching anything; do not re-derive the design from HANDOFF v1 alone, the real code has diverged in a few places from what v1 originally specified (see "What changed vs. the original spec" below).

## BLUF

HANDOFF v1's integration work is **done and merged**: `diarization_warmup`/`diarize` JSONL commands exist, run as background jobs (mutually exclusive with transcribe and each other via the shared `JobRegistry`), `capabilities` reports real model-cache state, and SwiftUI has a "辨識講者" button with speaker-labeled rendering guarded against overwriting in-progress edits. Python (293/293) and Swift (154/154) test suites are green, and a real PyInstaller onedir spike confirmed sherpa-onnx/soundfile/soxr bundle cleanly (32MB, no torch/pyannote leakage).

**What's left is verification the implementing session could not do itself**, not new design work:
- AC-7: nobody has clicked the actual "辨識講者" button in a running app and looked at the screen.
- AC-9: the original 19.12s-transition regression recording was never retained in the repo, so the "does the integrated pipeline still match the previously-confirmed-correct baseline" check was never run for real — only a synthetic unit test exists.
- Long-recording performance (only ever measured on a 34s sample) is still an open question.

## What NOT to do (already tried / already decided)

- Do NOT re-litigate librosa vs. soxr. The original spec said to add `librosa`, but the implementing session discovered librosa's core modules unconditionally `import numba`, which `worker.spec`'s `excludes` list drops — this would have caused an `ImportError` in the bundled Worker. It was swapped for `soxr` (a librosa dependency itself, no numba) after explicit user confirmation. `requirements.txt` reflects this with a comment; don't "fix" it back to librosa.
- Do NOT make `diarize`/`diarization_warmup` synchronous again. The first implementation pass ran them inline in `handle_line`, which would have blocked the entire JSONL stdin-read loop for the duration of diarization (~0.4x realtime — up to ~47 min for a 2-hour recording), starving `ping`/`cancel`/`transcribe` the whole time. This was caught by an independent review pass and fixed by extracting `_run_diarization_job` (worker_entrypoint.py), which spawns a background thread and registers the job in the same `JobRegistry` transcribe uses. This is why `diarize`/`diarization_warmup` reject with `WORKER_BUSY` against transcribe AND against each other — that's intentional, not a bug to "simplify away."
- Do NOT remove the `diarizationTargetEntryID`/`isDraftDirty` guard in `ContentView+Results.swift`'s `.onChange(of: worker.diarizedSegments)`. Without it, a diarization result arriving after the user has already hand-edited the transcript, or after they've switched to a different history entry, would silently clobber their edits. This was also caught by review — don't simplify it back to an unconditional overwrite.
- Do NOT assume `worker.spec` needs changes for sherpa-onnx/soundfile/soxr. A real `pyinstaller --onedir` spike (not just `pytest`) confirmed it bundles cleanly with the existing `hiddenimports`/`excludes` untouched. If you add further diarization-related dependencies later, re-verify with a similar spike before assuming spec changes are needed.

---

## What changed vs. the original v1 spec (read before assuming v1 = actual code)

1. **soxr instead of librosa** in `requirements.txt` and `diarization_service.py`'s `_read_audio` (see above).
2. **`_diarize`/`_diarization_warmup` run as background threads**, not inline — v1 didn't specify this either way, but the actual implementation needed it (see above). `WorkerRuntime._run_diarization_job` is the shared helper; both handlers now go through it.
3. **`worker_protocol.py`'s `COMMANDS`/`EVENTS` whitelists were updated** to include `diarization_warmup`/`diarize`/`diarization_ready`/`diarized` — v1's scope list didn't call this file out explicitly (it's a small file, easy to miss), but it's a required insertion point: without it, the new commands are rejected as `UNKNOWN_COMMAND` at the protocol layer before `worker_entrypoint.py` ever sees them. If you touch the JSONL protocol again, remember this file.
4. **`WorkerSupervisor.diarize()`/`diarizationWarmup()` guard against their own reentrancy** (`diarizationOperationInProgress`), not just against active transcription — a MEDIUM finding from the second review pass, fixed proactively since it was a one-line change. There's no UI path that triggers this today (only one button, already disabled while `diarizationOperationInProgress`), but if you add another call site (e.g., an auto-warmup-on-launch flow), this guard is why it won't silently drop the first request's result.

---

## The execution spec for this handoff

**Risk level:** L1–L2 (mostly verification; touches no new architecture)
**ESAEV entry point:** Approve → Execute for the verification tasks below; if AC-9's real regression check reveals a genuine pipeline regression, escalate to the user rather than "fixing" clustering parameters until it looks right (per v1's stop conditions, which still apply).

### Target end-state

All of HANDOFF v1's AC-7 and AC-9 move from "needs user verification" / "downgraded to synthetic" to either confirmed-passing or a clearly-documented, user-acknowledged gap.

### Task 1 — AC-7: real UI verification

**Allowed to modify:** nothing, in principle — this is a manual verification task. If you find an actual UI bug while doing this, fix it following the same scope constraints as HANDOFF v1 (don't touch `_start_transcription`/`TranscriptionService`/`transcribe`'s payload shape).

Steps:
1. ~~`./package.sh`~~ **Correction (2026-07-22): the actual Whisper Swift build scripts are `scripts/build_worker_runtime.sh` (PyInstaller worker bundle) then `scripts/build_swiftui_app.sh` (Swift app referencing it, produces `dist/Whisper Swift.app`) — `package.sh` in this repo builds Whisper *Classic*, a different app.** Real production PyInstaller build of the worker with the new sherpa-onnx/soundfile/soxr dependencies confirmed clean via `python3 ci/check_bundle_deps.py build/worker/xref-worker.html` (no torch/pyannote leakage). App was installed to `~/Applications/Whisper Swift.app`, `xattr -cr` cleaned, user manually approved via System Settings.
2. **Done, via an existing history entry rather than a fresh upload** (the SwiftUI `.fileImporter`-style "選擇音訊..." picker did not visibly surface a panel during this session's attempt — untriaged, not a confirmed bug, just worked around by loading one of 14 existing history entries via "載入結果" instead).
3. **Confirmed in the real running app**: clicked "辨識講者" on a real history entry (`system-audio-session-286D3058...`, a YouTube-narration-style single-speaker recording). Real caveat found and worth remembering: **the button row's layout shifts when the "下載講者辨識模型" button is present vs. absent** (6 buttons vs. 7), so fixed-offset clicking/automation against this row needs to re-locate the button each time rather than assume a stable position — this cost significant back-and-forth during this verification and would bite any future automated UI test the same way.
4. **Resolved (2026-07-22, same day):** a "下載講者辨識模型" button was added next to "辨識講者" in `ContentView+Results.swift`, shown when `!worker.diarizationAvailable && worker.diarizationStatus != "ready"`, calling a new `triggerDiarizationWarmup()` that invokes `worker.diarizationWarmup()`. **Confirmed working in the real app**: clicking it completed near-instantly (models were already cached from earlier verification in this same session) and the button correctly disappeared from the row afterward, within the same session — no Settings visit or relaunch needed. (This resolves the staleness caveat raised when the button was added — in practice `diarizationStatus` transitioning to "ready" via the `diarization_ready` event was sufficient, independent of `diarizationAvailable`/`requestCapabilities()`.)
5. **Confirmed in the real running app**: after diarization completed, every line of the transcript re-rendered with a `[Speaker A]` prefix (this particular recording is a single-speaker YouTube-style narration, so no `[Speaker B]` appeared — correct behavior, not a bug). No error message shown; the AI summary section below was untouched.
6. **Not tested this round** — the edit-guard (hand-edit during in-flight diarization should not be silently overwritten) still needs manual verification.
7. **Not tested this round** — the entry-switch guard (switching history entries mid-diarization should not bleed results across entries) still needs manual verification.

**Task 1 status: core flow (steps 1–5) confirmed working end-to-end in the real packaged app. Steps 6–7 (the two guard edge cases) remain open — deliberately stopped here rather than continuing indefinitely; pick these up in a future session if/when it matters.**

### Task 2 — AC-9: real regression check

**Blocker:** the original ~34s two-speaker recording (0.03s–19.12s Speaker 0, 19.12s–33.83s Speaker 1) that established the "usable accuracy" bar in `docs/Whisper_Phase3_Diarization_ONNX_Runtime_Spike_v2.md` was never committed to the repo (correctly — it's real user audio). **You cannot regenerate this without asking the user for the recording again**, or a similarly-labeled real 2-speaker sample.

Steps if the user provides audio:
1. Run it through the actual integrated pipeline (via the app UI, or a direct `diarize()` call against `diarization_service.py` using a real cached model) — not the standalone spike script from the ONNX spike, which no longer exists.
2. Compare against the previously-confirmed transition point (~19.12s) if it's the same recording, or get a fresh user confirmation of accuracy if it's a new one.
3. If the result differs meaningfully from before on the *same* recording, this is a regression in the integration (something in the merge-by-overlap logic, model loading, or resampling path), not a reason to retune clustering parameters — per HANDOFF v1's stop conditions, escalate to the user rather than push through.

If the user has no recording available or declines: document that AC-9 remains permanently downgraded to the synthetic unit test (`test_merge_speakers_assigns_max_overlap_speaker` in `tests/unit/test_diarization_service.py`, which reproduces the 19.12s timestamp structurally but not against real audio) and move on — don't block indefinitely on an artifact that may never reappear.

### Task 3 — open item: long-recording performance

Not blocking, but worth sizing properly per the original ONNX spike's "new open item" note: sherpa-onnx diarization measured ~0.4x realtime on the 34s sample (a 2-hour meeting would take ~47 minutes). This was accepted as a v1 design constraint (diarization is a separate, explicitly-user-triggered command, never blocking the transcript) — but nobody has verified this holds on a real long recording (say, 30+ minutes). If the user has a long real meeting recording and wants to test this:
1. Time an actual `diarize` call against it.
2. If it's dramatically worse than 0.4x-realtime linear scaling (e.g., due to memory pressure or clustering complexity blowing up with segment count), flag this back to the user — it may mean the UI needs a progress indicator or cancel button for diarization jobs, which doesn't exist today (`diarize`'s `WorkerCommand` has no cancellation path, unlike `transcribe`).

### Stop conditions — escalate to the user, do not push through

- Any need to modify `_start_transcription`/`TranscriptionService`/`transcribe`'s payload shape (same as v1)
- AC-9's real regression check shows a different (worse) result on the same recording than previously confirmed
- Adding a warmup-button UI affordance (Task 1, step 4) if it turns out to need more than a trivial addition — check with the user whether that belongs in this task's scope
- Diarization needing a cancel/progress affordance (Task 3) — this is new scope beyond HANDOFF v1, confirm with the user before building it

### Completion report format

Same as HANDOFF v1: summary of what was verified/changed, actual verification evidence (screenshots or described real interaction for UI tasks, actual command output for backend checks), scope confirmation, residual risk, anything left undone and why.

---

## Prior art / commit trail

- `9075773` — HANDOFF v1 spec added
- `dc4fe04` — HANDOFF v1 implemented: diarization_service.py, worker_entrypoint.py/worker_protocol.py commands, SwiftUI button + guards, soxr substitution, background-thread fix, reentrancy guard. Independent code review ran twice (first pass found 3 HIGH issues, all fixed and re-verified; second pass found 1 MEDIUM, fixed proactively). Python 293/293, Swift 154/154 passing. Pushed to `origin/whisper-swift`.

This document is being added on top as an uncommitted file — commit it yourself once reviewed, or ask the user first if unsure.
