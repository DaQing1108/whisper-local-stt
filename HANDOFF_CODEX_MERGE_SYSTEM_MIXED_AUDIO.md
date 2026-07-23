# Codex Task: 合併「系統音訊」與「混音」兩個即時錄音模式
Date: 2026-07-23
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc (whisper-swift branch)
Base commit: 894f50b

## BLUF
把兩個功能高度重疊、UI 層深度重複的即時錄音模式（純系統音訊 / 混音）合併成一個：拿掉「系統音訊」這個獨立入口，改成「混音」模式裡一個「同時錄我的聲音」開關，關掉就等同原本系統音訊模式的行為。動機：這次 session 修 RMS 靜音預過濾 bug 時，因為 `acceptFinalizedChunk`/`acceptCompletedChunk` 這類邏輯在 `SystemAudioRecordingController` 跟 `MixedAudioRecordingController` 兩邊逐字重複，同一個 bug 要改兩次，維護成本明顯偏高。

## 任務邊界

### 可改動
- `macos/WhisperApp/Sources/WhisperApp/AudioInputMode.swift`：刪除 `AudioInputMode` 的 `.system` case（enum 從 4 個 case 變 3 個：`.standard`/`.live`/`.mixed`）；`CaptureUIRules.shouldLockMode`/`CaptureUIRules.stopIsEnabled` 簽名拿掉對 `.system`/`systemPendingOrActive` 的參照
- `macos/WhisperApp/Sources/WhisperApp/AppSettingsStore.swift`（或現有存放 `audioMode` 設定的檔案）：新增一個持久化設定 `includeMicrophoneInMixedMode: Bool`（比照現有其他設定的 persist/restore 慣例，不要只放記憶體變數）
- `macos/WhisperApp/Sources/WhisperApp/MixedAudioRecordingController.swift`：`start(outputURL:)` 的麥克風權限檢查邏輯——目前是「拒絕就直接 throw `MixedAudioRecordingError.microphonePermissionDenied`，整個錄音失敗」；改成「呼叫端決定要不要錄麥克風（透過新的 bool 參數或 controller 屬性），不要錄的話完全跳過麥克風權限檢查與 `microphoneBackend.start(...)`，只用系統音訊；要錄的話維持現有的必要權限行為（拒絕就 throw，不退化）」。底層 `MixedAudioAccumulator.drain()` 已經能處理麥克風沒資料的情況（`if microphone.isEmpty { return system }`），這部分不用改
- `macos/WhisperApp/Sources/WhisperApp/ContentView+CaptureActions.swift`：6 處 `switch audioMode { ... }` 都要拿掉 `.system` case（`isPrimaryRecording`、`primaryActionEnabled`、`primaryButtonLabel`、`primaryStatusText`、`modeHelpText`、`primaryCaptureAction()` 的 start 分支與 stop 分支）；`.mixed` 分支的文字判斷要依 `includeMicrophoneInMixedMode` 動態顯示（例如 `primaryButtonLabel` 的「開始錄製系統音訊」vs「開始錄製麥克風與系統音訊」原本是 `.system`/`.mixed` 兩個 case，合併後變成 `.mixed` 一個 case 內的三元判斷）；刪除 `startSystemAudioRecording()`/`stopSystemAudioRecording()`，兩者的呼叫全部改呼叫 `startMixedAudioRecording()`/`stopMixedAudioRecording()`；`anyCaptureActive`（`CaptureUIRules.shouldLockMode` 呼叫處）拿掉 `systemPendingOrActive` 參數
- `macos/WhisperApp/Sources/WhisperApp/ContentView+Capture.swift`：`settingsPopoverContent` 裡 `if audioMode == .system || audioMode == .mixed` 改成 `if audioMode == .mixed`；在同一個區塊新增「同時錄我的聲音」開關（`Toggle`，綁定 `includeMicrophoneInMixedMode`，只在 `audioMode == .mixed` 時顯示，且錄音進行中要 disable，比照現有 `PillSegmentedControl` 的 `isDisabled: anyCaptureActive` 模式）
- `macos/WhisperApp/Sources/WhisperApp/ContentView+Results.swift`：刪除 `systemAudioRecording.acceptCompletedChunk(...)` 那整段完成後處理邏輯（約在 346-397 行附近），確認邏輯完全併入既有 `mixedAudioRecording.acceptCompletedChunk(...)` 那段（399-446 行附近），不需要新邏輯，該段已經能處理麥克風沒資料的情況
- `macos/WhisperApp/Sources/WhisperApp/ContentView.swift`：拿掉 `systemAudioRecording`（`@Environment(SystemAudioRecordingController.self)`）與 `systemAudioHistoryEntryID`（`@State`）兩個宣告
- `macos/WhisperApp/Sources/WhisperApp/WhisperApp.swift`：拿掉 `systemAudioRecording`、`systemAudioLifecycle`、`systemAudioBackend` 三者的建立與 `.environment(systemAudioRecording)` 注入；`systemAudioPermission`/`systemAudioBackend`（screen recording 用）如果混音模式仍需要就保留，不要一併刪掉——先確認 `MixedAudioRecordingController` 建構時需要哪些依賴再決定
- 刪除整個檔案：`macos/WhisperApp/Sources/WhisperApp/SystemAudioRecordingController.swift`
- 測試：刪除 `macos/WhisperApp/Tests/WhisperAppTests/SystemAudioLiveRecordingControllerTests.swift`；如果裡面有涵蓋到「純系統音訊、無麥克風」情境但 `MixedAudioRecordingControllerTests.swift` 目前沒有對應覆蓋的測試案例，改寫成新案例併入 `MixedAudioRecordingControllerTests.swift`（不要憑感覺跳過，先比對兩份測試檔案內容再決定哪些要保留）；`MixedAudioRecordingControllerTests.swift` 新增至少一個測試證明 `includeMicrophoneInMixedMode == false` 時麥克風權限被拒絕不影響錄音成功

