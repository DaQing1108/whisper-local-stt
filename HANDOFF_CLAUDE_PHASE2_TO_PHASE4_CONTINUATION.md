# Claude Code Handoff: Whisper Phase 2–4 Continuation

Date: 2026-07-17
Project: `/Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper`
Execution worktree: `/Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc`
Repo: `https://github.com/DaQing1108/whisper-local-stt.git`
Branch: `codex/swiftui-python-poc`
Base commit: `d8b3e46` (`v2.4.0`)
Target: `macos/WhisperApp` and bundled `dist/Whisper SwiftUI.app`
Mode: `continuation`

## BLUF

Phase 0（Core isolation）與 Phase 1（SwiftUI file-transcription PoC）已完成；Phase 2 已完成 Checkpoint 1（recording state machine 與 16 kHz mono PCM/WAV writer），目前暫停。下一週期應從 Phase 2 Checkpoint 2 的 microphone permission mapping 與 injectable `AVAudioEngine` capture service 繼續，依序完成 Phase 2–4。只有 Phase 4 完成、Gate C／D／E 所需證據齊全後，才可把 SwiftUI App 視為可交付並取代現有 Whisper App。

## Current State

- Phase 0：10/10 checkpoints，Gate A `PASS WITH BASELINE EXCEPTION`。
- Phase 1：6/6 checkpoints，Gate B `PASS WITH RELEASE EXCEPTIONS`。
- Phase 2：1/6 checkpoints；剩餘 5 個。
- Phase 3：尚未開始；包含 ScreenCaptureKit、mixed audio、Settings、history、Notion／Obsidian、diarization、Sparkle 與 UI/UX parity。
- Phase 4：尚未開始；包含 Developer ID、Hardened Runtime、notarization、Sparkle release、clean-machine validation、migration／rollback。
- 目前 SwiftUI UI 是 architecture PoC，不是 production UI；不可用畫面差異判定功能已交付。
- 現有 pywebview Whisper App 仍是 production fallback，Gate D 前不可停止維護。
- 工作樹尚未 commit、stage、push 或 merge；不得把未追蹤檔案當成可刪除垃圾。

## Acceptance Criteria Source

- Source：使用者決策「完成 Phase 4 才是可交付版本」、`docs/Whisper_Phase2_Native_Microphone_Plan_v1.md`、Notion architecture assessment／phased roadmap。
- Status：Locked。
- Rule：新增、刪除或改寫 release gate 前必須先取得 Alex 明確同意。

## Acceptance Criteria

### Locked AC

- AC-1：Phase 2 完成原生 microphone standard／live mode、長錄音、chunk ordering 與 device recovery；未通過前不宣稱 Gate D microphone parity。
- AC-2：Phase 3 補齊 system audio、mixed audio（可依 Gate D 決策延後）、Settings、history、Notion／Obsidian、diarization、Sparkle 與核心 UI/UX parity。
- AC-3：Phase 4 完成 Developer ID signing、Hardened Runtime、notarization／stapling、signed clean Apple Silicon Mac、first-model download、Sparkle update 與 rollback verification。
- AC-4：SwiftUI App 不依賴 Homebrew 或任意 system Python；Worker protocol stdout 必須維持純 JSONL。
- AC-5：cancellation、crash recovery、recording recovery file 與 job terminal state 不得退化。
- AC-6：Phase 4 及必要 Gates 通過前，SwiftUI App 不得取代現有 production Whisper App。

### Extra suggested checks, not mandatory AC

- 固定音檔做 legacy／SwiftUI dual-run CER、processing time 與 peak-memory comparison。
- 先解決 frozen CPU `tiny` inference 超過 120 秒，再擴大 clean-machine matrix。
- 視覺設計保留舊版熟悉的核心操作，但不要求逐像素複製 Web UI。

### Unauthorized AC

- App Store、App Sandbox、Universal Binary、純 Swift inference：不在目前 scope；若要加入需 Alex 重新批准。

## Files Changed By This Work

```text
Modified:
routes.py
tests/unit/test_transcribe_sync_and_upload.py
whisper_core.py

New Phase 0/Worker:
cancellable_process.py
transcription_events.py
transcription_jobs.py
transcription_service.py
worker_entrypoint.py
worker_protocol.py
worker.spec
tests/unit/test_cancellable_process.py
tests/unit/test_event_sink.py
tests/unit/test_worker_bundle.py
tests/unit/test_worker_entrypoint.py
tests/unit/test_worker_protocol.py

New SwiftUI/Phase 1–2:
macos/WhisperApp/**
scripts/build_worker_runtime.sh
scripts/build_swiftui_app.sh
scripts/phase1_real_worker_smoke.py
scripts/verify_worker_bundle.py

Docs:
docs/Whisper_Phase0_Gate_A_Readiness_Report_v1.md
docs/Whisper_Phase1_Gate_B_Readiness_Report_v1.md
docs/Whisper_Phase2_Native_Microphone_Plan_v1.md
```

## Verification Already Run By Codex

### Phase 0 baseline

```text
258 passed, 1 failed, 16 deselected
```

唯一失敗是 baseline tracked test 期待未追蹤的 `WhisperAI_ProductSpec_v1.md`；可在乾淨 baseline 重現，並非 Phase 0 regression。

### Python Worker／packaging

```bash
python3 -m pytest tests/unit/test_worker_bundle.py tests/unit/test_worker_protocol.py tests/unit/test_worker_entrypoint.py -q
python3 scripts/verify_worker_bundle.py dist/WhisperWorker
```

