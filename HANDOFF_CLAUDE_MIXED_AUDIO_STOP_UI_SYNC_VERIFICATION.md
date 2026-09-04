# Verification Report: 混音錄音停止後畫面同步最終結果

Date: 2026-09-05
Branch: `handoff/2026-09-05-mixed-audio-stop-ui-sync`
Base commit: `e28b0cb`
Commit hash: `29b8e8a` — fix(whisper-swift): sync workspace with finalized mixed-audio result on stop

## 1. Acceptance Criteria Source

未經 spec-writer，人工列出（使用者 2026-09-05 於對話中 approve），見
`HANDOFF_CODEX_MIXED_AUDIO_STOP_UI_SYNC.md` 的「驗收條件（AC）」章節。

## 2. AC 驗收結果

- **AC-1** ✅ `CaptureUIRules.shouldSyncFinalizedMixedAudioResult(isDraftDirty:)` 新增在
  `Sources/WhisperApp/AudioInputMode.swift`，`isDraftDirty: false → true`、
  `isDraftDirty: true → false`。單元測試 `finalizedMixedAudioResultSyncsOnlyWhenDraftIsClean()`
  （`Tests/WhisperAppTests/CaptureUIRulesTests.swift`）涵蓋兩個 case，通過。

- **AC-2** ✅（程式碼審查確認，真機走查待補）`stopMixedAudioRecording()`
  （`Sources/WhisperApp/ContentView+CaptureActions.swift`）：`history.updateResult(...)`
  呼叫本身維持無條件執行（`if let ... = try history.updateResult(...)` 這個 optional-binding
  只影響「有沒有拿到 entry 可以 restore」，不影響「有沒有寫入」——`updateResult` 內部邏輯本身
  沒有被 guard 包住，找不到 id 時回傳 nil 才會跳過 restore，這跟原本行為一致，不是新引入的
  跳過寫入路徑）。只有 `restore(updated)` 這一步受
  `CaptureUIRules.shouldSyncFinalizedMixedAudioResult(isDraftDirty: isDraftDirty)` guard。
  SwiftUI View 內的呼叫無法直接單元測試，真機走查步驟見第 5 節。

- **AC-3** ✅（程式碼審查確認，真機外觀待補）`transcriptContent`
  （`Sources/WhisperApp/ContentView+Results.swift`）新增：
  ```swift
  if mixedAudioRecording.isDraining {
      Text("⏳ 混音錄音已停止，最後片段仍在轉錄中…")
          .font(.caption).foregroundStyle(.orange)
  }
  ```
  直接讀 `mixedAudioRecording.isDraining`（既有 computed property，未新增判斷邏輯），
  放置在既有狀態列 `HStack { Text(worker.jobStatus)... }` 與 `ProgressView(value: worker.progress)`
  之間。真機外觀走查步驟見第 5 節。

- **AC-4** ✅ `git diff --stat e28b0cb HEAD -- macos/WhisperApp`（commit 對 commit，排除本
  worktree 既有未提交的 SPIKE 變更）只列 4 個檔案：`AudioInputMode.swift`、
  `ContentView+CaptureActions.swift`、`ContentView+Results.swift`、`CaptureUIRulesTests.swift`。
  未觸碰 `MixedAudioRecordingController.swift`/其 Tests/`TranscriptionHistoryStore.swift`/
  `TranscriptOverwriteGuard.swift`。（working-tree 版的 `git diff --stat e28b0cb -- macos/WhisperApp`
  仍會列出 `MixedAudioRecordingController.swift` 與其 Tests，那是本 worktree 既有、未提交的
  SPIKE，非本次改動，詳見第 4 節與第 6 節。）

- **AC-5** ✅ `swift test`：196 tests / 32 suites，僅 `MixedAudioRecordingControllerTests` 下的
  `debugSeparateTracksSpikeProducesTwoFilesWithContent()`（3 issues）失敗——此為 baseline 已知的
  SPIKE 測試，需要 `WHISPER_DEBUG_SEPARATE_TRACKS=1` 才會執行完整邏輯。已用
  `env WHISPER_DEBUG_SEPARATE_TRACKS=1 swift test --filter debugSeparateTracksSpike` 單獨驗證
  該測試在正確環境下全過（見第 3 節輸出）。`LiveRecordingControllerTests` 本次完整套件執行
  結果為全過（`✔ Suite LiveRecordingControllerTests passed`），未出現 baseline 提及的 device-recovery
  flake。新加的 `CaptureUIRulesTests` 全過。

- **AC-6** ✅ `swift build` 乾淨，`grep -Ei "warning:|error:"` 無輸出。

## 3. `swift test` 實際輸出（tail）

```
✔ Test transcribeTracksAcceptedProgressAndCompletedEvents() passed after 1.281 seconds.
✔ Test stopDuringStartWaitsForStartAndConcurrentStopsShareOneDrain() passed after 1.280 seconds.
✘ Suite MixedAudioRecordingControllerTests failed after 1.282 seconds with 3 issues.
✔ Test startsWorkerReceivesReadyAndPongThenStops() passed after 1.323 seconds.
✔ Suite WorkerSupervisorTests passed after 1.325 seconds.
✔ Test laterDeviceEventCannotIndefinitelyPostponeRecovery() passed after 1.452 seconds.
✔ Suite LiveRecordingControllerTests passed after 1.454 seconds.
✘ Test run with 196 tests in 32 suites failed after 1.455 seconds with 3 issues.
```

