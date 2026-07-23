# Codex Task: 修復即時轉錄模式（純麥克風）多個 chunk 逐字稿互相覆蓋
Date: 2026-07-23
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc (whisper-swift branch)
Base commit: bcbf808

## BLUF
即時轉錄模式（純麥克風，`AudioInputMode.live`）錄音跨越多個 15 秒 chunk 時，畫面上的逐字稿只顯示「最後一個完成的 chunk」內容，前面幾個 chunk 的轉錄結果會被覆蓋消失，也沒有累積時間戳。動機：真機測試錄了 60 秒（4 個 chunk），4 個 chunk 全部正確送出轉錄並完成（上一個 job stall watchdog 問題已修復，commit 894f50b），但顯示邏輯完全沒有跨 chunk 累加機制——這個缺口早在更早一次 RMS 靜音過濾修復時就被記錄「LiveRecordingController 沒有本地 duration bookkeeping，排除在該次範圍外」，這次要正式補上。

## 根因（已用程式碼追蹤驗證，非猜測）

- `ContentView+Results.swift:244-246` 的 `transcriptText` computed property 直接讀 `worker.resultText`/`worker.partialText`，這是目前即時模式逐字稿畫面實際綁定的來源。
- `WorkerSupervisor.swift` 的 `apply(event)` 在 `"completed"` case 每次都用 `resultText = event.payload["text"]?.string ?? ""` **覆蓋**（非累加），任何一個 job 完成都會把上一個 job 的結果整個蓋掉。
- `ContentView+Results.swift:344-425` 的 `showLatestWorkerResultIfNeeded()` 是實際處理「worker 完成一個 job 時要做什麼」的地方：先檢查 `mixedAudioRecording.acceptCompletedChunk(...)`（內部會先用 `ownsChunk` 判斷該 chunk 是否屬於 mixed 模式），若屬於就用 `mixedAudioRecording.transcriptText`（累加後的完整逐字稿）建立/更新 history entry；若不屬於，就直接用 `completed.text`（單一 chunk 的文字，覆蓋式）建立 `transientEntry`。這段本來是設計給 Standard 模式（單次請求單一結果，本來就不需要累加）用的，但即時模式目前完全沒有 `liveRecording.ownsChunk`/`liveRecording.acceptCompletedChunk` 這一層，所以每個 live chunk 都會落到這個「不屬於任何 controller」的 fallback 分支，導致多 chunk 互相覆蓋。
- 對照組 `MixedAudioRecordingController.swift:353-384` 的 `acceptCompletedChunk(url:text:segments:durationSeconds:)` 是正確、已驗證運作正常的參考範本：用 `ownsChunk` + `completedChunkURLs.insert(url).inserted` 去重、用 `transcriptDurationSeconds` 做時間戳 offset、組 `TranscriptionSegment` 陣列（offset 過的 start/end）、用 `TranscriptTimecodeFormatter.render(...)` 產生帶時間戳的文字段落並累加進 `transcriptText`（`\n` 串接），最後推進 `transcriptDurationSeconds += chunkDuration`。

## 任務邊界

### 可改動

- `macos/WhisperApp/Sources/WhisperApp/LiveRecordingController.swift`：
  在 `LiveRecordingController` class 新增：
  - `private(set) var transcriptText: String = ""`
  - `private(set) var transcriptSegments: [TranscriptionSegment] = []`
  - `private(set) var transcriptDurationSeconds: Double = 0`
  - `func ownsChunk(_ url: URL) -> Bool { finalizedChunkURLs.contains(url) }`（直接用既有的 `finalizedChunkURLs` 陣列，不需要新的追蹤集合）
  - `private var completedChunkURLs: Set<URL> = []`（跟 `MixedAudioRecordingController` 一樣，用來在 `acceptCompletedChunk` 內去重）
  - `@discardableResult func acceptCompletedChunk(_ url: URL, text: String, segments: [TranscriptionSegment] = [], durationSeconds: Double? = nil) -> Bool`——邏輯幾乎可以直接搬 `MixedAudioRecordingController.swift:353-384`，因為都是用同一個 `OrderedChunkSubmissionQueue`/15 秒 rotation，時間戳 offset 算法完全一樣。純麥克風沒有靜音跳過 chunk 的邏輯，所以 `acceptFinalizedChunk`／`enqueue` 不需要像 Mixed 那樣先判斷 silence，直接照現有寫法即可，只是完成後多了 `acceptCompletedChunk` 這層。
  - 錄音開始時（`start()` 或對應的重置點）要重置 `transcriptText`/`transcriptSegments`/`transcriptDurationSeconds`/`completedChunkURLs`，比照 `MixedAudioRecordingController.start(outputURL:includeMicrophone:)` 開頭那段重置邏輯。
  - `flushInterval`/`rotationInterval` 在 `LiveRecordingController` 裡現有屬性叫 `rotationInterval`（不是 `flushInterval`），`acceptCompletedChunk` 裡用來算 `chunkDuration` 的 fallback 值要用這個既有屬性，不要新增重複的常數。

- `macos/WhisperApp/Sources/WhisperApp/WhisperApp.swift`：
  `worker.transcriptionCompletedHandler` 的 guard 加上 `liveRecording?.ownsChunk(completed.audioURL) != true`，跟現有的 `mixedAudioRecording?.ownsChunk(completed.audioURL) != true` 並列（`guard mixedAudioRecording?.ownsChunk(...) != true, liveRecording?.ownsChunk(...) != true else { return }`），避免 live chunk 也被寫進全域 `history`（目前每個 live chunk 都被當成獨立一筆 history 紀錄，這是次要但一併要修的副作用）。

