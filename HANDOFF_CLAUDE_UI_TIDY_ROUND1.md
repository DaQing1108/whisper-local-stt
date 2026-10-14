# 任務規格：UI/UX 整理第一輪（macOS 原生風格）

**建立日期：** 2026-10-14
**風險等級：** L2（只動 Swift UI 與其規則函式；不動 Python、資料檔、Worker 契約、錄音／混音邏輯）
**ESAEV 起點：** Approve → Execute
**規劃／驗收／打包／push：** Claude（session「Whisper Swift 錄音品質檢查」）
**開發：** whisper-bc
**基準：** 分支 `whisper-swift`，HEAD `1f7fbf8`

**設計依據（使用者已決定）：** 不做新視覺設計，依 macOS 原生介面慣例整理（Apple HIG：中文化、隱藏不相關控制項、進階功能放偏好設定）。沿用既有 `DaylightPalette`、`StatusBadge`、`PillSegmentedControl` 等元件，不新增配色或字型。

建議四個 commit（Part A／B／C／D 各一）。

---

## 一、問題背景（規劃端檢視程式碼與 2026-10-14 截圖）

1. **工程用語外露、中英混雜**：狀態徽章「Python Worker ready」「Starting Python Worker…」；狀態列「Mixed audio idle」「Recording mic + system audio — N chunks finalized」等（`ContentView+CaptureActions.swift` 約 269–308 行、`ContentView.swift` 約 217 行）；結果分頁「Transcript／AI Summary」（`ContentView+Results.swift` 約 46 行）；「Export」選單；「Worker diagnostics」。
2. **主按鈕字被截斷**：混音模式顯示「開始錄製麥克風與…」（`primaryButtonLabel`）。
3. **閒置時顯示無用控制項**：結果頁常駐 `worker.jobStatus`（顯示「Idle」）、空的 `ProgressView`、灰掉的「取消」（`transcriptContent` 約 161–173 行）。
4. **逐字稿顯示兩次**：上方 `TextEditor`（300pt）＋下方 `segmentListView`（120pt）內容相同。
5. **開發者功能放在錄音頁快速設定**：「檢查模型」「下載 / 驗證模型 Cache」；結果頁底部常駐「Worker diagnostics」。
6. **large-v3 會卡住**：2026-10-12 有 15 次推論開始後未結束，全為 large-v3；模型選單未提示。
7. **混音模式的波形永遠是平的**：`AudioWaveformView(level: audioMode == .standard ? … : 0)`；混音時看不出麥克風或系統音訊是否有收到聲音。

### 任務目標（可觀察行為）
- 介面文字一律繁體中文（專有名詞如 Whisper、Obsidian、Notion、SRT 保留），不出現 Worker／chunk／idle 等工程用語。
- Worker 正常時不顯示狀態徽章；只有啟動中、重啟中、失敗時顯示中文狀態。
- 主按鈕在視窗預設寬度不被截斷。
- 沒有轉錄工作時，不顯示進度條、工作狀態文字與「取消」。
- 逐字稿預設為「閱讀模式」：只顯示可點擊跳播的時間碼清單；按「編輯」切換為文字編輯框；兩者不同時出現。
- 「檢查模型」「下載／驗證模型」與「診斷資訊」移到偏好設定。
- 模型選單中 large-v3 標示為較慢。
- 混音模式顯示麥克風與系統音訊兩條音量；任一路持續無聲時提示。

### 非本次目標
- 不改配色、字型、側邊欄結構、分頁數量。
- 不改 AI Summary 分頁內部、詞庫頁、歷史紀錄頁版面（文字中文化除外）。
- 不改錄音、混音、切段、轉錄邏輯；不動 Python。
- 不做回音消除、講者辨識流程調整。

---

## 二、執行範圍

