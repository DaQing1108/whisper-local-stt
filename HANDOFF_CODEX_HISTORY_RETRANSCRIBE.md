# Codex Task: 歷史會議記錄「重新轉錄」功能
Date: 2026-08-24
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc（whisper-swift 分支）
Base commit: 90e5711 (fix(swift): fix Chinese/CJK IME input in speaker rename sheet)
Schema version: 1.1

## BLUF
歷史會議記錄若在「segments 逐句時間戳記」欄位上線前錄製，`segments` 會 decode 成空陣列，導致「辨識講者」按鈕永遠灰掉、無法點擊。本任務要新增「重新轉錄」功能：對這類記錄（且原始音檔仍存在）重新呼叫 Whisper 轉錄，把新產生的 segments 寫回同一筆歷史記錄，使其之後可以辨識講者。

完整規格與 AC 見同目錄下 [docs/Whisper_History_Retranscribe_Spec_v1.md](docs/Whisper_History_Retranscribe_Spec_v1.md)——**這份 HANDOFF 是執行摘要，規格文件是唯一真相來源，兩者有出入以規格文件為準**。

## 任務邊界

### 可改動
- `macos/WhisperApp/Sources/WhisperApp/WorkerSupervisor.swift`
  — `transcribe(audioURL:modelName:language:domain:extraTerms:)`（約 line 343-350）補上 `guard !diarizationOperationInProgress else { throw ... }`。
- `macos/WhisperApp/Sources/WhisperApp/ContentView.swift`
  — 新增 `@State` 追蹤重新轉錄目標 entry id（例如 `retranscribeTargetEntryID: UUID?`），比照既有 `mixedAudioHistoryEntryID`/`liveHistoryEntryID`。
- `macos/WhisperApp/Sources/WhisperApp/ContentView+Results.swift`
  — 新增 `retranscribe(_ entry:)` 觸發函式（用 entry 當時的 model/language/domain/extraTerms）
  — 完成路由邏輯新增第三個分支：`retranscribeTargetEntryID` 命中時呼叫 `history.updateResult(id:text:segments:durationSeconds:audioURL: nil)`，**不呼叫 `restore(entry)`**
  — 目標 entry 若是目前開啟且 `isDraftDirty == true`，觸發前先走既有 `PendingDiarizationOverwrite` 同款 confirmation dialog
- `macos/WhisperApp/Sources/WhisperApp/ContentView+History.swift`
  — 歷史列表 row 按鈕列（`Button("刪除", ...)` 附近）新增「重新轉錄」按鈕
  — 顯示條件：`entry.segments.isEmpty && FileManager.default.fileExists(atPath: entry.audioPath)`
  — 停用條件：`worker.activeRequestID != nil || worker.diarizationOperationInProgress || worker.modelOperationInProgress`
- 對應測試：`WorkerSupervisorTests.swift`、`TranscriptionHistoryStoreTests.swift`，以及任何為新路由邏輯新增的測試

### 禁止改動
- `TranscriptionHistoryEntry` 的 struct/CodingKeys — 不新增/改欄位
- `MeetingSummaryController.swift`、`MeetingSummaryStore.swift` — 摘要不同步是刻意的非本次目標
- Obsidian/Notion 整合程式碼 — 不新增自動同步呼叫
- `MixedAudioRecordingController.swift` 及其測試 — 另一批未收尾 WIP，目前有 13 個既有測試失敗，與本任務無關，不得觸碰也不依賴其修改
- `history.json` migration/回填工具 — 本次只做單筆、使用者主動觸發
- `package.sh` / `scripts/build_swiftui_app.sh` / 簽名憑證

### 執行方不能做（留給 Claude Code）
- git push（一律留給接手驗收的 Claude Code，作為獨立驗證後才讓改動進入共用狀態的把關點）
- 可以 git commit（本機留下完整紀錄＋完成報告），但不要 git push
- package.sh / 打包 / 簽名
- 存取 ~/Library/Application Support/WhisperSTT/.env
- 任何需要本機 Keychain 的操作
- 真機 Gatekeeper 核准與真機驗證（`./scripts/build_swiftui_app.sh` 之後的手動測試）

## 驗收條件（AC）
AC Source: Locked（來自 /spec-writer，見 docs/Whisper_History_Retranscribe_Spec_v1.md 第四節）

□ AC-1. 對 `segments == []` 且 `audioPath` 檔案存在的記錄，顯示「重新轉錄」按鈕；`segments` 非空的記錄不顯示
□ AC-2. `audioPath` 檔案不存在時（即使 segments 為空），不顯示「重新轉錄」按鈕
□ AC-3. 重新轉錄使用 entry 當時儲存的 model/language/domain/extraTerms，不是使用者目前 UI 設定
□ AC-4. 完成後透過 `updateResult(id:)` 更新同一筆記錄（`entries.count` 不變，該筆 `segments` 從 `[]` 變非空）
□ AC-5. 完成後 `obsidianNotePath`/`notionChildPageID` 與轉錄前完全相同
□ AC-6. 完成時若 `currentEntryID` 不等於目標 entry id，不強制呼叫 `restore(entry)` 切換畫面
□ AC-7. 目標 entry 若目前開啟且 `isDraftDirty == true`，觸發前跳出確認對話框，選「取消」則不送出轉錄請求
□ AC-8. `worker.activeRequestID != nil` 或 `diarizationOperationInProgress` 或 `modelOperationInProgress` 為 true 時，按鈕停用
□ AC-9. `WorkerSupervisor.transcribe()` 在 `diarizationOperationInProgress == true` 時呼叫會 throw，不送出 worker command
□ AC-10. 目標 entry 在完成前被使用者刪除，`updateResult` no-op（回傳 nil），不 crash，不會把該筆重新加回 `history.entries`

負向驗收條件（不得破壞，同樣需驗證）：
□ 既有即時/混音錄音完成路由（`liveHistoryEntryID`/`mixedAudioHistoryEntryID`）行為與既有測試不受影響
□ SpeakerRename（含剛修好的 CJK IME 輸入）不受影響
□ MeetingSummary 流程不受影響
□ `MixedAudioRecordingControllerTests`/`LiveRecordingControllerTests` 既有失敗數（13 個）不增加

## 驗收指令（完成後自己跑，全部綠才算完成）
```bash
cd macos/WhisperApp
swift test --filter WorkerSupervisorTests
swift test --filter TranscriptionHistoryStoreTests
swift test 2>&1 | tail -30   # 確認整體失敗數維持在既有的 13 個（Mixed/LiveRecordingControllerTests），未新增
swift build
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
在專案根目錄建立 `HANDOFF_CLAUDE_HISTORY_RETRANSCRIBE_VERIFICATION.md`，內容包含：
1. Acceptance Criteria Source：Locked
2. 每條 AC（AC-1 ~ AC-10 + 4 條負向驗收條件）的驗收結果（✅ / ❌ + 原因）
3. 驗收指令的實際輸出（貼上完整 test result，特別是 `swift test` 全量結果的失敗數對比）
4. git diff --stat 摘要
5. Known caveats（若有，例如 ContentView+Results.swift 完成路由邏輯新增第三分支後的可讀性狀況）
6. 不應該 commit 的內容說明（例如 .env 檔、.build/ 產物）
