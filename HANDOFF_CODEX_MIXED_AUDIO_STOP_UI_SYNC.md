# Codex Task: 混音錄音停止後畫面沒同步最終結果

Date: 2026-09-05
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc
Base commit: e28b0cb (chore(whisper): remove transcript-overwrite-guard handoff docs after ship)
Branch (你自己開): handoff/2026-09-05-mixed-audio-stop-ui-sync
Schema version: 1.1
執行者類型: 另一個 Claude Code 帳號（有 git，可 git commit，**不要 git push**）

## BLUF

混音模式按「停止」時，程式會直接寫一次 `history.updateResult(...)` 把累積逐字稿存進 history，但**完全繞過畫面更新**（沒呼叫 `restore()`）。使用者實測一場近 3 小時的會議，停止後畫面沒顯示任何結果，得自己去 History 才找得到（資料本身完整、沒遺失）。本任務：停止時把畫面同步成最終寫入的內容，並在最後一段音訊還在轉錄時顯示提示。

## 背景（根因，程式碼位置）

- `ContentView+CaptureActions.swift` 的 `stopMixedAudioRecording()`：
  ```swift
  if let id = mixedAudioHistoryEntryID,
     let sessionURL = mixedAudioRecording.sessionFinalizedURL {
      _ = try history.updateResult(
          id: id, text: mixedAudioRecording.transcriptText,
          segments: mixedAudioRecording.transcriptSegments,
          durationSeconds: mixedAudioRecording.transcriptDurationSeconds,
          audioURL: sessionURL
      )
  }
  ```
  只丟棄回傳值（`_ =`），沒有呼叫 `restore()`，`transcriptDraft`/`currentEntryID` 停在錄音中最後一次 chunk 更新的舊狀態。
- 對照組：錄音進行中每個 chunk 完成時走的 `showLatestWorkerResultIfNeeded()` 裡的 `acceptCompletedChunk` 分支，每次都會 `restore(entry)`，畫面正常會跟著更新——只有「按下停止」這次額外寫入漏了這一步。
- 停止當下最後一段（tail chunk）的轉錄是非同步送給 worker，這次直接寫入時通常還沒包含它；等它真正轉完，理論上會走回 `acceptCompletedChunk` → `restore()` 補上，但整個過程沒有任何「還在收尾」的視覺提示，使用者容易誤以為已經結束卻沒有輸出。
- `MixedAudioRecordingController` 已有現成的 `var isDraining: Bool { fullSession == nil && (submissionQueue.activeURL != nil || !submissionQueue.pendingURLs.isEmpty) }`（`fullSession == nil` 代表音訊面已停止，`submissionQueue` 還有東西代表仍在轉錄）——直接讀用，不用新增邏輯。

## 任務邊界

### 可改動

1. **`Sources/WhisperApp/AudioInputMode.swift`（`enum CaptureUIRules` 內，跟現有 `shouldLockMode`/`liveIsStoppable`/`stopIsEnabled` 同一個 enum）** — 新增：
   ```swift
   /// Whether a just-finalized mixed-audio result should be reflected in the
   /// visible workspace. Mirrors the existing "don't clobber an in-progress
   /// manual edit" guard used elsewhere (diarization apply, retranscribe apply).
   static func shouldSyncFinalizedMixedAudioResult(isDraftDirty: Bool) -> Bool {
       !isDraftDirty
   }
   ```

2. **`Sources/WhisperApp/ContentView+CaptureActions.swift` — `stopMixedAudioRecording()`**：
   把
   ```swift
   if let id = mixedAudioHistoryEntryID,
      let sessionURL = mixedAudioRecording.sessionFinalizedURL {
       _ = try history.updateResult(
           id: id, text: mixedAudioRecording.transcriptText,
           segments: mixedAudioRecording.transcriptSegments,
           durationSeconds: mixedAudioRecording.transcriptDurationSeconds,
           audioURL: sessionURL
       )
   }
   ```
   改成（捕捉回傳值，成功且 `!isDraftDirty` 時同步畫面）：
   ```swift
   if let id = mixedAudioHistoryEntryID,
      let sessionURL = mixedAudioRecording.sessionFinalizedURL,
      let updated = try history.updateResult(
          id: id, text: mixedAudioRecording.transcriptText,
          segments: mixedAudioRecording.transcriptSegments,
          durationSeconds: mixedAudioRecording.transcriptDurationSeconds,
          audioURL: sessionURL
      ) {
       if CaptureUIRules.shouldSyncFinalizedMixedAudioResult(isDraftDirty: isDraftDirty) {
           restore(updated)
       }
   }
   ```
   **重要**：history 寫入（`updateResult` 呼叫本身）**必須無條件執行**，不受 `isDraftDirty` 影響——`isDraftDirty` 只控制「要不要動畫面」，不控制「要不要存檔」。這是跟現有 diarization/retranscribe 攔截邏輯一致的資料安全慣例，不要合併成單一 guard 把兩者都擋掉。
   `restore(_:)` 是既有函式（在 `ContentView+Results.swift`），會設定 `currentEntryID`/`transcriptDraft`/`isDraftDirty = false` 並清掉 playback 狀態——直接重用它，不要自己手動複製那幾個欄位。

3. **`Sources/WhisperApp/ContentView+Results.swift` — `transcriptContent`**：
   在現有狀態列（`HStack { Text(worker.jobStatus)... }`，大約在 `transcriptContent` 開頭附近）下方、`ProgressView(value: worker.progress)` 之前或之後（你判斷哪個位置視覺上更合理）加一行條件式狀態文字：
   ```swift
   if mixedAudioRecording.isDraining {
       Text("⏳ 混音錄音已停止，最後片段仍在轉錄中…")
           .font(.caption).foregroundStyle(.orange)
   }
   ```
   條件必須直接讀 `mixedAudioRecording.isDraining`，**不要**在 View 裡另外重寫一份判斷邏輯（例如自己比對 `submissionQueue` 狀態）。

