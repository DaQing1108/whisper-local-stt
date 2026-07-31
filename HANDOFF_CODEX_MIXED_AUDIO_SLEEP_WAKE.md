# Codex Task: Mixed Audio Sleep/Wake Recovery
Date: 2026-07-31
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc (branch `whisper-swift`)
Base commit: 9458e54
Schema version: 1.1

## BLUF
`MixedAudioRecordingController`（混音錄音，mic + 系統音訊）完全沒有監聽 macOS 睡眠/喚醒事件，
筆電休眠恢復後錄音狀態會卡死、「停止」按鈕永遠失敗——修好它，讓混音模式跟已經有完整實作的
`LiveRecordingController` 一樣，能在睡眠時暫停、喚醒後恢復，且不論恢復成功與否，狀態機都不會卡死。

## 根因（已確認，不需要重新調查）

`MixedAudioRecordingController.swift` 沒有 `eventMonitor` 屬性，完全沒接
`AudioCaptureRecovery.swift` 裡現成的 `SystemAudioCaptureEventMonitor`（它已經監聽
`NSWorkspace.willSleepNotification` / `didWakeNotification`，`LiveRecordingController` 早就在用）。

實際發生的事：
1. 筆電休眠時，OS 強制關閉 `SCStream`（系統音訊）與 `AVAudioEngine`（麥克風），但沒有任何事件處理器
   同步這件事，`microphoneActive`/`systemActive`/`fullSession` 全部維持原樣，`state` 停在 `.recording`。
2. 使用者按「停止」時，`performStop()`（`MixedAudioRecordingController.swift:252`）對著已死的
   backend 呼叫 `.stop()`，可能拋錯。
3. **關鍵 bug**：`performStop()` 裡 `catch { stopError = error }` 這個分支，一旦任一 backend 的
   `stop()` 失敗，`microphoneActive = false` / `self.fullSession = nil` 等清理**都不會執行**
   （只有成功路徑會清）。`hasActiveOperation` 因此永遠 `true`，狀態機卡死：既無法真正停止，
   也無法重新開始新錄音。

## 任務邊界

### 可改動