### 允許修改範圍（`macos/WhisperApp/Sources/WhisperApp/`）
- `ContentView.swift`（header、`statusText`、`messages`）、`ContentView+Capture.swift`、`ContentView+CaptureActions.swift`（狀態文字、按鈕文字）、`ContentView+Results.swift`（`transcriptContent`、分頁標題、`segmentListView`）、`ContentView+Settings.swift`（承接移過去的模型與診斷功能）、`ContentView+History.swift`（僅文字中文化）。
- `AppSettingsStore.swift`：僅 `displayName(for:)` 的顯示文字。
- `CaptureUIRules`（或新增純函式檔）：放所有「文字／是否顯示」判斷，便於測試。
- `MixedAudioRecordingController.swift`：**只允許新增**兩個唯讀的音量屬性（麥克風、系統音訊），在既有接收 PCM 的位置計算 RMS 並以既有 `MicrophoneCaptureService.normalizedLevel(forPCM16:)` 相同方式正規化；不得改動混音、切段、送出、時間軸的任何邏輯。
- `AudioWaveformView.swift`：可新增雙軌顯示或沿用元件放兩個。
- `Tests/WhisperAppTests/`：新增測試。

### 禁止修改範圍
- 所有 Python 檔、`Package.swift`、`scripts/`、資料檔格式、Worker 指令。
- `MixedAudioRecordingController` 的混音／切段／`ChunkTimeline`／送出邏輯；`MicrophoneCaptureService`、`ScreenCaptureKitAudioBackend` 的擷取邏輯（只能讀取既有資料）。
- `WorkerSupervisor` 的狀態機與指令（只能讀取狀態）。
- 不新增依賴。

### 需要人工核准的變更（預期皆為「否」，變成「是」→ 停止）
- [ ] 需要改錄音／混音擷取邏輯才能取得音量
- [ ] 需要改 Worker 或 Python
- [ ] 需要改側邊欄或分頁結構

---

## 三、規則與文字對照

### Part A：文字與狀態
| 位置 | 現在 | 改為 |
|---|---|---|
| 狀態徽章（Worker ready） | Python Worker ready | **不顯示** |
| 狀態徽章（starting） | Starting Python Worker… | 轉錄引擎啟動中… |
| 狀態徽章（restarting n） | Restarting Python Worker (attempt n)… | 轉錄引擎重新啟動中（第 n 次）… |
| 狀態徽章（failed） | Worker error: … | 轉錄引擎錯誤：… |
| 狀態徽章（stopped） | Worker stopped | 轉錄引擎已停止 |
| 混音閒置 | Mixed audio idle | **不顯示** |
| 混音錄音中 | Recording mic + system audio — N chunks finalized | 錄音中（麥克風＋系統音訊） 或 錄音中（系統音訊） |
| 混音收尾 | Transcribing remaining mixed audio chunks… | 正在轉錄最後幾段… |
| 混音其他狀態 | Starting… / Recovering… / Stopping… / error | 啟動中… / 音訊裝置恢復中… / 停止中… / 錄音錯誤：… |
| 混音送出暫停 | Mixed audio transcription paused: … Restart Worker to retry. | 轉錄暫停：…（請重新啟動轉錄引擎） |
| 標準、即時模式狀態 | 同樣原則中文化；閒置狀態不顯示 | |
| 主按鈕（混音、含麥克風） | 開始錄製麥克風與系統音訊 | **開始錄音**（模式說明改放 `.help()` tooltip 與快速設定裡的模式說明） |
| 主按鈕（混音、僅系統） | 開始錄製系統音訊 | 開始錄音 |
| 結果分頁 | Transcript／AI Summary | 逐字稿／AI 摘要 |
| 匯出選單 | Export | 匯出 |
| 波形 accessibility | Recording elapsed time | 錄音時間 |
- 閒置判斷：沒有任何錄音／擷取進行中、沒有轉錄工作、沒有收尾中。
- 狀態徽章仍放在原位置；不顯示時不留空白占位。

