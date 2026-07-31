# Verification: Mixed Audio Sleep/Wake Recovery
Date: 2026-07-31
Executed by: Claude Code (directly, per user instruction — no separate handoff/receive round trip this time)
Base commit: 9458e54
Handoff source: HANDOFF_CODEX_MIXED_AUDIO_SLEEP_WAKE.md (schema v1.1)

## 1. Acceptance Criteria Source
沿用 HANDOFF_CODEX_MIXED_AUDIO_SLEEP_WAKE.md：未經 spec-writer，來自 engineering-discipline-loop Step 1 Explore + Step 2 Plan 的人工分析（已與使用者對齊方向）。

本次執行前，使用者已明確授權跳過本 session 的 discipline-loop 前置關卡（該檔案目錄無 `.loop-state-*.md`），理由：HANDOFF 文件本身已包含完整 Explore/Plan/AC/已知陷阱，視同已完成對應步驟。

## 2. 每條 AC 的驗收結果

- **AC-1**（睡眠觸發 → `.recovering`，已錄音訊保留）：✅
  對應測試：`sleepNotificationSuspendsCaptureAndPreservesFinalizedChunks`
  斷言：`monitor.emit(.interruptionBegan)` 後 `controller.state == .recovering`、`mic.stopCount == 1`、`finalizedChunkURLs` 與睡眠前完全一致。

- **AC-2**（喚醒 → 自動重啟兩個 backend、`state` 回到 `.recording`、能繼續錄音）：✅
  對應測試：`wakeNotificationRestartsBackendsAndResumesRecording`
  斷言：`system.startCount` 從 1 變 2（重啟）、恢復後 `state == .recording`，喚醒後模擬新的 mic/system PCM + `scheduler.fire()` 確實產生新的 `finalizedChunkURLs`。

- **AC-3**（恢復失敗、bounded retry 用盡 → `.failed`，`hasActiveOperation` 恢復 false，可重新 `start()`）：✅
  對應測試：`recoveryFailureExhaustsRetriesAndUnlocksRestart`
  斷言：注入 `system.startError` 使恢復重試全部失敗後，`controller.state.isFailed`、`!controller.hasActiveOperation`、`controller.canStart` 皆成立；清除 `startError` 後重新 `start()` 成功並回到 `.recording` —— 這條直接驗證原始 bug（狀態機卡死）已修復。

- **AC-4**（`.recovering` 狀態下手動 `stop()`，正常回傳最終 URL、`state` 回到 `.idle`、不掛起不拋非預期錯誤）：✅
  對應測試：`stoppingWhileRecoveringFinalizesSessionCleanly`
  斷言：`.interruptionBegan` 後於 `.recovering` 狀態呼叫 `controller.stop()`，回傳值等於原始 `url`，`state == .idle`，`!hasActiveOperation`。

- **AC-5**：⏸️ 留待使用者真機驗證（執行方不需要也無法驗證這條）。需要使用者在真實筆電上實際休眠/喚醒一次，確認混音模式錄音能自動恢復，或至少「停止」按鈕不再永久卡死。

## 3. 驗收指令的實際輸出

```
$ cd macos/WhisperApp
$ swift build
Build complete!

$ swift test
...
✔ Test sleepNotificationSuspendsCaptureAndPreservesFinalizedChunks() passed
✔ Test wakeNotificationRestartsBackendsAndResumesRecording() passed
✔ Test recoveryFailureExhaustsRetriesAndUnlocksRestart() passed
✔ Test stoppingWhileRecoveringFinalizesSessionCleanly() passed
✔ Suite MixedAudioRecordingControllerTests passed
...
✔ Test run with 166 tests in 28 suites passed after 1.319 seconds.
```

新增的 4 個測試（對應 AC-1~AC-4）皆在輸出中且通過。`MixedAudioRecordingControllerTests` 既有 14 個案例全數維持通過（新增 `eventMonitor` 建構參數有預設值，既有測試呼叫點無需修改）。

補充：中途曾單獨重跑過一次 `swift test`（未 `--filter`），`LiveRecordingControllerTests.laterDeviceEventCannotIndefinitelyPostponeRecovery` 出現一次計時類間歇性失敗（`.recovering` vs `.recording`、`startCount 1` vs `2`），單獨用 `--filter` 重跑該測試立即通過；這是既有、與本次改動檔案（`MixedAudioRecordingController*`/`ContentView+CaptureActions.swift`）無關的 flaky test（同一顆 flaky test 在上一輪 checkpoint 的 `[checkpoint] fix(swift): add LocalizedError...` 工作中也曾出現過一次，屬已知狀況）。最終完整跑一次 `swift test`（未 filter）166/166 全綠，已附上方輸出。

## 4. `git diff --stat` 摘要

```
 .../WhisperApp/ContentView+CaptureActions.swift    |   1 +
 .../WhisperApp/MixedAudioRecordingController.swift | 112 +++++++++++++-
 .../MixedAudioRecordingControllerTests.swift       | 165 +++++++++++++++++++++
 3 files changed, 277 insertions(+), 1 deletion(-)
```

與 HANDOFF 文件「可改動」清單完全一致（3 個檔案，無其他檔案被觸碰）：
1. `MixedAudioRecordingController.swift` — 新增 `.recovering` state、`eventMonitor`/`includeMicrophone`/`recoveryAttempts`/`maximumRecoveryAttempts`/`resumeTask` 屬性、`init` 新增 `eventMonitor` 參數（有預設值）、`canStop` 加入 `.recovering` 分支、`performStop()` 開頭加入 resume/monitor 清理、新增 `handleSystemEvent`/`suspendCaptureForSleep`/`startResumeTask`/`resumeCaptureAfterSleep`/`failRecovery` 五個私有方法
2. `ContentView+CaptureActions.swift` — `mixedAudioRecordingStatusText` 補上 `.recovering` case
3. `MixedAudioRecordingControllerTests.swift` — 新增 `ManualAudioEventMonitor` fake（照搬 `LiveRecordingControllerTests.swift`）、`MixedSystemBackend` 新增 `startError` 支援、新增 4 個測試對應 AC-1~AC-4

## 5. Known caveats

- `.configurationChanged` / `.deviceChanged`（藍牙裝置切換等）刻意不處理，維持混音模式既有的獨立缺口，範圍已在 HANDOFF 文件中與使用者對齊，不在本次修復內。
- AC-5 真機睡眠/喚醒情境未經自動化驗證，僅靠單元測試裡的 `ManualAudioEventMonitor` 模擬 `NSWorkspace` 通知，真實 `SCStream`/`AVAudioEngine` 在真正睡眠下的行為（例如 OS 實際何時強制中斷 stream）仍待使用者真機確認。
- 未依 HANDOFF 文件的「Blockers」流程留下任何條目——執行過程中沒有遇到規格不清楚或需要澄清的地方；`isWorkerReady` 起初以為是新符號需要確認，查證後發現是 `OrderedChunkSubmissionQueue`（定義於 `LiveRecordingController.swift:112`）既有的屬性，`MixedAudioRecordingController` 本來就持有同一個 `submissionQueue` 實例，直接可用，不算真正的 blocker。

## 6. 不應該 commit 的內容說明

本次改動只涉及 3 個 Swift 原始碼/測試檔案，未觸碰 `.env`、Keychain、`package.sh`/打包簽名相關檔案。執行過程中確認 `git status` 沒有意外把任何 `.loop-state-*.md`（本 session 未產生新的）或其他 untracked handoff 文件一併 `git add` 進 commit——commit 只包含上述 3 個檔案的 diff。
