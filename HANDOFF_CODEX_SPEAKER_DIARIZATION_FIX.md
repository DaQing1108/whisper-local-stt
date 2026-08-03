# Codex Task: 修復講者辨識過度分裂 + 新增講者重新命名功能
Date: 2026-08-03
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc (branch: whisper-swift)
Base commit: b7271deb5ee26b023d69eb8f9b0b3d4aa1da31a4
Schema version: 1.1

## BLUF
講者辨識（diarization）目前用 sherpa-onnx `FastClusteringConfig()` 預設值（`num_clusters=-1` 自動偵測、`threshold=0.5`），真實會議只有 4~6 位講者卻被切成 `Speaker 31`/`33`/`39`/`46`/`55` 等幾十個假講者。且逐字稿完全沒有「把 Speaker 編號改成真實姓名」的功能。本任務：(1) 讓 clustering 的 `num_speakers`／`threshold` 可從呼叫端傳入（不猜測、不改預設值，只加介面），(2) 在 UI 加一個「重新命名講者」功能，把逐字稿裡的 `[Speaker X]` 標籤取代成使用者輸入的真實姓名。

## 任務邊界

### 可改動
- `diarization_service.py`
  - `_build_pipeline` 新增參數 `threshold: float = 0.5`（**不改預設值**，只加介面），套用到 `sherpa_onnx.FastClusteringConfig(num_clusters=..., threshold=threshold)`
  - `diarize()` 新增參數 `num_speakers: int | None = None`，透傳給 `_build_pipeline` 對應到 `FastClusteringConfig(num_clusters=num_speakers or -1, ...)`
  - 若 `diarize()` 也想接受 `threshold` 參數請一併加（預設 `0.5`，維持現況相容）
- `tests/unit/test_diarization_service.py`：新增測試（見下方 AC-1~3）
- `worker_entrypoint.py`
  - `_diarize()`：從 `payload` 用 `payload.get("num_speakers")` 讀取（可能不存在/None），透傳給 `diarize(...)`
- `tests/unit/test_worker_entrypoint.py`：新增測試（見 AC-4），可參考既有 `test_worker_diarize_merges_speakers_when_cached` 的 pattern（monkeypatch `diarization_service.diarize`）
- `macos/WhisperApp/Sources/WhisperApp/WorkerSupervisor.swift`
  - `func diarize(audioPath: String, segments: [TranscriptionSegment]) throws -> String`（第 309 行附近）新增可選參數 `numSpeakers: Int? = nil`，塞進 command payload（參考同一函式現有 payload 組裝方式）
- 新檔案 `macos/WhisperApp/Sources/WhisperApp/SpeakerRename.swift`：兩個**純函式**（不依賴 SwiftUI/Observation，方便單元測試）：
  ```swift
  enum SpeakerRename {
      /// 掃描逐字稿，抓出所有 "[Speaker X] ..." 開頭的行，回傳去重後的唯一標籤（依首次出現順序）
      static func extractSpeakerLabels(from text: String) -> [String]

      /// 把 renames 裡每個 "舊標籤" -> "新名字" 的對應，全域取代逐字稿裡對應的 "[舊標籤] " 前綴
      static func applySpeakerRenames(_ renames: [String: String], in text: String) -> String
  }
  ```
  - 標籤格式規則：每行若以 `[` 開頭，抓到第一個 `]` 之前的內容視為標籤候選；只收集看起來像 `renderSpeakerLabeled` 產生的格式（即整個 `[...]` 後面緊跟一個空白再接文字）。不需要判斷內容是否以 "Speaker" 開頭——因為 `renderSpeakerLabeled`（`ContentView+Results.swift:172`）產生的 `transcriptDraft` 只會有講者標籤這一種中括號格式，沒有時間戳記混在裡面。
  - 取代時務必是「整行前綴」取代（`[舊標籤] ` → `[新名字] `），不要用容易誤傷內文的寬鬆字串取代。
  - 新名字若包含 `[` 或 `]`，直接移除這兩個字元後再套用（避免破壞後續 parsing），不需要跳出錯誤。
- `macos/WhisperApp/Sources/WhisperApp/ContentView+Results.swift`
  - 「辨識講者」按鈕（第 107 行附近）旁加一個可選的「已知講者人數」數字輸入欄位（例如 `TextField` + 綁定一個 `@State private var knownSpeakerCount: String = ""`），呼叫 `triggerDiarization` 時把它轉成 `Int?` 傳給 `worker.diarize(audioPath:segments:numSpeakers:)`
  - 新增「重新命名講者」按鈕：僅在 `SpeakerRename.extractSpeakerLabels(from: transcriptDraft)` 非空時顯示。點擊後開啟一個 sheet：對每個抓到的標籤顯示一個文字輸入框（預填原標籤），使用者輸入姓名後按確認 → 呼叫 `SpeakerRename.applySpeakerRenames(...)` 更新 `transcriptDraft`，並設 `isDraftDirty = true`（沿用現有「儲存修改」按鈕 → `saveDraft()` → `history.updateText(...)` 的既有持久化路徑，**不要**新增資料模型欄位或修改 `TranscriptionHistoryEntry`/`TranscriptionSegment`）
- 新檔案 `macos/WhisperApp/Tests/WhisperAppTests/SpeakerRenameTests.swift`

