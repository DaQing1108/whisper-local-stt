# Whisper SwiftUI＋Python Worker Phase 0 Gate A Readiness Report v1

- Date: 2026-07-17
- Branch: `codex/swiftui-python-poc`
- Baseline: `main` at `d8b3e46`（Whisper STT v2.4.0）
- Decision: **PASS WITH BASELINE EXCEPTION**

## BLUF

Phase 0 已建立 transport-independent `TranscriptionService`、versioned JSONL v1 protocol、Python Worker、job identity、hard cancellation、process ownership 與 legacy Flask adapter。Gate A 所要求的 Core isolation、舊 UI 相容性及無新增 regression 均有證據支持，可以進入 Phase 1 SwiftUI file-transcription PoC。

完整 test suite 仍有一個 Phase 0 前即存在的 baseline defect：`tests/unit/test_release_hardening.py` 讀取未納入 Git 的 `WhisperAI_ProductSpec_v1.md`，在乾淨 worktree 產生 `FileNotFoundError`。本階段未複製該未追蹤文件，也未把它誤列為本次 regression。

## Gate A Requirement Mapping

### A1. Python transcription service 不再依賴 Flask／SSE

PASS。

- `whisper_core.py` 不再 import `sse.broadcast`。
- Event transport 由 `EventSink` 注入。
- `TranscriptionRequest`／`TranscriptionResult` 封裝 Core contract。
- `/transcribe` 與 `/api/transcribe-sync` 已改走 `TranscriptionService`。

### A2. 舊 Flask UI 仍可透過 adapter 運作

PASS。

- Legacy Flask server 實際啟動於 `127.0.0.1:5001`。
- `/api/ping` 回傳 `whisper-stt`、version `2.4.0`。
- `/api/jobs/gate-missing/cancel` 回傳 structured JSON 與 HTTP 404。
- Flask／upload／integration regression tests 通過。

### A3. 既有 Python test suite 無品質回歸

PASS WITH BASELINE EXCEPTION。

- Final full run: `258 passed, 1 failed, 16 deselected`。
- 唯一 failure 與 pre-change baseline 相同：缺少未追蹤的 `WhisperAI_ProductSpec_v1.md`。
- 排除該已知 baseline defect 後，本階段最後一次完整 regression 為全綠。

## Worker and Cancellation Evidence

- 真實 Worker OS process：`ready → ping → pong → EOF → exit 0`。
- 真實 cached `large-v3` cancellation：`accepted → status(cancelling) → cancelled`。
- Cancel observation window：5 秒內完成。
- Worker stdin EOF 會 cancel active jobs 並等待 cleanup。
- Owned subprocess 使用獨立 process group；先 `SIGTERM`，逾期 `SIGKILL`。
- Timeout、unexpected exception 與 cancellation 都會回收 child。
- JSONL stdout purity 由 Worker contract tests 驗證；diagnostics／traceback 僅走 stderr。

## Phase 0 Deliverables

- `transcription_events.py`
- `transcription_jobs.py`
- `transcription_service.py`
- `cancellable_process.py`
- `worker_protocol.py`
- `worker_entrypoint.py`
- Flask file-job cancel endpoint
- Unit、adapter、protocol、Worker lifecycle 與 process ownership tests

## Known Limits and Phase 1 Risks

1. Worker 目前會將 `audio_path` 讀成 bytes，再交給既有 Core；超大檔案仍有 memory duplication。
2. In-process faster-whisper 無法 hard kill，只能做 cooperative cancellation；packaged Worker 應優先維持 owned subprocess path。
3. Python runtime 仍可能偵測 system Python；Phase 1／Gate B 必須驗證 self-contained packaged runtime。
4. 真實 cancel smoke 使用本機已快取 `large-v3`，尚未在 signed `.app` 或 clean Mac 驗證。
5. Cancel endpoint 目前只支援 `/transcribe` file job，不涵蓋 chunk recording、system audio 或 synchronous endpoint。
6. Notarization、Sparkle、microphone、ScreenCaptureKit 與 mixed audio 不屬於 Gate A。

## Phase 1 Entry Decision

批准進入 Phase 1，但仍屬 architecture experiment，不代表批准完整 migration。

Phase 1 第一個 checkpoint 應建立獨立 SwiftUI/Xcode shell 與 `WorkerSupervisor`，只驗證 Worker startup、ready/ping、file selection、event decoding、cancel 及 crash restart。不得在 Gate B／C 前取代現有 production App。
