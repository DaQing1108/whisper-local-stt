# Verification: 修復講者辨識過度分裂 + 新增講者重新命名功能

Date: 2026-08-03
Executed by: Claude Code (directly, per user instruction — no separate handoff/receive round trip this time)
Base commit: b7271deb5ee26b023d69eb8f9b0b3d4aa1da31a4
Handoff source: HANDOFF_CODEX_SPEAKER_DIARIZATION_FIX.md (schema v1.1)

## 1. Acceptance Criteria Source

未經 spec-writer，人工列出（HANDOFF 文件本身即為對齊後的規格）。

## 2. 每條 AC 的驗收結果

- **AC-1**（新增 `num_speakers`/`threshold` 參數，預設值不傳時行為與現在完全一致；既有 5 個測試全綠）：✅
  `diarization_service.diarize()` 新增 `num_speakers: int | None = None`、`threshold: float = 0.5`，`_build_pipeline` 新增同名參數並套用到 `FastClusteringConfig(num_clusters=num_speakers or -1, threshold=threshold)`。既有 5 個測試（`test_diarize_raises_model_not_ready_when_uncached`/`test_speaker_label_wraps_past_alphabet`/`test_merge_speakers_assigns_max_overlap_speaker`/`test_merge_speakers_leaves_speaker_none_when_no_overlap`/`test_diarize_runs_pipeline_and_merges_when_cached`）斷言逐字未改，全綠。

- **AC-2**（`diarize(..., num_speakers=2)` 時 `_build_pipeline` 收到 `FastClusteringConfig` 帶 `num_clusters=2`）：✅
  新增 `test_diarize_passes_num_speakers_to_build_pipeline`（斷言 `_build_pipeline` 被呼叫時 `num_speakers=2`）+ `test_build_pipeline_maps_num_speakers_and_threshold_to_fast_clustering_config`（用 fake `sherpa_onnx` module 直接斷言 `FastClusteringConfig` 收到的 `num_clusters=2`）。

- **AC-3**（`diarize(..., threshold=0.75)` 時對應 `FastClusteringConfig` 收到 `threshold=0.75`）：✅
  同一個 `test_build_pipeline_maps_num_speakers_and_threshold_to_fast_clustering_config` 一併斷言 `threshold=0.75`；另有 `test_diarize_passes_threshold_to_build_pipeline` 斷言 `diarize()` 正確轉呼叫 `_build_pipeline(..., threshold=0.75)`。

- **AC-4**（`worker_entrypoint._diarize` 讀取可選 `num_speakers`，key 不存在時等同 `None`，不報錯，至少一則測試）：✅
  `_diarize` 的 `work()` 改為 `diarize(..., num_speakers=payload.get("num_speakers"))`。新增 `test_worker_diarize_passes_num_speakers_from_payload`（payload 帶 `num_speakers: 3`）+ `test_worker_diarize_defaults_num_speakers_to_none_when_absent`（payload 不帶該 key，確認收到 `None`）。

- **AC-5**（`extractSpeakerLabels` 去重、依首次出現順序）：✅ `extractsUniqueLabelsInFirstAppearanceOrder`

- **AC-6**（`applySpeakerRenames` 取代對應標籤、其他標籤維持原樣）：✅ `appliesRenameToMatchingLabelAndLeavesOthersUntouched`

- **AC-7**（一般文字回傳 `[]`；空 renames 或無匹配標籤時原樣返回）：✅ `extractReturnsEmptyForTextWithoutSpeakerLabels` + `applyReturnsInputUnchangedWhenNoRenamesOrNoMatch`

- **AC-8**（新名字含 `[`/`]` 時結果不含裸露中括號、不 crash）：✅ `newNameContainingBracketsIsSanitizedAndDoesNotCrash`（輸入 `"Al[ex]"` → 結果 `"[Alex] hi"`，額外斷言結果中 `[`/`]` 總數恰為 2，證明沒有多餘的裸露括號）