### Part B：逐字稿閱讀／編輯模式（`transcriptContent`）
- 新增 `isEditingTranscript` 狀態，預設 `false`。
- **閱讀模式**：顯示時間碼清單（沿用 `segmentListView` 的點擊跳播與播放中高亮），高度改為填滿原本兩個區塊的空間（約 minHeight 300）。沒有 segments 的紀錄（例如舊資料或純文字）改顯示唯讀文字。
- **編輯模式**：顯示原本的 `TextEditor`，隱藏時間碼清單。
- 切換按鈕：「編輯」／「完成」，放在按鈕列。
- 有未儲存修改（`isDraftDirty`）時按「完成」：維持既有「儲存修改」流程不變，只切回閱讀模式並保留草稿；草稿與 segments 不一致時，閱讀模式頂端顯示一行提示「有未儲存的修改」。
- 轉錄進行中（即時、混音）新內容持續出現時，閱讀模式需自動捲到最新一段（若清單已在底部）。
- 「清空文字」只在編輯模式顯示。
- 既有功能（儲存、複製、播放、講者辨識、重新命名講者、匯出、重新轉錄的覆蓋確認）行為不變。

### Part C：快速設定與偏好設定
- 快速設定移除「檢查模型」「下載 / 驗證模型 Cache」，保留模型 Picker 與一行模型就緒狀態（中文）。
- 偏好設定新增「模型」區塊放這兩個按鈕（行為、disabled 條件不變）。
- 結果頁移除「Worker diagnostics」DisclosureGroup；偏好設定新增「診斷資訊」DisclosureGroup，內容與行為不變。
- `displayName(for:)`：`large-v3` → 「large-v3（較慢，長錄音可能卡住）」；`large-v3-turbo` 維持「large-v3-turbo（快速）」。儲存值不變。
- 語言快速選單的「English」「Japanese」改「英文」「日文」；「Auto」改「自動偵測」。

### Part D：混音雙音源音量與無聲提示
- 混音模式錄音中，控制列顯示兩條音量（標籤「麥克風」「系統」）；未啟用麥克風時只顯示「系統」。標準模式維持原本一條。
- 音量來源：`MixedAudioRecordingController` 新增的兩個唯讀屬性；更新頻率不高於既有麥克風 audioLevel。
- 無聲提示：錄音中某一路正規化音量連續 ≥ 20 秒低於門檻（具名常數，預設與 `AudioChunkSilenceDetector.defaultThreshold` 對應的正規化值）→ 在控制列下方顯示一行橘色小字「麥克風持續沒有聲音」或「系統音訊持續沒有聲音」；恢復有聲後消失。判斷寫成純函式（輸入：最近音量取樣與時間），可單元測試。
- 錄音停止後音量歸零、提示消失。

---

## 四、驗收條件

### Part A
- [ ] AC-A1 狀態文字規則以純函式實作並逐一測試：各 Worker 狀態、各模式各狀態對應上表；ready／閒置回傳 nil（不顯示）。
- [ ] AC-A2 主按鈕文字：三種模式閒置時為「開始錄音」或「開始即時轉錄」，錄音中為既有停止文字；測試覆蓋。
- [ ] AC-A3 grep 確認 Sources 內使用者可見字串不再出現 `Worker ready`、`chunks finalized`、`Mixed audio`、`Live mode`、`Microphone idle`、`"Transcript"`、`"AI Summary"`、`"Export"`、`Worker diagnostics`（log／診斷內容與程式識別字不算）。回報附 grep 指令與結果。

### Part B
- [ ] AC-B1 預設閱讀模式：時間碼清單可見、TextEditor 不在畫面（以可測的顯示規則函式或 ViewInspector 以外的方式驗證，例如將「顯示哪一個」抽成函式並測試）。
- [ ] AC-B2 切換到編輯後僅 TextEditor 可見；「清空文字」只在編輯模式可用。
- [ ] AC-B3 有未儲存修改切回閱讀模式：草稿保留、提示顯示；儲存後提示消失（測試規則函式）。
- [ ] AC-B4 無 segments 的紀錄在閱讀模式顯示唯讀文字。
- [ ] AC-B5 既有儲存、重新轉錄覆蓋確認、講者重新命名相關測試全過、行為不變。

