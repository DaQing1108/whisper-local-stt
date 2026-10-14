# 任務規格：逐字稿品質修正（時間碼偏移、語意校對防呆、幻聽過濾）

**建立日期：** 2026-10-14
**風險等級：** L2（跨 Swift／Python；不改資料檔格式、不改 Worker 指令契約）
**ESAEV 起點：** Approve → Execute
**規劃／驗收／打包／push：** Claude（session「Whisper Swift 錄音品質檢查」）
**開發：** whisper-d3
**基準：** 分支 `whisper-swift`，HEAD `4b312f2`

建議三個 commit（Part A／B／C 各一），方便驗收與單獨回退。

---

## 一、問題背景（規劃端已用 2026-10-14 一場 1 小時 53 分會議實測，與 Teams 逐字稿對照）

**A. 時間碼累積偏移（bug）**
- 錄音檔實長 6,773 秒，逐字稿時間軸到 7,150 秒，多 377 秒；與 Teams 對照同一句話，偏移從開頭 −47 秒逐步累積到結尾 +383 秒。點逐字稿跳播在會議後段會跳錯位置。
- 推定根因：`MixedAudioRecordingController.acceptCompletedChunk`（約第 618 行）與 `LiveRecordingController.acceptCompletedChunk`（約第 511 行）用 `max(maximumSegmentEnd, durationSeconds ?? …)` 推進 `transcriptDurationSeconds`。Worker 回傳的 `info.duration_seconds` 已是該 chunk 的**實際音訊長度**（`whisper_core.py` 約第 750 行），但 Whisper 的 segment `end` 常超出實長，每段多累積一點。
- 疑點（請驗證）：`acceptFinalizedChunk`（約第 589 行）對靜音 chunk 當下就呼叫 `acceptCompletedChunk` 推進時間軸，不等前面仍在轉錄的 chunk；若前面 chunk 尚未完成，時間軸順序可能錯亂。

**B. 語意校對把 LLM 的拒答寫進逐字稿（bug）**
- 逐字稿 `[01:00:48]` 出現 LLM 回覆原文：「我無法處理這個輸入，因為它只包含重複的笑聲符號…請提供真實的 ASR 語音辨識原始輸出文字…」。`llm_post.llm_punctuate` 只在逾時或例外時退回原文，沒有檢查輸出內容。

**C. 幻聽／亂碼未被過濾**
- 連續重複短句：「謝謝」×18、「拍拖子」連續 ×13、「OK」×18、「對啊」×15。既有 `_collapse_consecutive_repeats` 要求正規化後 ≥4 字，短句全部漏掉。
- 句內循環：「對呀,對呀,…」×14、「那個,那個,…」×6、「可能會有這個狀況」×4、「RD,RD,RD,RD」。
- 中文數字清單幻聽：「一、四、二、五、四、四、五、九、…」。
- 16 段日／韓／俄／葡／土文字混雜亂碼（例：`ネタ`、`Итак,選由 Vocês預見 minds…`、`我們 있으니까`、`我們要ря`、`如果可以加速�나呢`），集中在遠端講者時段；但也有長句中只夾一個「です」的情況，該句其餘內容是真的。

### 任務目標
- A：逐字稿時間軸總長＝錄音實長（誤差 ≤ 1 秒／小時），segment 時間不超出所屬 chunk 範圍，且依 chunk 順序遞增。
- B：LLM 輸出不像「原文加標點」時，該段退回原文。
- C：上述四類幻聽被移除或壓縮，真實內容不被誤刪。

### 非本次目標
- 不回頭修正既有歷史紀錄（無 per-chunk 資料可重算）。
- 不做講者辨識、不改錄音／混音音訊處理（回音問題另案）。
- 不改語意校對的 prompt 文字內容。
- 不做跨 chunk 的重複偵測（只在單一 chunk 的 segment 清單內處理；跨 chunk 列為已知限制）。

---

## 二、執行範圍

### 允許修改範圍
**Part A（Swift）**
- `MixedAudioRecordingController.swift`、`LiveRecordingController.swift` 的 `acceptCompletedChunk` 與時間軸推進邏輯；必要時調整靜音 chunk 的接受時機以維持順序。
- 若兩者邏輯相同，可抽共用的純函式（例如 `ChunkTimelineAccumulator`）。

**Part B（Python）**
- `llm_post.py`：新增輸出驗證純函式（建議名 `is_plausible_punctuation(original, output) -> (bool, reason)`），在 `llm_punctuate`（及其分段呼叫處）對每一段 LLM 輸出驗證，不通過則該段用原文。

