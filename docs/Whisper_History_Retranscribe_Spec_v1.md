# 任務規格：歷史會議記錄「重新轉錄」功能

**建立日期：** 2026-08-24
**風險等級：** L2
**ESAEV 起點：** Spec
**負責人：** ⚠️ 待確認（daqingliao）
**技術負責人：** ⚠️ 待確認（執行方 Claude Code 帳號）

---

## 📋 需求診斷

輸入：歷史會議記錄缺少 `segments`（逐句時間戳記）欄位，導致「辨識講者」按鈕永遠是灰的；需要一個「重新轉錄」功能補回 segments。

已知：
- 問題根因（`TranscriptionHistoryStore.swift:73`，legacy JSON 缺 `segments` key → decode 成 `[]`）
- 完成後寫回機制（`updateResult(id:text:segments:durationSeconds:audioURL:)` 已存在，保留 obsidianNotePath/notionChildPageID）
- Worker 互斥機制現況與既有 gap（`transcribe()` 未 guard `diarizationOperationInProgress`）
- 舊模式（mixed/live）完成路由 pattern 可參考，但不能照抄硬跳轉
- UI 觸發入口位置（`ContentView+History.swift` 的歷史列表 row，`Button("刪除", ...)` 旁）
- 影響檔案範圍

缺失：
- 產品端最終定案人（非阻塞，⚠️ 待確認即可，不影響技術執行）

風險等級建議：L2（跨 4 個原始碼檔案 + 對應測試，觸及共用 worker pipeline 與既有完成路由邏輯；不涉及資料庫 schema 變更或正式環境）

---

## 一、問題背景與目標

### 問題背景
Whisper Swift 版的 `TranscriptionHistoryEntry.segments`（逐句時間戳記，含後續可標註的 `speaker`）是在產品後期才加入 JSON schema 的欄位。在此之前錄製、已寫入 `history.json` 的會議記錄，解碼時 `segments` 因 key 不存在而 fallback 成空陣列（`TranscriptionHistoryStore.swift:73`）。「辨識講者」按鈕的啟用條件是 `!entry.segments.isEmpty`（`ContentView+Results.swift:152`），因此這些歷史記錄的「辨識講者」永遠無法點擊，且沒有任何回填路徑——唯一能拿到 segments 的方式是對原始音檔重新跑一次轉錄。

### 任務目標
使用者在「轉錄歷史」列表中，對一筆 `segments` 為空、且原始音檔仍存在於磁碟上的歷史記錄，可以點擊「重新轉錄」：
1. 系統用該筆記錄當時的 `model`/`language`/`domain`/`extraTerms` 設定，對 `entry.audioPath` 指向的音檔重新呼叫 Whisper 轉錄。
2. 轉錄完成後，新產生的 `text`/`segments`/`durationSeconds` 透過 `TranscriptionHistoryStore.updateResult(id:)` 寫回**同一筆**歷史記錄（不建立新記錄），`obsidianNotePath`/`notionChildPageID` 維持不變。
3. 寫回成功後，該筆記錄的「辨識講者」按鈕從灰色變為可點擊（因為 `segments` 不再是空陣列）。

### 非本次目標
- 不自動重新產生或更新已存在的 `MeetingSummary`（摘要）——摘要與新逐字稿不同步是已知、可接受的限制，使用者需要自行重新產生摘要。
- 不自動推送更新到已發布的 Obsidian 筆記或 Notion 頁面——`obsidianNotePath`/`notionChildPageID` 只是保留欄位值，不觸發任何外部同步動作。
- 不處理音檔已遺失（`audioPath` 指向的檔案不存在）的情況——這類記錄不提供「重新轉錄」入口，属於永久無法補救的已知限制，不在本次範圍內設計救援機制。
- 不批次處理多筆記錄——一次只針對使用者明確點擊的單一筆記錄。
- 不修改 `TranscriptionHistoryEntry` 的 JSON schema 或新增欄位。

---

## 二、執行範圍

### 允許修改範圍
- `macos/WhisperApp/Sources/WhisperApp/WorkerSupervisor.swift`
  — 在 `transcribe(audioURL:modelName:language:domain:extraTerms:)`（約 line 343-350）補上 `guard !diarizationOperationInProgress else { throw ... }`，修正既有 gap（辨識講者進行中時，理論上不該讓任何新轉錄請求送出，含未來的重新轉錄）。
