# Verification: 混音 chunk 靜音判定改成分窗

Date: 2026-09-05
Branch: `handoff/2026-09-05-silence-detector-windowing`
Base commit: `6247ae2`
Commit produced: `42768d2` — fix(swift): windowed silence detection for mixed-audio chunks

## 1. Acceptance Criteria Source

未經 spec-writer，人工列出（使用者 2026-09-05 於對話中 approve，見
`HANDOFF_CODEX_SILENCE_DETECTOR_WINDOWING.md`）。

## 2. AC 驗收結果

- **AC-1**（核心案例，14s 近乎全 0 + 最後 1 秒響亮 → `isSilent == false`）
  ✅ PASS — 新測試 `isSilentReturnsFalseWhenOnlyTheFinalSecondIsLoud`。用 15s（16kHz）
  chunk，前 14s 樣本值 0、最後 1s 樣本值 1500。測試內先斷言整塊平均 RMS
  （≈387）確實低於門檻 500（驗證「稀釋」前提成立），再斷言 `isSilent(contentsOf:)`
  （用預設 `windowSeconds`/`sampleRate`）回傳 `false`。

- **AC-2**（全程近乎 0 → `isSilent == true`，既有行為保留）
  ✅ PASS — 新測試 `isSilentReturnsTrueWhenEveryWindowIsQuiet`（5 個窗格全靜音）+
  既有測試 `isSilentReturnsTrueForQuietFile` 不變仍過。

- **AC-3**（全程響亮 → `isSilent == false`，既有行為保留）
  ✅ PASS — 新測試 `isSilentReturnsFalseWhenEveryWindowIsLoud`（5 個窗格全響亮）+
  既有測試 `isSilentReturnsFalseForLoudFile` 不變仍過。

- **AC-4**（既有 6 個測試不變且維持通過，不需修改）
  ✅ PASS — `isSilentReturnsTrueForQuietFile`、`isSilentReturnsFalseForLoudFile`、
  `isSilentFailsOpenForMissingFile`、`isSilentReturnsTrueForHeaderOnlyFile`、
  `rootMeanSquareOfAllZeroSamplesIsZero`、`rootMeanSquareOfLoudSamplesIsHigh` 全部
  **逐字未改**，全部通過（見下方 tail 輸出）。

- **AC-5**（窗格數不整除，殘餘尾端響亮樣本仍要被查到）
  ✅ PASS — 新測試 `isSilentDetectsLoudSampleInResidualTailWindow`：`windowSeconds=1.0`、
  `sampleRate=10`（即每窗 10 樣本），總共 23 個樣本（2 個完整窗格 + 3 樣本殘餘尾端），
  響亮樣本只出現在殘餘尾端最後一格。`isSilent == false`，證明 `while` 迴圈的
  `min(offset + windowByteCount, samples.endIndex)` 沒有把尾端殘餘樣本丟掉。

- **AC-6**（`rootMeanSquare(ofPCM16LittleEndian:)` 簽章與行為不變）
  ✅ PASS — 該函式完全未修改（`git diff` 確認，見下方 AC-7 段落的完整 diff 內容），
  `isSilent` 只在窗格迴圈裡重複呼叫它。既有兩個 `rootMeanSquare*` 測試不變仍過。

- **AC-7**（`git diff --stat 6247ae2 -- macos/WhisperApp` 只列 2 個檔案）
  ⚠️ CAVEAT — 見下方「Known caveats」第一項。**commit 範圍本身**（`git diff --stat
  6247ae2 HEAD -- macos/WhisperApp`）只列 2 個檔案，符合 AC 精神；但驗收指令原文
  用的是「working tree vs base」比較（無第二個 ref），這在本 worktree 會連同任務
  文件明確指出、我未觸碰的既有未提交 SPIKE（`MixedAudioRecordingController.swift` +
  其測試）一起列出，變成 4 個檔案 — 這是 worktree 既有狀態，非本次改動造成，判定
  **PASS（with documented caveat）**。