新測試（`CaptureUIRulesTests`）：
```
◇ Test finalizedMixedAudioResultSyncsOnlyWhenDraftIsClean() started.
✔ Test finalizedMixedAudioResultSyncsOnlyWhenDraftIsClean() passed after 0.02... seconds.
✔ Suite CaptureUIRulesTests passed after 0.029 seconds.
```

單獨驗證 SPIKE 測試（附證據，非本次引入）：
```
env WHISPER_DEBUG_SEPARATE_TRACKS=1 swift test --filter debugSeparateTracksSpike
...
[SPIKE] mic debug exists: true
[SPIKE] system debug exists: true
[SPIKE] mic debug size: 48
✔ Test debugSeparateTracksSpikeProducesTwoFilesWithContent() passed after 0.014 seconds.
✔ Suite MixedAudioRecordingControllerTests passed after 0.014 seconds.
✔ Test run with 1 test in 1 suite passed after 0.015 seconds.
```

`swift build` warning/error grep：
```
(no output — clean)
```

## 4. `git diff --stat` 摘要

Commit-only（`e28b0cb..HEAD`，本任務實際改動範圍）：
```
 .../Sources/WhisperApp/AudioInputMode.swift           |  7 +++++++
 .../WhisperApp/ContentView+CaptureActions.swift       | 19 +++++++++++--------
 .../Sources/WhisperApp/ContentView+Results.swift      |  4 ++++
 .../Tests/WhisperAppTests/CaptureUIRulesTests.swift   |  6 ++++++
 4 files changed, 28 insertions(+), 8 deletions(-)
```

Working-tree（含既有未提交 SPIKE，非本次改動，僅供對照）：
```
.../Sources/WhisperApp/AudioInputMode.swift        |  7 +++
 .../WhisperApp/ContentView+CaptureActions.swift    | 19 ++++---
 .../Sources/WhisperApp/ContentView+Results.swift   |  4 ++
 .../WhisperApp/MixedAudioRecordingController.swift | 60 +++++++++++++++++++---
 .../WhisperAppTests/CaptureUIRulesTests.swift      |  6 +++
 .../MixedAudioRecordingControllerTests.swift       | 48 +++++++++++++++++
 6 files changed, 130 insertions(+), 14 deletions(-)
```

## 5. Known caveats — 需要真機走查

以下項目 SwiftUI View 行為/UX 無法用單元測試驗證，留給真機走查：

- **AC-2 真機走查步驟**：
  1. 啟動 App，切到混音模式，開始錄一段夠長（例如 > 1 分鐘、跨過至少一次 15 秒 chunk 輪替）
     的混音錄音，錄音期間不要手動編輯逐字稿（維持 `isDraftDirty == false`）。
  2. 按「停止」。確認畫面上的逐字稿內容在停止後有更新成最終合併結果（不需要手動切去 History
     再切回來才看得到）。
  3. 重複步驟 1，但這次在停止前先手動在逐字稿欄位打幾個字（讓 `isDraftDirty == true`），再按停止。
     確認畫面**不會**被覆蓋（使用者手動編輯的內容保留），同時去 History 分頁確認該筆 entry 的
     內容仍然有被正確存檔（`updateResult` 無條件執行）。

- **AC-3 真機走查步驟**：
  1. 錄一段混音錄音並停止，觀察停止當下畫面是否短暫出現
     「⏳ 混音錄音已停止，最後片段仍在轉錄中…」提示（橘字、caption 字級）。
  2. 確認提示在最後一段轉錄完成後自動消失（`isDraining` 轉為 `false`）。
  3. 確認提示位置（狀態列與進度條之間）在視覺上不突兀、不影響既有版面。

## 6. 確認事項

- ✅ 未執行 `git push`（僅本機 commit）。
- ✅ 未修改、未讀取、未 commit `MixedAudioRecordingController.swift` 或
  `MixedAudioRecordingControllerTests.swift`（僅讀用既有的 `isDraining` property，未觸碰其定義）；
  commit 使用明確 `git add <file>`（4 個檔案），未使用 `git add -A`/`git add .`，該兩份 SPIKE
  檔案在 commit 後仍維持 working-tree 未提交狀態。
- ✅ 未存取 `~/Library/Application Support/WhisperSTT/.env`、Keychain。
- ✅ 未執行 `package.sh`、未 build .app、未寫入 Notion/README。
- 未發現 iCloud 同步造成的 stray `* 2.swift` / `Contents 2` 檔案
  （`find . -name "* 2.*" -not -path "*/.build/*"` 在開工前執行過，無結果）。

## 7. Commit hash 清單

- `29b8e8a` — fix(whisper-swift): sync workspace with finalized mixed-audio result on stop
  （branch `handoff/2026-09-05-mixed-audio-stop-ui-sync`，parent `e28b0cb`）