- `macos/WhisperApp/Sources/WhisperApp/ContentView+Results.swift`：
  1. 在 `showLatestWorkerResultIfNeeded()` 裡，`mixedAudioRecording.acceptCompletedChunk(...)` 那個 `if` 區塊（346-398 行附近）之後、`guard CaptureUIRules.shouldPresentCompletedResult(...)`（399 行）之前，新增一個對稱的 `if liveRecording.acceptCompletedChunk(...)` 區塊，邏輯完全比照 mixed 分支：成功累加就用 `liveRecording.transcriptText`/`liveRecording.transcriptSegments`/`liveRecording.transcriptDurationSeconds` 建立/更新 history entry（需要一個對應 `mixedAudioHistoryEntryID` 的新 `@State`，例如 `liveHistoryEntryID`），然後 `return`，不要落到後面 Standard 模式的 fallback 分支。
  2. 第 244-246 行的 `transcriptText` computed property 目前是給 UI 顯示用的「全域」屬性。需要確認即時模式實際顯示逐字稿的地方（搜尋這個 computed property 在哪些 View 裡被引用）改成：**當 `liveRecording` 有 active 或剛完成的 session 時**（判斷條件例如 `liveRecording.state != .idle || !liveRecording.transcriptText.isEmpty`）優先顯示 `liveRecording.transcriptText`；否則維持原本 `worker.resultText`/`worker.partialText` 的 fallback（Standard 模式的行為完全不能變）。這個判斷條件要謹慎設計，避免誤判導致 Standard 模式也被攔截——寫完後務必手動 trace 一次 Standard 模式的完整路徑確認沒有受影響。

- `macos/WhisperApp/Tests/WhisperAppTests/LiveRecordingControllerTests.swift`：
  新增測試，比照 `MixedAudioRecordingControllerTests.swift` 裡驗證 `acceptCompletedChunk` 累加行為與時間戳 offset 正確性的案例（先讀那份測試檔案裡對應的測試函式作為範本），新增至少：
  - 一個測試證明依序完成 3 個 chunk 後，`liveRecording.transcriptText` 包含全部 3 段內容且 `transcriptDurationSeconds` 正確遞增（不是只剩最後一段）
  - 一個測試證明 `acceptCompletedChunk` 對同一個 `url` 呼叫兩次，第二次回傳 `false` 且不會重複累加（去重驗證）
  - 一個測試證明 `ownsChunk` 對不屬於這個 controller 的 URL 回傳 `false`

### 禁止改動

- `MixedAudioRecordingController.swift` 本身：已驗證正常運作，只能讀取參考，不要修改。
- `worker_entrypoint.py`／`worker_protocol.py`／`whisper_core.py`／任何 Python worker 端檔案：這次改動完全在 Swift UI/controller 層，跟轉錄協定無關。
- Standard 模式（`StandardRecordingController.swift`）的既有行為：本次只補齊即時模式的累加邏輯，不改動 Standard 模式的單次請求/單次結果行為。
- 不處理 Standard 模式錄音中途被音訊裝置重新設定（例如藍牙裝置協商）打斷、且沒有自動復原機制的問題（`MicrophoneCaptureService` 缺少裝置變更復原邏輯）——這是完全獨立的第三個已知問題，不在本次範圍，會另外交接。

### 執行方不能做（留給 Claude Code）
- git push（留給接手驗收的 Claude Code，作為獨立驗證後才讓改動進入共用狀態的把關點）
- 可以 git commit（本機留下完整紀錄＋完成報告），但不要 git push
- 打包（`scripts/build_worker_runtime.sh`／`scripts/build_swiftui_app.sh`）、簽名、安裝到 `~/Applications`
- 存取 `~/Library/Application Support/WhisperSTT/.env`、Keychain
- 真機測試（AC-6 標注 [需使用者驗證]，你只需要跑得動 build/test，實際錄音驗證留給使用者）

## 驗收條件（AC）
已鎖定，不得新增：
- □ AC-1. `swift build` 成功，無編譯錯誤/警告
- □ AC-2. `swift test` 全部通過（不得低於現況 163/163）
- □ AC-3. 新測試證明：多個 chunk 依序完成時，`liveRecording.transcriptText` 正確累加、時間戳 offset 遞增（不是覆蓋）
- □ AC-4. 新測試證明：`liveRecording.acceptCompletedChunk` 用累加後的完整逐字稿建立/更新 history entry，而不是單一 chunk 的 `completed.text`
- □ AC-5. 新測試證明：Standard 模式（非 live）的 `transcriptText` 顯示邏輯行為不變，fallback 到 `worker.resultText` 的既有路徑沒有被破壞
- □ AC-6. [需使用者驗證] 真機測試：即時模式錄音跨越至少 3 個 chunk（45 秒以上），確認畫面逐字稿包含所有 chunk 內容且時間戳遞增，不是只顯示最後一段——你不用執行這條，只要在 VERIFICATION.md 標注「待使用者驗證」即可

## 驗收指令（完成後自己跑，AC-1/AC-2 全部綠才算完成）
```bash
cd macos/WhisperApp
swift build
swift test
```

## 完成後產出
在專案根目錄建立 `HANDOFF_CLAUDE_LIVE_TRANSCRIPT_ACCUMULATION_VERIFICATION.md`，內容包含：
1. 每條 AC 的驗收結果（✅ / ❌ + 原因，AC-6 標注「待使用者驗證」）
2. 驗收指令的實際輸出（貼上 `swift test` 的完整結果）
3. `git diff --stat` 摘要
4. Known caveats（若有，例如 244-246 行 fallback 判斷條件的具體寫法與為什麼這樣判斷不會誤判 Standard 模式）
5. 不應該 commit 的內容說明（例如本檔案跟 `.env`）
