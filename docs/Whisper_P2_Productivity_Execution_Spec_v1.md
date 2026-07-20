# Whisper SwiftUI P2 Productivity Execution Spec v1

## BLUF

P2 補齊不改變 transcript/summary 核心語意的日常效率功能：saved vocabulary、model readiness、history management、native shortcuts、timer 與可存取 audio level。所有資料寫入必須 atomic；刪除動作需由使用者明確觸發。

## Acceptance criteria

1. Saved vocabulary 可新增、停用、刪除、重啟恢復，active terms 會與 one-shot terms 合併送入所有 transcription paths。
2. History 可搜尋、單筆刪除、clear all，retention 可選且縮減時立即 atomic persist。
3. Native menu commands 提供 import、record toggle、copy result、clear workspace，並顯示 keyboard shortcuts。
4. Model UI 區分 cached/needs download/loading/failed；下載並驗證 inference-child 實際使用的 cache，不得宣稱模型常駐 loaded，且不得與 active transcription 併行。
5. Recording UI 顯示 elapsed timer 與 accessibility-labelled audio level；不要求 legacy waveform 動畫。
6. 完整 Swift/Python/release tests 與 independent review 通過。

## Boundaries

- 不自動刪除 history、audio、model cache 或 vocabulary。
- 不為測試觸發真實 model download、LLM call 或外部發布。
- 不 commit、push、stage 或修改 legacy app。
