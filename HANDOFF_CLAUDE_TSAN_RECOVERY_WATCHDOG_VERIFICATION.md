# Verification: TSAN Recovery Watchdog Timing Race 修復
Date: 2026-09-19
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc
Base commit: 3aaeb31
Verified by: Claude Code（whisper-swift worktree session，含獨立 code-reviewer subagent 兩輪審查）

## 1. AC Source
沿用 `HANDOFF_CODEX_TSAN_RECOVERY_WATCHDOG.md`：未經 spec-writer，人工列出（L2 任務，已與使用者確認跳過正式 spec-writer）。

## 2. 每條 AC 結果

- **AC-1** ✅ — `swift build` 在 whisper-swift 分支乾淨無 warning。
- **AC-2** ✅ — `swift test --filter LiveRecordingControllerTests` 22/22 通過（正常模式，無 TSAN；20 個原有測試 + 2 個新增的 `TaskRecoveryWatchdogScheduler` 直接單元測試）。
- **AC-3** ✅ — `swift test --sanitize=thread --filter LiveRecordingControllerTests` 連續執行 3 次全過（另有獨立 review agent 額外重跑 2 次，共 5 次全綠，0 個 TSAN race warning）。
- **AC-4** ✅ — 完整 `swift test`（全專案）220 個測試 / 33 suites 全過。測試總數較修改前（218 個）**增加** 2 個（新增的 scheduler 單元測試），符合「不得比修改前少」。
- **AC-5** ✅ — `git diff --stat` 只觸碰 `LiveRecordingController.swift` 與 `LiveRecordingControllerTests.swift` 兩個檔案。
- **AC-6** ✅ — `LiveRecordingController` 建構子新增 `recoveryWatchdogScheduler: any RecoveryWatchdogScheduling = TaskRecoveryWatchdogScheduler()` 參數，有預設值；18 個未修改的既有測試呼叫端（未傳入此參數）全數編譯通過並執行成功，證明向後相容。

## 3. 驗收指令實際輸出

### AC-1：swift build
```
$ cd macos/WhisperApp
$ swift build -c debug
Building for debugging...
[Planning deferred tasks]
...
Build complete!
```
（無 warning 輸出）

### AC-2：正常模式測試
```
$ swift test --filter LiveRecordingControllerTests
...
✔ Test recoveryWatchdogSchedulerAllowsReschedulingAfterCancel() passed after 2.091 seconds.
✔ Test recoveryWatchdogSchedulerIgnoresReschedulingWhilePending() passed after 2.090 seconds.
✔ Suite LiveRecordingControllerTests passed after 2.092 seconds.
✔ Test run with 22 tests in 1 suite passed after 2.093 seconds.
```

### AC-3：TSAN 連續 3 次執行（本次交付方）
第 1 次：
```
$ swift test --sanitize=thread --scratch-path /tmp/whisper-swift-tsan-check --filter LiveRecordingControllerTests
...
✔ Test recoveryWatchdogSchedulerAllowsReschedulingAfterCancel() passed after 2.202 seconds.
✔ Test recoveryWatchdogSchedulerIgnoresReschedulingWhilePending() passed after 2.202 seconds.
✔ Suite LiveRecordingControllerTests passed after 2.203 seconds.
✔ Test run with 22 tests in 1 suite passed after 2.203 seconds.
```
第 2 次：
```
✔ Test recoveryWatchdogSchedulerAllowsReschedulingAfterCancel() passed after 2.159 seconds.
✔ Test recoveryWatchdogSchedulerIgnoresReschedulingWhilePending() passed after 2.159 seconds.
✔ Suite LiveRecordingControllerTests passed after 2.160 seconds.
✔ Test run with 22 tests in 1 suite passed after 2.160 seconds.
```
第 3 次：
```
✔ Test recoveryWatchdogSchedulerIgnoresReschedulingWhilePending() passed after 2.157 seconds.
✔ Test recoveryWatchdogSchedulerAllowsReschedulingAfterCancel() passed after 2.157 seconds.
✔ Suite LiveRecordingControllerTests passed after 2.158 seconds.
✔ Test run with 22 tests in 1 suite passed after 2.160 seconds.
```
（獨立 review agent 另外重跑 2 次，同樣全綠，且以 `grep -i "warning\|race\|ThreadSanitizer"` 確認 log 中無任何命中）

