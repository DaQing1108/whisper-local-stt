# 任務規格：詞彙智慧保留＋誤聽修正表

**建立日期：** 2026-10-14
**風險等級：** L2（跨 Swift／Python；新增兩個資料檔、`transcribe` 指令新增一個**選填**欄位，屬加法且向下相容；不改既有資料檔格式）
**ESAEV 起點：** Approve → Execute
**規劃／驗收／打包／push：** Claude（session「Whisper Swift 錄音品質檢查」）
**開發：** whisper-d3
**基準：** 分支 `whisper-swift`，HEAD `658ace1`（含上一輪 token 上限）

建議分兩個 commit：Part A、Part B 各一，方便驗收與必要時單獨回退。

---

## 一、問題背景與目標

### 問題背景
- 上一輪已能精確顯示 token 用量（使用者詞庫 228/223），但超過時捨棄的是**最早加入**的詞，跟重要性無關；新詞（例如「建議詞彙」加入的）加在尾端，反而把常用人名擠掉。
- 2026-10-14 實測：同一場會議即使詞庫正確，`Articature`／`Free 上傳`／`朋友放入到KM` 這類誤聽仍會反覆出現；「建議詞彙」的 LLM 回應已帶 `heard_as`（誤聽寫法），但目前只顯示、沒有被利用。
- prompt 有 223 token 上限，無法靠一直加詞解決。

### 任務目標
**Part A：依使用頻率決定保留順序**
- 詞送進 prompt 的順序改為「最不重要的在前、最重要的在後」（faster-whisper 從開頭截斷，所以後面的詞會被保留）。
- 重要性＝該詞「最近活動時間」：`max(加入時間, 最後一次出現在逐字稿的時間)`。很久沒出現、也很久前加入的詞最先被捨棄；剛加入的詞與常出現的詞會被保留。
- 首次啟用時，用既有歷史紀錄（`transcription-history.json`）回填每個詞的最後出現時間。

**Part B：誤聽修正表**
- 新增修正規則 `{錯誤寫法 → 正確寫法}`，轉錄完成後對每個 segment 做**精確字串替換**；不佔 prompt、數量不受 token 上限限制。
- 規則來源：(1)「建議詞彙」加入時，可勾選一併加入它的 `heard_as` 對照；(2) 詞庫頁手動新增。一律人工確認才寫入。
- 規則可停用、可刪除。

### 非本次目標
- 不回頭修改既有歷史逐字稿（修正只作用於之後的轉錄）。
- 不做模糊比對／拼音相似度替換（只做精確字串）。
- 不做「釘選永遠保留」、手動拖曳排序、依會議情境挑詞（另案）。
- 不改詞庫頁的清單顯示順序（顯示仍照使用者加入順序；只改送進 prompt 的順序）。
- 不改 Classic（`main`）。

---

## 二、執行範圍

### 允許修改範圍
**Part A（Swift）**
- 新增 `VocabularyUsageStore.swift`（建議名）：讀寫新檔 `~/Library/Application Support/WhisperSwiftUI/vocabulary-usage.json`，內容以詞的 `id`（UUID）為鍵：`{addedAt, lastSeenAt}`；寫入用 atomic write，失敗不影響轉錄。
- `VocabularyStore.swift`：
  - `add`／`addAll` 時記錄 `addedAt`（寫到 usage store，**不得**改 `vocabulary.json` 格式）。
  - 新增「依優先順序排列的啟用詞」計算（建議名 `promptOrderedActiveTerms`），`activeTermsText` 改用此順序。
  - 既有詞沒有 `addedAt` 時，以「在清單中的位置」換算出遞增的虛擬時間（越後面越新），保證排序穩定、可測。
- 轉錄完成寫入歷史的位置（`TranscriptionHistoryStore` 新增／更新結果時，或其呼叫端）：掃描完成的逐字稿，對**不分大小寫**出現的啟用詞更新 `lastSeenAt`。
- 首次回填：usage 檔不存在時，掃描全部歷史紀錄，以各紀錄的 `completedAt` 填 `lastSeenAt`；只做一次。
- `VocabularyBudgetController.swift`：`droppedTermIDs` 改為依 prompt 實際順序對應（不能再假設是清單前段）。
- 詞庫頁：被標「不會套用」的詞依新順序計算；可在每個詞旁以小字顯示「最近出現：N 天前／從未出現」（選做，見 AC-A6）。