**Part C（Python）**
- `transcribe_common.py`：擴充 `clean_segments` 與相關常數／純函式。
- `clean_segments` 需要知道語言時，可新增**選填**參數（預設行為不變），呼叫端（`whisper_core.py`）傳入有效語言。

**測試**：`tests/unit/`、`Tests/WhisperAppTests/` 新增。

### 禁止修改範圍
- 資料檔格式（`transcription-history.json`、`vocabulary*.json`、`correction-rules.json` 等）。
- Worker 指令與回傳格式（含 `info.duration_seconds` 的語意）。
- 語意校對 prompt 文字（`_LLM_PUNCT_PROMPT`）、LLM 供應商與模型選擇。
- 切段演算法（`ChunkRotationDecider`、`AudioChunkSilenceDetector` 的門檻）。
- 既有 `is_hallucination` 六條規則與 `_FAKE_SUBTITLE_RES` 的行為（可新增規則，不可放寬或刪除既有規則）。
- `scripts/`、`package.sh`、`Package.swift`、`requirements.txt`；不得新增依賴。

### 需要人工核准的變更（預期皆為「否」，變成「是」→ 停止）
- [ ] 資料檔格式或 Worker 指令契約變更
- [ ] 新增依賴
- [ ] 切段或靜音判斷門檻變更

---

## 三、系統限制與規則

### Part A
- 有 `durationSeconds`（Worker 回傳實長）時，**一律用它**推進時間軸；`maximumSegmentEnd` 只在 `durationSeconds` 為 nil 時當備援。
- 每個 segment 的 `start`／`end` 夾在 `[0, chunkDuration]` 內再加 offset；`start > end` 時令 `end = start`。
- 時間軸必須依 chunk 產生順序推進（含靜音 chunk）。若現行靜音 chunk 會插隊，改成依序接受（例如交由既有 ordered queue 處理，或延後到前一個 chunk 完成）。

### Part B
驗證不通過任一條即退回該段原文（只記 reason 代碼與數量到 log，不記文字內容）：
1. **後設回覆偵測**：輸出含下列任一樣式、而原文不含——「無法處理」「請提供」「我會按照」「作為AI」「作為一個」「ASR」「語音辨識原始輸出」「I cannot」「I can't」「As an AI」「Please provide」。
2. **長度比**：去除標點與空白後，輸出字數 ÷ 原文字數 不在 `[0.7, 1.3]`。
3. **行數**：原文 ≥ 3 行時，輸出非空行數與原文行數差超過 20%。
常數可具名、可調，但預設值照上述。

### Part C（僅在 segment 清單內處理）
1. **短句連續重複**：正規化後長度 1–3 字的相同 segment 連續 ≥ 5 次 → 保留第一個。（既有 ≥4 字、連續 ≥3 次規則不變。）
2. **句內循環壓縮**：同一 segment 內，1–8 字的片語以 `,`、`，`、`、`、`.`、`。`、空白分隔**連續重複 ≥ 4 次** → 壓成 1 次（保留前後其他文字）。
3. **中文數字清單**：segment 內出現 ≥ 10 個以「、」或「,」分隔的單一中文數字（一～十）→ 丟棄該 segment。
4. **外文字元污染**（只在有效語言為 `zh` 時套用）：
   - 外文字元＝平假名、片假名、韓文、西里爾、阿拉伯字母、拉丁擴充（如 `ç ê ş ı ö`），以及 U+FFFD（�）。
   - 外文字元佔「非空白、非標點字元」比例 ≥ 10%，或 segment 去標點後 ≤ 6 字且含任一外文字元 → 丟棄 segment。
   - 否則移除這些外文字元（及因此留下的多餘空白），保留其餘內容。
   - **不得**刪除純 ASCII 英文（會議常有英文術語）。
- 每條規則觸發時記 warning（只記規則名與數量，不記內容），比照既有 `[CleanSegments]` 格式。

### 安全與隱私
- **測試只能用合成句子**，不得把 10/14 會議的真實內容、同事姓名寫進 repo。規則所需的樣式可用合成句重現（例：`好的,好的,好的,好的,好的`、`ありがとう`、`一、二、三、…`）。
- 新增 log 不含逐字稿或 LLM 輸出內容。

---

## 四、驗收條件

