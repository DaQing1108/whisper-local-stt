# Codex Task: Standard 模式錄音中裝置變更自動復原
Date: 2026-07-23
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc (whisper-swift branch)
Base commit: bcbf808

## BLUF
Standard 模式（單次錄音，`StandardRecordingController`/`MicrophoneCaptureService`）錄音中途若遇到音訊裝置重新設定（例如藍牙耳機協商），底層 `AVAudioEngine` 會被 macOS 靜默停止，且完全沒有機制發現或復原，導致整段錄音變成 0 frames 空檔案，UI 卻顯示「Completed」沒有任何錯誤提示。使用者真機測試已重現：log 顯示 `iounit configuration changed > stopping the engine` 發生在 `engine.start()` 後 11 毫秒，之後整整 22 秒（到使用者按停止為止）引擎再也沒有啟動過。

## 根因（已用 log 追蹤驗證，非猜測）

`MicrophoneCaptureService`（`MicrophoneCaptureService.swift`）底層用的 `AVAudioEngineCaptureBackend` 跟 `LiveRecordingController.swift`（即時轉錄模式）是**同一個** backend class。差異在於：`LiveRecordingController` 有注入 `AudioCaptureEventMonitoring`（實作是 `AudioCaptureRecovery.swift` 裡的 `SystemAudioCaptureEventMonitor`，監聽 `NotificationCenter` 的 `.AVAudioEngineConfigurationChange` 等通知），偵測到裝置變更會觸發既有的 `suspendCaptureForRecovery`/`resumeCaptureAfterInterruption`/`scheduleRecoveryWatchdog` 復原流程；`MicrophoneCaptureService` 完全沒有這一層——裝置重新設定導致引擎停止，這**不是**透過 `AudioCaptureBackend.onError` callback 通知的（那是給音訊處理過程中的錯誤用的），是獨立的系統通知，目前完全沒人在聽，所以 `RecordingStateMachine` 一直停在 `.recording` 狀態，UI 完全無感知，最終 `stop()` 直接把幾乎沒收到任何 PCM 資料的 session 當正常結果 finalize 成一個空的/接近空的 WAV。

## 任務邊界

### 可改動

- `macos/WhisperApp/Sources/WhisperApp/MicrophoneCaptureService.swift`：
  在 `MicrophoneCaptureService` class：
  1. 新增建構參數 `eventMonitor: any AudioCaptureEventMonitoring = SystemAudioCaptureEventMonitor()`（`AudioCaptureEventMonitoring` protocol 與 `SystemAudioCaptureEventMonitor` 已存在於 `AudioCaptureRecovery.swift`，直接重用，不要重新發明）。
  2. `start(outputURL:at:)` 成功啟動 backend 後，呼叫 `eventMonitor.start { [weak self] event in self?.handleSystemEvent(event) }`。
  3. `stop()`／`reset()`／`captureFailed(_:sessionID:)` 這幾個會離開 `.recording` 狀態的路徑都要呼叫 `eventMonitor.stop()`，避免殘留監聽。
  4. 新增 `private func handleSystemEvent(_ event: AudioCaptureSystemEvent)`：
     - 只在 `machine.state == .recording(...)` 時處理 `.configurationChanged`/`.deviceChanged`；其餘事件（`.interruptionBegan`/`.interruptionEnded`）與非 `.recording` 狀態本次不處理，直接忽略。
     - 需要 debounce，避免短時間內連續事件觸發重複重啟——參考 `LiveRecordingController.swift` 裡 `ignoreDeviceEventsUntil`/`scheduleRecoveryWatchdog` 的既有寫法，抓等效的防抖動時間窗（可以沿用同樣的數值，例如 500ms/2s，實際數字自行判斷合理性並在 VERIFICATION.md 說明理由）。
     - 復原動作：**不要** finalize 現有 `CaptureSession`／不要開新檔案（這點跟 `LiveRecordingController` 的「結束當前 chunk、開新 chunk」策略不同，因為 Standard 模式是單一連續錄音、沒有分 chunk 的概念）。正確做法是保留同一個 `session`，只重啟底層 `backend`：呼叫 `backend.stop()` 再重新呼叫 `backend.start(onPCM:onError:)`（用跟原本 `start()` 一樣的 `onPCM`/`onError` closure，讓 PCM 繼續 append 進同一個 `session`）。重啟失敗時的行為比照現有 `captureFailed` 邏輯（fail 整個 session）。

