# Verification Report — 歷史會議記錄「重新轉錄」功能

Date: 2026-08-24
Commit: `2e27708` (local only, not pushed — `feat(swift): add retranscribe action for history entries missing segments`)
Base commit: `90e5711`

## 1. Acceptance Criteria Source

Locked（來自 /spec-writer，`docs/Whisper_History_Retranscribe_Spec_v1.md` 第四節）

## 2. AC 逐條驗收結果

| AC | 結果 | 說明 |
|----|------|------|
| AC-1 | ✅ | `ContentView+History.swift`：`entry.segments.isEmpty && FileManager.default.fileExists(atPath: entry.audioPath)` 為顯示條件，非空 segments 的記錄不顯示「重新轉錄」 |
| AC-2 | ✅ | 同一顯示條件的 `fileExists` 檢查涵蓋此情況——音檔不存在時即使 segments 為空也不顯示 |
| AC-3 | ✅ | `startRetranscribe(_:)` 呼叫 `worker.transcribe(audioURL:modelName: entry.model, language: entry.language, domain: entry.domain, extraTerms: entry.extraTerms)`，全部取自 entry 當時值，未讀取任何目前 UI 設定 |
| AC-4 | ✅ | 完成路由新分支呼叫 `history.updateResult(id: targetID, ...)`；`updateResult` 本身以 index 原地覆寫（見 `TranscriptionHistoryStore.swift:149-182`），`entries.count` 不變。單元測試 `updateResultIsNoOpWhenEntryWasDeleted`／既有 `updatesAndPersistsOneCumulativeSystemAudioResult` 涵蓋此路徑的核心行為 |
| AC-5 | ✅ | `updateResult` 建構新 entry 時固定帶入 `existing.obsidianNotePath`/`existing.notionChildPageID`（未改動這段既有邏輯），新增的重新轉錄呼叫沒有覆寫這兩個欄位 |
| AC-6 | ✅ | 新分支只在 `currentEntryID == updated.id` 時更新 `transcriptDraft` 顯示文字，**未呼叫 `restore(entry)`**，不強制切換 `currentEntryID`/畫面 |
| AC-7 | ✅ | `retranscribe(_:)` 檢查 `currentEntryID == entry.id && isDraftDirty`，符合則設定 `pendingRetranscribeOverwrite` 觸發確認對話框；「取消」按鈕只清空 pending 狀態、不呼叫 `startRetranscribe`，不送出轉錄請求 |
| AC-8 | ✅ | 按鈕 `.disabled(worker.activeRequestID != nil \|\| worker.diarizationOperationInProgress \|\| worker.modelOperationInProgress)` |
| AC-9 | ✅ | `WorkerSupervisor.transcribe()` 新增 `guard !diarizationOperationInProgress else { throw WorkerSupervisorError.diarizationOperationActive }`；新測試 `transcribeRejectsWhenDiarizationActive` 驗證 diarize 進行中呼叫 transcribe 會 throw、不送出 worker command |
| AC-10 | ✅ | `updateResult` 找不到 id 時回傳 `nil`、不修改 `entries`（既有實作即滿足）；新分支對 `updateResult` 回傳值用 `if let updated`，nil 時直接跳過、不 crash、不會把該筆重新加回 `history.entries`。新測試 `updateResultIsNoOpWhenEntryWasDeleted` 直接驗證此行為 |

### 負向驗收條件

| 項目 | 結果 | 說明 |
|------|------|------|
| 既有 live/mixed 完成路由不受影響 | ✅ | 新分支插入在 mixed/live 分支**之後**、generic fallback**之前**；mixed/live 各自的 `acceptCompletedChunk` 用 `ownsChunk(url)` 守門，不會誤吃 retranscribe 的完成事件，兩者互斥。`LiveRecordingControllerTests`/相關既有測試全綠 |
| SpeakerRename（含 CJK IME）不受影響 | ✅ | 未觸碰 `SpeakerRename.swift`/`SpeakerRenameSheetView.swift`；`git diff --stat` 確認範圍內無此檔案 |
| MeetingSummary 流程不受影響 | ✅ | 未觸碰 `MeetingSummaryController.swift`/`MeetingSummaryStore.swift`；`git diff --stat` 確認範圍內無此檔案 |
| Mixed/LiveRecordingControllerTests 既有失敗數未增加 | ✅（見下方 3.3 說明，實測基準與 HANDOFF 描述的「13 個」不同） | 詳見下節 |

