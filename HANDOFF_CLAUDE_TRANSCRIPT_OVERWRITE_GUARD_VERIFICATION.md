# Verification: 逐字稿破壞性覆寫 — 攔截 + 備份

Date: 2026-09-04
Executor: DEV Claude Code (handoff branch `handoff/2026-09-04-transcript-overwrite-guard`, base `b3659ec`)
Source handoff: `HANDOFF_CODEX_TRANSCRIPT_OVERWRITE_GUARD.md`

## 1. Acceptance Criteria Source

未經 spec-writer，人工列出（使用者 2026-09-04 於對話中 approve）。逐字複製自 handoff 文件
「驗收條件（AC）」節，AC-1 ~ AC-8。

## 2. Per-AC result

| AC | Result | Notes |
|----|--------|-------|
| **AC-1** `TranscriptOverwriteGuard.isDestructiveShrink` 六個 case | ✅ | `TranscriptOverwriteGuardTests.swift`，6 tests 全綠。273→89 = true；5000→4800 = false；120→5 = false；1000→500 = false（嚴格小於）；1000→499 = true；""→"" = false 不 crash。實作：`existingText.count >= 200 && incomingText.count < Int(Double(existingText.count) * 0.5)`。 |
| **AC-2** `updateResult`/`updateText` 覆寫前產生舊值 `.json` 備份 | ✅ | `TranscriptionHistoryStoreTests.backupCapturesPreOverwriteValues`：`updateResult` 後 `history-backups/<entryID>/` 有 1 檔，decode 後 `text`/`segments`/`durationSeconds` = 覆寫前值；接著 `updateText`，第 2 檔 decode `text` = 前一次的值（即 `updateResult` 寫入的 text）。 |
| **AC-3** 7 次更新後備份目錄維持 5 檔、保留最新 5 | ✅ | `TranscriptionHistoryStoreTests.backupRotationKeepsNewestFive`：`recordCompleted(text:"gen-0")` + 7×`updateText("gen-1..7")`。每次備份存的是**舊** text，故產生 gen-0..gen-6 共 7 檔；輪替後剩 `["gen-2","gen-3","gen-4","gen-5","gen-6"]`（最舊 2 份 gen-0/gen-1 被刪）。輪替依檔名（epoch millis）數值排序刪最舊。測試每次更新間 `Thread.sleep(0.003)` 確保 millis 檔名互異。 |
| **AC-4** 備份目錄無法寫入時主寫入仍成功 | ✅ | `TranscriptionHistoryStoreTests.backupFailureNeverBlocksMainPersist`：在 `history-backups` 路徑放一個同名檔案佔位使 `createDirectory` 失敗。`updateText` + `updateResult` 皆不 throw；重新載入 store，entry 有正確新內容（`text == "retranscribed"`, `durationSeconds == 2`）；`latestBackup(for:)` 回 nil。`backupEntry` 整段包在 `do/catch`，失敗只設非致命 `writeError`（隨後主 `persist()` 成功會清掉）。 |
| **AC-5** diarization 套用分支走 `TranscriptOverwriteGuard` | ✅（邏輯層） | `ContentView+Results.swift` `.onChange(of: worker.diarizedSegments)`：先算 `let rendered = Self.renderSpeakerLabeled(segments)`；既有 `guard !isDraftDirty` 維持；新增 `if TranscriptOverwriteGuard.isDestructiveShrink(existingText: currentEntry?.text ?? "", incomingText: rendered) { pendingDiarizationOverwrite = PendingDiarizationOverwrite(segments: segments); return }`（**不**動 `transcriptDraft`）；否則 `transcriptDraft = rendered; isDraftDirty = true`。判斷只透過 `TranscriptOverwriteGuard`，View 內無另寫比較。既有 `confirmationDialog` message 補字數：`"目前逐字稿 \(currentEntry?.text.count ?? 0) 字，新結果 \(Self.renderSpeakerLabeled(pending.segments).count) 字。…"`。SwiftUI `.onChange` closure 無法在 SwiftTesting 直接驅動，guard 邏輯由 AC-1 完整涵蓋。**手動驗證項**：真機跑「辨識講者」使 segments 大幅減少 → 應跳確認框且草稿不變。 |
| **AC-6** retranscribe 完成分支：shrink 時不呼叫 `updateResult`、設 pending；確認後套用；取消則完全不變 | ✅（邏輯層 + store） | `ContentView+Results.swift` 完成路由（原 L561-581）：`retranscribeTargetEntryID` 分支內先 `let existing = history.entries.first { $0.id == targetID }`，`if let existing, TranscriptOverwriteGuard.isDestructiveShrink(existingText: existing.text, incomingText: completed.text) { pendingRetranscribeResultOverwrite = PendingRetranscribeResultOverwrite(entryID:text:segments:durationSeconds:); return }`（**未**呼叫 `updateResult`）。新 `confirmationDialog(presenting: pendingRetranscribeResultOverwrite)`：確認 → `applyRetranscribeResultOverwrite(pending)`（呼叫 `history.updateResult(id:text:segments:durationSeconds:audioURL:nil)`，若 `currentEntryID == updated.id` 則 `transcriptDraft = updated.text; isDraftDirty = false`）；取消 → 只 `pendingRetranscribeResultOverwrite = nil`，entry 不動。新型別 `PendingRetranscribeResultOverwrite`（`id`/`entryID`/`text`/`segments`/`durationSeconds`）在 `ContentView+Results.swift`；`@State var pendingRetranscribeResultOverwrite` 在 `ContentView.swift` 緊鄰 `pendingRetranscribeOverwrite`。store 層「覆寫前備份 + 取消不動」由 AC-2/AC-4 涵蓋。**手動驗證項**：真機對長逐字稿記錄按「重新轉錄」，結果殘缺 → 應跳確認框；取消後記錄與 Obsidian note 不變；確認後套用新結果且舊版在 `history-backups/`。 |
| **AC-7** `swift test` 全綠 | ⚠️ 綠（扣除既有 flaky/SPIKE） | 見第 3 節。新增 20 tests（`TranscriptOverwriteGuardTests` 6 + `TranscriptionHistoryStoreTests` 擴充 5，其餘為既有）全綠。完整 run 剩兩類失敗，皆**非本次引入**、已於 baseline（stash 掉本次改動後）重現：(a) `LiveRecordingControllerTests` 的 device-recovery watchdog 測試在整套並行負載下 flaky（單獨跑 `--filter` 100% 通過）；(b) `MixedAudioRecordingControllerTests.debugSeparateTracksSpikeProducesTwoFilesWithContent()` 屬工作區既有未提交 SPIKE（`WHISPER_DEBUG_SEPARATE_TRACKS`），不在本任務範圍、未由本人改動。 |
| **AC-8（可選）** History row context menu「還原上一版本」 | ⏭️ SKIPPED（UI 部分） | 依 handoff「AC-8（可選）… 不做則在 VERIFICATION.md 註明留 follow-up」。UI menu item 未做，留 follow-up：接手方若要，接 `history.latestBackup(for: entry.id)` + `history.updateResult(...)` 套回即可。**`latestBackup(for:)` 函式已實作**（`TranscriptionHistoryStore.swift`）且有單元測試 `latestBackupReadsNewestSnapshot`（無備份→nil；兩次更新後回最新一份、`id` 正確），AC-2 亦涵蓋「decode 讀回」。 |