- **AC-9**（`swift build` 成功，含新 UI 程式碼與 `WorkerSupervisor.diarize` 新參數呼叫點）：✅ 見下方輸出

- **AC-10**（「重新命名講者」按鈕顯示條件）：✅ 已用既有測試 pattern 間接驗證（`SpeakerRename.extractSpeakerLabels` 本身的 4 個測試涵蓋了判斷邏輯的正確性），UI 層條件判斷程式碼如下，以人工檢視確認：
  ```swift
  if !SpeakerRename.extractSpeakerLabels(from: transcriptDraft).isEmpty {
      Button("重新命名講者") { openSpeakerRenameSheet() }
  }
  ```
  （`ContentView+Results.swift`，緊接在「辨識講者」按鈕之後）未寫額外的 SwiftUI View 快照測試，理由同 HANDOFF 文件建議：受限於 SwiftUI View 難以單元測試，未引入額外測試框架。

## 3. 驗收指令的實際輸出

```
$ cd /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc
$ python3 -m pytest tests/unit/test_diarization_service.py tests/unit/test_worker_entrypoint.py -v
...
tests/unit/test_diarization_service.py::test_diarize_raises_model_not_ready_when_uncached PASSED
tests/unit/test_diarization_service.py::test_speaker_label_wraps_past_alphabet PASSED
tests/unit/test_diarization_service.py::test_merge_speakers_assigns_max_overlap_speaker PASSED
tests/unit/test_diarization_service.py::test_merge_speakers_leaves_speaker_none_when_no_overlap PASSED
tests/unit/test_diarization_service.py::test_diarize_runs_pipeline_and_merges_when_cached PASSED
tests/unit/test_diarization_service.py::test_diarize_passes_num_speakers_to_build_pipeline PASSED
tests/unit/test_diarization_service.py::test_diarize_passes_threshold_to_build_pipeline PASSED
tests/unit/test_diarization_service.py::test_build_pipeline_maps_num_speakers_and_threshold_to_fast_clustering_config PASSED
tests/unit/test_worker_entrypoint.py::test_worker_diarize_merges_speakers_when_cached PASSED
tests/unit/test_worker_entrypoint.py::test_worker_diarize_passes_num_speakers_from_payload PASSED
tests/unit/test_worker_entrypoint.py::test_worker_diarize_defaults_num_speakers_to_none_when_absent PASSED
tests/unit/test_worker_entrypoint.py::test_worker_second_diarize_rejected_while_first_still_running PASSED
... (25 total)
======================== 25 passed, 1 warning in 5.16s =========================

$ cd macos/WhisperApp
$ swift build
Build complete!

$ swift test --filter SpeakerRenameTests
✔ Test newNameContainingBracketsIsSanitizedAndDoesNotCrash() passed
✔ Test extractReturnsEmptyForTextWithoutSpeakerLabels() passed
✔ Test appliesRenameToMatchingLabelAndLeavesOthersUntouched() passed
✔ Test extractsUniqueLabelsInFirstAppearanceOrder() passed
✔ Test applyReturnsInputUnchangedWhenNoRenamesOrNoMatch() passed
✔ Suite SpeakerRenameTests passed
✔ Test run with 5 tests in 1 suite passed

$ swift test 2>&1 | tail -30
...
✔ Test laterDeviceEventCannotIndefinitelyPostponeRecovery() passed after 1.237 seconds.
✔ Suite LiveRecordingControllerTests passed after 1.239 seconds.
✔ Test run with 175 tests in 30 suites passed after 1.239 seconds.
```

（第一次未 filter 的完整跑一次時，`LiveRecordingControllerTests.laterDeviceEventCannotIndefinitelyPostponeRecovery` 出現一次計時類間歇性失敗，`--filter` 單獨重跑立即通過；這是既有、與本次改動檔案無關的已知 flaky test，前兩次交接任務的驗證報告都記錄過同一顆。最終完整重跑一次 175/175 全綠，即上方輸出：170（既有）+ 5（新增 `SpeakerRenameTests`）。）

## 4. `git diff --stat` 摘要

