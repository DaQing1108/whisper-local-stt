# 任務規格：詞彙 Prompt Token 上限（Vocabulary Token Budget）

**建立日期：** 2026-10-14
**風險等級：** L2（跨 Swift／Python；新增一個 Worker 指令屬「加法」，不改既有指令與 payload；轉錄 prompt 的截斷方式小幅改變）
**ESAEV 起點：** Approve → Execute
**規劃／驗收／打包／push：** Claude（session「Whisper Swift 錄音品質檢查」）
**開發：** whisper-d3
**基準：** 分支 `whisper-swift`，HEAD `ce3944f`

---

## 一、問題背景與目標

### 問題背景（已實測）
- faster-whisper 的 `initial_prompt` 只保留**最後 223 個 token**（`max_length // 2 - 1`），超過的部分從**開頭**默默丟掉。
- 2026-10-14 實測：詞彙表 50 個詞＋設定額外詞，`build_prompt` 結果 502 字＝**231 tokens**，超過上限；開頭的 `Dream Ku`、`Michael Chien` 整個被丟，`OpenMAM` 被切成殘字。使用者完全看不到這件事。
- 新上線的「建議詞彙」會讓詞彙表成長更快，問題會持續惡化。
- 計算方式（規劃端已驗證）：`tokenizer.encode(" " + prompt.strip()).ids` 的長度，tokenizer 取自該模型的 `tokenizer.json`。

### 任務目標
1. 詞庫頁顯示目前 prompt 的 token 用量（例：`231 / 223 tokens`），超過時標示哪些詞**不會被套用**。
2. 轉錄時若超過上限，改為**以整個詞為單位**從開頭捨棄，不再出現殘字；捨棄結果與詞庫頁顯示一致。
3. 新增詞彙（手動加入、建議詞彙的「加入／全部加入」）後，用量即時更新；若因此超過上限，畫面顯示警示。

### 非本次目標
- 不做詞彙排序／拖曳調整順序（另案）。
- 不做詞彙分組或依領域帶入（另案）。
- 不自動刪除或停用任何詞彙；超過時只警示，由使用者決定。
- 不改 `vocabulary.json` 格式、不改 Classic（`main` 分支）。
- 不處理 `MERGED_PROMPT_MAX_CHARS`／`_merge_prompt`（Swift Worker 路徑未使用）。

---

## 二、執行範圍

### 允許修改範圍
**Python（Worker）**
- `whisper_core.py`：新增純函式（建議命名，可調整）：
  - `load_prompt_tokenizer(model_name)`：從本機模型快取讀 `tokenizer.json`（`tokenizers.Tokenizer.from_file`），**不載入模型權重**；找不到時回傳 `None`。
  - `fit_prompt_to_budget(domain, extra_terms, tokenizer, limit=223) -> {prompt, tokens, limit, kept_terms, dropped_terms}`：以 `build_prompt` 相同規則組 prompt；超過上限時從開頭以「整個詞」為單位捨棄（詞的分隔：`, `、`、`、`，`）；`DOMAIN_TERMS` 的領域詞視為最前面的詞，一樣可被捨棄。
  - 轉錄路徑（`build_prompt(domain, extra_terms)` 被呼叫處，`whisper_core.py:599` 一帶）改用 `fit_prompt_to_budget` 的 `prompt`；tokenizer 取不到時**維持原行為**（直接用 `build_prompt` 結果）。
- `worker_entrypoint.py`：新增指令 `prompt_budget`（payload：`domain`、`extra_terms`、`model`），同步回傳 `{tokens, limit, dropped_terms, available}`；比照 `model_status` 的處理方式，不佔用轉錄 job。
- `worker_protocol.py`：若需要，登記新指令（加法）。
- `tests/unit/`：新增 Python 測試。