- **AC-8**（`swift test` 全綠，已知例外允許）
  ✅ PASS — 完整套件 201 tests，僅 `debugSeparateTracksSpikeProducesTwoFilesWithContent`
  （既有 SPIKE，`MixedAudioRecordingControllerTests.swift`）失敗，且需要
  `WHISPER_DEBUG_SEPARATE_TRACKS=1` 才會過 — 已用 `--filter` + 該環境變數單獨驗證通過
  （見下方證據）。另在一次完整套件執行中觀察到 `LiveRecordingControllerTests` 的
  4 個 device-recovery 測試 timing flake，`--filter LiveRecordingControllerTests`
  單獨執行 19/19 全過 — 與 baseline 描述的已知 flake 模式一致，非本次引入。

- **AC-9**（`swift build` 乾淨、無新增 warning）
  ✅ PASS — `swift build 2>&1 | grep -Ei "warning:|error:"` 無輸出。

## 3. `swift test` 實際輸出

### 完整套件（一次執行，AudioChunkSilenceDetectorTests 全過，僅已知 SPIKE 失敗）

```
✔ Test rootMeanSquareOfAllZeroSamplesIsZero() passed after 0.001 seconds.
✔ Test isSilentDefaultWindowingUsesPCM16WAVWriterSampleRate() passed after 0.001 seconds.
✔ Test rootMeanSquareOfLoudSamplesIsHigh() passed after 0.002 seconds.
✔ Test durationSecondsIsZeroForMissingFile() passed after 0.002 seconds.
✔ Test isSilentFailsOpenForMissingFile() passed after 0.001 seconds.
✔ Test isSilentReturnsTrueForHeaderOnlyFile() passed after 0.002 seconds.
✔ Test isSilentReturnsTrueForQuietFile() passed after 0.002 seconds.
✔ Test isSilentReturnsFalseForLoudFile() passed after 0.002 seconds.
✔ Test isSilentReturnsFalseWhenEveryWindowIsLoud() passed after 0.002 seconds.
✔ Test isSilentDetectsLoudSampleInResidualTailWindow() passed after 0.002 seconds.
✔ Test isSilentReturnsTrueWhenEveryWindowIsQuiet() passed after 0.002 seconds.
✔ Test durationSecondsMatchesActualPCMByteCountNotAFixedInterval() passed after 0.005 seconds.
✔ Test isSilentReturnsFalseWhenOnlyTheFinalSecondIsLoud() passed after 0.133 seconds.
✔ Suite AudioChunkSilenceDetectorTests passed after 0.134 seconds.
...
✘ Suite MixedAudioRecordingControllerTests failed after 1.060 seconds with 3 issues.
✘ Test laterDeviceEventCannotIndefinitelyPostponeRecovery() ... (LiveRecordingControllerTests flake)
✘ Test deviceChangeResumesWhenNoMatchingEndEventArrives() ... (LiveRecordingControllerTests flake)
✘ Test repeatedDeviceRecoveryFailureStopsAfterBoundedAttempts() ... (LiveRecordingControllerTests flake)
✘ Test deviceChangeFinalizesCurrentChunkAndResumesCapture() ... (LiveRecordingControllerTests flake)
✘ Suite LiveRecordingControllerTests failed after 1.199 seconds with 8 issues.
✘ Test run with 201 tests in 32 suites failed after 1.314 seconds with 11 issues.
```

### `--filter AudioChunkSilenceDetectorTests`（本次改動的測試單獨執行）

```
Test run with 13 tests in 1 suite passed after 0.134 seconds.
```
（13 = 既有 8 個 + 新增 5 個：`isSilentReturnsFalseWhenOnlyTheFinalSecondIsLoud`、
`isSilentReturnsTrueWhenEveryWindowIsQuiet`、`isSilentReturnsFalseWhenEveryWindowIsLoud`、
`isSilentDetectsLoudSampleInResidualTailWindow`、
`isSilentDefaultWindowingUsesPCM16WAVWriterSampleRate`）

### `--filter LiveRecordingControllerTests`（單獨驗證 flake 為 pre-existing）

```
Test run with 19 tests in 1 suite passed after 0.841 seconds.
```
全過，證實完整套件並行負載下的 4 個失敗是既有 timing flake，非本次引入。

### `WHISPER_DEBUG_SEPARATE_TRACKS=1 swift test --filter debugSeparateTracksSpikeProducesTwoFilesWithContent`

