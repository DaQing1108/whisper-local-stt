# HANDOFF — RMS 靜音預過濾（Live Recording Chunk Pipeline）

Base commit: 504293e（`whisper-swift` 分支，含 Capture UI 重構）
Task ID（發起方 discipline-loop）: `20260723-rms1`
給：另一個 Claude Code 帳號

## BLUF

即時錄音管線（系統音訊 + 混音）每 15 秒把一個 chunk 送進 Whisper worker 轉錄。近靜音/純靜音的
chunk 目前也會被送進去，浪費算力並且是幻覺文字的主要來源之一（安靜片段被 Whisper 腦補出不存在
的字）。本任務要在 chunk 送進 worker 之前，用 RMS 判斷是否為靜音，是的話直接跳過轉錄、刪除暫存
檔案，但仍要讓 `transcriptDurationSeconds` 正確推進，避免後續字幕時間戳偏移。

## 先讀這些（依序，含實際行號）

1. `macos/WhisperApp/Sources/WhisperApp/SystemAudioRecordingController.swift`
   - `acceptFinalizedChunk`（216-220）：目前無條件呼叫 `submissionQueue.enqueue(url)`
   - `acceptCompletedChunk`（233-264）：**已經**正確處理「空文字仍推進 duration」的邏輯——
     `chunkDuration = max(maximumSegmentEnd, durationSeconds ?? rotationInterval)`，
     `transcriptDurationSeconds += max(0, chunkDuration)` 永遠執行。這條路徑不需要修改，
     問題只在於「跳過的 chunk 根本不會走到這裡」，需要在跳過時自己補一次等效的 duration 推進。
   - `removeCompletedChunkFiles`（226-231）：只清理「進過 `submissionQueue.completedURLs`」的檔案。
     跳過轉錄的 chunk 永遠不會進 `completedURLs`，**必須在跳過當下自行 `FileManager.default.removeItem`**，
     否則會變孤兒檔案（累積在 `~/Library/Application Support/WhisperSwiftUI/SystemAudioChunks/`）。
2. `macos/WhisperApp/Sources/WhisperApp/MixedAudioRecordingController.swift`
   - `acceptFinalizedChunk`（326-330）：與上面完全同構的重複邏輯，同樣需要修改
   - `acceptCompletedChunk`（343-374）：與 System 版本邏輯相同，同樣不需修改
3. `macos/WhisperApp/Sources/WhisperApp/PCM16WAVWriter.swift`（或搜尋專案內產生 chunk WAV 檔的
   writer，確認 header 格式）：本專案的 chunk WAV 固定為 16kHz mono 16-bit PCM，44-byte 標準
   WAV header，之後的 raw sample bytes 為 little-endian Int16。RMS 計算直接讀這段即可，不需要
   額外的音訊框架。
4. `macos/WhisperApp/Tests/WhisperAppTests/SystemAudioLiveRecordingControllerTests.swift`（1-80+）：
   既有測試基礎設施——`SystemLiveCaptureBackend.emitPCM(_:)` 模擬硬體送資料、
   `SystemLiveScheduler.fire()` 模擬計時器觸發 rotate、`SystemLiveTranscriber.submittedURLs`
   可斷言「哪些 URL 有被送進轉錄」。新增的整合測試直接複用這套 fixture。
5. `macos/WhisperApp/Tests/WhisperAppTests/MixedAudioRecordingControllerTests.swift`：同上，Mixed
   版本的等效 fixture。

## 允許改動的檔案

- 新增 `macos/WhisperApp/Sources/WhisperApp/AudioChunkSilenceDetector.swift`
- `macos/WhisperApp/Sources/WhisperApp/SystemAudioRecordingController.swift`（僅 `acceptFinalizedChunk`，約 8 行內）
- `macos/WhisperApp/Sources/WhisperApp/MixedAudioRecordingController.swift`（僅 `acceptFinalizedChunk`，約 8 行內）
- 新增 `macos/WhisperApp/Tests/WhisperAppTests/AudioChunkSilenceDetectorTests.swift`
- `macos/WhisperApp/Tests/WhisperAppTests/SystemAudioLiveRecordingControllerTests.swift`（新增一個測試函數）
- `macos/WhisperApp/Tests/WhisperAppTests/MixedAudioRecordingControllerTests.swift`（新增一個測試函數）