**Swift（App）**
- `WorkerSupervisor.swift`：新增請求 `prompt_budget` 的方法與結果型別（比照 `requestModelStatus`）。
- `WorkerProtocol.swift`：若需要，新增結果解碼型別（加法）。
- 新增 `VocabularyBudgetController.swift`（建議名）：`@MainActor @Observable`，持有最新用量結果；詞彙或設定（模型、領域、額外詞）變更時，以 debounce（約 300–500ms）重新請求。
- 詞庫頁（`ContentView.swift` 的 `vocabularySection`，或拆出新 extension 檔）：顯示用量列與「不會套用」標記。
- `ContentView+VocabularySuggestions.swift`：加入後若超過上限，顯示警示文字。
- `WhisperApp.swift`／`ContentView.swift`：僅限注入新 controller。
- `Tests/WhisperAppTests/`：新增測試。

### 禁止修改範圍
- `vocabulary.json`、`transcription-history.json`、`meeting-summaries.json` 的檔案格式。
- 既有 Worker 指令（`transcribe`、`diarize`、`model_status` 等）的 payload 與回傳格式。
- `MeetingSummaryClient.swift`、`VocabularySuggestionClient.swift` 的 LLM 呼叫邏輯。
- 錄音／切段相關 controller（`MixedAudioRecordingController`、`LiveRecordingController` 等）。
- 打包腳本（`scripts/`、`package.sh`）、`Package.swift`、`requirements.txt`（`tokenizers` 已是 faster-whisper 的依賴，**不得新增依賴**）。
- `main` 分支。

### 需要人工核准的變更（預期皆為「否」，變成「是」→ 停止）
- [ ] 資料檔案格式變更
- [ ] 既有 Worker 指令契約變更（新增指令不算）
- [ ] 新增外部依賴
- [ ] 打包流程變更

---

## 三、系統限制

### 技術限制
- 上限 223 是 faster-whisper 的行為（`max_length=448`，`448//2-1`）。寫成具名常數，並在註解說明來源。
- large-v3 與 large-v3-turbo 的 tokenizer 相同；base 等小模型略有不同，一律用「目前選擇的模型」的 tokenizer。
- Worker 是 PyInstaller 打包；`tokenizers` 已在 bundle 內（faster-whisper 依賴），不得在 bundle 外另裝。
- tokenizer 取不到（模型尚未下載）→ `available=false`，App 顯示「尚未下載模型，無法計算用量」，不得 crash、不得阻擋轉錄。

### 安全與隱私限制
- 不得把詞彙內容寫進 log 或 `Diagnostics/inference.jsonl`（只可記 token 數）。

### 產品與業務規則
- 不自動刪除／停用詞彙；只顯示與警示。
- 詞庫頁「不會套用」的詞清單，必須與實際轉錄時捨棄的詞**完全一致**（同一個函式算出）。
- 已停用（`isEnabled=false`）的詞不計入用量。

---

## 四、驗收條件

### 正向驗收條件
- [ ] AC-1 Python：`fit_prompt_to_budget` 在未超過上限時，`prompt` 與 `build_prompt(domain, extra_terms)` **逐字相同**、`dropped_terms` 為空（測試覆蓋）。
- [ ] AC-2 Python：超過上限時，結果 token 數 ≤ 223，被捨棄的是**開頭的完整詞**，`prompt` 不含任何殘字（測試：用一組會超過的詞，斷言 `prompt` 等於「保留詞」依原規則重組的結果）。
- [ ] AC-3 Python：以**合成詞彙**（不得使用真實人名或使用者詞庫內容，避免個資進 repo）組出超過上限的 prompt，用真實 large-v3-turbo `tokenizer.json` 驗證：fit 前 token 數 > 223、fit 後 ≤ 223、`dropped_terms` 為開頭連續的完整詞。tokenizer 不存在時 skip 並註明原因。（使用者實際詞庫 231 tokens、捨棄 `Dream Ku`…的重現，由規劃端驗收時以本機資料跑，不進 repo。）
- [ ] AC-4 Python：轉錄路徑使用 fit 後的 prompt；tokenizer 取不到時退回 `build_prompt` 原結果（測試以 monkeypatch 模擬兩種情況）。
- [ ] AC-5 Worker：`prompt_budget` 指令回傳 `{tokens, limit, dropped_terms, available}`；模型未下載時 `available=false` 且不拋例外（測試覆蓋）。
- [ ] AC-6 Swift：詞庫頁顯示 `X / 223 tokens`；超過時顯示警示，並在被捨棄的詞旁標示「不會套用」（以 controller 狀態測試覆蓋；UI 外觀留給真機驗證）。
- [ ] AC-7 Swift：詞彙新增／刪除／停用、或模型／領域／額外詞變更後，經 debounce 重新請求一次（假 Worker 計數測試：連續 5 次變更 → 只送 1 次）。
- [ ] AC-8 Swift：「建議詞彙」加入後若超過上限，顯示警示（controller 狀態測試）。
- [ ] AC-9 Swift：`available=false` 時顯示「尚未下載模型，無法計算用量」，不顯示錯誤數字。