## 3. `swift test` 實際輸出（tail）

完整指令：`cd macos/WhisperApp && swift test`

```
✔ Test stopDuringStartWaitsForStartAndConcurrentStopsShareOneDrain() passed after 1.360 seconds.
✘ Suite MixedAudioRecordingControllerTests failed after 1.362 seconds with 3 issues.
✔ Test transcribeTracksAcceptedProgressAndCompletedEvents() passed after 1.450 seconds.
✔ Test startsWorkerReceivesReadyAndPongThenStops() passed after 1.487 seconds.
✔ Suite WorkerSupervisorTests passed after 1.487 seconds.
✘ Test run with 195 tests in 32 suites failed after 1.488 seconds with 5 issues.
```

Failing tests (all pre-existing, reproduced on baseline with this branch's changes stashed):

```
✘ debugSeparateTracksSpikeProducesTwoFilesWithContent()  — MixedAudioRecordingControllerTests.swift:770/802/803
    (uncommitted SPIKE test, WHISPER_DEBUG_SEPARATE_TRACKS; NOT in scope, NOT mine)
✘ deviceChangeFinalizesCurrentChunkAndResumesCapture()  — LiveRecordingControllerTests.swift:317/319
    (device-recovery watchdog; full-suite parallel-load flake — passes 100% under
     `swift test --filter LiveRecordingControllerTests/deviceChangeFinalizesCurrentChunkAndResumesCapture`)
```

Baseline confirmation (this branch's 6 files stashed, SPIKE left in place):
`✘ Test run with 185 tests in 31 suites failed ... with 11 issues` — same `LiveRecordingControllerTests`
device-recovery cluster + same SPIKE test. i.e. the pre-existing failures are worse/noisier on baseline,
not introduced here.

New suites in isolation — `swift test --filter "TranscriptOverwriteGuardTests|TranscriptionHistoryStoreTests"`:

```
✔ Suite TranscriptOverwriteGuardTests passed after 0.001 seconds.
✔ Suite TranscriptionHistoryStoreTests passed after 0.113 seconds.
✔ Test run with 20 tests in 2 suites passed after 0.113 seconds.
```

`swift build 2>&1 | grep -Ei "warning:|error:"` → no output (no new warnings, no errors).

## 4. `git diff --stat b3659ec -- macos/WhisperApp`

```
 .../Sources/WhisperApp/ContentView+Results.swift   |  81 +++++++++++++-
 .../Sources/WhisperApp/ContentView.swift           |   1 +
 .../WhisperApp/MixedAudioRecordingController.swift |  60 +++++++++--   <-- NOT mine (pre-existing SPIKE, uncommitted, left untouched)
 .../WhisperApp/TranscriptionHistoryStore.swift     |  54 ++++++++++
 .../MixedAudioRecordingControllerTests.swift       |  48 +++++++++     <-- NOT mine (pre-existing SPIKE, uncommitted, left untouched)
 .../TranscriptionHistoryStoreTests.swift           | 116 +++++++++++++++++++++
 6 files changed, 351 insertions(+), 9 deletions(-)
```

Plus two NEW untracked files not shown by `diff --stat` against a commit (shown once committed):
`macos/WhisperApp/Sources/WhisperApp/TranscriptOverwriteGuard.swift`,
`macos/WhisperApp/Tests/WhisperAppTests/TranscriptOverwriteGuardTests.swift`.

Files changed by THIS task (committed on the handoff branch, explicit `git add`):
- `macos/WhisperApp/Sources/WhisperApp/TranscriptOverwriteGuard.swift` (new)
- `macos/WhisperApp/Sources/WhisperApp/TranscriptionHistoryStore.swift`
- `macos/WhisperApp/Sources/WhisperApp/ContentView+Results.swift`
- `macos/WhisperApp/Sources/WhisperApp/ContentView.swift`
- `macos/WhisperApp/Tests/WhisperAppTests/TranscriptOverwriteGuardTests.swift` (new)
- `macos/WhisperApp/Tests/WhisperAppTests/TranscriptionHistoryStoreTests.swift`
- `HANDOFF_CLAUDE_TRANSCRIPT_OVERWRITE_GUARD_VERIFICATION.md` (this file)

## 5. Known caveats

1. **Backup filename collision window**: filename is `Int(Date().timeIntervalSince1970 * 1000).json` (epoch
   millis) per handoff spec. Two backup-triggering updates to the same entry within the same millisecond would
   collide (second overwrites first, rotation still bounded). Backup triggers are user-driven (儲存修改 /
   重新轉錄完成), so this is practically unreachable in production; tests insert `Thread.sleep(0.003)` to
   guarantee distinct names. Not changed because the spec fixes the filename format and rotation sorts by its
   numeric value.
2. **`writeError` after a backup failure is transient**: `backupEntry` sets a non-fatal `writeError`; the
   caller's subsequent successful `persist()` sets `writeError = nil`. Net effect: a backup-only failure is
   not surfaced to the UI. This matches the handoff ("失敗時**可**設 `writeError`… 但主寫入仍要照常完成
   並回傳成功") and AC-4 (which asserts success, not a visible error). If surfacing backup failures is later
   wanted, use a separate property.
3. **AC-5 / AC-6 View interaction not unit-tested**: SwiftUI `.onChange` / `confirmationDialog` closures are
   not exercised by SwiftTesting. The decision helper (`TranscriptOverwriteGuard`) and the store-layer
   behaviour (backup-before-overwrite, cancel-leaves-entry-untouched) are covered; the wiring itself needs the
   manual checks listed in the AC-5/AC-6 rows above.
4. **AC-8 UI not implemented** (see AC-8 row). `latestBackup(for:)` + test done.
5. **Pre-existing full-suite flakiness** in `LiveRecordingControllerTests` device-recovery tests is unrelated
   to this change and was not addressed (per handoff instruction).

## 6. Boundary confirmations

- **NOT pushed.** No `git push` was run. Commits exist only locally on `handoff/2026-09-04-transcript-overwrite-guard`.
- **SPIKE not committed.** `MixedAudioRecordingController.swift` and `MixedAudioRecordingControllerTests.swift`
  (the uncommitted `WHISPER_DEBUG_SEPARATE_TRACKS` SPIKE) were left exactly as found — not edited, not reverted,
  not staged. Every commit used explicit `git add <file>` (never `git add -A` / `.`). They still show as
  unstaged working-tree changes.
- **`.env` not touched.** `~/Library/Application Support/WhisperSTT/.env` was never read or written. No Keychain,
  no `package.sh`, no `.app` build, no Notion/README writes.
- `TranscriptionHistoryEntry` `CodingKeys` / `init(from:)` / JSON schema unchanged — no new fields.

## 7. Commit hashes (on `handoff/2026-09-04-transcript-overwrite-guard`)

Branch created from `b3659ec` (= HEAD of `whisper-swift` at handoff time).

1. `58765e79b123782317446c99c1148737c911dbfb`
   `feat(swift): guard transcript against silent destructive overwrite + keep pre-change backups`
   — the 6 source/test files (explicit `git add`).
2. `<this commit>` `docs(swift): transcript overwrite guard verification report`
   — this VERIFICATION.md only.

The uncommitted SPIKE (`MixedAudioRecordingController*.swift`) and the PLAN-owned
`HANDOFF_CODEX_TRANSCRIPT_OVERWRITE_GUARD.md` are deliberately NOT in either commit.
Nothing was pushed.
