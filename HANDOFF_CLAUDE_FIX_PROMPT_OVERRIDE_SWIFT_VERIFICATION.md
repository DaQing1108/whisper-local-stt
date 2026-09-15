# Verification Report: initial_prompt 合併邏輯修復（whisper-swift 分支移植）

Date: 2026-09-15
Branch: whisper-swift
Base commit: ef21efe
Schema version: 1.1

## Acceptance Criteria Source

沿用 `HANDOFF_CODEX_FIX_PROMPT_OVERRIDE_SWIFT.md`：人工列出（比照 main 分支已驗證過的修法移植，未經 spec-writer）。

## AC 驗收結果

- **AC-1**. whisper_core.py 內以合併邏輯取代覆蓋邏輯
  ✅ 通過 — 新增 `_merge_prompt(domain_prompt, override)`（whisper_core.py:189-209），`run_whisper` 呼叫點（whisper_core.py:539-540）改為 `prompt = _merge_prompt(prompt, kwargs.get("initial_prompt_override", ""))`，取代原本第 538-540 行的直接賦值覆蓋。

- **AC-2**. tests/unit/test_prompts.py 新增 TestMergePrompt，至少 4 個案例，全部通過
  ✅ 通過 — 新增 `TestMergePrompt` class，共 7 個測試案例：
  1. `test_domain_and_override_both_present_merges_both` — 兩者皆有值時合併結果同時包含兩者
  2. `test_override_empty_returns_domain_prompt_unchanged` — override 為空字串時行為不變
  3. `test_override_none_like_falsy_returns_domain_prompt_unchanged` — override 為 None 時行為不變
  4. `test_domain_prompt_empty_returns_override_unchanged` — domain prompt 為空時行為不變
  5. `test_both_empty_returns_empty_string` — 兩者皆空回傳空字串
  6. `test_merged_over_limit_truncates_but_keeps_domain_terms` — 超過長度門檻時驗證截斷且 domain 詞彙保留
  7. `test_merge_respects_configured_max_chars_constant` — 驗證長度上限為具名常數

- **AC-3**. tests/unit/test_prompts.py 既有測試全部維持通過
  ✅ 通過 — 全檔案 25 個測試（18 舊 + 7 新）全部 PASSED，無回歸。

- **AC-4**. tests/unit/test_mixed_mode_prompt_and_llm.py 既有測試全部維持通過 + 新增至少 1 個驗證「override 存在時 domain prompt 仍生效」的案例，通過
  ✅ 通過 — 新增 `test_initial_prompt_override_merges_with_domain_prompt`（於 `TestMixedModePromptEffective` class 內，風格比照既有測試），透過 mock `whisper_core._transcribe_file` 呼叫 `run_whisper(domain="media", extra_terms="", initial_prompt_override="上一段的結尾文字")`，驗證最終 `captured_opts["initial_prompt"]` 同時包含 domain 詞彙（"ASR"/"TVBS"）與 override 文字。全檔案 6 個測試（5 舊 + 1 新）全部 PASSED，無回歸。

- **AC-5**. 合併後的 prompt 長度有明確上限保護，且該上限是具名常數
  ✅ 通過 — `MERGED_PROMPT_MAX_CHARS = 200`（whisper_core.py:189），`_merge_prompt` 內部運算全部引用此常數。

## 驗收指令實際輸出

```
$ python3 -m pytest tests/unit/test_prompts.py tests/unit/test_mixed_mode_prompt_and_llm.py -v
======================== 31 passed, 1 warning in 1.76s =========================
```

（實際執行使用 `/usr/bin/python3`，因專案已知限制：`python3 -m pytest` 經由 RTK hook 攔截 spawn 會失敗且 exit 0 誤導，需直呼系統 python3 繞開。）

## git diff --stat 摘要

```
 tests/unit/test_mixed_mode_prompt_and_llm.py | 24 +++++++++++++
 tests/unit/test_prompts.py                   | 51 +++++++++++++++++++++++++++-
 whisper_core.py                              | 30 ++++++++++++++--
 3 files changed, 101 insertions(+), 4 deletions(-)
```

## Known caveats

- **與 main 分支修復的一致性**：`_merge_prompt()` / `MERGED_PROMPT_MAX_CHARS` 邏輯與 main 分支 commit `74b0dc1` 完全相同（逐字比對邏輯本體），只有呼叫點因這個分支多了 `cancellation`/`event_sink`/`_normalize_language_code()` 而略有上下文差異，修復本身未做任何客製化調整。
- **長度門檻 200 字元**：沿用 main 分支與交接文件建議值，未針對 whisper-swift 分支的實際使用模式（15秒即時模式）額外調整或實測。
- **`_strip_prompt_echo` 交互作用**：與 main 分支相同結論——測試環境未使用真實 Whisper 推論，只驗證字串邏輯層，未觀察到因 prompt 變長而產生誤判 echo 的副作用。若真實使用中發現，依交接文件規則另開任務處理，本次未觸碰 `_strip_prompt_echo` 本身。
- **Swift 端未變動**：僅修改 Python 側 `whisper_core.py` 與測試，`MixedAudioRecordingController`、`WorkerSupervisor` 等 Swift 檔案完全未觸碰，符合交接文件的任務邊界。
- **未執行**：package.sh 打包、Xcode build、Gatekeeper 相關操作、Keychain 存取——皆依交接文件指示，留給後續驗收階段處理。

## 不應該 commit 的內容說明

未動到任何 `.env`、Keychain、簽章憑證。本次 commit 僅包含 `whisper_core.py`、`tests/unit/test_prompts.py`、`tests/unit/test_mixed_mode_prompt_and_llm.py` 三個檔案的改動，以及本驗證報告本身；未納入與本任務無關的既有 dirty 檔案（若有）。