## 不要做

- **不要碰** `LiveRecordingController.swift`（純麥克風管線）——架構不對稱，沒有本地
  duration bookkeeping，明確排除在本次範圍外，不要「順手」把它也改了
- **不要修改** `acceptCompletedChunk` 的邏輯——它已經正確處理空文字/duration 推進，
  問題只在「跳過的 chunk 走不到這個函數」，不要重寫它
- **不要修改** worker 端（`worker_supervisor` / Python worker protocol）——這是純 Swift 端
  in-process 的決策，跳過的 chunk 根本不會產生任何 IPC/subprocess 呼叫，不涉及協定改動
- **不要**假設「刪除跳過的 chunk 檔案」可以晚點再做——必須在判定為靜音的同一個呼叫路徑內
  立即刪除，否則會有孤兒檔案累積（沒有其他機制會回頭清理它們）
- **不要**用 package.sh 打包驗證（那是 Whisper Classic，不是這個 App）；本任務也**不需要**
  打包，`swift build`/`swift test` 即可完成全部可自動驗證的 AC
- **不要 git push**（見下方「執行方不能做」）

## 執行方不能做

- `git push`（一律留給接手驗收的 Claude Code）
- 打包 / 簽名 / Gatekeeper 相關任何操作
- 讀取 `.env` / Keychain
- 修改 `.loop-state-20260723-rms1.md`（發起方的狀態檔，不進 repo）

## 驗收條件（AC）

- **AC-1** `swift build` 成功，無編譯錯誤/警告
- **AC-2** `swift test` 全部通過（含新增測試，現況基準 154/154，不得倒退）
- **AC-3** `AudioChunkSilenceDetector` 對已知靜音樣本（全 0 或極低振幅 PCM）與已知非靜音樣本
  （明顯振幅 PCM）的 RMS 判斷正確（單元測試覆蓋）
- **AC-4** `SystemAudioRecordingController`：RMS 低於門檻的 finalized chunk **不會**呼叫
  `submissionQueue.enqueue`，且該 chunk 的暫存檔案會被刪除（`FileManager` 確認檔案不存在）
- **AC-5** `MixedAudioRecordingController`：同 AC-4
- **AC-6** 跳過一個靜音 chunk 之後，下一個非靜音 chunk 的 `transcriptDurationSeconds` 累加值
  與「該靜音 chunk 沒被跳過、只是轉錄結果為空文字」時的累加值**一致**（即跳過路徑要呼叫等效的
  duration 推進邏輯，不能讓後續 segment 時間戳偏移）
- **AC-7** `[需人工驗證，不在本次範圍]` 真機錄音走查——執行方不需驗證，Claude Code 接手後補做

## 驗證指令

```bash
cd macos/WhisperApp
swift build
swift test
```

AC-4/AC-5/AC-6 建議寫成整合測試：模擬 backend 送出一段全靜音 PCM → `scheduler.fire()` 觸發
rotate → 斷言 `transcriber.submittedURLs` 不包含該 chunk、對應暫存檔已被刪除、且緊接著送出
一段非靜音 PCM 後其 duration offset 與預期一致。

## 完成後請產出

`HANDOFF_CLAUDE_RMS_SILENCE_PREFILTER_VERIFICATION.md`，格式比照
`HANDOFF_CLAUDE_CAPTURE_UI_REDESIGN_VERIFICATION.md`（同 repo 內既有範例）：
- AC-1 ~ AC-7 逐條結果（AC-7 標 `[需人工驗證，執行方未做]`）
- 實際 `swift build`/`swift test` 輸出
- `git diff --stat` 摘要
- Known caveats（若有）
- 「不應該 commit 的內容說明」

## 分工

- 你（執行方）：實作 + 寫測試 + 跑 `swift build`/`swift test` + `git commit`（**不 push**）+
  產出上述 VERIFICATION.md
- Claude Code（接手驗收）：獨立重新驗證（含 AC-7 真機走查、重跑 build/test）、確認無誤後
  checkpoint + `git push`
