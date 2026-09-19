# Codex Task: TSAN Recovery Watchdog Timing Race 修復
Date: 2026-09-19
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper（whisper-swift 分支）
Base commit: 3aaeb31
Schema version: 1.1

## BLUF
LiveRecordingControllerTests 裡 repeatedDeviceRecoveryFailureStopsAfterBoundedAttempts 與 laterDeviceEventCannotIndefinitelyPostponeRecovery 兩個測試，靠「等待一段真實時間」去賭 production code 裡 500ms 的 recovery watchdog 真實計時器（Task.sleep）一定會先觸發。在 TSAN（swift test --sanitize=thread）插樁減速下，這個賭注會輸——log 完全沒有 TSAN race 警告，證實不是真正的資料競爭，純粹是測試對真實時間的容忍度不夠。要把這顆計時器抽成可注入介面，測試改用手動觸發的 fake scheduler，徹底消除這類真實時間 race。

## 視覺依據
無（純邏輯/測試基礎設施修改，無 UI 變動）。

## 任務邊界

### 可改動
- macos/WhisperApp/Sources/WhisperApp/LiveRecordingController.swift
  1. 新增一個 @MainActor protocol RecoveryWatchdogScheduling（放在檔案裡既有的 ChunkRotationScheduling，約 line 72-76 附近，風格仿照它）：
     ```swift
     @MainActor
     protocol RecoveryWatchdogScheduling: AnyObject {
         func scheduleWatchdog(after interval: TimeInterval, action: @escaping @MainActor @Sendable () -> Void)
         func cancelWatchdog()
     }
     ```
  2. 新增預設 production 實作（仿照 TimerChunkRotationScheduler 的寫法，但用 Task.sleep，因為原本就是 Task 不是 Timer）：
     ```swift
     @MainActor
     final class TaskRecoveryWatchdogScheduler: RecoveryWatchdogScheduling {
         private var task: Task<Void, Never>?

         func scheduleWatchdog(after interval: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
             cancelWatchdog()
             task = Task { @MainActor in
                 try? await Task.sleep(for: .seconds(interval))
                 guard !Task.isCancelled else { return }
                 action()
             }
         }

         func cancelWatchdog() {
             task?.cancel()
             task = nil
         }
     }
     ```
     行為必須與現行 scheduleRecoveryWatchdog()（line 585-593）完全等價：同樣是 500ms、同樣在觸發前檢查 Task.isCancelled、同樣在觸發後才呼叫 action（目前是 resumeCaptureAfterInterruption()）。
  3. LiveRecordingController 的 init(...)（約 line 292-325）新增參數：
     ```swift
     recoveryWatchdogScheduler: any RecoveryWatchdogScheduling = TaskRecoveryWatchdogScheduler(),
     ```
     必須有預設值——backward-compat 硬性要求（AC-6），所有現有呼叫端不得因此被迫改動。
  4. 移除 private var recoveryWatchdog: Task<Void, Never>?（line 287），改存 private let recoveryWatchdogScheduler: any RecoveryWatchdogScheduling（在 init 裡指派）。
  5. scheduleRecoveryWatchdog()（line 585-593）整個改寫為：
     ```swift
     private func scheduleRecoveryWatchdog() {
         recoveryWatchdogScheduler.scheduleWatchdog(after: 0.5) { [weak self] in
             self?.resumeCaptureAfterInterruption()
         }
     }
     ```
     注意：原本有 guard recoveryWatchdog == nil else { return } 這個「已排程就不要重複排程」的防呆——這個語意必須保留。因為上面 production 實作的 scheduleWatchdog 目前寫法是「呼叫就 cancel 舊的再開新的」，這其實改變了行為（原本是忽略重複呼叫，新版是重置計時器）。這點必須跟原始邏輯核對清楚，如果外部呼叫 scheduleRecoveryWatchdog() 兩次的時序在現有測試中有意義（例如 handleDeviceEvent() line 544-547 有 `if state == .recovering { scheduleRecoveryWatchdog() }` 這種重入路徑），要嘛在 TaskRecoveryWatchdogScheduler.scheduleWatchdog 內部保留「已有 pending task 就不重新排程」的邏輯（不要 cancel 舊的），要嘛在 LiveRecordingController 這層自己補一個旗標維持原語意。你要先讀懂 line 544-547 的呼叫情境再決定，不要憑空選一種寫法。
  6. 所有其他直接操作 recoveryWatchdog?.cancel(); recoveryWatchdog = nil 的地方（start() line 330-331、stop() line 367-368、captureFailed(_:sessionID:) line 450-451、submissionFailed(_:) line 461-462、workerBecameUnavailable(_:) line 478-479、fail(_:) line 501-502、resumeCaptureAfterInterruption() line 563-564，共 7 處），一律改成 recoveryWatchdogScheduler.cancelWatchdog()。
  7. makeOutputURL 以下、檔案結尾不動。

