# 任務規格：選單列錄音指示＋錄音中保護主視窗

**建立日期：** 2026-10-15
**風險等級：** L2（Swift UI／App 層；不改錄音、混音、轉錄、存檔邏輯；不動 Python、資料格式）
**規劃／驗收／打包：** Claude（session「Whisper Swift 錄音品質檢查」）；**開發：** whisper-bc
**基準：** 分支 `whisper-swift`，HEAD `e8234f3`

「依實際用途重新設計」第 2 輪。

---

## 一、背景

### 使用者用途（已確認）
會議中錄下去就不管，只偶爾檢查轉錄有沒有異常；Teams 佔主畫面。

### 規劃端查到的既有風險（本輪必須處理）
- 混音／即時的 chunk 結果由 `ContentView` 的 `.onChange(of: worker.completionRevision)` → `showLatestWorkerResultIfNeeded()` → `acceptCompletedChunk` 收進逐字稿（`ContentView.swift` 約 145 行、`ContentView+Results.swift` 約 379–434 行）。
- 停止後寫入歷史（`stopMixedAudioRecording` 更新 history、session 音檔）也在 `ContentView`；選單「Start or Stop Recording」是 `NotificationCenter` 送 `.whisperToggleRecording`，只有 `ContentView` 在聽。
- 因此**錄音中關閉主視窗（ContentView 被銷毀）→ 之後的 chunk 不會進逐字稿、停止指令沒有人接收**。選單列停止鍵若照現況實作，在視窗關閉時會無效。

### 任務目標
**Part A：選單列錄音指示**
1. 任何錄音模式錄音中（含收尾轉錄中），選單列出現項目：紅點＋錄音時間（`H:MM:SS`）；不錄音時不顯示。
2. 點開面板顯示：
   - 模式與狀態（例：混音錄音中／正在轉錄最後幾段…）。
   - 音量：混音顯示「麥克風」「系統」兩條（未啟用麥克風只顯示系統）；標準模式顯示麥克風一條；即時模式沿用其可取得的音量，取不到就不顯示。
   - 無聲提示（沿用上一輪 `InputSilenceMonitor` 的結果，文字相同）。
   - 最近 3 行逐字稿（混音、即時）；標準模式顯示「錄音結束後才會轉錄」。
   - 按鈕：「停止並轉錄」（即時模式為「停止即時模式」）、「打開 Whisper」。
3. 「停止並轉錄」走**與主視窗相同的停止流程**（同一個入口），結果與在主視窗按停止完全相同。

**Part B：錄音中保護主視窗**
4. 錄音中（含收尾）按主視窗的關閉鈕或 ⌘W：**隱藏視窗而非關閉**，`ContentView` 不被銷毀，錄音與逐字稿累積持續；「打開 Whisper」或點 Dock 圖示重新顯示同一個視窗。不錄音時關閉行為維持原樣。
5. 錄音中按 ⌘Q：跳出確認「錄音進行中，結束 Whisper 會中斷錄音。確定要結束嗎？」（結束／取消）。不錄音時不詢問。

### 非本次目標
- 不把 chunk 累積或停止存檔邏輯從 `ContentView` 搬出（架構重構另案）。
- 不做錄製頁精簡（第 3 輪）、不改版號（第 2 輪完成後由規劃端另做）。
- 不新增開始錄音入口到選單列（只做進行中的指示與停止）。

---

## 二、執行範圍

### 允許修改範圍
- `WhisperApp.swift`：新增 `MenuBarExtra` scene（`isInserted` 綁定「錄音中」）、注入共用狀態、App delegate（若需要處理 ⌘Q 確認）。
- 新增檔案（建議）：
  - `CaptureStatusBoard.swift`：`@MainActor @Observable` 共用狀態（錄音開始時間、模式、是否收尾中、無聲提示文字），由 `ContentView` 在開始／停止時寫入、選單列讀取。
  - `MenuBarRecordingView.swift`：選單列面板。
  - `MenuBarRules.swift`：純函式（是否顯示、標籤文字、最近 N 行逐字稿抽取、按鈕文字）。
  - `MainWindowCloseGuard.swift`：錄音中把關閉改為隱藏（例如 `NSWindowDelegate.windowShouldClose` 回傳 false 並 `orderOut`，或等效作法）。
- `ContentView+CaptureActions.swift`、`ContentView+Capture.swift`、`ContentView.swift`：只允許在既有開始／停止流程中**寫入** `CaptureStatusBoard`、安裝視窗保護；不得改變流程本身。
- `Tests/WhisperAppTests/`：新增測試。

