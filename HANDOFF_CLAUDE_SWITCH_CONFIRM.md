# 任務規格：切換紀錄前確認未儲存的逐字稿修改

**建立日期：** 2026-10-15
**風險等級：** L1（Swift UI，2–3 個檔案；不改資料格式與既有儲存流程）
**規劃／驗收／打包：** Claude（session「Whisper Swift 錄音品質檢查」）；**開發：** whisper-bc
**基準：** 分支 `whisper-swift`，HEAD `a8b856f`（0.3.1）

## 一、背景
第 3 輪新增標頭「最近會議」下拉後，使用者切換紀錄的機會變多。既有行為：逐字稿有未儲存修改（`isDraftDirty == true`）時，「載入結果」或下拉切換會直接捨棄修改、不詢問。

## 二、目標
使用者**主動**切換到另一筆紀錄時，若 `isDraftDirty == true` 且目標不是目前這筆，先顯示確認對話框：
- 標題：「逐字稿有未儲存的修改」
- 說明：「切換到其他會議前要儲存嗎？」
- 按鈕：**儲存並切換**（預設）／**不儲存**（捨棄修改後切換）／**取消**（留在原紀錄，什麼都不改）
- 「儲存並切換」＝呼叫既有 `saveDraft()`，成功後再 `restore(target)`；儲存失敗則留在原紀錄並沿用既有錯誤顯示。

**適用的入口（只有這兩個）**
1. `ContentView+History.swift` 約 32 行「載入結果」（確認後才切到錄製頁）。
2. `ContentView+ReviewPage.swift` 約 88 行最近會議下拉。

**不適用**（自動切換，維持原樣）：啟動時載入最新、錄音完成後同步、重新轉錄覆蓋流程、`ContentView+Results.swift` 內既有的 restore 呼叫。

**非目標**：AI 摘要草稿（已有 `pendingSummaryDrafts` 保留機制，不動）；不改 `saveDraft`／`restore` 內容。

## 三、範圍
- 允許：`ContentView+History.swift`、`ContentView+ReviewPage.swift`、`ContentView.swift`（只新增確認狀態與 `.confirmationDialog`／`.alert`）、新增純函式（例：`SwitchGuardRules.needsConfirmation(isDraftDirty:currentID:targetID:)`）、測試。
- 禁止：`saveDraft`、`restore`、`showLatestWorkerResultIfNeeded` 的內容；資料 store；錄音 controller；Python；`Package.swift`；`scripts/`；`Info.plist`。

## 四、驗收條件
- [ ] AC-1 規則純函式：dirty＋不同目標 → 需要確認；不 dirty、或目標等於目前 → 不需要（測試）。
- [ ] AC-2 兩個入口都改走同一個「請求切換」函式；不需要確認時行為與原本完全相同（程式審查：列出呼叫路徑）。
- [ ] AC-3 三個按鈕行為：儲存並切換（先 save 再 restore；save 失敗不切換）、不儲存（直接 restore）、取消（不變）（以可測的狀態函式或程式審查說明）。
- [ ] AC-4 「載入結果」只在實際切換後才把 `selectedSection` 設為 `.capture`；取消時停留在歷史紀錄頁。
- [ ] AC-N1 既有測試全過且不減（基準 swift 358、pytest 462），TSAN 通過；`git diff --stat a8b856f HEAD` 零觸碰禁止範圍。

## 五、停止條件
- 需要修改 `saveDraft` 或 `restore` 才能實作。
- 「儲存並切換」無法得知儲存是否成功（例如 `saveDraft` 不回報結果）——回報替代方案，不要改 `saveDraft`。
- 連續兩次修正仍未通過同一測試。

## 六、工作位置與回報
- 分支 `ui/switch-confirm`，worktree `1P_Projects/Whisper-wt-switch-confirm`，只 commit 不 push。
- 回報：commit hash、AC 逐條、測試結尾輸出、`git diff --stat a8b856f HEAD`、偏離與理由。
