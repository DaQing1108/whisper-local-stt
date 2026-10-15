# 任務規格：錄製頁第 3 輪（設定摘要、最近會議切換、小修正）

**建立日期：** 2026-10-15
**風險等級：** L2（Swift UI＋一條 Python 過濾規則；不改資料格式、Worker 契約、錄音流程）
**規劃／驗收／打包：** Claude（session「Whisper Swift 錄音品質檢查」）；**開發：** whisper-bc
**基準：** 分支 `whisper-swift`，HEAD `5474fa8`（0.3.0）

「依實際用途重新設計」第 3 輪。分四部分，建議各一個 commit。

---

## 一、目標

**A. 錄音前看得到設定**
- 控制列「開始錄音」右側顯示一行設定摘要：`混音 · turbo · 中文 · 詞庫 220/223`（依實際值）。
  - 模式：標準／即時／混音（混音且未啟用麥克風時顯示「混音（僅系統）」）。
  - 模型：沿用 `AppSettingsStore.displayName(for:)` 的簡短形式（turbo、large-v3、base…；括號說明不顯示）。
  - 語言：自動偵測／中文／英文／日文，其他代碼原樣顯示。
  - 詞庫：`VocabularyBudgetController.budget` 有值時顯示 `詞庫 X/223`，超過上限以 `.orange` 顯示；無值時不顯示這一段。
- 點擊摘要＝打開既有的快速設定 popover（與齒輪同一個），不新增設定介面。
- 錄音中摘要維持顯示但不可點（設定本來就不能在錄音中改）。

**B. 最近會議切換**
- 檢視頁標頭會議名稱右側加一個下拉按鈕（`chevron.down`），選單列出最近 5 筆紀錄（依完成時間新到舊，排除目前這筆），每項顯示「名稱 · M/d HH:mm · 長度」；名稱規則與標頭相同（已存名稱優先，否則「會議 M/d HH:mm」）。
- 選擇後呼叫既有的切換流程（`restore(entry)`；與歷史紀錄「載入結果」相同），切換前提交未存的名稱（沿用既有行為）。
- 選單最後一項「所有紀錄…」→ 切到歷史紀錄分頁。
- 錄音中仍可切換（只影響檢視頁，不影響錄音）。

**C. 「儲存修改」只在有修改時顯示**
- 閱讀模式與編輯模式：`isDraftDirty == false` 時不顯示「儲存修改」；有修改時顯示並維持既有行為。
- 既有「切換紀錄時未存草稿」的處理不變。

**D. 過濾英文語助詞幻聽（Python）**
- `clean_segments` 在有效語言為 `zh` 時，丟棄「整段去除標點與空白後，不分大小寫完全等於」下列之一的 segment：`mm`、`mmm`、`mmmm`、`hmm`、`hm`、`mhm`、`uh`、`um`、`uhhuh`、`uh-huh`（去標點後比對 `uhhuh`）。
- 只比對整段；句中含這些字的正常句子不受影響（例：`Um, 我們先開始` 保留）。
- log 只記規則名與數量（比照既有 `[CleanSegments]` 格式）。

### 非本次目標
- 不改快速設定 popover 的內容、歷史紀錄分頁版面、檢視頁其他區塊。
- 不做 Window scene 單視窗化、不改選單列錄音指示。

---

## 二、範圍

### 允許修改
- Swift：`ContentView+Capture.swift`（控制列摘要）、`ContentView+ReviewPage.swift`（標頭下拉、儲存按鈕顯示）、`ReviewRules.swift` 或新增 `CaptureSummaryRules.swift`（純函式）、測試。
- Python：`transcribe_common.py`（新增規則與常數）、`tests/unit/` 新增測試。

### 禁止修改
- 資料檔格式、Worker 指令、`WorkerSupervisor`、錄音 controller、`ChunkTimeline`、`MeetingSummaryStore`／Controller、`CaptureStatusBoard`／`MainWindowCloseGuard`／選單列檔案。
- 既有 `clean_segments` 規則與 `is_hallucination`（只能新增）。
- `Package.swift`、`scripts/`、`Info.plist`（版號由規劃端處理）。

---

## 三、驗收條件
- [ ] AC-A1 摘要純函式：三種模式（含混音僅系統）× 模型 × 語言 × 詞庫（有值／超限／無值）輸出正確（測試）。
- [ ] AC-A2 點擊摘要開啟既有 popover；錄音中不可點（程式審查）。
- [ ] AC-B1 最近 5 筆選取純函式：排序、排除目前紀錄、不足 5 筆、空歷史（測試）。
- [ ] AC-B2 選單項文字格式與標頭命名規則一致（測試）。
- [ ] AC-B3 選擇後走既有 `restore(entry)` 路徑；「所有紀錄…」切到歷史紀錄（程式審查）。
- [ ] AC-C1 顯示規則：未修改不顯示、修改後顯示、儲存後隱藏（純函式測試＋程式審查）。
- [ ] AC-D1 Python：上列每個語助詞（含大小寫、句點、空白變化）整段被丟棄；`Um, 我們先開始`、`OK`、`Hmm 這個要再想` 保留；語言非 zh 時不套用（測試）。
- [ ] AC-N1 既有測試全過且數量不減（基準 swift 352、pytest 446），TSAN 通過。
- [ ] AC-N2 `git diff --stat 5474fa8 HEAD` 零觸碰禁止範圍。

### 必要驗證指令
```bash
/usr/bin/python3 -m pytest tests/unit -q
cd macos/WhisperApp
swift test --scratch-path /tmp/r3-test
swift test --scratch-path /tmp/r3-tsan --sanitize=thread
git diff --stat 5474fa8 HEAD
```

## 四、停止條件
- 摘要需要讀取 Worker 或改 controller 才能取得資訊。
- 最近會議切換需要另寫切換邏輯（不能重用 `restore`）。
- 語助詞規則在負向測試中無法不誤刪。
- 連續兩次修正仍未通過同一測試；任一檔案超過 800 行。

## 五、工作位置與回報
- 分支 `ui/capture-round3`，worktree `1P_Projects/Whisper-wt-capture-r3`，只 commit 不 push。
- 回報：commit hash、AC 逐條、測試結尾輸出、`git diff --stat 5474fa8 HEAD`、偏離與理由、需真機確認項目（控制列在 820pt 寬是否放得下摘要、下拉選單外觀）。

## 品質審核結論
✅ 可直接交付。決策記錄：摘要點擊重用既有 popover、會議切換重用既有 `restore`，不新增平行流程；語助詞只比對整段、只在 zh 套用。