4. **`Tests/WhisperAppTests/CaptureUIRulesTests.swift`** — 加 AC-1 的兩個測試案例，跟檔案裡既有的其他 `CaptureUIRules` 測試同樣風格。

### 禁止改動

- **`Sources/WhisperApp/MixedAudioRecordingController.swift` 與 `Tests/WhisperAppTests/MixedAudioRecordingControllerTests.swift`** — 工作區目前有一份未提交的 SPIKE（`WHISPER_DEBUG_SEPARATE_TRACKS`）掛在這兩個檔案上，**完全不要碰**（不用改、不用讀來改邏輯——`isDraining` 已經存在且穩定，直接在別的檔案裡讀用即可）。commit 時用明確的 `git add <你改的檔案>`，不要 `git add -A` / `git add .`。
- `TranscriptionHistoryStore.swift`、`TranscriptOverwriteGuard.swift` 及其測試（上一個任務剛完成的東西）— 不動。
- `showLatestWorkerResultIfNeeded()` 裡錄音進行中的正常路徑（`acceptCompletedChunk` 分支）— 本來就正確，不要改。
- `MixedAudioRecordingController.isDraining` 的定義本身 — 不要改它的邏輯，只讀用。

### 執行方不能做（留給 Claude Code）

- `git push`（一律留給接手驗收的 Claude Code）
- 可以 `git commit`（本機留完整紀錄 + 完成報告），但**不要 push**
- build .app / `package.sh` / 簽名 / 安裝到 `~/Applications`
- 真機 App UI 走查（收尾提示長怎樣、按停止後畫面實際同步的體驗——這兩個是 SwiftUI View 行為，單元測試測不到，本來就要留給真機驗證）
- 存取 `~/Library/Application Support/WhisperSTT/.env`、Keychain
- 寫入 Notion / README checkpoint

## 驗收條件（AC）

AC Source: 未經 spec-writer，人工列出（使用者 2026-09-05 於對話中 approve）

- [ ] **AC-1** `CaptureUIRules.shouldSyncFinalizedMixedAudioResult(isDraftDirty: false) == true`；`(isDraftDirty: true) == false`。單元測試涵蓋兩個 case。
- [ ] **AC-2** `stopMixedAudioRecording()`：`history.updateResult(...)` 這次呼叫**無條件執行**（不受 `isDraftDirty` 影響）；只有 `restore(updated)` 這一步受 `CaptureUIRules.shouldSyncFinalizedMixedAudioResult` guard。程式碼審查確認邏輯正確（SwiftUI View 內的呼叫無法直接單元測試，這點在 VERIFICATION.md 中說明，留給真機走查）。
- [ ] **AC-3** `transcriptContent` 新增的收尾提示文字，其顯示條件是 `mixedAudioRecording.isDraining`，未新寫重複判斷邏輯。程式碼審查確認；真機外觀留給真機走查。
- [ ] **AC-4** `git diff --stat e28b0cb -- macos/WhisperApp` 只列：`AudioInputMode.swift`、`ContentView+CaptureActions.swift`、`ContentView+Results.swift`、`CaptureUIRulesTests.swift`。未觸碰 `MixedAudioRecordingController.swift`/其 Tests/`TranscriptionHistoryStore.swift`/`TranscriptOverwriteGuard.swift`。
- [ ] **AC-5** `cd macos/WhisperApp && swift test` 全綠（baseline 允許：SPIKE 測試需 `WHISPER_DEBUG_SEPARATE_TRACKS=1`、`LiveRecordingControllerTests` device-recovery 在完整套件並行負載下的 flake——這兩類非本次引入，若出現請在 VERIFICATION.md 註明並附證據（例如單獨 `--filter` 全過）。
- [ ] **AC-6** `swift build` 乾淨、無新增 warning。

## 驗收指令（完成後自己跑，全部綠才算完成）

```bash
cd /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc/macos/WhisperApp
swift test 2>&1 | tail -40
swift build 2>&1 | grep -Ei "warning:|error:"
cd /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc
git diff --stat e28b0cb -- macos/WhisperApp | cat
```

如果切分支或改動過程中發現 worktree 裡冒出未被追蹤的 `* 2.swift` / `Contents 2` 之類檔案（iCloud 同步在這個 worktree 的已知問題），先 `find . -name "* 2.*" -not -path "*/.build/*"` 確認它們不含你的改動內容後刪除，在 VERIFICATION.md 註明你踩到了、怎麼處理的。

## Blockers（執行中卡住時使用，不要重新發起一輪交接）

在本檔案這個區塊 append：
```
### [日期] Blocker
Q: [具體問題]
影響：[卡住的是哪個 AC 或哪個改動]
```

## 完成後產出

在專案根目錄建立 `HANDOFF_CLAUDE_MIXED_AUDIO_STOP_UI_SYNC_VERIFICATION.md`，內容包含：
1. Acceptance Criteria Source（未經 spec-writer，人工列出）
2. 每條 AC 的驗收結果（✅ / ❌ + 原因）
3. `swift test` 實際輸出（貼 tail）
4. `git diff --stat e28b0cb -- macos/WhisperApp` 摘要
5. Known caveats（含 AC-2/AC-3 需要真機走查這件事，明確列出要走查的具體步驟）
6. 確認：未 push；未碰 `MixedAudioRecordingController*`；未碰 `.env`
7. commit hash 清單