1. **`macos/WhisperApp/Sources/WhisperApp/MixedAudioRecordingController.swift`**
   - `MixedAudioRecordingState` enum（第 4–10 行）：新增 `case recovering`（放在 `.recording` 和
     `.stopping` 之間，模仿 `LiveRecordingState` 的順序）
   - 新增 stored properties（放在既有 `private var isHandlingCaptureFailure = false` 附近）：
     ```swift
     private let eventMonitor: any AudioCaptureEventMonitoring
     private var includeMicrophone = true
     private var recoveryAttempts = 0
     private let maximumRecoveryAttempts = 2
     private var resumeTask: Task<Void, Never>?
     ```
   - `init(...)`：新增參數 `eventMonitor: any AudioCaptureEventMonitoring = SystemAudioCaptureEventMonitor()`
     （放在 `scheduler` 之後、`transcriber` 之前，跟 `LiveRecordingController.init` 的參數順序一致），
     存進 `self.eventMonitor`。**不需要改 `WhisperApp.swift` 的組裝點**，因為有預設值。
   - `start(outputURL:includeMicrophone:)`：
     - 一進來就記住 `self.includeMicrophone = includeMicrophone`
     - 成功啟動兩個 backend、`state` 設為 `.recording`/`.stopping` 之後，呼叫
       `eventMonitor.start { [weak self] event in self?.handleSystemEvent(event) }`
     - 重置 `recoveryAttempts = 0`
   - `canStop` computed property（第 103 行）：改成
     ```swift
     var canStop: Bool { fullSession != nil && (microphoneActive || systemActive || state == .recovering) }
     ```
     （否則 `.recovering` 期間 `microphoneActive`/`systemActive` 都是 false，UI 的 Stop 按鈕會被鎖住）
   - `performStop()`（第 252 行開始）：在 `guard let fullSession else { throw ... }` 之後，
     立刻加：
     ```swift
     resumeTask?.cancel()
     resumeTask = nil
     eventMonitor.stop()
     ```
   - 新增私有方法（放在 `handleCaptureFailure` 附近）：

     ```swift
     private func handleSystemEvent(_ event: AudioCaptureSystemEvent) {
         switch event {
         case .interruptionBegan:
             suspendCaptureForSleep()
         case .interruptionEnded:
             if state == .recovering { startResumeTask() }
         case .configurationChanged, .deviceChanged:
             // 混音模式的裝置切換恢復是既有的獨立缺口，不在本次範圍內處理。
             break
         }
     }

     private func suspendCaptureForSleep() {
         guard state == .recording else { return }
         state = .recovering
         scheduler.cancel()
         if microphoneActive {
             try? microphoneBackend.stop()
             microphoneActive = false
         }
         // 不在這裡 await systemBackend.stop()：willSleepNotification 的 handler 是同步呼叫，
         // 無法在裡面 await。OS 本身會在睡眠時強制中斷 SCStream；真正的 stop-then-restart
         // 留到 resumeCaptureAfterSleep() 的 async context 裡做（見下方，那裡會先呼叫
         // systemBackend.stop() 清空死掉的 stream 參照，這是必要的，見下方「已知陷阱」）。
         systemActive = false
     }

     private func startResumeTask() {
         resumeTask?.cancel()
         resumeTask = Task { [weak self] in
             await self?.resumeCaptureAfterSleep()
             self?.resumeTask = nil
         }
     }

     private func resumeCaptureAfterSleep() async {
         guard state == .recovering else { return }
         guard accumulator != nil else {
             failRecovery("Mixed audio session lost during recovery")
             return
         }
         guard submissionQueue.isWorkerReady else {
             failRecovery("Python Worker unavailable during audio recovery")
             return
         }
         // 必須先 stop() 清空 ScreenCaptureKitAudioBackend 內部的舊 stream 參照，
         // 否則 start() 的 `guard stream == nil` 會無聲提前 return，恢復會靜默失敗。
         try? await systemBackend.stop()
         errorBox = MixedAudioErrorBox()

         var lastError: Error?
         while recoveryAttempts < maximumRecoveryAttempts {
             guard !Task.isCancelled else { return }
             do {
                 try await systemBackend.start()
                 systemActive = true
                 if includeMicrophone {
                     try microphoneBackend.start(
                         onPCM: { [weak self] in self?.accumulator?.appendMicrophone($0) },
                         onError: { [weak self] error in self?.errorBox?.record(error) }
                     )
                     microphoneActive = true
                 }
                 scheduler.schedule(every: flushInterval) { [weak self] in self?.rotateChunk() }
                 state = .recording
                 recoveryAttempts = 0
                 return
             } catch {
                 lastError = error
                 recoveryAttempts += 1
                 if systemActive { try? await systemBackend.stop(); systemActive = false }
                 if microphoneActive { try? microphoneBackend.stop(); microphoneActive = false }
             }
         }
         failRecovery("Mixed audio recovery failed: \(lastError?.localizedDescription ?? "unknown error")")
     }

     private func failRecovery(_ message: String) {
         resumeTask?.cancel()
         resumeTask = nil
         eventMonitor.stop()
         scheduler.cancel()
         if microphoneActive { try? microphoneBackend.stop(); microphoneActive = false }
         systemActive = false
         if !didFinalFlush { finalFlush(); didFinalFlush = true }
         if let fullSession, let url = try? fullSession.finalize() {
             lastFinalizedURL = url
         }
         self.fullSession = nil
         self.chunkSession = nil
         accumulator = nil
         errorBox = nil
         state = .failed(message)
     }
     ```

     注意：`finalFlush()`、`didFinalFlush`、`MixedAudioErrorBox` 都是既有的 private
     成員/型別，直接沿用，不要重新定義。

2. **`macos/WhisperApp/Sources/WhisperApp/ContentView+CaptureActions.swift`**（293–299 行）
   - `mixedAudioRecordingStatusText` 的 `switch mixedAudioRecording.state` 是 exhaustive，
     加新 case 後編譯會失敗，必須補：
     ```swift
     case .recovering: "Recovering mixed audio capture…"
     ```
     位置放在 `case .recording: ...` 之後、`case .stopping: ...` 之前。