**Part B（Swift＋Python）**
- 新增 `CorrectionRuleStore.swift`（建議名）：新檔 `~/Library/Application Support/WhisperSwiftUI/correction-rules.json`，每筆 `{id, wrong, right, isEnabled, createdAt}`。
- 詞庫頁：新增「誤聽修正」區塊，可手動新增（錯誤寫法、正確寫法）、停用、刪除。
- `ContentView+VocabularySuggestions.swift`：候選詞若有 `heardAs`，在「加入」旁提供選項（勾選或第二個按鈕）一併建立 `heard_as → term` 規則；預設**不勾選**。
- `WorkerSupervisor.swift`：`transcribe` 指令 payload 新增**選填**欄位 `corrections`（`[{wrong, right}]`，只送啟用中的規則）；所有轉錄入口（標準錄音、即時、混音、檔案、批次、重新轉錄）都帶上。
- Python：`worker_entrypoint.py` 讀選填 `corrections`；`whisper_core.py` 新增純函式 `apply_corrections(segments, corrections)`，在 `clean_segments`／繁體轉換**之後**套用；`worker_protocol.py` 驗證選填欄位（型別錯誤 → protocol error，缺欄位 → 視為空）。
- 測試檔：`tests/unit/` 與 `Tests/WhisperAppTests/` 新增。

### 禁止修改範圍
- `vocabulary.json`、`transcription-history.json`、`meeting-summaries.json` 的檔案格式。
- 既有 Worker 指令的**必填**欄位與回傳格式（`corrections` 是唯一允許新增的選填欄位）。
- `fit_prompt_to_budget`／`build_prompt` 的演算法（排序在 Swift 端完成，Python 照收到的順序處理）。
- 錄音／切段 controller 的切段邏輯、`MeetingSummaryClient.swift`、LLM 呼叫邏輯。
- `scripts/`、`package.sh`、`Package.swift`、`requirements.txt`；不得新增依賴。

### 需要人工核准的變更（預期皆為「否」，變成「是」→ 停止）
- [ ] 既有資料檔格式變更
- [ ] 既有 Worker 指令必填欄位或回傳格式變更
- [ ] 新增外部依賴

---

## 三、系統限制

### 技術限制
- 排序與 usage 只影響「送進 prompt 的順序」；token 計算與捨棄仍由上一輪的 `prompt_budget`／`fit_prompt_to_budget` 處理，兩者必須看到**同一個順序**的字串。
- 詞的出現判斷：不分大小寫的子字串比對；ASCII 詞要求左右不是英數字（避免 `KM` 命中 `KMS`）。
- 修正替換規則：
  - 精確字串、區分大小寫。
  - `wrong` 為純 ASCII 時要求左右不是英數字（避免 `Free` 命中 `Freedom`）；含中日韓字元時直接子字串替換。
  - 多條規則依 `wrong` 長度**由長到短**套用，避免短規則先吃掉長規則。
  - `wrong` 不得為空、不得等於 `right`；`wrong` 長度 ≥ 2。
- usage／規則檔讀取失敗：記錄錯誤並以空資料運作，不得阻擋轉錄或 app 啟動。

### 安全與隱私限制
- 規則內容與詞彙內容不得寫進 log／診斷檔（只可記數量）。
- 測試只用合成資料，不得把使用者真實詞庫、人名或逐字稿寫進 repo。

### 產品與業務規則
- 不自動建立修正規則，不自動刪除或停用詞彙；一律人工確認。
- 修正只套用在之後的轉錄，不改已存在的歷史。

---

## 四、驗收條件

### Part A：依使用頻率保留
- [ ] AC-A1 排序：給定三個詞（很久前加入且從未出現／很久前加入但昨天出現／今天剛加入），`activeTermsText` 順序為「第一個 → 第二個／第三個（依時間）」，最重要的在最後（測試覆蓋）。
- [ ] AC-A2 舊詞沒有 `addedAt` 時，以清單位置換算的虛擬時間排序，結果穩定（同輸入多次呼叫結果相同）。
- [ ] AC-A3 轉錄完成寫入歷史後，逐字稿中出現的啟用詞 `lastSeenAt` 被更新；未出現的不變；ASCII 邊界規則有測試（`KM` 不命中 `KMS`）。
- [ ] AC-A4 首次回填：usage 檔不存在時掃描歷史一次，以 `completedAt` 填入；第二次啟動不重掃（測試用合成歷史）。
- [ ] AC-A5 `VocabularyBudgetController` 的「不會套用」標示依 prompt 實際順序對應：測試構造「清單第 1 個詞因最近出現而排在 prompt 尾端」的情況，超過上限時被標示的是 prompt 開頭的詞，不是清單第 1 個。
- [ ] AC-A6（選做）詞庫頁顯示「最近出現：N 天前／從未出現」。
- [ ] AC-A7 `vocabulary.json` 格式不變（既有 `VocabularyStoreTests` 全過；新舊檔互讀測試仍過）。