- `macos/WhisperApp/Sources/WhisperApp/ContentView.swift`
  — 新增 `@State` 追蹤「目前正在重新轉錄的目標 entry id」（例如 `retranscribeTargetEntryID: UUID?`），比照既有 `mixedAudioHistoryEntryID`/`liveHistoryEntryID` pattern。
- `macos/WhisperApp/Sources/WhisperApp/ContentView+Results.swift`
  — 新增觸發函式（例如 `func retranscribe(_ entry: TranscriptionHistoryEntry)`），呼叫 `worker.transcribe(audioURL:modelName:language:domain:extraTerms:)`（吃 entry 當時的設定值），並設定 `retranscribeTargetEntryID = entry.id`。
  — 在既有的完成路由邏輯（`presentCompletedResultIfNeeded` 或等效函式）新增一個分支：當 `retranscribeTargetEntryID` 有值且與本次完成事件相關時，呼叫 `history.updateResult(id:text:segments:durationSeconds:audioURL: nil)`（`audioURL` 傳 `nil`，保留原本 `audioPath`），**不呼叫 `restore(entry)`**（不強制切換畫面），完成後清空 `retranscribeTargetEntryID`。
  — 若目標 entry 正好是目前開啟（`currentEntryID == entry.id`）且 `isDraftDirty == true`，觸發前需先走既有的 `PendingDiarizationOverwrite` confirmation dialog 同一套機制（可重用該 struct，或新增一個語意相同的 pending-overwrite 狀態），使用者需明確選擇「覆蓋」或「取消」。
- `macos/WhisperApp/Sources/WhisperApp/ContentView+History.swift`
  — 在歷史列表每筆 row 的按鈕列（約 line 31-46，`Button("刪除", ...)` 附近）新增「重新轉錄」按鈕，顯示條件：`entry.segments.isEmpty && FileManager.default.fileExists(atPath: entry.audioPath)`；停用條件：`worker.activeRequestID != nil || worker.diarizationOperationInProgress || worker.modelOperationInProgress`。
- 對應的測試檔案：
  - `macos/WhisperApp/Tests/WhisperAppTests/WorkerSupervisorTests.swift`
  - `macos/WhisperApp/Tests/WhisperAppTests/TranscriptionHistoryStoreTests.swift`（若需要新增針對「已刪除 entry 呼叫 updateResult」no-op 行為的測試，目前應已被既有測試涵蓋，執行方需先確認）
  - 新增或擴充 UI 邏輯層的測試（若 ContentView+Results.swift 的路由邏輯可抽出為可測試的純函式，比照現有 `CaptureUIRules` pattern）

### 禁止修改範圍
- `TranscriptionHistoryEntry` 的 struct 定義與 `CodingKeys`（`TranscriptionHistoryStore.swift:18-79`）——不得新增/修改欄位，本功能完全依賴既有的 `updateResult` 簽章。
- `MeetingSummaryController.swift`、`MeetingSummaryStore.swift`——不觸碰摘要相關邏輯，摘要與新逐字稿的不同步是刻意的非本次目標。
- Obsidian/Notion 整合程式碼（`ObsidianExportService`、`NotionClient` 相關檔案）——不新增任何自動同步呼叫。
- `MixedAudioRecordingController.swift` 及其測試——這是另一批目前有 13 個測試失敗、尚未收尾的無關 WIP，本次任務不得觸碰，也不得依賴其修改。
- `history.json` 既有資料的 migration script 或一次性回填工具——本次不做批次回填，只做「使用者主動觸發、單筆」的路徑。
- `package.sh`／`scripts/build_swiftui_app.sh`／簽名憑證——打包與簽名留給接手驗收的 Claude Code。

### 需要人工核准的變更
- [ ] 資料庫結構或遷移 — 不適用（無資料庫，本地 JSON 檔案）
- [ ] 公開 API 契約變更 — 不適用（無公開 API）
- [x] 共用元件修改 — `WorkerSupervisor.transcribe()` 屬於共用元件，本次的 `diarizationOperationInProgress` guard 修改需要在完成報告中明確標注影響範圍（可能影響「即時／混音錄音」以外的其他呼叫路徑），供人工核准前檢視
- [ ] 權限與安全政策 — 不適用
- [ ] 正式環境設定 — 不適用（本機 app）
- [ ] 新增外部依賴 — 不適用

