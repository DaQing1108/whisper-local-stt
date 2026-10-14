# 任務規格：會後「詞彙建議」（Vocabulary Suggestions）

**建立日期：** 2026-10-14
**風險等級：** L2（跨多檔案，無 schema／CI 變更；新增一次對外 LLM 呼叫但沿用既有供應商與金鑰）
**ESAEV 起點：** Approve → Execute
**規劃／驗收／打包／push：** Claude（whisper-swift 規劃端，session「Whisper Swift 錄音品質檢查」）
**開發：** 本文件的接收方 Claude
**基準：** 分支 `whisper-swift`，HEAD `c3c40df`

---

## 一、問題背景與目標

### 問題背景
2026-10-14 一場 3 分鐘會議的逐字稿，中英混雜的專有名詞大量誤聽（Articature→Architecture、Free 上傳→FTP、朋友放入到KM→文件放入KM 等）。詞彙表（`vocabulary.json`）目前只能手動維護，使用者要自己回頭比對逐字稿才知道該補哪些詞。詞彙會被組成 initial_prompt 餵給 Whisper，補對詞即可改善下一場辨識。

### 任務目標
在 AI Summary 分頁新增「建議詞彙」按鈕。使用者按下後，app 用**已設定的摘要供應商與金鑰**把目前這筆逐字稿送給 LLM，取得「疑似專有名詞／疑似誤聽詞」候選清單，顯示在畫面上，使用者可逐個或一次加入 `VocabularyStore`。

### 非本次目標
- 不做自動觸發（轉錄完成後不得自動送 LLM；一律使用者按鈕觸發）。
- 不做自動寫入詞彙表（一律人工確認）。
- 不從 Obsidian／Notion 批次抽詞（另案）。
- 不做詞彙分組／依領域帶入（另案）。
- 不改 Python Worker、不改 initial_prompt 組裝邏輯。

---

## 二、執行範圍

### 允許修改範圍（`macos/WhisperApp/`）
- 新增 `Sources/WhisperApp/VocabularySuggestionClient.swift`：protocol＋OpenAI／Anthropic 實作（重用 `MeetingSummaryHTTPTransport`、`LLMCredentialStore`、`MeetingSummaryProvider`）。
- 新增 `Sources/WhisperApp/VocabularySuggestionController.swift`：`@MainActor @Observable`，管理狀態（idle／loading／loaded／failed）、候選清單、錯誤訊息。
- `Sources/WhisperApp/VocabularyStore.swift`：僅可新增方法（例如批次加入），**不得改變**既有 `add/toggle/remove` 行為與 `vocabulary.json` 格式。
- `Sources/WhisperApp/ContentView+Results.swift`（`summaryContent` 區塊）：加按鈕與候選清單 UI。
- `Sources/WhisperApp/WhisperApp.swift`、`ContentView.swift`：僅限注入新 controller 的必要接線。
- `Tests/WhisperAppTests/`：新增對應測試檔；可小幅擴充既有 mock。

### 禁止修改範圍
- 所有 Python 檔（`worker_entrypoint.py` 等）與 `*.py`。
- `MeetingSummaryClient.swift` 既有的摘要 prompt 與行為（可重用其型別，不得改動既有函式簽章與 instructions）。
- `vocabulary.json`、`meeting-summaries.json`、`transcription-history.json` 的檔案格式（零 schema 變更）。
- `LLMCredentialStore` 的儲存位置與讀寫行為。
- 打包／簽章腳本（`scripts/`、`package.sh`）、`Package.swift` 依賴（不得新增外部依賴）。
- 轉錄、錄音相關 controller。

### 需要人工核准的變更（本次預期全為「否」，若變成「是」→ 停止）
- [ ] 資料庫結構或遷移
- [ ] 公開 API 契約變更
- [ ] 新增外部依賴
- [ ] 權限與安全政策
- [ ] 正式環境設定

---

## 三、系統限制

### 技術限制
- Swift／SwiftUI，沿用 `@Observable` 與既有 transport 抽象，測試用注入假 transport，不打真實網路。
- 不新增外部套件。

### 安全與隱私限制
- 逐字稿屬敏感資料：**只在使用者按下按鈕時送出一次**；不得自動送出、不得背景重試送出。
- 沿用使用者已選的 `settings.summaryProvider` 與其金鑰；缺金鑰時顯示既有 `missingCredential` 錯誤，不得改用其他供應商或硬編碼金鑰。
- 不得把逐字稿或 LLM 回應寫入 log／診斷檔。
- 網路逾時或不確定結果，沿用 `ambiguousOutcome` 語意：不自動重送。

### 產品與業務規則
- LLM 回傳須為 JSON：`[{"term": "FTP", "heard_as": ["Free"], "reason": "..."}]`。非 JSON 或格式錯誤 → 顯示「無法解析建議結果」，不得寫入任何詞彙。
- 過濾規則（在 app 端做，不依賴 LLM 遵守）：
  1. 去除與現有詞彙（不分大小寫）重複者；
  2. `term` 去頭尾空白後長度 1–40 字元、不含換行；
  3. 同一回應內不分大小寫去重；
  4. 最多顯示 20 筆。