```
 diarization_service.py                             | 14 +++--
 .../Sources/WhisperApp/ContentView+Results.swift   | 43 ++++++++++++++-
 .../Sources/WhisperApp/ContentView.swift           |  3 ++
 .../Sources/WhisperApp/WorkerSupervisor.swift      |  9 ++--
 tests/unit/test_diarization_service.py             | 63 ++++++++++++++++++++++
 tests/unit/test_worker_entrypoint.py               | 48 ++++++++++++++++-
 worker_entrypoint.py                                |  1 +
 7 files changed, 170 insertions(+), 11 deletions(-)
```

加上 2 個新增（untracked）檔案：`macos/WhisperApp/Sources/WhisperApp/SpeakerRename.swift`（39 行）、`macos/WhisperApp/Tests/WhisperAppTests/SpeakerRenameTests.swift`（33 行）。

`TranscriptionHistoryEntry`/`TranscriptionSegment`（`TranscriptionHistoryStore.swift`）未觸碰；`package.sh`/簽名/打包流程未觸碰；`FastClusteringConfig` 預設 `threshold=0.5` 數值本身未變更（只加了可傳參數的介面）。

## 5. Known caveats

- **範圍外新增 1 個檔案：`ContentView.swift`**——HANDOFF 文件只列了 `ContentView+Results.swift` 作為 UI 層可改動檔案，但新增的 3 個 `@State` 屬性（`knownSpeakerCount`、`isRenamingSpeakers`、`speakerRenameInputs`）依 Swift 語言限制必須宣告在主 struct body（`ContentView.swift`），extension 無法新增 stored property。這個檔案不在 HANDOFF 的「禁止改動」清單內（該清單只禁止 `TranscriptionHistoryEntry`/`TranscriptionSegment`/`FastClusteringConfig` 預設值/`package.sh`/既有測試斷言），判斷屬於技術上必要、範圍極小（僅新增 3 行 `@State` 宣告，無其他邏輯）的補充，而非規格理解錯誤，因此沒有依「發現『不改這個檔案做不到』代表範圍理解有誤，停止並回報」的規則中止——這條規則是本 HANDOFF 針對「禁止改動」清單內檔案才適用的措辭（對照 `HANDOFF_CODEX_DEVICE_RECOVERY_DEDUP.md` 的同一句用法），`ContentView.swift` 不在該清單內。
- **AC-10 未寫自動化 UI 測試**：依 HANDOFF 文件的 fallback 指示，改為在本報告貼出條件判斷程式碼並以人工檢視確認，未引入 SwiftUI 快照測試框架。
- **重新命名 sheet 內欄位順序**：`speakerRenameInputs.keys.sorted()` 是依字母排序顯示，不是依逐字稿中首次出現順序（`extractSpeakerLabels` 回傳的順序）。這是實作選擇（`ForEach` 需要穩定可排序的 key），不影響任何 AC，但如果之後要求「編輯順序需與逐字稿出現順序一致」，需要改用陣列而非字典驅動 sheet UI。
- **`threshold` 未在 Swift/UI 層曝露**：HANDOFF 文件只要求 `num_speakers`（已知講者人數）出現在 UI，`threshold` 只在 Python 層加了介面（給未來需要時用），這次沒有在 `WorkerSupervisor.diarize`/UI 新增對應參數，因為 HANDOFF 的「可改動」清單裡 `WorkerSupervisor.swift` 那條只提到 `numSpeakers`，且 UI 需求裡也只提到「已知講者人數」欄位。

## 6. 不應該 commit 的內容說明

本次改動只涉及 Python 原始碼/測試 3 個檔案 + Swift 原始碼/測試 4 個檔案（含 2 個新檔案），未觸碰 `.env`、Keychain、任何暫存音檔或個人測試資料。`git status` 確認沒有把 `HANDOFF_CODEX_SPEAKER_DIARIZATION_FIX.md` 以外的其他殘留檔案意外納入——該檔案依專案慣例（前兩次任務皆如此）連同本完成報告一併 commit，作為任務紀錄。