### Part A
- [ ] AC-A1 模擬 200 個 chunk、實長 8–30 秒、segment `end` 隨機超出實長 0–3 秒：累積 `transcriptDurationSeconds` 與實長總和誤差 < 0.01 秒（Mixed 與 Live 各一）。
- [ ] AC-A2 segment 時間夾在 chunk 範圍內：任一 segment `end` ≤ 該 chunk offset＋實長；全部 segment `start` 單調不遞減。
- [ ] AC-A3 靜音 chunk 與非靜音 chunk 交錯、且非靜音 chunk 晚完成：時間軸仍依 chunk 順序（測試：chunk1 非靜音延遲完成、chunk2 靜音立即判定 → chunk1 的 segment offset＝0，chunk2 的 offset＝chunk1 實長）。若現行行為已正確，附測試證明即可。
- [ ] AC-A4 `durationSeconds` 為 nil 時維持既有備援行為（既有測試全過）。

### Part B
- [ ] AC-B1 三條驗證各有通過／不通過的測試；後設回覆以合成拒答句測試；原文本身含「ASR」時不誤判。
- [ ] AC-B2 驗證不通過時該段回傳原文，其餘段落照常使用 LLM 結果（多段測試）。
- [ ] AC-B3 log 只含 reason 代碼與數量（測試 caplog 不含原文字串）。

### Part C
- [ ] AC-C1～C4 四條規則各有正向（觸發）與負向（不誤刪）測試；負向至少包含：
  - 真實的兩次重複「對對」「OK OK」不被壓縮；
  - 含英文術語的中文句（`把 Feature 對到 KR 下面`）不受外文規則影響；
  - 長句中夾 1 個假名字元時，只移除該字元、句子保留；
  - 正常列舉「一、二、三」不被丟棄。
- [ ] AC-C5 呼叫 `clean_segments` 不帶語言參數時，外文規則不套用（向下相容）。

### 負向驗收（不得破壞）
- [ ] AC-N1 既有測試全過且數量不減：基準 pytest 410、swift test 292（以 `4b312f2` 實際執行為準），TSAN 通過。
- [ ] AC-N2 `git diff --stat 4b312f2 HEAD` 零觸碰禁止範圍（`_LLM_PUNCT_PROMPT`、切段門檻、既有 `is_hallucination` 規則、資料檔、scripts 等）。
- [ ] AC-N3 新增 log 不含任何逐字稿或 LLM 輸出文字。

### 必要驗證指令
```bash
/usr/bin/python3 -m pytest tests/unit -q
cd macos/WhisperApp
swift test --scratch-path /tmp/tq-test
swift test --scratch-path /tmp/tq-tsan --sanitize=thread
git diff --stat 4b312f2 HEAD
```

---

## 五、執行規則

### 停止條件（任一發生即停止並 SendMessage 回報）
- 修正 A 需要改 Worker 回傳格式，或發現 `info.duration_seconds` 並非 chunk 實長。
- 修正 A3 的順序問題需要改動 `OrderedChunkSubmissionQueue` 的公開行為，且會影響既有測試的語意。
- Part C 任一規則在負向測試中無法同時滿足「抓到幻聽」與「不誤刪」——回報取捨，不要自行放寬負向條件。
- 需要改禁止範圍、或新增依賴。
- 連續兩次修正仍未通過同一測試。

### 執行方不能做（留給規劃端）
- `git push`、打包、安裝；讀 `.env`、Keychain、使用者的歷史紀錄或錄音。
- 可以在自己的分支 commit。

### 工作位置與分支
- 從 `whisper-swift`（`4b312f2`）開分支 `fix/transcript-quality`，獨立 worktree `1P_Projects/Whisper-wt-transcript-quality`。

### 升級對象
- 產品問題 → 使用者；技術問題 → 規劃端 Claude（SendMessage）。

---

## 六、完成回報格式
1. 分支與三個 commit hash。
2. 修改摘要；A3 疑點的查證結論（原本是否真的會亂序）。
3. AC 逐條 ✅／❌，附 pytest、`swift test`、TSAN 結尾輸出。
4. `git diff --stat 4b312f2 HEAD` 全文。
5. 偏離規格與理由；Part C 各規則的取捨說明。
6. 已驗證／無法驗證（規劃端會用 10/14 會議的實際 segment 離線重放 Part C，並打包後驗證 A、B）。

---

## 品質審核結論
✅ 可直接交付。無阻塞性 `⚠️ 待確認`。
決策記錄：
- A 用 Worker 回傳實長為準：該值來自 WAV frame 數，比 Whisper segment 時間可靠。
- B 用保守的三條驗證、不通過只退回單段：寧可少一段標點，也不讓 LLM 的回話進入逐字稿。
- C 外文規則分「丟棄／移除字元」兩級：遠端亂碼段整段丟，長句裡的單一雜字只移除，避免誤刪真實發言。