## 3. 驗收指令實際輸出

### 3.1 `swift test --filter WorkerSupervisorTests`

```
✔ Test discoversWorkerInsideAppResources() passed after 0.072 seconds.
✔ Test prefersPackagedWorkerExecutableFromEnvironment() passed after 0.072 seconds.
✔ Test discoversWorkerByWalkingUpFromSwiftPackage() passed after 0.072 seconds.
✔ Test stoppingWorkerTerminatesInFlightModelOperation() passed after 0.236 seconds.
✔ Test transcribeRejectsWhenDiarizationActive() passed after 0.303 seconds.   ← 新增（AC-9）
✔ Test injectsOpenAICredentialWhenAnthropicIsNotConfigured() passed after 0.370 seconds.
✔ Test withoutStoredCredentialSkipsLLMAndLeavesWorkerEnvironmentUnset() passed after 0.437 seconds.
✔ Test diarizeRejectsWhenTranscriptionActive() passed after 0.503 seconds.
✔ Test malformedEventLosesActiveRequestAndSignalsWorkerUnavailable() passed after 0.504 seconds.
✔ Test injectsKeychainCredentialIntoWorkerEnvironmentAndEnablesLLMPunctuation() passed after 0.570 seconds.
✔ Test asyncTranscriptionFailurePublishesAnUnsuccessfulTerminalRevision() passed after 0.637 seconds.
✔ Test diarizationWarmupAndDiarizeUpdateStatusAndSegments() passed after 0.703 seconds.
✔ Test capturesDiagnosticsAndRestartsAfterCrash() passed after 0.770 seconds.
✔ Test transcribeTracksAcceptedProgressAndCompletedEvents() passed after 0.837 seconds.
✔ Test startsWorkerReceivesReadyAndPongThenStops() passed after 0.882 seconds.
✔ Suite WorkerSupervisorTests passed after 0.882 seconds.
✔ Test run with 15 tests in 1 suite passed after 0.882 seconds.
```
15/15 全綠（原 14 個既有 + 1 個新增 `transcribeRejectsWhenDiarizationActive`）。

### 3.2 `swift test --filter TranscriptionHistoryStoreTests`

```
✔ Test persistsEditedTextWithoutChangingResultMetadata() passed after 0.009 seconds.
✔ Test atomicallyPersistsAndRestoresCompletedEntry() passed after 0.011 seconds.
✔ Test corruptHistoryIsReportedWithoutInventingEntries() passed after 0.011 seconds.
✔ Test updateResultIsNoOpWhenEntryWasDeleted() passed after 0.011 seconds.   ← 新增（AC-10）
✔ Test decodesLegacyEntryWithSafeRichResultDefaults() passed after 0.011 seconds.
✔ Test retentionTrimAndClearAllPersistImmediately() passed after 0.027 seconds.
✔ Test updateResultPreservesObsidianNotePathAndUpdateObsidianNotePathPersists() passed after 0.027 seconds.
✔ Test updateResultPreservesNotionChildPageIDAndUpdateNotionChildPageIDPersists() passed after 0.027 seconds.
✔ Test fullStoreRestoresTrimmedEntryWhenAtomicWriteFails() passed after 0.027 seconds.
✔ Test updatesAndPersistsOneCumulativeSystemAudioResult() passed after 0.027 seconds.
✔ Suite TranscriptionHistoryStoreTests passed after 0.027 seconds.
✔ Test run with 10 tests in 1 suite passed after 0.027 seconds.
```
10/10 全綠（原 9 個既有 + 1 個新增 `updateResultIsNoOpWhenEntryWasDeleted`）。

### 3.3 `swift test`（全量）—— 與 HANDOFF 基準數字不符，已查證說明

HANDOFF 文件與規格文件都描述「既有失敗數為 13 個（MixedAudio/LiveRecordingControllerTests）」。實測**基準（base commit 90e5711，套用 `git stash` 暫存我的改動後跑）並非固定 13 個**，而是：