3. **`macos/WhisperApp/Tests/WhisperAppTests/MixedAudioRecordingControllerTests.swift`**
   - 新增一個 private fake（複製 `LiveRecordingControllerTests.swift` 第 44–51 行的
     `ManualAudioEventMonitor`，一字不改地搬過來即可，型別完全通用）：
     ```swift
     @MainActor
     private final class ManualAudioEventMonitor: AudioCaptureEventMonitoring {
         private var handler: (@MainActor @Sendable (AudioCaptureSystemEvent) -> Void)?
         func start(handler: @escaping @MainActor @Sendable (AudioCaptureSystemEvent) -> Void) {
             self.handler = handler
         }
         func stop() { handler = nil }
         func emit(_ event: AudioCaptureSystemEvent) { handler?(event) }
     }
     ```
   - 新增 4 個測試（見下方 AC，每條 AC 對應一個測試）。所有既有測試建構
     `MixedAudioRecordingController(...)` 時都沒有傳 `eventMonitor` 參數，因為有預設值，
     **不需要動任何一個既有測試**——只有新測試需要手動注入 `ManualAudioEventMonitor`。
   - 因為 `.interruptionEnded` 的恢復路徑內部用了 `Task { ... }`（`startResumeTask()`），
     測試裡 `monitor.emit(.interruptionEnded)` 之後，斷言前要 `await Task.yield()` 一次或多次
     讓 Task 有機會跑完（可以參考 `stopDuringStartWaitsForStartAndConcurrentStopsShareOneDrain`
     測試裡處理並行 Task 的方式，用一個小的 `for _ in 0..<50 where ... { try await
     Task.sleep(for: .milliseconds(20)) }` 輪詢等待比單次 `Task.yield()` 更穩，因為
     `systemBackend.start()`/`stop()` 都真的是 async suspension point）。

### 禁止改動
- `macos/WhisperApp/Sources/WhisperApp/AudioCaptureRecovery.swift` —
  `SystemAudioCaptureEventMonitor`/`AudioCaptureSystemEvent` 已經是通用元件，直接重用，不要改
- `macos/WhisperApp/Sources/WhisperApp/WhisperApp.swift` — `eventMonitor` 有預設值，組裝點不用動
- `macos/WhisperApp/Sources/WhisperApp/LiveRecordingController.swift` — 只是參考對照組，
  不要動它的任何邏輯
- 不要處理 `.configurationChanged` / `.deviceChanged`（Bluetooth 裝置切換等）——這是混音模式
  既有的、獨立於本次任務的缺口，範圍已經跟使用者確認過，不在這次修復內

### 執行方不能做（留給 Claude Code）
- `git push`（一律留給接手驗收的 Claude Code，作為獨立重新驗證後才讓改動進入共用狀態的把關點）
- 可以 `git commit`（本機留下完整紀錄＋完成報告），但不要 push
- `package.sh` / 打包 / 簽名（這次改動不涉及打包驗證，是純 Swift source + test 改動）
- 存取 `~/Library/Application Support/WhisperSTT/.env` 或任何本機 Keychain 操作（用不到）

## 已知陷阱（踩過的坑，直接避開）

1. **`ScreenCaptureKitAudioBackend.start()` 的 `guard stream == nil, !isStarting else { return }`**
   ——如果 `stream` 還非 nil（例如睡眠時我方沒有機會 stop() 乾淨），呼叫 `start()`
   會**無聲**什麼都不做地 return，不會拋錯，也不會真的開始擷取。所以 `resumeCaptureAfterSleep()`
   一定要先 `try? await systemBackend.stop()` 才能呼叫 `systemBackend.start()`。