- 候選清單中每筆顯示 `term`、`heard_as`（若有）、`reason`；每筆有「加入」，另有「全部加入」。
- 加入後該筆從候選清單移除；`VocabularyStore` 寫入失敗要顯示錯誤，且候選保留。
- 同一時間只允許一個建議請求進行中（按鈕 loading 時 disabled）。

---

## 四、驗收條件

### 正向驗收條件
- [ ] AC-1 AI Summary 分頁有「建議詞彙」按鈕；未選取逐字稿或請求進行中時為 disabled。
- [ ] AC-2 注入假 transport 回傳合法 JSON 時，controller 產出候選清單，且已存在於詞彙表的詞（含大小寫不同）被過濾掉（測試覆蓋）。
- [ ] AC-3 過濾規則 1–4 各有一條單元測試（重複、超長／含換行、回應內重複、超過 20 筆截斷）。
- [ ] AC-4 回應非 JSON、缺欄位、空陣列時：狀態為 failed 或 loaded(空)，**詞彙表內容不變**（測試覆蓋，斷言 `vocabulary.terms` 前後相等）。
- [ ] AC-5 缺金鑰時不發出任何 request（假 transport 呼叫次數 = 0）並顯示 missingCredential 錯誤。
- [ ] AC-6 「加入」呼叫 `VocabularyStore.add`，成功後該筆從候選移除；`VocabularyStore` 寫入失敗時候選保留並顯示錯誤。
- [ ] AC-7 OpenAI 與 Anthropic 兩個實作各有一條 request 組裝測試（URL、header、model、body 內含逐字稿且 system／instructions 含「只回傳 JSON」）。

### 負向驗收條件（不得破壞）
- [ ] AC-8 既有 Swift 測試全數通過（基準：Swift 108 tests，以實際執行為準，不得減少）。
- [ ] AC-9 `git diff --stat` 零觸碰任何 `*.py`、`Package.swift`、`scripts/`。
- [ ] AC-10 `MeetingSummaryClient.swift` 內既有 `instructions` 字串與 `generate` 簽章未變（`git diff` 該檔僅允許為重用而放寬的 `private`→`internal` 存取修飾，且需在回報中列出）。
- [ ] AC-11 `vocabulary.json` 編碼格式不變：既有 `VocabularyStoreTests` 全過，且新增一條「新舊檔案互讀」測試。
- [ ] AC-12 轉錄完成流程不得自動呼叫建議功能（測試或程式審查可證：僅按鈕 action 會呼叫 controller）。

### 必要驗證指令
```bash
cd macos/WhisperApp
# 注意：iCloud 目錄下 codesign 會卡 FinderInfo，一律加 scratch-path（見專案 CLAUDE.md）
swift test --scratch-path /tmp/vocab-sugg-test
swift test --scratch-path /tmp/vocab-sugg-tsan --sanitize=thread
git diff --stat   # 對照 AC-9、AC-10
```

---

## 五、執行規則

### 停止條件（遇到任一即停止並回報，不要自行解決）
- 需要修改禁止範圍內的檔案，或需要新增外部依賴。
- 需要改變 `vocabulary.json`／history／summary 檔案格式。
- 發現既有 `MeetingSummaryClient` 必須改行為才能重用。
- 連續兩次修正仍未通過同一測試。
- 需要真實 API 金鑰或真實網路才能驗證（本任務所有測試都應以假 transport 完成）。
- 實作過程發現必須自動觸發（違反非目標）才能達成需求。

### 執行方不能做（留給規劃端）
- `git push`；打包、簽章、`build_swiftui_app.sh`、安裝到 `~/Applications`。
- 讀取 `~/Library/Application Support/WhisperSTT/.env` 或任何 Keychain 憑證。
- 可以在自己的分支 `git commit`（見下節）。

### 工作位置與分支
- 請從 `whisper-swift` 開新分支 `feat/vocab-suggestions`，**用獨立 worktree**（`git worktree add`），不要直接在 `.worktrees/swiftui-python-poc` 工作（該處有其他 session 的未追蹤 HANDOFF 檔與進行中改動）。
- worktree 位置沿用 `1P_Projects/Whisper-wt-vocab-suggestions`（與既有 `Whisper-wt-mixed-stopgap` 同層）。

### 升級對象
- 產品問題 → 使用者（Alex）
- 技術問題 → 規劃端 Claude（用 SendMessage 回覆本文件的發送者）
- 安全問題 → Dream（Dev Director），經由使用者

---

## 六、完成回報格式

完成時用 SendMessage 回覆規劃端，內容須含：
1. 分支名與 commit hash（未 push）。
2. 修改摘要（檔案清單與採用方案）。
3. 驗收證據：AC-1~AC-12 逐條 ✅／❌，並貼 `swift test` 與 TSAN 的結尾輸出（測試總數、失敗數）。
4. 範圍確認：`git diff --stat` 全文。
5. 已知風險與未完成事項。
6. **我（開發方）已驗證／無法驗證**：UI 實際外觀與真實 LLM 回應品質無法自動驗證，留給規劃端與使用者真機測試。

---

## 品質審核結論
✅ 可直接交付。無阻塞性 `⚠️ 待確認`。決策記錄：採「使用者按鈕觸發」而非自動，理由是逐字稿送外部 LLM 屬敏感操作，維持與「產生摘要」相同的使用者主導模式；日後若要改自動，另開規格。