---

## 三、系統限制

### 技術限制
- Swift 6、SwiftUI（macOS），沿用專案既有 `swift build`/`swift test` 工具鏈，不引入新套件。
- 必須維持單一 worker process 的互斥假設（`activeRequestID == nil` 為唯一同時只能有一個轉錄/辨識任務進行中的守門條件），不得引入平行轉錄。
- 音檔存在性檢查使用 `FileManager.default.fileExists(atPath:)`，不做內容完整性驗證（例如檔案損毀、格式不符）——若音檔存在但無法被 Whisper 讀取，視為既有轉錄流程本來就會回報的錯誤（`worker.diagnostics`/`errorMessage`），不需要為此新增特殊處理。

### 安全與隱私限制
- 不涉及新的敏感資料處理；重新轉錄使用的仍是使用者本機既有音檔與既有本機 Whisper worker，無新的網路呼叫、無新的憑證存取。

### 產品與業務規則
- 「重新轉錄」只能對 `segments.isEmpty` 的記錄提供，**不得**對已經有 segments 的記錄顯示同樣的按鈕（避免使用者誤觸重跑已完成的辨識工作、覆蓋既有的講者標籤或手動編輯）。
- 若使用者已經對該筆記錄做過「重新命名講者」（逐字稿內文含 `[某講者名稱]` 標籤），理論上這種記錄本來就已經有 segments（否則無法辨識講者在先），因此不會同時符合「重新轉錄」的顯示條件——兩個功能互斥觸發，不需要額外處理併發情境。

---

## 四、驗收條件

### 正向驗收條件（必須通過）
- [ ] AC-1：對一筆 `segments == []` 且 `audioPath` 對應檔案存在的歷史記錄，「轉錄歷史」列表 row 上顯示「重新轉錄」按鈕；對 `segments` 非空的記錄，不顯示此按鈕。
- [ ] AC-2：對 `audioPath` 對應檔案不存在的記錄（即使 `segments` 為空），不顯示「重新轉錄」按鈕。
- [ ] AC-3：點擊「重新轉錄」後，`worker.transcribe()` 被呼叫時使用的 `modelName`/`language`/`domain`/`extraTerms` 等於該 entry 當時儲存的值，而非使用者目前 UI 上選擇的設定。
- [ ] AC-4：轉錄完成後，該筆記錄透過 `history.updateResult(id:)` 更新（可用單元測試以假 worker/假 store 驗證：`entries[index].segments` 從 `[]` 變為非空，`entries[index].id` 不變、`entries.count` 不變 — 沒有新增記錄）。
- [ ] AC-5：轉錄完成後，該筆記錄的 `obsidianNotePath`/`notionChildPageID` 與轉錄前完全相同（值不變）。
- [ ] AC-6：轉錄完成時，若使用者當下 `currentEntryID` 不等於被重新轉錄的 entry id，畫面**不會**被強制切換到該筆記錄（即不呼叫 `restore(entry)`）。
- [ ] AC-7：若被重新轉錄的 entry 正是目前開啟中且 `isDraftDirty == true`，點擊「重新轉錄」會先跳出確認對話框，使用者需明確選擇「覆蓋」才會真正送出轉錄請求；選擇「取消」則不送出。
- [ ] AC-8：`worker.activeRequestID != nil` 或 `worker.diarizationOperationInProgress == true` 或 `worker.modelOperationInProgress == true` 時，「重新轉錄」按鈕為停用狀態。
- [ ] AC-9：`WorkerSupervisor.transcribe()` 在 `diarizationOperationInProgress == true` 時呼叫，會 throw 錯誤（不送出 worker command），修正既有 gap。
- [ ] AC-10：轉錄完成前，若使用者手動刪除了目標 entry（`history.entries` 中已無該 id），完成回呼呼叫 `updateResult` 應 no-op（回傳 `nil`，且不 crash、不拋錯中斷 app），且 `history.entries` 不會被意外重新加回該筆記錄。

