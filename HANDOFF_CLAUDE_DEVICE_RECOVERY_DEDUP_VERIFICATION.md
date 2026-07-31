# Verification: 裝置復原邏輯純去重

Date: 2026-08-01
Executed by: Claude Code (directly, per user instruction — no separate handoff/receive round trip)
Base commit: 00fd4af (HEAD of whisper-swift, already synced with origin at start of this task)
Handoff source: HANDOFF_CODEX_DEVICE_RECOVERY_DEDUP.md

## 1. 每條 AC 的驗收結果

- **AC-1**（`swift test` 全數通過，測試數不得低於 162）：✅
  170/170 通過（含既有測試 + 本次新增 4 個 `DeviceEventDebouncerTests`）。
  過程中 `LiveRecordingControllerTests.laterDeviceEventCannotIndefinitelyPostponeRecovery` 出現一次計時類間歇性失敗，`--filter` 單獨重跑立即通過；這是既有、與本次改動檔案無關的已知 flaky test（前一次 sleep/wake 修復的驗證報告中也記錄過同一顆）。最終完整跑一次 `swift test`（未 filter）170/170 全綠，見下方輸出。

- **AC-2**（`MicrophoneCaptureService.swift` 和 `LiveRecordingController.swift` 對外可觀察行為零改變）：✅
  兩處呼叫點都只是把原本 inline 的 `if let ignoreDeviceEventsUntil, ignoreDeviceEventsUntil > Date() { return }` 判斷改為呼叫 `DeviceEventDebouncer.evaluate(...)` 並讀取回傳的 `shouldIgnore`；`ignoreDeviceEventsUntil` 何時被寫入、寫入什麼值，兩邊都維持原邏輯不變（`MicrophoneCaptureService` 在通過 debounce 檢查後立刻設定新視窗；`LiveRecordingController` 的 `.configurationChanged` 分支本來就不寫入該欄位，只讀，這次也刻意不寫入，寫入邏輯仍留在 `resumeCaptureAfterInterruption()` 裡未動）。所有既有測試（包含 `repeatedDeviceEventsDebounceBeforeRestartingCapture`、`deviceChangeFinalizesCurrentChunkAndResumesCapture`、`repeatedDeviceRecoveryFailureStopsAfterBoundedAttempts` 等 debounce/裝置事件相關案例）逐行未修改即全數通過，證明行為零改變。

- **AC-3**（新增至少一個針對共用 helper 本身的獨立單元測試，涵蓋視窗內忽略、視窗外允許、允許後正確設定下一個視窗）：✅
  新增 `macos/WhisperApp/Tests/WhisperAppTests/DeviceEventDebouncerTests.swift`，4 個測試：
  - `ignoresEventInsideWindow` — 視窗內忽略，且 `nextIgnoreUntil` 原樣回傳既有視窗
  - `allowsEventOutsideWindow` — 視窗已過期時允許
  - `allowsEventWhenNoPriorWindow` — 從未設過視窗（`nil`）時允許
  - `settingNextWindowExtendsIntervalFromNow` — 允許後 `nextIgnoreUntil == now + interval`

- **AC-4**（`git diff --stat` 僅 `AudioCaptureRecovery.swift`/`MicrophoneCaptureService.swift`/`LiveRecordingController.swift` 及其測試檔案被改動，未觸碰 `StandardRecordingController.swift`）：✅
  見下方 diff 摘要；`StandardRecordingController.swift` 未出現在 diff 中。

## 2. 驗收指令的實際輸出

```
$ cd macos/WhisperApp
$ swift test
...
✔ Test ignoresEventInsideWindow() passed
✔ Test allowsEventOutsideWindow() passed
✔ Test allowsEventWhenNoPriorWindow() passed
✔ Test settingNextWindowExtendsIntervalFromNow() passed
✔ Suite DeviceEventDebouncerTests passed
...
✔ Test repeatedDeviceEventsDebounceBeforeRestartingCapture() passed
✔ Test deviceChangeFinalizesCurrentChunkAndResumesCapture() passed
✔ Test repeatedDeviceRecoveryFailureStopsAfterBoundedAttempts() passed
✔ Test laterDeviceEventCannotIndefinitelyPostponeRecovery() passed
✔ Suite LiveRecordingControllerTests passed
...
✔ Test run with 170 tests in 29 suites passed after 1.197 seconds.
```

（中途一次未 filter 的執行曾出現 `laterDeviceEventCannotIndefinitelyPostponeRecovery` 的計時類間歇性失敗，`swift test --filter laterDeviceEventCannotIndefinitelyPostponeRecovery` 單獨重跑 0.640s 內通過；最終完整重跑一次 170/170 全綠，即上方輸出。）

## 3. `git diff --stat` 摘要

```
 .../Sources/WhisperApp/AudioCaptureRecovery.swift  | 23 ++++++++++++++++++++++
 .../WhisperApp/LiveRecordingController.swift       |  3 ++-
 .../WhisperApp/MicrophoneCaptureService.swift      |  7 +++++--
 3 files changed, 30 insertions(+), 3 deletions(-)
```

加上新增的 untracked 測試檔案 `macos/WhisperApp/Tests/WhisperAppTests/DeviceEventDebouncerTests.swift`（39 行）。與 HANDOFF 文件「可改動」清單完全一致，`StandardRecordingController.swift`、`MixedAudioRecordingController.swift`、`AudioInputMode.swift`、`ContentView+CaptureActions.swift`、`ContentView+Capture.swift`、`WhisperApp.swift` 均未觸碰。

## 4. Known caveats

- Helper 命名為 `DeviceEventDebouncer`（enum，namespace 用途）+ `DeviceEventDebounceDecision`（純資料 struct），符合文件建議的「小型共用型別」但實作上拆成「決策邏輯」與「決策結果」兩個型別，而非單一 struct 身兼儲存狀態——因為文件明確要求 helper「不擁有」`ignoreDeviceEventsUntil` 本身的儲存狀態，狀態繼續留在兩個呼叫端。
- `evaluate()` 回傳的 `nextIgnoreUntil` 在 `LiveRecordingController.swift` 的 `.configurationChanged` 分支中被刻意忽略不寫回（`guard !decision.shouldIgnore else { return }` 之後沒有賦值動作），因為原始程式碼在這個分支本來就只讀不寫——寫入動作留在 `resumeCaptureAfterInterruption()`（第 544 行左右）維持不動，這是刻意的行為保留，不是遺漏。
- `LiveRecordingController.swift` 呼叫 `evaluate` 時 interval 直接沿用原本的字面量 `2`，未額外抽成具名常數（`MicrophoneCaptureService` 那邊已有 `Self.deviceEventDebounceInterval`），因為文件範圍只允許改動「debounce 判斷」這一行，不擴大到新增常數這種額外整理。

## 5. 不應該 commit 的內容說明

本次改動只涉及 3 個 Swift 原始碼檔案 + 1 個新測試檔案，未觸碰 `.env`、Keychain、`package.sh`/打包簽名相關檔案。`git status` 確認沒有把 `HANDOFF_CODEX_DEVICE_RECOVERY_DEDUP.md` 以外的其他殘留檔案意外納入（該檔案本身依規格保留在 repo 根目錄，這次連同完成報告一併 commit，作為任務紀錄）。
