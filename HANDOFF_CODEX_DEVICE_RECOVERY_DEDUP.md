# Codex Task: 裝置復原邏輯純去重
Date: 2026-07-24
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc (branch: whisper-swift)
Base commit: 8df17f8

## BLUF
`MicrophoneCaptureService.handleSystemEvent` 和 `LiveRecordingController.handleSystemEvent` 各自維護一套幾乎相同的「裝置事件 debounce」判斷邏輯（`ignoreDeviceEventsUntil: Date?` + 固定 2 秒視窗），抽成共用 helper 消除重複，但兩邊各自「怎麼重啟」的動作（Standard 是重啟 backend 沿用同一個 session；Live 是 suspend 進 `.recovering` 走既有 watchdog）完全不合併、不改變。這是一個純去重的低風險版本，明確不做先前被擱置的「Standard 委派 Live 架構」重寫。

## 任務邊界

### 可改動
- `macos/WhisperApp/Sources/WhisperApp/AudioCaptureRecovery.swift`
  新增一個小型共用型別（例如 `DeviceEventDebouncer`，實作時自行定案命名），純函式/小 struct，輸入目前時間、上次重啟時間、debounce interval，輸出「這次事件該不該被忽略」+ 若不忽略則給出下一個忽略截止時間。**不擁有** backend/session 重啟動作本身，只抽「要不要重啟」的判斷。
- `macos/WhisperApp/Sources/WhisperApp/MicrophoneCaptureService.swift`
  `ignoreDeviceEventsUntil`/`deviceEventDebounceInterval` 常數 + `handleSystemEvent` 裡的 debounce 判斷改為呼叫共用 helper。`guard machine.state.canStop, let session else { return }` 前置守衛維持不動（不屬於 helper 範圍）。`backend.stop()` + `backend.start()` 重啟動作維持不動。
- `macos/WhisperApp/Sources/WhisperApp/LiveRecordingController.swift`
  **僅** `.configurationChanged` 分支中 `ignoreDeviceEventsUntil` 的 debounce 判斷改為呼叫同一個共用 helper。`handleDeviceEvent()`/`suspendCaptureForRecovery`/`resumeCaptureAfterInterruption`/recovery watchdog 等既有狀態機邏輯一律不動。`.interruptionBegan`/`.interruptionEnded`（睡眠復原）路徑完全不動，那是 Live 專屬行為。
- `macos/WhisperApp/Tests/WhisperAppTests/MicrophoneCaptureServiceTests.swift`
  既有測試應零行為變化全過；若既有測試斷言方式與新 helper 呼叫方式衝突，做最小調整使其通過，不改變測試意圖。
- `macos/WhisperApp/Tests/WhisperAppTests/LiveRecordingControllerTests.swift`
  同上，既有 15s rotation/debounce 相關案例必須維持不動且全過。
- 新增一個獨立測試檔案或在既有測試檔案中新增：針對共用 helper 本身的單元測試（見 AC-3）。

### 禁止改動
- `macos/WhisperApp/Sources/WhisperApp/StandardRecordingController.swift` —— 對外委派/建構架構完全不動，這是先前被擱置的合併任務唯一想避免的風險點，本次刻意排除，若發現「不改這個檔案做不到」代表範圍理解有誤，**停止並回報，不要自行擴大範圍**
- `macos/WhisperApp/Sources/WhisperApp/MixedAudioRecordingController.swift` —— 不涉及此次重複邏輯，且已在先前任務中驗證正常運作，僅供參考
- `macos/WhisperApp/Sources/WhisperApp/AudioInputMode.swift`、`ContentView+CaptureActions.swift`、`ContentView+Capture.swift`、`WhisperApp.swift` —— UI 層與建構注入與此次改動完全無關
- `LiveRecordingController.swift` 的 `.interruptionBegan`/`.interruptionEnded`（睡眠復原）路徑 —— Live 模式獨有行為（Standard 模式沒有對應概念），不在「重複邏輯」範圍內，不合併
- Python worker 端所有程式碼

### 執行方不能做（留給 Claude Code）
- git push（一律留給接手驗收的 Claude Code，作為獨立驗證後才讓改動進入共用狀態的把關點）
- 可以 git commit（本機留下完整紀錄＋完成報告），但不要 git push
- `scripts/build_swiftui_app.sh` 打包 / 簽名
- 真機 smoke test
- 存取 `~/Library/Application Support/WhisperSTT/.env` 或任何本機 Keychain 操作

## 驗收條件（AC）
（已鎖定，不得新增或修改）

- [ ] AC-1. `swift test` 全數通過，測試數不得低於目前的 162
- [ ] AC-2. `MicrophoneCaptureService.swift` 和 `LiveRecordingController.swift` 對外可觀察行為（public API 簽名、`state`/`errorMessage` 等屬性語意）零改變
- [ ] AC-3. 新增至少一個針對共用 helper 本身的獨立單元測試（涵蓋：視窗內忽略、視窗外允許、允許後正確設定下一個視窗）
- [ ] AC-4. `git diff --stat` 顯示僅 `AudioCaptureRecovery.swift`/`MicrophoneCaptureService.swift`/`LiveRecordingController.swift` 及其測試檔案被改動，未觸碰 `StandardRecordingController.swift`

## 驗收指令（完成後自己跑，全部綠才算完成）
```bash
cd /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc/macos/WhisperApp
swift test
```

## 完成後產出
在專案根目錄（`.worktrees/swiftui-python-poc/`）建立 `HANDOFF_CLAUDE_DEVICE_RECOVERY_DEDUP_VERIFICATION.md`，內容包含：
1. 每條 AC 的驗收結果（✅ / ❌ + 原因）
2. 驗收指令的實際輸出（貼上 `swift test` 完整結果）
3. `git diff --stat` 摘要
4. Known caveats（若有，例如 helper 命名、debounce 視窗語意的實作細節）
5. 不應該 commit 的內容說明（本任務應該沒有，若有請說明）

完成後 `git commit`（本機留下紀錄），但**不要 `git push`**。