### Part C
- [ ] AC-C1 快速設定不再含兩個模型按鈕；偏好設定含有且 disabled 條件與原本相同（以程式審查＋截圖由規劃端驗收）。
- [ ] AC-C2 `displayName(for: "large-v3")` 含「較慢」；儲存值仍為 `large-v3`（測試）。
- [ ] AC-C3 診斷資訊只出現在偏好設定。

### Part D
- [ ] AC-D1 混音 controller 收到 PCM 後兩個音量屬性更新、停止後歸零（以既有 fake backend 測試）。
- [ ] AC-D2 無聲判斷純函式：連續 19 秒無聲不提示、20 秒提示、恢復後消失、未啟用麥克風時不判斷麥克風（測試）。
- [ ] AC-D3 `git diff` 顯示 `MixedAudioRecordingController` 只有新增屬性與在既有 PCM 接收處的計算，未改混音／切段／時間軸／送出邏輯（回報附相關 diff 段落）。

### 負向驗收
- [ ] AC-N1 既有測試全過且數量不減：基準 swift test 300、pytest 446（Python 不應有變動，跑一次確認），TSAN 通過。
- [ ] AC-N2 `git diff --stat 1f7fbf8 HEAD` 零觸碰：所有 `*.py`、`Package.swift`、`scripts/`、`WorkerSupervisor.swift`、`MicrophoneCaptureService.swift`、`ScreenCaptureKitAudioBackend.swift`、`ChunkTimeline.swift`。
- [ ] AC-N3 未新增配色常數或字型。

### 必要驗證指令
```bash
cd macos/WhisperApp
swift test --scratch-path /tmp/ui1-test
swift test --scratch-path /tmp/ui1-tsan --sanitize=thread
cd ../.. && /usr/bin/python3 -m pytest tests/unit -q
git diff --stat 1f7fbf8 HEAD
```

---

## 五、執行規則

### 停止條件（任一發生即停止並 SendMessage 回報）
- 取得混音雙音源音量必須改動擷取或混音邏輯（不是只在既有 PCM 接收處讀取）。
- 閱讀／編輯模式切換會改變既有儲存、覆蓋確認、講者重新命名的行為。
- 需要改側邊欄、分頁結構、配色或新增依賴。
- 連續兩次修正仍未通過同一測試。
- 版面在預設視窗寬度（約 900pt）下仍無法讓主按鈕不截斷——回報並提出替代做法，不要自行縮小字級。

### 執行方不能做（留給規劃端）
- `git push`、打包、安裝；讀 `.env`、Keychain、使用者資料。
- 可以在自己的分支 commit。

### 工作位置與分支
- 從 `whisper-swift`（`1f7fbf8`）開分支 `ui/tidy-round1`，獨立 worktree `1P_Projects/Whisper-wt-ui-tidy`。

### 升級對象
- 產品／文字用詞問題 → 使用者；技術問題 → 規劃端 Claude（SendMessage）。

---

## 六、完成回報格式
1. 分支與四個 commit hash。
2. 修改摘要；Part D 的 `MixedAudioRecordingController` diff 段落。
3. AC 逐條 ✅／❌，附 `swift test`、TSAN、pytest 結尾輸出與 AC-A3 grep 結果。
4. `git diff --stat 1f7fbf8 HEAD` 全文。
5. 偏離規格與理由；任何你認為不妥的中文用詞。
6. 已驗證／無法驗證：實際外觀（規劃端打包後截圖、使用者真機確認）、實際錄音時雙音量與無聲提示。

---

## 品質審核結論
✅ 可直接交付。無阻塞性 `⚠️ 待確認`。
決策記錄：
- 依使用者選擇採 macOS 原生風格，不做新視覺設計。
- 逐字稿依使用者選擇採「預設閱讀＋編輯切換」，避免同內容顯示兩次。
- 主按鈕統一為「開始錄音」，模式差異交給模式選擇器與 tooltip，解決截斷且符合 HIG 的簡短動詞按鈕。
- Worker 正常不顯示徽章：狀態只在需要使用者注意時出現。
- 雙音源音量只讀既有 PCM，不碰擷取邏輯，降低對錄音穩定性的風險。
