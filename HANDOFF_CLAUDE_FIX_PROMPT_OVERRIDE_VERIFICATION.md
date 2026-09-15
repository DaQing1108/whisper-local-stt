# Verification Report: initial_prompt 合併邏輯修復

Date: 2026-09-15
Base commit: ff74911
Schema version: 1.1

## Acceptance Criteria Source

沿用 `HANDOFF_CODEX_FIX_PROMPT_OVERRIDE.md`：人工列出（bug fix 範圍夠小，PLAN 端判斷不需要走 spec-writer）。

## AC 驗收結果

- **AC-1**. whisper_core.py 內以合併邏輯取代覆蓋邏輯，domain prompt 與 initial_prompt_override 都不再互相清空對方
  ✅ 通過 — 新增 `_merge_prompt(domain_prompt, override)`（whisper_core.py:172-192），`run_whisper` 呼叫點（whisper_core.py:511-512）改為 `prompt = _merge_prompt(prompt, kwargs.get("initial_prompt_override", ""))`，不再是直接賦值覆蓋。

- **AC-2**. tests/unit/test_prompts.py 新增至少 4 個測試案例，全部通過
  ✅ 通過 — 新增 `TestMergePrompt` class，共 7 個測試案例（超過要求的 4 個）：
  1. `test_domain_and_override_both_present_merges_both` — 兩者皆有值時合併結果同時包含兩者
  2. `test_override_empty_returns_domain_prompt_unchanged` — override 為空字串時行為不變
  3. `test_override_none_like_falsy_returns_domain_prompt_unchanged` — override 為 None 時行為不變
  4. `test_domain_prompt_empty_returns_override_unchanged` — domain prompt 為空時行為不變
  5. `test_both_empty_returns_empty_string` — 兩者皆空回傳空字串
  6. `test_merged_over_limit_truncates_but_keeps_domain_terms` — 超過長度門檻時驗證截斷且 domain 詞彙保留
  7. `test_merge_respects_configured_max_chars_constant` — 驗證長度上限為具名常數

- **AC-3**. 既有 tests/unit/test_prompts.py 全部測試維持通過（不能破壞既有行為）
  ✅ 通過 — 全檔案 25 個測試（18 舊 + 7 新）全部 PASSED，無回歸。

- **AC-4**. 既有 tests/unit/test_transcribe_sync_and_upload.py 全部測試維持通過
  ✅ 通過 — 全檔案 15 個測試全部 PASSED，無回歸。

- **AC-5**. 合併後的 prompt 長度有明確上限保護，且該上限是具名常數，不是裸數字
  ✅ 通過 — `MERGED_PROMPT_MAX_CHARS = 200`（whisper_core.py:172），`_merge_prompt` 內部運算全部引用此常數，未見裸數字寫死於邏輯判斷中。

## 驗收指令實際輸出

```
$ python3 -m pytest tests/unit/test_prompts.py -v
======================== 25 passed, 1 warning in 1.37s =========================

$ python3 -m pytest tests/unit/test_transcribe_sync_and_upload.py -v
======================== 15 passed, 1 warning in 1.00s =========================
```

（實際執行使用 `/usr/bin/python3`，因專案 CLAUDE.md 已知限制：`python3 -m pytest` 經由 RTK hook 攔截 spawn 會失敗且 exit 0 誤導，需直呼系統 python3 繞開。）

## git diff --stat 摘要

```
 tests/unit/test_prompts.py | 51 +++++++++++++++++++++++++++++++++++++++++++++-
 whisper_core.py            | 30 ++++++++++++++++++++++++---
 2 files changed, 77 insertions(+), 4 deletions(-)
```

## Known caveats

- **長度門檻 200 字元**：沿用交接文件建議值，未做額外實測調整。若未來實測發現 Whisper 對更長 prompt 反應更好或更差，此常數可單獨調整而不影響合併邏輯本身。
- **截斷策略**：目前策略是「domain prompt 全文優先保留，截斷 override 尾端」——當 domain prompt 本身就超過 200 字元時（目前 DOMAIN_TERMS 內容都遠短於此），會退化為只保留 domain prompt 前 200 字元、override 完全捨棄；這個邊界情況未特別寫測試，因目前詞彙表內容不會觸發。
- **`_strip_prompt_echo` 交互作用**：未觀察到因 prompt 變長而產生的誤判 echo 問題（測試環境未使用真實 Whisper 推論，只驗證字串邏輯層），若之後真實使用中發現此副作用，需另開任務處理（依交接文件禁止改動範圍規則，未在本次修改 `_strip_prompt_echo` 本身）。

## 不應該 commit 的內容說明

未動到 `.env`、Keychain、或任何本機密鑰相關檔案。`.notion-draft/` 為既有 untracked 目錄，非本次任務產生，未納入 commit。
