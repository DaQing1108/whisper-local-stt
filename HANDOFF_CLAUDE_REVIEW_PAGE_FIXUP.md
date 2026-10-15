# 任務規格：檢視頁小修正（預設會議名稱、實際錄音長度）

**建立日期：** 2026-10-15
**風險等級：** L1（Swift UI 顯示規則，2–4 個檔案；不改資料格式）
**規劃／驗收／打包：** Claude（session「Whisper Swift 錄音品質檢查」）；**開發：** whisper-bc
**基準：** 分支 `whisper-swift`，HEAD `e159c64`

## 一、背景（使用者真機截圖 2026-10-15）
1. 沒取名的紀錄，標頭顯示音檔檔名「mixed-audio-session-B354DC6E-…」，無意義。
2. 10/14 那筆的標頭與播放列顯示 1:59:10，實際錄音 1:52:53。原因：舊紀錄存的 `durationSeconds` 是時間軸修正前的偏大值；`ContentView+PlaybackBar.swift` 約第 25 行用 `max(audioPlayer?.duration, 存檔長度)`，取了較大者；標頭用 `ReviewHeaderRules.durationSeconds(of:)`（存檔長度優先）。

## 二、目標
1. **預設會議名稱**：沒有使用者名稱時，顯示「會議 M/d HH:mm」（紀錄完成時間）。只影響顯示與「產生摘要時帶入的預設名稱」；不得因瀏覽紀錄而寫入任何資料。
2. **錄音長度以實際音檔為準**：標頭與播放列總長，優先使用音檔實際長度；音檔讀不到時才退回存檔長度，再退回最後一段結束時間。

## 三、範圍
- 允許：`ReviewRules.swift`（預設名稱、長度選擇的純函式）、`ContentView+Results.swift`（約 304、563 行的預設名稱來源改用新函式）、`ContentView+ReviewPage.swift`、`ContentView+PlaybackBar.swift`、測試。
- 實際長度讀法：用 `AVAudioFile` 讀檔頭（`length / processingFormat.sampleRate`），**不得讀入整個音檔**；在載入紀錄時計算一次並快取在 view 狀態，不寫回資料。
- 禁止：資料檔格式、`TranscriptionHistoryStore`、`MeetingSummaryStore`／Controller、Python、錄音 controller、`scripts/`、`Package.swift`。

## 四、驗收條件
- [ ] AC-1 預設名稱純函式：輸入完成時間 → 「會議 10/14 12:57」格式（含月日個位數、跨年不顯示年份）；有使用者名稱時不使用預設（測試）。
- [ ] AC-2 只瀏覽（不編輯名稱）切換多筆紀錄後，`meeting-summaries.json` 不新增記錄（測試：store 記錄數不變）。
- [ ] AC-3 長度選擇純函式：實際長度存在 → 用實際長度（即使存檔長度較大）；實際長度 nil → 存檔長度；兩者皆無 → 最後一段結束（測試）。
- [ ] AC-4 播放列總長與進度條範圍使用同一個長度來源，不再取 max（程式審查＋測試）。
- [ ] AC-5 讀取實際長度只讀檔頭：以 200MB 等級的合成 WAV 或程式審查證明未整檔讀入（回報說明方法）。
- [ ] AC-N1 既有測試全過且不減（基準 swift 337、pytest 446），TSAN 通過；`git diff --stat e159c64 HEAD` 零觸碰禁止範圍。

## 五、停止條件
- 預設名稱改動會改變既有摘要記錄裡已存的名稱。
- 需要改資料格式或 store。
- 連續兩次修正仍未通過同一測試。

## 六、工作位置與回報
- 分支 `ui/review-fixup`，獨立 worktree `1P_Projects/Whisper-wt-review-fixup`，只 commit 不 push。
- 回報：commit hash、AC 逐條、測試結尾輸出、`git diff --stat e159c64 HEAD`、偏離與理由。

## 已知非目標
- 舊紀錄的 segment 時間碼本身偏移（時間軸修正前的錄音）不回修；只修正長度顯示。