### 禁止改動
- `TranscriptionHistoryEntry` / `TranscriptionSegment`（`TranscriptionHistoryStore.swift`）：不新增欄位、不做任何 JSON schema migration。重新命名功能只作用在 `transcriptDraft` 文字層，靠既有 `updateText` 存回去即可，範圍已經足夠。
- `FastClusteringConfig` 的預設 `threshold=0.5` 數值本身：只加「可傳參數」的介面，不要自己決定改成什麼數字——沒有真實錄音驗證，改預設值等於未經驗證的猜測，違反本專案 CLAUDE.md 的 Spike 原則。
- `package.sh`、簽名、打包流程：不動。
- 不要修改任何既有測試的既有斷言（`test_diarize_runs_pipeline_and_merges_when_cached` 等 5 個既有測試必須維持全綠、斷言不變）。

### 執行方不能做（留給 Claude Code）
- git push（一律留給接手驗收的 Claude Code，作為獨立驗證後才讓改動進入共用狀態的把關點）
- 可以 git commit（本機留下完整紀錄＋完成報告），但不要 git push
- package.sh / 打包 / 簽名 / bundle smoke test
- 存取 ~/Library/Application Support/WhisperSTT/.env
- 任何需要本機 Keychain 的操作

## 驗收條件（AC）
AC Source: 未經 spec-writer，人工列出

```
□ AC-1. diarization_service.diarize() 新增 num_speakers（與 threshold，若加了的話）參數，預設值不傳時行為與現在完全一致；既有 5 個測試（test_diarize_raises_model_not_ready_when_uncached / test_speaker_label_wraps_past_alphabet / test_merge_speakers_assigns_max_overlap_speaker / test_merge_speakers_leaves_speaker_none_when_no_overlap / test_diarize_runs_pipeline_and_merges_when_cached）斷言不變、全綠
□ AC-2. 新增測試：diarize(..., num_speakers=2) 時，_build_pipeline 收到的 FastClusteringConfig 帶 num_clusters=2（可 patch `sherpa_onnx.FastClusteringConfig` 或直接檢查傳入 _build_pipeline 的參數，依你實作方式選擇好驗證的切入點）
□ AC-3. 新增測試：threshold 參數若加了，diarize(..., threshold=0.75) 時對應 FastClusteringConfig 收到 threshold=0.75
□ AC-4. worker_entrypoint._diarize 從 payload 讀取可選 num_speakers（key 不存在時等同 None，不報錯）並透傳給 diarize()，新增至少一則測試涵蓋（可仿照 test_worker_entrypoint.py:181 的 test_worker_diarize_merges_speakers_when_cached pattern）
□ AC-5. SpeakerRenameTests.swift：extractSpeakerLabels(from: "[Speaker A] hi\n[Speaker B] yo\n[Speaker A] again") == ["Speaker A", "Speaker B"]（去重、依首次出現順序）
□ AC-6. SpeakerRenameTests.swift：applySpeakerRenames(["Speaker A": "Alex"], in: "[Speaker A] hi") == "[Alex] hi"，且未提及的其他標籤（若有）維持原樣
□ AC-7. SpeakerRenameTests.swift：對不含 "[...] " 講者標籤格式的一般文字呼叫 extractSpeakerLabels 回傳 []；applySpeakerRenames 對空 renames dict 或無匹配標籤時原樣返回輸入文字
□ AC-8. SpeakerRenameTests.swift：新名字包含 "[" 或 "]" 時（例如輸入 "Al[ex]"），套用後結果不包含裸露的中括號字元，且不 crash
□ AC-9. `swift build` 成功（ContentView+Results.swift 新增的 UI 程式碼可編譯，含 WorkerSupervisor.diarize 新參數呼叫點）
□ AC-10.「重新命名講者」按鈕的顯示條件（transcriptDraft 含至少一個講者標籤時才出現）：若能用既有測試 pattern 簡單驗證就寫測試；若受限於 SwiftUI View 難以單元測試，改為在 VERIFICATION.md 裡貼出這段條件判斷的程式碼 diff 並註明「以人工檢視程式碼邏輯確認，未寫自動化測試」，不要為了硬測而引入額外測試框架或大改架構
```

## 驗收指令（完成後自己跑，全部綠才算完成）
```bash
cd /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc
python3 -m pytest tests/unit/test_diarization_service.py tests/unit/test_worker_entrypoint.py -v
cd macos/WhisperApp
swift build
swift test --filter SpeakerRenameTests
swift test 2>&1 | tail -30
```

## Blockers（執行中卡住時使用）
若執行中發現規格不清楚或需要澄清，**不要重新發起一輪交接**，直接在本檔案這個區塊 append 具體問題、commit，並告知 PLAN 端：

```
### [日期] Blocker
Q: [具體問題]
影響：[卡住的是哪個 AC 或哪個改動]
```

PLAN 端下次上線只需讀這個區塊回覆，不必重新對齊整份規格。

## 完成後產出
在專案根目錄（本 worktree 根目錄）建立 `HANDOFF_CLAUDE_SPEAKER_DIARIZATION_FIX_VERIFICATION.md`，內容包含：
1. Acceptance Criteria Source：未經 spec-writer，人工列出
2. 每條 AC（AC-1 ~ AC-10）的驗收結果（✅ / ❌ + 原因）
3. 驗收指令的實際輸出（貼上 pytest / swift test 結果）
4. `git diff --stat` 摘要
5. Known caveats（若有，例如 AC-10 用人工檢視取代自動測試的說明）
6. 不應該 commit 的內容說明（例如若有暫存的 .env 或個人測試音檔，需列出並確認未加入 git）