### AC-4：完整 swift test（全專案）
```
$ swift test
...
✔ Test recoveryWatchdogSchedulerIgnoresReschedulingWhilePending() passed after 2.339 seconds.
✔ Test recoveryWatchdogSchedulerAllowsReschedulingAfterCancel() passed after 2.339 seconds.
✔ Suite LiveRecordingControllerTests passed after 2.342 seconds.
✔ Test run with 220 tests in 33 suites passed after 2.344 seconds.
```
（連續執行 3 次，皆為 220 tests / 33 suites 全過；亦以 `--sanitize=thread` 跑過全專案一次，同樣 220/220 全過）

### AC-5：改動範圍
```
$ git diff --stat
.../WhisperApp/LiveRecordingController.swift       | 59 ++++++++++++------
 .../LiveRecordingControllerTests.swift             | 72 ++++++++++++++++++++--
 2 files changed, 105 insertions(+), 26 deletions(-)
```

## 4. git diff --stat 摘要

```
macos/WhisperApp/Sources/WhisperApp/LiveRecordingController.swift       | 59 ++++++++++++------
macos/WhisperApp/Tests/WhisperAppTests/LiveRecordingControllerTests.swift | 72 ++++++++++++++++++++--
 2 files changed, 105 insertions(+), 26 deletions(-)
```

僅兩個檔案改動，符合任務邊界。

## 5. Known caveats

- **範圍已擴大，超出原始 handoff 明確列出的 2 個測試**：獨立 review agent（Step 7）發現同檔案內另有 3 個測試（`deviceChangeFinalizesCurrentChunkAndResumesCapture`、`deviceChangeResumesWhenNoMatchingEndEventArrives`、`repeatedDeviceEventsDebounceBeforeRestartingCapture`）同樣依賴真實 700ms `Task.sleep` 去賭同一個 500ms watchdog，屬同一根因的 TSAN race。使用者已在對話中明確確認一併修復（記錄於 `.loop-state-20260919-tsw4.md` 的 `scope_exception`），本次一併轉換為 fake scheduler + `.fire()`。若這超出原發起方的預期範圍，請告知，可視需要拆分或討論。

- **第 4 個測試 `sleepWaitsForWakeInsteadOfStartingTheDeviceRecoveryWatchdog` 刻意不修改**：獨立 review agent 第一輪誤判此測試也有同樣 race，經查證後確認錯誤並在第二輪 review 中撤回。此測試發出 `.interruptionBegan`（sleep 原因），而 `suspendCaptureForRecovery(reason:)` 只有 `.deviceChange` 原因才會呼叫 `scheduleRecoveryWatchdog()`（見 `LiveRecordingController.swift` 約 line 581-583 的 `if case .deviceChange = reason`）。因此此測試中 watchdog 從未被排程，700ms sleep 是在驗證「沒有」自動恢復發生，不是賭真實計時器會贏，不屬於本次修復的問題類別。