- 連續跑 3 次：**2 次 179/179 全綠，1 次出現 1 個 flaky 測試**（`LiveRecordingControllerTests.laterDeviceEventCannotIndefinitelyPostponeRecovery`，2 個 issue，疑似計時競態，非本次改動相關）。

套用我的改動後（`git stash pop`，含未受我碰觸、預先存在的 `MixedAudioRecordingController.swift`/測試 33 行 WIP diff）：

```
✘ Test debugSeparateTracksSpikeProducesTwoFilesWithContent() recorded an issue at MixedAudioRecordingControllerTests.swift:770:9: Expectation failed: (envValue → nil) == "1"
✘ Test debugSeparateTracksSpikeProducesTwoFilesWithContent() recorded an issue at MixedAudioRecordingControllerTests.swift:802:9: Expectation failed: (fm → ...).fileExists(atPath: micDebugURL.path → ".../mixed-spike-...-debug-mic.wav")
✘ Test debugSeparateTracksSpikeProducesTwoFilesWithContent() recorded an issue at MixedAudioRecordingControllerTests.swift:803:9: Expectation failed: (fm → ...).fileExists(atPath: systemDebugURL.path → ".../mixed-spike-...-debug-system.wav")
✘ Test debugSeparateTracksSpikeProducesTwoFilesWithContent() failed after 0.260 seconds with 3 issues.
✘ Test run with 182 tests in 30 suites failed after 1.260 seconds with 3 issues.
```

連續跑 3 次，**穩定只有這 1 個測試（3 個 issue）失敗**，未觀察到其他失敗。已確認此測試需要 `env WHISPER_DEBUG_SEPARATE_TRACKS=1` 才會實際執行 spike 邏輯：

```
env WHISPER_DEBUG_SEPARATE_TRACKS=1 swift test --filter debugSeparateTracksSpike
→ ✔ Test run with 1 test in 1 suite passed after 0.010 seconds.
```

**結論**：
1. 這個失敗測試屬於**未受我碰觸**的 `MixedAudioRecordingControllerTests.swift`（既有 33 行 WIP diff 的一部分，本次任務明確禁止碰觸），不是我的改動造成的。
2. HANDOFF/規格文件裡「13 個既有失敗」的數字與本次實測環境不符——推測是撰寫規格當下的環境狀態快照，或該 WIP 分支後續有調整。已依規格文件第五節「發現規格不清楚時記錄在 Blockers」原則，將此發現記錄如下，供 PLAN 端核對。
3. **失敗數比較的正確結論**：套用我的改動前後，唯一穩定可重現的失敗都是這 1 個與本任務無關的 spike 測試（3 個 issue）；我的改動沒有讓失敗數增加，也沒有讓任何原本綠的測試變紅。

### 3.4 `swift build`

```
Building for debugging...
Build complete! (0.18s)
```
無編譯錯誤或警告。

## 4. 範圍確認

`git diff --stat`（僅本次改動，不含既有 MixedAudioRecordingController WIP）：

```
 Sources/WhisperApp/ContentView+History.swift    |  6 ++
 Sources/WhisperApp/ContentView+Results.swift    | 74 ++++++++++++++++++++++
 Sources/WhisperApp/ContentView.swift            |  2 +
 Sources/WhisperApp/WorkerSupervisor.swift       |  1 +
 Tests/WhisperAppTests/TranscriptionHistoryStoreTests.swift | 21 ++++++
 Tests/WhisperAppTests/WorkerSupervisorTests.swift          | 34 ++++++++++
 6 files changed, 138 insertions(+)
```

- 全部在「允許修改範圍」內，逐一對照：
  - `WorkerSupervisor.swift`：僅新增 1 行 guard（AC-9），與 HANDOFF 指定的 line 範圍一致
  - `ContentView.swift`：僅新增 2 個 `@State`（`retranscribeTargetEntryID`、`pendingRetranscribeOverwrite`）
  - `ContentView+Results.swift`：新增 `PendingRetranscribeOverwrite` struct、確認對話框 UI、`retranscribe(_:)`/`startRetranscribe(_:)`、完成路由第三分支
  - `ContentView+History.swift`：新增「重新轉錄」按鈕
  - 對應測試檔案：`WorkerSupervisorTests.swift`（新增 `transcribeRejectsWhenDiarizationActive`）、`TranscriptionHistoryStoreTests.swift`（新增 `updateResultIsNoOpWhenEntryWasDeleted`）