### 禁止修改範圍
- 錄音／混音／即時 controller 的邏輯（只能讀取既有公開屬性：音量、`transcriptText`、狀態）。
- `showLatestWorkerResultIfNeeded`、`acceptCompletedChunk`、`stopMixedAudioRecording` 等既有流程的內容。
- `WorkerSupervisor`、`ChunkTimeline`、資料 store、Python、`Package.swift`、`scripts/`、`Info.plist`。

### 需要人工核准的變更（變成「是」→ 停止）
- [ ] 需要搬動或修改 chunk 累積／停止存檔流程
- [ ] 需要改錄音 controller
- [ ] 需要新增依賴或改 Info.plist（例如 LSUIElement）

---

## 三、規則
- 停止：選單列「停止並轉錄」一律透過既有 `.whisperToggleRecording` 通知（或抽出共用的同一個 action），**不得另寫一套停止邏輯**。因 Part B 保證錄音中 `ContentView` 存活，通知一定有人接收；送出前若視窗隱藏，不需要顯示視窗。
- 防連點：停止送出後到狀態離開「錄音中」之前，按鈕停用。
- 錄音時間來源：`CaptureStatusBoard.startedAt`（與主視窗計時同一來源）；面板內每秒更新，選單列標籤也每秒更新。
- 最近逐字稿：取 `transcriptText` 最後 3 個非空行，去掉開頭時間碼 `[HH:MM:SS]`，每行最多 60 字，超過以 … 結尾。
- 選單列面板寬度約 320pt；顏色沿用系統色（紅點用 `.red`），不新增配色常數。
- 視窗保護：只在「錄音中或收尾中」生效；狀態回到閒置後，關閉行為恢復原樣（使用者之後按關閉就是真的關閉）。

---

## 四、驗收條件

### Part A
- [ ] AC-A1 `MenuBarRules`：三種模式 × 閒置／錄音中／收尾中 → 是否顯示、標籤、按鈕文字（測試）。
- [ ] AC-A2 最近逐字稿抽取：去時間碼、取最後 3 個非空行、60 字截斷、空字串（測試）。
- [ ] AC-A3 計時文字：`0:00:05`、`1:52:53`（測試）。
- [ ] AC-A4 選單列停止與主視窗停止走同一入口（程式審查：回報列出呼叫路徑）。
- [ ] AC-A5 `CaptureStatusBoard` 在開始時寫入、在停止完成（含收尾結束）時清除；失敗路徑也清除（測試或程式審查列出所有寫入點）。

### Part B
- [ ] AC-B1 關閉規則純函式：錄音中／收尾中 → 隱藏；閒置 → 允許關閉（測試）。
- [ ] AC-B2 隱藏後重新顯示的是同一個 `ContentView` 實例（程式審查說明機制；規劃端真機驗證）。
- [ ] AC-B3 ⌘Q 確認只在錄音中出現（規則測試＋程式審查）。

### 負向
- [ ] AC-N1 既有測試全過且數量不減（基準 swift 344、pytest 446），TSAN 通過。
- [ ] AC-N2 `git diff --stat e8234f3 HEAD` 零觸碰禁止範圍；`ContentView` 既有流程函式內容無變更（回報附這些函式的 diff 為空的證明）。
- [ ] AC-N3 未新增依賴、未改 Info.plist、未新增配色常數。

### 必要驗證指令
```bash
cd macos/WhisperApp
swift test --scratch-path /tmp/mb-test
swift test --scratch-path /tmp/mb-tsan --sanitize=thread
cd ../.. && /usr/bin/python3 -m pytest tests/unit -q
git diff --stat e8234f3 HEAD
```

---

## 五、停止條件（任一發生即停止並 SendMessage 回報）
- 錄音中保護主視窗無法在不搬動既有流程的前提下做到（例如 SwiftUI 仍會銷毀 ContentView）——回報替代方案，不要自行搬邏輯。
- 選單列停止需要另寫停止邏輯才能運作。
- 需要改錄音 controller、Info.plist 或新增依賴。
- 連續兩次修正仍未通過同一測試；任一檔案超過 800 行。

## 六、工作位置與回報
- 分支 `ui/menubar-recording`，獨立 worktree `1P_Projects/Whisper-wt-menubar`，只 commit 不 push。
- 回報：commit hash、AC 逐條（含 AC-A4 呼叫路徑、AC-A5 寫入點、AC-B2 機制說明）、測試結尾輸出、`git diff --stat e8234f3 HEAD`、偏離與理由、無法驗證項目（真機：實際錄音中選單列外觀、關閉視窗後逐字稿持續累積、停止後存檔完整）。

## 品質審核結論
✅ 可直接交付。決策記錄：
- 視窗保護採「錄音中關閉＝隱藏」，以最小改動消除既有資料遺失風險，不搬動錄音流程（重構另案）。
- 選單列停止重用既有通知入口，確保與主視窗行為一致。