### 負向驗收條件（不得破壞）
- [ ] 既有「即時錄音」「混音錄音」完成後的 `recordCompleted`/`updateResult` 路由邏輯（`liveHistoryEntryID`/`mixedAudioHistoryEntryID` 分支）行為不變，既有測試全部通過。
- [ ] 既有「辨識講者」（`SpeakerRename` 相關）功能與本次剛修復的 CJK IME 輸入行為不受影響。
- [ ] 既有 `MeetingSummary` 產生/儲存流程不受影響，本次改動不觸碰 `MeetingSummaryController`/`MeetingSummaryStore`。
- [ ] 不影響 `MixedAudioRecordingController.swift` 現有的（雖然目前本來就失敗的）13 個測試的失敗數量——即本次改動不得讓失敗數變多，也不需要負責修好它們。

### 品質門檻
- [ ] 單元測試通過（新增/修改的測試 + 全部既有測試中，扣除已知的 `MixedAudioRecordingControllerTests`/`LiveRecordingControllerTests` 13 個既有失敗後，其餘全綠）
- [ ] 整合測試通過 — 本專案無獨立整合測試層，以 `swift test` 全量結果視為等效
- [ ] 靜態分析通過 — `swift build`（debug）與 `swift build -c release`（透過 `scripts/build_swiftui_app.sh` 由接手方驗證）皆無編譯錯誤
- [ ] 效能符合門檻 — ⚠️ 待確認：本功能重用既有轉錄 pipeline，效能特徵應與「標準模式上傳音檔轉錄」相同，不另訂新門檻

### 必要驗證指令
```bash
# 單元測試（執行方在自己的 worktree 跑，git commit 前必須全綠或維持既有失敗數不變）
cd macos/WhisperApp
swift test --filter WorkerSupervisorTests
swift test --filter TranscriptionHistoryStoreTests
swift test 2>&1 | tail -30   # 確認整體失敗數維持在既有的 13 個（MixedAudio/LiveRecordingControllerTests），未新增

# 靜態分析 / 編譯
swift build
```
```bash
# 真機驗證（留給接手驗收的 Claude Code，執行方不需要做）
./scripts/build_swiftui_app.sh
# 手動：對一筆缺 segments 的歷史記錄點「重新轉錄」，確認完成後「辨識講者」按鈕變為可點擊
```

---

## 五、執行規則

### 停止條件
遇到以下任一情況，立即停止並升級：
- 需要修改 `TranscriptionHistoryEntry` 的 schema 或 `MeetingSummary`/Obsidian/Notion 相關程式碼才能完成 AC
- 發現除了 `transcribe()` 缺少 `diarizationOperationInProgress` guard 之外，還有其他既有共用元件的行為需要變更才能滿足 AC
- `ContentView+Results.swift` 現有的完成路由邏輯（mixed/live 分支）複雜到無法在不破壞既有行為的前提下新增第三個分支，需要先重構才能繼續
- 連續兩次修正仍未通過 AC-4（正確寫回同一筆記錄、不建立新記錄）或 AC-6（不強制跳轉畫面）——這兩條是本功能的核心正確性，反覆失敗代表理解有誤，應停下回報而非繼續嘗試
- 在 `Blockers` 區塊記錄具體問題後，等待 PLAN 端（Claude Code）回覆，不重新發起整輪交接

### 升級對象
- 產品問題（例如：是否要為「重新轉錄」加上批次處理、是否要順便更新摘要）→ daqingliao
- 技術問題（例如：完成路由邏輯的重構方式）→ PLAN 端 Claude Code（本 session）
- 安全問題 → Dream（Dev Director）（本任務預期不會觸發）

---

## 六、完成回報格式

完成時，提供：
1. 修改摘要（影響模組與採用方案，特別說明 `transcribe()` guard 修改的實際影響範圍）
2. 驗收證據（AC-1 至 AC-10 逐條列出 ✅/❌ + 測試指令實際輸出）
3. 範圍確認（實際修改檔案是否在「允許修改範圍」內，有無誤觸「禁止修改範圍」）
4. 已知風險（殘留風險與監控建議，例如：`ContentView+Results.swift` 完成路由邏輯目前已經有 3 個分支 mixed/live/generic，本次新增第 4 個分支後的可讀性與未來維護建議）
5. 未完成事項（若有，含具體原因與建議下一步）
