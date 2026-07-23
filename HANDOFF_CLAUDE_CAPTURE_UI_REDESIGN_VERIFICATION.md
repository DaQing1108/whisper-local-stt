# Completion Report — Capture 分頁 UI/UX 重構

Date: 2026-07-23
Executed by: Claude Code (this session directly executed HANDOFF_CODEX_CAPTURE_UI_REDESIGN.md,
per user instruction — this run did not go through the separate Codex account/session)
Base commit: fca376970202c4604c6a01fec9cec8e8f7ae2abc

## AC 驗收結果

- **AC-1** ✅ `swift build` 成功，無編譯錯誤/警告
- **AC-2** ✅ `swift test` 154/154 全過（現況基準 154/154，未倒退）
- **AC-3** ✅ `compactControlBar` 呈現錄音/停止按鈕 + 計時器 + `AudioWaveformView` + Settings 齒輪按鈕；點擊觸發 popover，內含原 `quickSettings` 全部欄位（音訊模式/模型語言/模型狀態/領域專有詞/螢幕錄製權限提示）+ `fileTranscription` + `batchTranscription`
- **AC-4** ✅ Capture 分頁主內容區以 `PillSegmentedControl` 切換 Transcript / AI Summary（`workspaceContainer` → `transcriptContent`/`summaryContent`），原有功能（逐字稿編輯、講者辨識、播放跳轉、摘要生成）欄位邏輯完全原封不動搬移，未重寫
- **AC-5** ✅ 浮動 Copy/Export 按鈕存在（`workspaceContainer` 的 `.overlay(alignment: .bottomTrailing)`），複用既有 `copyDraft()`/`export()`，僅在 `.transcript` tab 且逐字稿非空時顯示
- **AC-6** [需人工驗證] history/vocabulary/integrations/settings 4 分頁套用新外殼（固定頂欄 header + Divider + 滿版 ScrollView）後，內部 `historySection`/`vocabularySection`/`advancedSettings` 邏輯完全未修改，只是外層容器結構改變。我认为可疑/高風險的走查點：
  - `historySection` 內任何依賴「整頁 ScrollView 從最頂端算起」的捲動位置邏輯（若有的話）——外殼改變後捲動容器邊界不同
  - `advancedSettings`（Obsidian/Notion 整合設定）內的 `DisclosureGroup` 展開狀態是否因為容器改變而在 tab 切換時被重置（理論上不會，因為 `@State` 綁定在 struct 層級不因外殼改變而重置，但建議實際點開驗證一次）
  - 詞彙新增（`vocabularySection`）的 `TextField` 焦點行為
- **AC-7** ✅ 21 個 `@Environment` binding 全部保留於 `ContentView.swift`（未刪減任何一行 `@Environment` 宣告），`swift build` 無編譯錯誤本身即可作為此項的直接證據
- **AC-8** ✅ `segmentLabel`（`[MM:SS]` 時間戳格式化函式）完全未被此次改動觸碰，diff 中無任何相關變更

## 驗收指令實際輸出

```
$ cd macos/WhisperApp && swift build
ok (build complete)

$ swift test
Test run with 154 tests in 29 suites passed after 1.153 seconds.
```

## git diff --stat 摘要

```
 macos/WhisperApp/Sources/WhisperApp/AudioWaveformView.swift     | 40 ++++++++++ (new file)
 macos/WhisperApp/Sources/WhisperApp/ContentView+Capture.swift   | 75 +++++++++---------
 macos/WhisperApp/Sources/WhisperApp/ContentView+Results.swift   | 90 ++++++++++++++++------
 macos/WhisperApp/Sources/WhisperApp/ContentView.swift           | 45 ++++++-----
 4 files changed, 167 insertions(+), 83 deletions(-)
```

## Known caveats

1. **[MEDIUM，源自核准規格本身] Settings popover 讓 fileTranscription/batchTranscription 多了一層點擊路徑**：原本 `quickSettings`/`fileTranscription`/`batchTranscription` 在 Capture 分頁一直可見（在可捲動內容區裡）；現在需要先點 Settings 齒輪開啟 popover 才能看到。這是 handoff 規格明確要求的搬動方式，不是本次執行偏離，但值得你在真機驗收時確認這個互動深度（gear → popover → scroll → DisclosureGroup 才到批次轉錄）符合預期的 UX 決策。
2. **[MEDIUM，源自核准規格本身] `settingsPopoverContent` 內巢狀 cardStyle 視覺不一致**：`fileTranscription`/`batchTranscription` 這兩個函式本身仍保留各自的 `.cardStyle()`（因為 plan 明確要求「現有邏輯不變，只搬動容器位置」，不可修改這兩個函式本體），但現在它們被塞進一個本身沒有 cardStyle 的 popover ScrollView 裡，視覺上會呈現「popover 裡又有兩個卡片」的巢狀觀感，跟 popover 上半部（PillSegmentedControl/Picker 等無卡片包裝的欄位）不一致。這是 build 測不出來的視覺細節，需要你實際打開 popover 看一眼。
3. **[LOW] AudioWaveformView 在非 `.standard` 音訊模式（system/mixed）下，`level` 恆為 0**：波形會顯示但呈現靜止/最小振幅狀態，而非像原本 `captureCard` 那樣完全不顯示 level 相關 UI。這是刻意的視覺簡化（波形元件本身作為一個一致的視覺錨點，不因音訊模式而消失），但如果你覺得「靜止的波形」在系統音訊模式下看起來像壞掉，可能需要之後補一個「非 standard 模式時淡出/隱藏」的處理。
4. 已修復（非 caveat，僅記錄）：獨立 review 抓到 `AudioWaveformView` 原本用 `.accessibilityHidden(true)` 會讓 VoiceOver 使用者失去原本 `ProgressView` 有的音量讀出，已補回等義的 `accessibilityLabel`/`accessibilityValue`。

## 不應該 commit 的內容說明

無。本次改動僅涉及 4 個計畫內檔案（3 修改 + 1 新增），沒有暫存檔或實驗性檔案產生。
`.loop-state-20260723-u3ss.md`（本機狀態檔）依 handoff 指示不進 repo，也確實在 `.gitignore` 範圍內，未被加入本次 commit。
`docs/Whisper_SwiftUI_P0_Gap_Closing_Specs_v1.md` 是先前 session 遺留的既有 untracked 檔案，與本次任務無關，未觸碰、未加入本次 commit。