- **新增的 2 個 `TaskRecoveryWatchdogScheduler` 直接單元測試使用真實 `Task.sleep`**：`recoveryWatchdogSchedulerIgnoresReschedulingWhilePending` 與 `recoveryWatchdogSchedulerAllowsReschedulingAfterCancel` 直接測試 scheduler 本身的計時邏輯（而非透過 fake scheduler），因此無法完全避免真實計時。首版用 50ms 間隔 + 150ms 等待（3倍餘裕）在滿載時真的 flake 過一次，已修正為 10ms 間隔 + 2 秒等待（200倍餘裕），並經本次 3 次全套件重跑 + 獨立 review agent 額外 2 次重跑（共 5 次）+ TSAN 5 次重跑皆穩定通過。這是刻意的工程判斷（測試 scheduler 自身無法完全消除真實計時依賴），非重新引入原始 bug 類別——原始問題是「緊繃餘裕（700ms vs 500ms，僅 1.4 倍）賭贏一個被多個測試共用的 production 依賴」，這次是「寬鬆餘裕（200倍）測試獨立的 scheduler 元件，無其他測試依賴其結果」。若未來 scheduler 計時邏輯再變動，建議改用可注入的 fake clock，而非重複「real sleep + 餘裕」模式（獨立 review agent 標記為 MEDIUM、不阻擋本次交付的追蹤項）。

- **`TaskRecoveryWatchdogScheduler.scheduleWatchdog` 的語意保留**：原始 `scheduleRecoveryWatchdog()` 的 guard `recoveryWatchdog == nil else { return }` 語意是「已排程就忽略」而非「重置計時器」。若照 handoff 原始建議程式碼（`cancelWatchdog()` 後才排程新的）實作，會改變 production 行為。已修正為 `guard task == nil else { return }`，保留原始語意，並新增 `recoveryWatchdogSchedulerIgnoresReschedulingWhilePending` 直接驗證此行為，同時保留 `recoveryWatchdogSchedulerAllowsReschedulingAfterCancel` 驗證 `cancelWatchdog()` 確實能解除這個 guard。

- **`laterDeviceEventCannotIndefinitelyPostponeRecovery` 的 fake scheduler 呼叫次數**：`ManualRecoveryWatchdogScheduler.scheduleWatchdog` 實際被呼叫 2 次（不是原先 Plan 假設的 1 次），因為 fake test double 本身沒有模擬「已有 pending task 就忽略」的邏輯，只是單純記錄每次呼叫並覆蓋 action。已將測試斷言從「`scheduleCallCount == 1`」改為移除該斷言，只保留原本驗證的行為結果（`state == .recording`、`backend.startCount == 2`），並在其餘轉換測試中也未使用 `scheduleCallCount` 斷言，避免產生無法真正區分「正確 coalesce」與「錯誤 reset」行為的偽陽性測試。這個語意的真正驗證改由新增的 2 個 scheduler 直接單元測試承擔。

- **本機環境沒有 `act`**，無法完全模擬 GitHub Actions runner，已改用本機直接重現每個驗收指令的方式驗證。

## 6. 不應該 commit 的內容說明

本任務未涉及 `.env`、Keychain 憑證或任何敏感檔案。改動範圍僅 `LiveRecordingController.swift` 與 `LiveRecordingControllerTests.swift`。

驗證過程中產生的本機 scratch path（`/tmp/whisper-swift-build-check`、`/tmp/whisper-swift-full-check*`、`/tmp/whisper-swift-tsan-check`、`/tmp/whisper-swift-tsan-full`、`/tmp/whisper-swift-flake-check`、`/tmp/whisper-swift-closeout`）已在驗證完成後清除，未進入版控。

工作目錄中另存在兩個 untracked 文件（`HANDOFF_CODEX_TSAN_RECOVERY_WATCHDOG.md` 本身、既有的 `HANDOFF_CLAUDE_WHISPER_SWIFT_OPTIMIZATION_ASSESSMENT.md`）——後者為非本次任務產生的既有文件，是否納入 commit 由 PLAN 端決定。本次僅 commit `LiveRecordingController.swift`、`LiveRecordingControllerTests.swift`、`HANDOFF_CODEX_TSAN_RECOVERY_WATCHDOG.md`（本次任務輸入文件）與本驗收文件本身。

.github/workflows/ci.yml 未改動，TSAN job 維持 advisory（`continue-on-error: true`）。