2. **`willSleepNotification` 是同步派發**（`AudioCaptureRecovery.swift` 裡用
   `synchronously: true`），但 `SystemAudioCaptureBackend.stop()` 是 `async throws`——
   不可能在同步的睡眠事件 handler 裡 `await` 它。設計上刻意讓 `suspendCaptureForSleep()`
   只同步標記 `systemActive = false`，真正的 async stop-then-restart 留到喚醒時的
   `resumeCaptureAfterSleep()` 裡做。**不要把這個「改成」在 suspend 裡硬塞一個
   fire-and-forget `Task { await systemBackend.stop() }`**——那樣的 Task 不保證在系統實際
   睡眠前執行到，且沒有必要（OS 反正會強制中斷 stream，我方在喚醒時的 stop-then-restart
   已經足夠清乾淨）。
3. **恢復失敗時務必清空 `fullSession`/`chunkSession`/`accumulator`/`errorBox`**，這是本次
   修復的核心目的：只要這四個沒清乾淨，`hasActiveOperation` 就會永遠 `true`，
   使用者永遠無法重新開始錄音——這正是原始 bug 的直接成因，Review 階段會重點檢查這一點。

## 驗收條件（AC）
AC Source: 未經 spec-writer，來自 engineering-discipline-loop Step 1 Explore + Step 2 Plan 的人工分析（已與使用者對齊方向）

```
□ AC-1. 睡眠（.interruptionBegan）觸發後，controller.state 立即變為 .recovering，
        且睡眠前已錄的音訊被保留（finalizedChunkURLs 不遺失）
□ AC-2. 喚醒（.interruptionEnded）後，controller 自動重啟兩個 backend（startCount 增加），
        state 回到 .recording，且能繼續錄音、繼續產生新的 finalized chunk
□ AC-3. 喚醒恢復失敗（bounded retry 用盡，例如 system backend 的 start() 持續拋錯）時，
        state 變為 .failed，且 hasActiveOperation 恢復 false
        （可以重新呼叫 start() 開始新錄音）——這條直接驗證原始 bug 已修復
□ AC-4. 在 .recovering 狀態下（等待喚醒期間）手動呼叫 stop()，能正常回傳最終 URL、
        state 回到 .idle，不掛起、不拋出非預期錯誤
□ AC-5. [需用戶驗證，執行方不需要也無法驗證這條] 真實筆電休眠/喚醒情境下，混音模式錄音
        能自動恢復或至少「停止」按鈕永遠可操作、不再卡死——留給接手的 Claude Code 記錄，
        由使用者在真機上實際休眠一次來確認
```

## 驗收指令（完成後自己跑，全部綠才算完成）
```bash
cd macos/WhisperApp
swift build
swift test
```
確認新增的 4 個測試（對應 AC-1 ~ AC-4）都在輸出中且通過，並確認既有測試套件（尤其
`MixedAudioRecordingControllerTests` 全部既有案例）沒有因為新增 `eventMonitor` 參數或
`canStop` 邏輯變更而回歸。

## Blockers（執行中卡住時使用）
若執行中發現規格不清楚或需要澄清，**不要重新發起一輪交接**，直接在本檔案這個區塊 append
具體問題、commit，並告知 PLAN 端：

```
### [日期] Blocker
Q: [具體問題]
影響：[卡住的是哪個 AC 或哪個改動]
```

PLAN 端下次上線只需讀這個區塊回覆，不必重新對齊整份規格。

## 完成後產出
在專案根目錄建立 `HANDOFF_CLAUDE_MIXED_AUDIO_SLEEP_WAKE_VERIFICATION.md`，內容包含：
1. Acceptance Criteria Source（沿用本文件：未經 spec-writer，人工列出）
2. 每條 AC 的驗收結果（✅ / ❌ + 原因），AC-5 標記為「留待使用者真機驗證」
3. 驗收指令的實際輸出（貼上 `swift test` 的完整結果，至少包含通過的測試數量）
4. `git diff --stat` 摘要
5. Known caveats（若有，例如 device-change 恢復仍是已知缺口）
6. 不應該 commit 的內容說明（本次應該沒有，但如果意外碰到 `.env`／`.loop-state-*.md` 之類的
   檔案要特別註明並確認沒有被 git add 進去）