### 負向驗收條件（不得破壞）
- [ ] AC-10 既有 Swift 測試全過（基準 264，以實際執行為準，不得減少）；既有 Python 單元測試全過（基準以 `ce3944f` 實際執行數為準，不得減少）。
- [ ] AC-11 `git diff --stat` 零觸碰：`scripts/`、`package.sh`、`Package.swift`、`requirements.txt`、錄音／切段 controller、LLM client。
- [ ] AC-12 既有 Worker 指令的 payload／回傳格式不變（既有 protocol 測試全過，`git diff` 對既有指令分支無語意變更）。
- [ ] AC-13 詞彙內容不出現在任何 log／診斷輸出（grep 新增程式碼中的 log 呼叫確認）。

### 必要驗證指令
```bash
# Python（RTK hook 會攔截 python -m pytest，直接呼叫系統 python3）
/usr/bin/python3 -m pytest tests/unit -q
# Swift（iCloud 路徑一定要 scratch-path）
cd macos/WhisperApp
swift test --scratch-path /tmp/vocab-budget-test
swift test --scratch-path /tmp/vocab-budget-tsan --sanitize=thread
git diff --stat ce3944f HEAD
```

---

## 五、執行規則

### 停止條件（任一發生即停止並 SendMessage 回報規劃端）
- 需要新增 Python 或 Swift 外部依賴，或 `tokenizers` 在 Worker 環境無法 import。
- 需要改既有 Worker 指令的 payload／回傳格式。
- 需要改任何資料檔案格式。
- `fit_prompt_to_budget` 無法做到與實際轉錄捨棄結果一致（例如 faster-whisper 另有前綴 token 導致數字對不上）。
- 連續兩次修正仍未通過同一測試。
- 需要真實錄音或打包後才能驗證的項目——標記為「無法驗證」，不要自行打包。

### 執行方不能做（留給規劃端）
- `git push`、打包（`build_worker_runtime.sh`、`build_swiftui_app.sh`）、安裝到 `~/Applications`。
- 讀取 `.env` 或 Keychain。
- 可以在自己的分支 commit。

### 工作位置與分支
- 從 `whisper-swift`（`ce3944f`）開分支 `feat/vocab-token-budget`，用獨立 worktree `1P_Projects/Whisper-wt-vocab-budget`。
- 不要在 `.worktrees/swiftui-python-poc` 直接改（有其他 session 的未追蹤檔）。

### 升級對象
- 產品問題 → 使用者
- 技術問題 → 規劃端 Claude（SendMessage 回覆）

---

## 六、完成回報格式

用 SendMessage 回覆規劃端：
1. 分支與 commit hash（未 push）。
2. 修改摘要（檔案清單、新增函式與指令名稱）。
3. AC-1～AC-13 逐條 ✅／❌，並貼 pytest 與 `swift test`（含 TSAN）結尾輸出。
4. `git diff --stat ce3944f HEAD` 全文。
5. 偏離規格之處與理由。
6. 已驗證／無法驗證：bundle 內 `tokenizers` 可用性、詞庫頁 UI 外觀，留給規劃端打包後與使用者真機確認。

---

## 品質審核結論
✅ 可直接交付。無阻塞性 `⚠️ 待確認`。
決策記錄：
- 超過上限時「只警示、不自動刪詞」——避免系統替使用者決定哪些詞重要。
- 轉錄截斷改為「整個詞」——消除殘字，並讓詞庫頁顯示與實際行為一致；tokenizer 取不到時退回原行為，風險最小。
- 不做排序功能——先讓問題可見，排序視使用回饋另開規格。