- 測試檔案：先找到 `MicrophoneCaptureService` 現有的測試檔案（可能是 `MicrophoneCaptureServiceTests.swift` 或類似名稱，`swift test --list-tests` 或 `grep -rl "MicrophoneCaptureService" macos/WhisperApp/Tests` 可以找到），仿照 `LiveRecordingControllerTests.swift` 裡驗證裝置變更復原/debounce 的既有測試案例（例如 `deviceChangeResumesWhenNoMatchingEndEventArrives`、`repeatedDeviceEventsDebounceBeforeRestartingCapture`）寫對應版本。

### 禁止改動

- `StandardRecordingController.swift`：除非為了把 `eventMonitor` 參數透傳出去才需要碰，否則盡量把改動侷限在 `MicrophoneCaptureService` 內部，`eventMonitor` 用預設值即可，不強制要求 `StandardRecordingController` 也能注入假的 monitor（除非寫測試時發現不透傳就測不到，再評估要不要加）。
- `LiveRecordingController.swift`／`MixedAudioRecordingController.swift`：兩者現有的裝置變更復原邏輯已驗證正常運作，不要修改。**注意：可能有另一個 Claude Code session 同時在處理 `LiveRecordingController.swift` 的逐字稿累加問題，這是完全不同的任務，兩邊都不要碰對方的檔案，降低衝突風險。**
- `AudioCaptureRecovery.swift`：`AudioCaptureEventMonitoring`/`SystemAudioCaptureEventMonitor` 已經是通用、可重用的既有實作，直接拿來用，不要修改這個檔案本身。
- 任何 Python worker 端檔案：這次改動完全在 Swift 音訊擷取層，跟轉錄協定無關。
- `.interruptionBegan`/`.interruptionEnded`（睡眠/喚醒）復原：本次只處理已確認重現的裝置變更情境，不要順便擴大範圍去做睡眠復原。

### 執行方不能做（留給 Claude Code）
- git push（留給接手驗收的 Claude Code，作為獨立驗證後才讓改動進入共用狀態的把關點）
- 可以 git commit（本機留下完整紀錄＋完成報告），但不要 git push
- 打包（`scripts/build_worker_runtime.sh`／`scripts/build_swiftui_app.sh`）、簽名、安裝到 `~/Applications`
- 存取 `~/Library/Application Support/WhisperSTT/.env`、Keychain
- 真機測試（AC-6 標注 [需使用者驗證]，藍牙裝置協商這類情境無法在單元測試環境重現，你只需要跑得動 build/test，實際驗證留給使用者）

## 驗收條件（AC）
已鎖定，不得新增：
- □ AC-1. `swift build` 成功，無編譯錯誤/警告
- □ AC-2. `swift test` 全部通過（不得低於現況 163/163）
- □ AC-3. 新測試證明：錄音中收到 `.configurationChanged` 事件時，backend 會重啟且沿用同一個 session（不會 finalize 舊檔案另開新檔）
- □ AC-4. 新測試證明：短時間內收到多個裝置事件會 debounce，不會重複重啟
- □ AC-5. 新測試證明：非 `.recording` 狀態（例如 `.idle`）收到裝置事件不會有任何動作
- □ AC-6. [需使用者驗證] 真機測試：錄音中途觸發藍牙裝置協商（或用系統設定切換輸入裝置模擬），確認錄音不會變成 0 frames，且最終逐字稿正常產出——你不用執行這條，只要在 VERIFICATION.md 標注「待使用者驗證」即可

## 驗收指令（完成後自己跑，AC-1/AC-2 全部綠才算完成）
```bash
cd macos/WhisperApp
swift build
swift test
```

## 完成後產出
在專案根目錄建立 `HANDOFF_CLAUDE_MIC_DEVICE_RECOVERY_VERIFICATION.md`，內容包含：
1. 每條 AC 的驗收結果（✅ / ❌ + 原因，AC-6 標注「待使用者驗證」）
2. 驗收指令的實際輸出（貼上 `swift test` 的完整結果）
3. `git diff --stat` 摘要
4. Known caveats（若有，例如 debounce 時間窗選了多少、為什麼；重啟失敗時的實際行為）
5. 不應該 commit 的內容說明（例如本檔案跟 `.env`）