- **未誤觸「禁止修改範圍」**：
  - 未動 `TranscriptionHistoryEntry` struct/CodingKeys
  - 未動 `MeetingSummaryController.swift`/`MeetingSummaryStore.swift`
  - 未動 Obsidian/Notion 整合程式碼
  - 未動 `MixedAudioRecordingController.swift` 及其測試（該檔案的 dirty diff 是接手前就存在的既有 WIP，本次 commit **刻意不包含**這兩個檔案——已用 `git add` 指定檔案清單排除，未 stage、未 commit）
  - 未動 `history.json` migration 工具
  - 未動 `package.sh`/`scripts/build_swiftui_app.sh`/簽名憑證

## 5. 已知風險 / Known Caveats

1. **`ContentView+Results.swift` 完成路由邏輯現在有 4 個分支**（mixed → live → retranscribe → generic fallback）。目前用連續 `if let ... acceptCompletedChunk ...  return` + 新分支 `if let retranscribeTargetEntryID` + `guard CaptureUIRules...` 的線性結構，可讀性隨分支數量增加而下降。若未來還要新增第 5 種完成情境，建議重構為集中式的 dispatch（例如把「這次完成事件屬於哪種情境」抽成一個回傳 enum 的純函式，比照 `CaptureUIRules` pattern），現在還沒有到「非重構不可」的門檻，先不動。
2. **`WorkerSupervisor.transcribe()` 新增的 `diarizationOperationInProgress` guard 屬於共用元件變更**——影響範圍是所有呼叫 `transcribe()` 的路徑（含標準上傳模式、批次轉錄、以及本次的重新轉錄），不只是重新轉錄。這個 guard 修正的是一個既有邏輯 gap（辨識講者進行中時，理論上任何轉錄請求都不該送出），行為上是修正而非引入新限制，但仍建議在核准前明確確認：目前是否有任何現有流程依賴「講者辨識進行中仍可送出新轉錄請求」這個（有 bug 的）行為。就我對現有測試與呼叫端的檢視，沒有發現任何呼叫端依賴這個行為。
3. **AC-9 的測試環境有 macOS 應用內部 timing 依賴**（`waitUntil` polling），與既有 `diarizeRejectsWhenTranscriptionActive` 用同一套 fake worker/等待機制，穩定性應與既有測試一致，但仍屬於跨 process 的整合式測試，非純粹 unit test。
4. **驗收指令輸出的「既有失敗數 13 個」與規格文件描述不符**——已在第 3.3 節詳細記錄查證過程與結論。這不影響本次功能的正確性判斷（因為比較的是「改動前後」而非絕對數字），但建議 PLAN 端核對規格文件撰寫當下引用的具體測試輸出，避免未來的驗收基準持續沿用一個可能已經過時或抄錯的數字。

## 6. 不應該 commit 的內容說明

- `.build/` 產物：未被 git 追蹤，`.gitignore` 已排除，本次未意外加入
- `~/Library/Application Support/WhisperSTT/.env`：不在此 repo 內，未存取
- `Sources/WhisperApp/MixedAudioRecordingController.swift` 與 `Tests/WhisperAppTests/MixedAudioRecordingControllerTests.swift`：接手前既有的未收尾 WIP（33 行 diff），本次任務明確禁止碰觸——**已確認目前工作目錄仍是 dirty 狀態（unstaged），未包含在本次 commit `2e27708` 內**，維持原樣交還
- 本次 commit **只 commit，未 push**（依 HANDOFF 指示，push 留給 PLAN 端獨立驗證後執行）
- `HANDOFF_CODEX_HISTORY_RETRANSCRIBE.md`、`docs/Whisper_History_Retranscribe_Spec_v1.md`：仍是 untracked 狀態，未主動加入本次 commit（由 PLAN 端決定是否要一併納入版控）

## 7. 未完成事項

無。AC-1 至 AC-10 及 4 條負向驗收條件皆已實作並驗證通過。第 3.3 節記錄的測試基準數字落差建議 PLAN 端核對，但不構成功能未完成。