- macos/WhisperApp/Tests/WhisperAppTests/LiveRecordingControllerTests.swift
  1. 新增 test double（仿照既有 ManualRotationScheduler，約 line 33-41 附近）：
     ```swift
     @MainActor
     private final class ManualRecoveryWatchdogScheduler: RecoveryWatchdogScheduling {
         private var action: (@MainActor @Sendable () -> Void)?
         private(set) var scheduleCallCount = 0
         func scheduleWatchdog(after interval: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
             self.action = action
             scheduleCallCount += 1
         }
         func cancelWatchdog() { action = nil }
         func fire() {
             let toRun = action
             action = nil
             toRun?()
         }
     }
     ```
  2. repeatedDeviceRecoveryFailureStopsAfterBoundedAttempts（line 483-507）：建構 LiveRecordingController 時注入 recoveryWatchdogScheduler: ManualRecoveryWatchdogScheduler()（保留 local 變數方便呼叫 .fire()）。monitor.emit(.configurationChanged) 之後，移除 try await Task.sleep(for: .milliseconds(700))，改呼叫 scheduler.fire()（同步）。斷言不變：controller.state 是 .failed、backend.startCount == 3。
  3. laterDeviceEventCannotIndefinitelyPostponeRecovery（line 424-450）：同樣注入 ManualRecoveryWatchdogScheduler。monitor.emit(.deviceChanged) 後移除 try await Task.sleep(for: .milliseconds(300))，改呼叫 scheduler.fire()。monitor.emit(.configurationChanged) 後移除第二段 300ms sleep；注意這次呼叫因為 state 已經是 .recovering，handleDeviceEvent() 會走 scheduleRecoveryWatchdog() 這條路（重新排程或忽略，取決於上面第 5 點怎麼處理語意），要照該測試原本驗證的意圖（controller.state == .recording、backend.startCount == 2）去核對 .fire() 呼叫時機是否需要呼叫兩次或一次——跑起來斷言過了才算數，不要只憑推理。
  4. 檢查同檔案內其他會經過 scheduleRecoveryWatchdog() 路徑、但目前用真實 Task.sleep 等待的測試（至少要看：sleepWaitsForWakeInsteadOfStartingTheDeviceRecoveryWatchdog line 453-480、deviceChangeResumesWhenNoMatchingEndEventArrives line 361 起）。這兩個測試若同樣依賴 500ms 真實計時器來讓 assertion 成立，一併改用 ManualRecoveryWatchdogScheduler；若讀完後判斷它們測的是別的路徑則不動，並在 VERIFICATION.md 裡寫清楚為什麼不動。
  5. 其餘測試不要動。

### 禁止改動
- .github/workflows/ci.yml — TSAN job 保持 advisory（continue-on-error: true）不變
- jobStallTimeout / pauseRecoveryPollInterval / OrderedChunkSubmissionQueue 相關程式碼與測試
- 500ms watchdog 間隔本身、maximumRecoveryAttempts = 2 等既有時間常數
- 其他任何檔案

### 執行方不能做（留給 Claude Code）
- git push（留給接手驗收的 Claude Code，作為獨立驗證後才讓改動進入共用狀態的把關點）
- 可以 git commit（本機留下完整紀錄＋完成報告），但不要 git push
- package.sh / 打包 / 簽名
- 存取 ~/Library/Application Support/WhisperSTT/.env
- 任何需要本機 Keychain 的操作
- 修改 .github/workflows/ci.yml

## 驗收條件（AC）
AC Source: 未經 spec-writer，人工列出（L2 任務，已與使用者確認跳過正式 spec-writer）

- AC-1. swift build 在 whisper-swift 分支乾淨無 warning
- AC-2. swift test --filter LiveRecordingControllerTests 全過（正常模式，無 TSAN）
- AC-3. swift test --sanitize=thread --filter LiveRecordingControllerTests 全過，且連續執行 3 次結果一致
- AC-4. 完整 swift test（全專案）全過，測試總數不得比修改前少
- AC-5. git diff --stat 只觸碰 LiveRecordingController.swift 與 LiveRecordingControllerTests.swift 兩個檔案
- AC-6. LiveRecordingController 對外建構子簽章維持向後相容——新參數必須有預設值

## 驗收指令（完成後自己跑，全部綠才算完成）
```bash
cd macos/WhisperApp
swift build
swift test --filter LiveRecordingControllerTests
swift test --sanitize=thread --scratch-path /tmp/whisper-swift-tsan-handoff --filter LiveRecordingControllerTests
swift test --sanitize=thread --scratch-path /tmp/whisper-swift-tsan-handoff --filter LiveRecordingControllerTests
swift test --sanitize=thread --scratch-path /tmp/whisper-swift-tsan-handoff --filter LiveRecordingControllerTests
swift test
git diff --stat
```

## Blockers
執行中若發現規格不清楚，不要重新發起交接，直接在你建立的 HANDOFF_CODEX_TSAN_RECOVERY_WATCHDOG.md 這個區塊 append 具體問題、commit，並回訊息告知我。

## 完成後產出
在 whisper-swift 工作目錄根目錄建立 HANDOFF_CLAUDE_TSAN_RECOVERY_WATCHDOG_VERIFICATION.md，包含：
1. AC Source（未經 spec-writer，人工列出）
2. 每條 AC 結果（✅/❌ + 原因）
3. 驗收指令實際輸出（AC-3 三次 TSAN 重跑都要貼）
4. git diff --stat 摘要
5. Known caveats（例如第 5 點語意處理方式）
6. 不應該 commit 的內容說明