### Part B：誤聽修正表
- [ ] AC-B1 Python `apply_corrections`：中文子字串替換、ASCII 邊界（`Free 上傳`→`FTP 上傳` 成立，`Freedom` 不變）、長規則優先、空清單不變，各有測試。
- [ ] AC-B2 Worker：`transcribe` 帶 `corrections` 時套用；不帶時行為與基準完全相同（既有測試全過＋新增一條「無 corrections 時輸出逐字相同」測試）；`corrections` 型別錯誤回 protocol error。
- [ ] AC-B3 Swift：所有轉錄入口送出的 payload 都帶啟用中的規則；停用的規則不送（假 Worker 檢查 payload）。
- [ ] AC-B4 規則驗證：`wrong` 空白、長度 < 2、等於 `right`、重複的 `wrong` 一律拒絕並顯示原因。
- [ ] AC-B5 建議詞彙：有 `heardAs` 的候選，勾選後「加入」同時建立 `heard_as[i] → term` 規則；未勾選只加詞（測試覆蓋）；`heard_as` 與 `term` 相同者略過。
- [ ] AC-B6 規則檔讀取失敗時，以空規則運作且顯示錯誤，不阻擋轉錄。

### 負向驗收條件（不得破壞）
- [ ] AC-N1 既有測試全過且數量不減：基準 pytest 397、swift test 275（以 `658ace1` 實際執行為準）；TSAN 通過。
- [ ] AC-N2 `git diff --stat 658ace1 HEAD` 零觸碰：`scripts/`、`package.sh`、`Package.swift`、`requirements.txt`、錄音／切段 controller 的切段邏輯、`MeetingSummaryClient.swift`、`VocabularySuggestionClient.swift` 的 LLM 呼叫、`fit_prompt_to_budget`／`build_prompt`。
- [ ] AC-N3 新增的 log 不含詞彙或規則內容。
- [ ] AC-N4 `transcription-history.json`、`vocabulary.json` 格式不變。

### 必要驗證指令
```bash
/usr/bin/python3 -m pytest tests/unit -q
cd macos/WhisperApp
swift test --scratch-path /tmp/vocab-prio-test
swift test --scratch-path /tmp/vocab-prio-tsan --sanitize=thread
git diff --stat 658ace1 HEAD
```

---

## 五、執行規則

### 停止條件（任一發生即停止並 SendMessage 回報）
- 需要改 `vocabulary.json`／歷史檔格式，或改既有 Worker 指令的必填欄位／回傳格式。
- 找不到所有轉錄入口共用的送出點，導致 AC-B3 必須逐一修改超過 6 個呼叫點——先回報設計再動手。
- 修正替換放在 Python 出口後，即時（live／mixed）逐字稿顯示與最終存檔不一致。
- 需要新增依賴。
- 連續兩次修正仍未通過同一測試。

### 執行方不能做（留給規劃端）
- `git push`、打包（Worker 與 app）、安裝。
- 讀取 `.env`、Keychain、使用者實際的 `vocabulary.json`／歷史紀錄內容（測試一律用合成資料）。
- 可以在自己的分支 commit。

### 工作位置與分支
- 從 `whisper-swift`（`658ace1`）開分支 `feat/vocab-priority-corrections`，獨立 worktree `1P_Projects/Whisper-wt-vocab-priority`。

### 升級對象
- 產品問題 → 使用者
- 技術問題 → 規劃端 Claude（SendMessage）

---

## 六、完成回報格式
1. 分支與 commit hash（Part A、Part B 各自的 commit）。
2. 修改摘要（檔案清單、新增資料檔與欄位、所有轉錄入口如何帶上 `corrections`）。
3. AC 逐條 ✅／❌，附 pytest、`swift test`、TSAN 結尾輸出。
4. `git diff --stat 658ace1 HEAD` 全文。
5. 偏離規格之處與理由。
6. 已驗證／無法驗證（UI 外觀、真實會議的修正效果、回填在使用者真實歷史上的結果——由規劃端打包後驗證）。

---

## 品質審核結論
✅ 可直接交付。無阻塞性 `⚠️ 待確認`。
決策記錄：
- 重要性用「最近活動時間」而非累計次數：避免早期高頻、現已不用的詞永遠佔位；剛加入的詞不會立刻被擠掉。
- usage 與規則各存新檔，不動 `vocabulary.json`：既有格式零風險、可單獨刪檔回退。
- 修正放在 Python 轉錄出口：所有模式共用一個套用點；`corrections` 為選填，不帶時行為與基準相同。
- 只做精確替換＋ASCII 邊界：誤換風險最低；模糊比對另案評估。