Result：24/24 passed；166 MB standalone Worker 包含 Python、faster-whisper、CTranslate2、ONNX Runtime、Silero VAD 與 ffmpeg，不探測 system Python。

### SwiftUI

```bash
cd macos/WhisperApp
CLANG_MODULE_CACHE_PATH=/tmp/whisper-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/whisper-clang-cache \
swift test --scratch-path /tmp/whisper-swift-build
```

Result：Phase 2 Checkpoint 1 後 9/9 passed，包括 Worker lifecycle、file transcription events、crash restart、bundled Worker discovery、recording state machine 與 WAV header。

### Real-model／bundle

- Development `tiny`：4.11 秒台灣中文音訊完成，得到非空中文逐字稿。
- Development cached `large-v3`：`accepted → cancelling → cancelled`，約 1.2 秒。
- Packaged Worker：startup 與 cancellation passed。
- `dist/Whisper SwiftUI.app`：166 MB。
- Ad-hoc signing：passed。
- `codesign --verify --deep --strict`：passed。
- Isolated HOME／minimal PATH bundled Worker startup：passed，輸出 `ready`。

Known caveats：

- Frozen CPU `tiny` completion 超過 120 秒 smoke window，尚未通過效能門檻。
- Developer ID、Hardened Runtime、notarization、stapling、physical clean Mac、Sparkle update 尚未驗證。
- 本機 App 使用 staging name 簽章後改名為 `.app`；此流程已寫入 `scripts/build_swiftui_app.sh`。

## Claude Code Mission

### 1. Inspect Before Acting

```bash
cd /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc
git status --short
git branch --show-current
git rev-parse --short HEAD
sed -n '1,240p' docs/Whisper_Phase2_Native_Microphone_Plan_v1.md
cd macos/WhisperApp
swift test
```

確認 branch 為 `codex/swiftui-python-poc`、base 為 `d8b3e46`，並保留所有 dirty／untracked work。

### 2. Execute The Remaining Work

第一個 implementation slice 僅做 Phase 2 Checkpoint 2：

1. 建立 microphone permission abstraction 與 macOS mapping。
2. 建立 injectable audio-capture backend。
3. 實作 `AVAudioEngine` capture service，輸出可交給 `PCM16WAVWriter` 的 16 kHz mono Int16 PCM。
4. 用 fake backend 測試 permission denied／granted、start／stop、engine error 與 state mapping。
5. 真實 microphone／TCC 僅做 manual evidence；unit tests 不應彈權限視窗。

Checkpoint 2 通過後，再依 Phase 2 plan 逐一前進，不要一次混入 Phase 3 scope。

### 3. Fix Only Findings In Scope

- 可修改 `macos/WhisperApp/**` 與 Phase 2 docs/tests。
- Protocol 變更若必要，必須維持 JSONL v1 backward compatibility 或顯式升版。
- 不修改既有 production pywebview UX，除非是維持 adapter 相容性的必要修正。
- 不處理 App Store、Universal Binary 或純 Swift inference。

### 4. Compare AC Source

- `Locked AC`：正常驗證並計入 pass/fail。
- `Extra suggested checks`：只列為 optional evidence。
- `Unauthorized AC`：停止並請 Alex 選擇接受、降級為 extra check 或拒絕。

### 5. Re-run Verification

每個 checkpoint 至少執行：

```bash
cd /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc/macos/WhisperApp
CLANG_MODULE_CACHE_PATH=/tmp/whisper-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/whisper-clang-cache \
swift test --scratch-path /tmp/whisper-swift-build

cd /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc
git diff --check
```

需要 GUI／TCC evidence 時，再啟動 packaged App 並記錄 permission、start、stop、WAV file 與 recovery 結果。

## Report Back Format

```markdown
## Whisper Phase 2 Checkpoint <N> Result

### Result
- Status: Ready / Not ready
- Completed:
- Blocked:

### Evidence
- Swift tests:
- Manual microphone/TCC:
- Generated audio artifact:
- git diff --check:

### Fixes Made
- <file: summary>

### Remaining Risks
- <risks>

### Recommended Next Action
- Continue next checkpoint / re-test / request Alex decision
```

## Do Not Do

- Do not run `git reset --hard` or delete untracked files.
- Do not commit、stage、push、merge unless Alex explicitly asks.
- Do not commit this handoff file、`.env`、credentials 或 machine-specific secrets unless Alex explicitly asks.
- Do not replace the production Whisper App before Phase 4 and all applicable Gates pass.
- Do not treat the current SwiftUI PoC UI as final product design。
- Do not silently expand Phase 2 into ScreenCaptureKit／mixed audio／Sparkle work。

## Useful Context

- Notion cumulative checkpoint：<https://app.notion.com/p/3a0280a95f7681e08354c6fee03ffcf0>
- Local Gate A：`docs/Whisper_Phase0_Gate_A_Readiness_Report_v1.md`
- Local Gate B：`docs/Whisper_Phase1_Gate_B_Readiness_Report_v1.md`
- Phase 2 plan：`docs/Whisper_Phase2_Native_Microphone_Plan_v1.md`
- Current local App：`dist/Whisper SwiftUI.app`

## Resume Prompt

請依照 `/Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc/HANDOFF_CLAUDE_PHASE2_TO_PHASE4_CONTINUATION.md`，從 Phase 2 Checkpoint 2 繼續 Whisper SwiftUI＋Python Worker 開發；先檢查 dirty worktree 並重跑既有測試，不要 commit、push 或擴張 scope。
