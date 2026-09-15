# Codex Task: 修復 initial_prompt 覆蓋 bug（分段轉錄領域詞彙遺失）
Date: 2026-09-15
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper
Base commit: ff74911
Schema version: 1.1

## BLUF
分段轉錄（15 秒即時模式 / 混音模式）從第 2 段起，`whisper_core.py` 用前段結尾文字覆蓋掉領域詞彙 `initial_prompt`（TVBS、DGX、ASR 等專有名詞提示），導致長時間錄音的專有名詞辨識率系統性偏低。要把「覆蓋」改成「合併」，同時保留領域詞彙提示與前段語境連貫性。

## 根因說明（背景，不要重新調查，直接照此修）
- `whisper_core.py:152-158` 的 `DOMAIN_TERMS` 字典存了各領域的專有名詞（media domain 含 TVBS、ASR、DGX 等）。
- `build_prompt(domain, extra_terms)`（`whisper_core.py:161-169`）把這些詞組成 Whisper 的 `initial_prompt`。
- `routes.py:428-433` 的 `_chunk_prev_context()` 會取「前一段轉錄結果的結尾 100 字」，當作下一段的 `initial_prompt_override`，目的是讓分段轉錄的語意銜接更連貫。
- 問題出在 `whisper_core.py:486-498`：

```python
domain      = kwargs.get("domain", "general")
extra_terms = kwargs.get("extra_terms", "")
prompt      = build_prompt(domain, extra_terms)
# 分段錄音：用前段結尾覆蓋 initial_prompt 增加連貫性
if kwargs.get("initial_prompt_override"):
    prompt = kwargs["initial_prompt_override"]      # ← 直接覆蓋，領域詞彙整個消失
print(f"[Whisper] prompt={repr(prompt[:60])}, lang={language}", flush=True)
```

第一段（chunk 0）沒有 `initial_prompt_override`，所以領域詞彙有效；從第二段開始，`override` 完全取代 `prompt`，領域詞彙提示消失，只剩前段文字。這解釋了為何長會議錄音中後段的專有名詞辨識率明顯變差。

## 視覺依據
無 UI 改動，純後端邏輯修正，不需要 mockup。

## 任務邊界

### 可改動
- `whisper_core.py`：把第 486-498 行附近的覆蓋邏輯改成合併邏輯。建議寫成獨立函式（例如 `_merge_prompt(domain_prompt: str, override: str) -> str`），方便單獨測試，再從 `_transcribe_file`（或對應的呼叫點）呼叫。
  - 合併規則：兩者都有值時，用 `。` 或 `、` 串接（domain 詞彙在前，override 語境在後，因為 override 是最近的語境，離要轉錄的音訊時間點更近，放後面對 Whisper 的 next-token 預測更有效）。
  - 任一為空時，維持現有行為（回歸不能破壞）：只有 domain prompt → 用 domain prompt；只有 override → 用 override；兩者皆空 → 空字串。
  - **長度保護**：Whisper `initial_prompt` 實務上建議控制在數百字元內（過長會被截斷或影響效果，且合併後更容易被 `_strip_prompt_echo` 誤判為 prompt echo）。合併後若總長度超過門檻（建議 200 字元，可依實測調整，寫成具名常數而非魔法數字），優先保留 domain 詞彙 + override 尾端內容，中間可截斷。不要無限增長。
- `tests/unit/test_prompts.py`：新增 `TestMergePrompt` class（或等效測試），至少覆蓋：
  1. domain prompt 有值 + override 有值 → 合併結果同時包含兩者的內容
  2. domain prompt 有值 + override 為空/None → 結果等於原本的 domain prompt（不變行為）
  3. domain prompt 為空 + override 有值 → 結果等於 override（不變行為）
  4. 合併後總長度超過門檻 → 驗證有截斷，且 domain 詞彙不會被完全截掉（至少保留一部分領域詞彙）
  5.（建議）domain prompt 為空 + override 為空 → 結果為空字串

### 禁止改動
- `routes.py` 的 `domain = request.form.get("domain", "general")` 預設值 — 屬於另一個獨立議題（前端 UI 是否暴露領域選擇），不在本次範圍。
- Whisper 模型呼叫參數（`condition_on_previous_text` 等）— 維持現狀。
- `DOMAIN_TERMS` 字典內容 — 不要新增/修改詞彙表內容，只改「怎麼組合」的邏輯。
- 不要動 `_strip_prompt_echo()` 的邏輯本身（除非你的合併邏輯測試發現它因為 prompt 變長而誤判——若發現這個副作用，在 Blockers 區塊記錄，不要自行擴大範圍去改它）。

### 執行方不能做（留給 Claude Code）
- git push（一律留給接手驗收的 Claude Code）
- 可以 git commit（本機留下完整紀錄＋完成報告）
- package.sh / 打包 / 簽名
- 存取 `~/Library/Application Support/WhisperSTT/.env`
- 任何需要本機 Keychain 的操作
- 不要跑打包後的 bundle smoke test（那是 Claude Code 驗收階段的事）

## 驗收條件（AC）
AC Source: 未經 spec-writer，人工列出（bug fix 範圍夠小，PLAN 端判斷不需要走 spec-writer）

```
□ AC-1. whisper_core.py 內以合併邏輯取代覆蓋邏輯，domain prompt 與 initial_prompt_override 都不再互相清空對方
□ AC-2. tests/unit/test_prompts.py 新增至少 4 個測試案例（如上列 1-4），全部通過
□ AC-3. 既有 tests/unit/test_prompts.py 全部測試維持通過（不能破壞既有行為）
□ AC-4. 既有 tests/unit/test_transcribe_sync_and_upload.py 全部測試維持通過（涉及 transcribe_audio 呼叫路徑）
□ AC-5. 合併後的 prompt 長度有明確上限保護（不可能無限增長導致 Whisper API 報錯或效能劣化），且該上限是具名常數，不是裸數字
```

## 驗收指令（完成後自己跑，全部綠才算完成）
```bash
cd "/Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper"
python3 -m pytest tests/unit/test_prompts.py -v
python3 -m pytest tests/unit/test_transcribe_sync_and_upload.py -v
```

## Blockers（執行中卡住時使用）
若執行中發現規格不清楚或需要澄清，**不要重新發起一輪交接**，直接在本檔案這個區塊 append 具體問題、commit，並告知 PLAN 端：

```
### [日期] Blocker
Q: [具體問題]
影響：[卡住的是哪個 AC 或哪個改動]
```

## 完成後產出
在專案根目錄建立 `HANDOFF_CLAUDE_FIX_PROMPT_OVERRIDE_VERIFICATION.md`，內容包含：
1. Acceptance Criteria Source（沿用本文件：人工列出）
2. 每條 AC 的驗收結果（✅ / ❌ + 原因）
3. 驗收指令的實際輸出（貼上 test result）
4. git diff --stat 摘要
5. Known caveats（若有，例如長度門檻是怎麼決定的、有沒有實測過極端案例）
6. 不應該 commit 的內容說明（例如 .env 檔，若有動到的話）

### 送達紀錄
2026-09-15 已透過 SendMessage 送達 whisper-4d，等 VERIFICATION.md。