### 禁止改動
- `SystemAudioCaptureLifecycleController.swift`／`SystemAudioPermissionController.swift`／`ScreenCaptureKitAudioBackend.swift`：這些是螢幕錄製權限與底層音訊擷取的共用基礎設施，合併後的混音模式仍然依賴，不要動
- `LiveRecordingController.swift`（純麥克風即時轉錄，`AudioInputMode.live`）：這是第三種獨立模式，這次只處理系統音訊/混音的合併，不在範圍內。這個檔案剛在 base commit `894f50b` 加了 job stall watchdog，不要碰
- 任何 `whisper_core.py`／`transcribe_common.py`／Python worker 端檔案：這次改動完全在 Swift UI/controller 層，不影響轉錄協定
- 歷史紀錄相關資料結構（`TranscriptionHistoryStore`／`transcription-history.json` 的 schema）：不動資料格式，只影響「未來新錄音」用哪個入口

### 執行方不能做（留給 Claude Code）
- git push（留給接手驗收的 Claude Code，作為獨立驗證後才讓改動進入共用狀態的把關點）
- 可以 git commit（本機留下完整紀錄＋完成報告），但不要 git push
- 打包（`scripts/build_worker_runtime.sh`／`scripts/build_swiftui_app.sh`）、簽名、安裝到 `~/Applications`
- 存取 `~/Library/Application Support/WhisperSTT/.env`、Keychain
- 真機測試（AC-7 標注 [需使用者驗證]，你只需要跑得動 build/test，實際錄音驗證留給使用者）

## 驗收條件（AC）
已鎖定，不得新增：
- □ AC-1. `swift build` 成功，無編譯錯誤/警告
- □ AC-2. `swift test` 全部通過（不得低於現況 171/171）
- □ AC-3. `AudioInputMode.allCases` 只剩 3 個 case（`.standard`/`.live`/`.mixed`），`.system` 已移除
- □ AC-4. 新測試證明：`includeMicrophoneInMixedMode == false` 時，`MixedAudioRecordingController.start()` 即使麥克風權限被拒絕也能成功開始錄音（不拋出 `microphonePermissionDenied`）
- □ AC-5. 新測試證明：`includeMicrophoneInMixedMode == true` 時，麥克風權限被拒絕會正確拋出錯誤（維持原本混音模式的行為不退化）
- □ AC-6. `git grep -n "AudioInputMode.system\|\.system:"` 在改動後的檔案裡沒有殘留引用（確認 6 處 switch 跟其他地方都改乾淨）
- □ AC-7. [需使用者驗證] 真機測試：切換「同時錄我的聲音」開關關閉/開啟，兩種情況都能正常錄音轉錄——你不用執行這條，只要在 VERIFICATION.md 標注「待使用者驗證」即可

## 驗收指令（完成後自己跑，AC-1/AC-2/AC-6 全部綠才算完成）
```bash
cd macos/WhisperApp
swift build
swift test
cd ../..
git grep -n "AudioInputMode.system\|\.system:" -- macos/WhisperApp/Sources macos/WhisperApp/Tests
```
（`git grep` 找到任何殘留結果都算 AC-6 未通過，除非該行是無關的巧合命中，需在 VERIFICATION.md 說明）

## 完成後產出
在專案根目錄建立 `HANDOFF_CLAUDE_MERGE_SYSTEM_MIXED_AUDIO_VERIFICATION.md`，內容包含：
1. 每條 AC 的驗收結果（✅ / ❌ + 原因，AC-7 標注「待使用者驗證」）
2. 驗收指令的實際輸出（貼上 `swift test` 的完整結果、`git grep` 的實際輸出，即使是空的也要說明「無輸出，確認通過」）
3. `git diff --stat` 摘要
4. Known caveats（若有，例如 SystemAudioLiveRecordingControllerTests.swift 裡有哪些案例決定不保留、為什麼）
5. 不應該 commit 的內容說明（例如本檔案跟 `.env`）