```
✔ Test debugSeparateTracksSpikeProducesTwoFilesWithContent() passed after 0.012 seconds.
Test run with 1 test in 1 suite passed after 0.013 seconds.
```
全過，證實該 SPIKE 測試失敗只是缺環境變數，非本次改動造成。

## 4. `git diff --stat` 摘要

**Commit 範圍**（`git diff --stat 6247ae2 HEAD -- macos/WhisperApp`）— 只有本任務改動的 2 個檔案：

```
 .../WhisperApp/AudioChunkSilenceDetector.swift     |  19 +++-
 .../AudioChunkSilenceDetectorTests.swift           | 104 +++++++++++++++++++++
 2 files changed, 121 insertions(+), 2 deletions(-)
```

**驗收指令原文**（`git diff --stat 6247ae2 -- macos/WhisperApp`，working tree vs base，
含既有未提交 SPIKE）：

```
 .../WhisperApp/AudioChunkSilenceDetector.swift     |  19 +++-
 .../WhisperApp/MixedAudioRecordingController.swift |  60 ++++++++++--
 .../AudioChunkSilenceDetectorTests.swift           | 104 +++++++++++++++++++++
 .../MixedAudioRecordingControllerTests.swift       |  48 ++++++++++
 4 files changed, 223 insertions(+), 8 deletions(-)
```

`swift build 2>&1 | grep -Ei "warning:|error:"` → 無輸出（乾淨）。

## 5. Known caveats

1. **AC-7 的 4-vs-2 檔案落差**：`MixedAudioRecordingController.swift` 與
   `MixedAudioRecordingControllerTests.swift` 的修改是工作區既有、未提交的 SPIKE
   （`WHISPER_DEBUG_SEPARATE_TRACKS`），在本任務開始前就已存在（見 handoff 文件
   「禁止改動」章節），本次**完全沒有讀取、編輯或 commit** 這兩個檔案。working-tree
   比較（AC-7 驗收指令原文）因此必然帶出這兩個檔案；只有透過「commit-to-commit」比較
   （`git diff --stat 6247ae2 HEAD`）才能單獨看到本次改動的 2 個檔案。這個落差是
   worktree 既有狀態決定的，不是本次改動的範圍外溢。

2. **本修復只處理「整塊平均稀釋」這個機制**。工作區那份未提交的 SPIKE
   （`WHISPER_DEBUG_SEPARATE_TRACKS`）在查另一個可能的複合成因——混音振幅減半——
   尚未確認是否也是根因之一，**不在本任務範圍**，未被本次改動觸碰或驗證。

3. `dist/Whisper Swift 2.app`（0 位元組、git-ignored 的建置產物殘留，符合 handoff
   文件提到的 iCloud 同步已知問題，命名模式與文件描述的 `* 2.swift`/`Contents 2`
   同類但副檔名是 `.app`）在切分支後被發現。確認為 0 位元組、`git check-ignore`
   確認被 `.gitignore:31` 的 `dist/` 規則忽略、不含任何原始碼或本次改動內容後已刪除
   （`rm -rf`）。刪除後 `find . -iname "* 2.*"` 與 `find . -iname "*Contents 2*"`
   （排除 `.build/`）均無結果。

4. 真機驗證（實際錄一段混音會議、確認掉字情況改善）需要真實麥克風/系統音輸入，
   單元測試測不到，依 handoff 文件範圍留給使用者 / 後續真機驗證階段。

## 6. 確認事項

- ✅ 未 `git push`（僅本機 commit 在 `handoff/2026-09-05-silence-detector-windowing` 分支）。
- ✅ 未碰 `MixedAudioRecordingController.swift` / `MixedAudioRecordingControllerTests.swift`
  （未 `git add`、未 `Read`、未 `Edit`；commit 用明確 `git add <file>` 只加了本任務的 2 個檔案）。
- ✅ 未存取 `~/Library/Application Support/WhisperSTT/.env` 或 Keychain。
- ✅ 未執行 `package.sh` / build `.app` / 安裝到 `~/Applications`。
- ✅ 未寫入 Notion / README checkpoint。

## 7. Commit hash 清單

- `42768d2` — fix(swift): windowed silence detection for mixed-audio chunks
  （分支 `handoff/2026-09-05-silence-detector-windowing`，base `6247ae2`，未 push）
