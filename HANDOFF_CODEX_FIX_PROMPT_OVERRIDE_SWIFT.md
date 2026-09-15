# Codex Task: 修復 initial_prompt 覆蓋 bug（whisper-swift 分支版）
Date: 2026-09-15
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc
Branch: whisper-swift
Base commit: ef21efe
Schema version: 1.1

## BLUF
`main` 分支（Whisper Classic，已凍結）的同一個 bug 已經修復（commit `74b0dc1`），但使用者實際日常使用的是 `whisper-swift` 分支（SwiftUI + Python Worker，現階段主力開發分支）。這個分支有自己獨立的 `whisper_core.py` 副本，同樣的 bug 存在，需要套用相同的修復。

## 背景（不要重新調查，直接照此修）
- 分段轉錄（15 秒即時模式 / 混音模式）從第 2 段起，`whisper_core.py:538-540`（`run_whisper()` 內）用前段結尾文字直接覆蓋領域詞彙 `initial_prompt`，導致長時間錄音的專有名詞（TVBS、DGX、ASR 等，見 `DOMAIN_TERMS`）辨識率系統性偏低：

```python
domain      = kwargs.get("domain", "general")
extra_terms = kwargs.get("extra_terms", "")
prompt      = build_prompt(domain, extra_terms)
# 分段錄音：用前段結尾覆蓋 initial_prompt 增加連貫性
if kwargs.get("initial_prompt_override"):
    prompt = kwargs["initial_prompt_override"]      # ← 直接覆蓋，領域詞彙整個消失
normalized_language = _normalize_language_code(language)
```

- 這個分支的 `run_whisper()` 比 main 多了 `cancellation`、`event_sink`、`_normalize_language_code()` 等邏輯，但 bug 本身完全一樣，只需要修這一段。
- main 分支已有的修復參考（可直接比照移植，邏輯完全通用）：新增 `_merge_prompt(domain_prompt, override) -> str`，domain prompt 放前面（穩定術語），override 放後面（最近語境），任一為空維持原行為，合併超過 `MERGED_PROMPT_MAX_CHARS`（建議 200，具名常數）時優先保留 domain prompt 全文、截斷 override 尾端。

## 視覺依據
無 UI 改動，純 Python 後端邏輯修正。

## 任務邊界

### 可改動
- `whisper_core.py`：新增 `_merge_prompt()` + `MERGED_PROMPT_MAX_CHARS` 常數，取代第 538-540 行附近的覆蓋邏輯改為 `prompt = _merge_prompt(prompt, kwargs.get("initial_prompt_override", ""))`。
- `tests/unit/test_prompts.py`：這個分支的內容與 main 完全相同（79 行，`TestBuildPrompt` + `TestStripPromptEcho`）。新增 `TestMergePrompt` class，至少覆蓋：
  1. domain prompt 有值 + override 有值 → 合併結果同時包含兩者
  2. domain prompt 有值 + override 為空/None → 結果等於原本的 domain prompt
  3. domain prompt 為空 + override 有值 → 結果等於 override
  4. 合併後總長度超過門檻 → 驗證有截斷，且 domain 詞彙不會被完全截掉
- `tests/unit/test_mixed_mode_prompt_and_llm.py`：這個檔案已有 `TestMixedModePromptEffective` class（AC-C1/C2），驗證 domain prompt 有正確傳入 `initial_prompt`，但**沒有測試 `initial_prompt_override` 存在時的行為**。請在這個 class 裡新增至少 1 個測試案例，風格比照既有測試（呼叫 `run_whisper()`，mock `whisper_core._transcribe_file`，檢查 `captured_opts.get("initial_prompt")`），驗證：當同時傳入 `domain="media"` 與 `initial_prompt_override="上一段的結尾文字"` 時，最終 `initial_prompt` **同時包含** domain 詞彙（例如 "ASR" 或 "TVBS"）**與** override 文字，而不是只剩其中一個。

### 禁止改動
- `routes.py` / worker_entrypoint.py 的 domain 預設值或參數傳遞邏輯 — 不在本次範圍。
- `_strip_prompt_echo()` 邏輯本身 — 不要動，除非你的新測試發現因 prompt 變長而產生的副作用，若發現記錄在 Blockers，不要自行擴大範圍修它。
- `DOMAIN_TERMS` 字典內容 — 不要新增/修改詞彙表，只改「怎麼組合」的邏輯。
- Swift 端程式碼（`MixedAudioRecordingController`、`WorkerSupervisor` 等）— 這次只動 Python 側，不動 Swift。

### 執行方不能做（留給 Claude Code）
- git push（一律留給接手驗收的 Claude Code；這個 worktree 對應 `whisper-swift` 分支，push 目標是 `origin/whisper-swift`）
- 可以 git commit（本機留下完整紀錄）
- 打包（`dist/build_swiftui_app.sh` 或任何 Xcode build）
- Gatekeeper 相關操作（這個分支的 CLAUDE.md 明確指出無法自動化繞過，需要使用者手動在 Finder 雙擊 + 系統設定核准）
- 存取任何 Keychain / 簽章憑證

## 驗收條件（AC）
AC Source: 未經 spec-writer，人工列出（bug fix 範圍夠小，比照 main 分支已驗證過的修法移植）

```
□ AC-1. whisper_core.py 內以合併邏輯取代覆蓋邏輯
□ AC-2. tests/unit/test_prompts.py 新增 TestMergePrompt，至少 4 個案例（如上列），全部通過
□ AC-3. tests/unit/test_prompts.py 既有測試全部維持通過
□ AC-4. tests/unit/test_mixed_mode_prompt_and_llm.py 既有測試全部維持通過 + 新增至少 1 個驗證「override 存在時 domain prompt 仍生效」的案例，通過
□ AC-5. 合併後的 prompt 長度有明確上限保護，且該上限是具名常數
```

## 驗收指令（完成後自己跑，全部綠才算完成）
```bash
cd "/Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc"
python3 -m pytest tests/unit/test_prompts.py tests/unit/test_mixed_mode_prompt_and_llm.py -v
```

## Blockers（執行中卡住時使用）
若執行中發現規格不清楚或需要澄清，不要重新發起一輪交接，直接在本檔案這個區塊 append 具體問題、commit，並告知 PLAN 端。

## 完成後產出
在這個 worktree 根目錄建立 `HANDOFF_CLAUDE_FIX_PROMPT_OVERRIDE_SWIFT_VERIFICATION.md`，內容包含：
1. Acceptance Criteria Source
2. 每條 AC 的驗收結果（✅ / ❌ + 原因）
3. 驗收指令的實際輸出
4. git diff --stat 摘要
5. Known caveats
6. 不應該 commit 的內容說明

### 送達紀錄
2026-09-15 已透過 SendMessage 送達 whisper-4d，等 VERIFICATION.md。
