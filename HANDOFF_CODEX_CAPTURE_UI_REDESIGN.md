# Codex Task: Whisper Swift macOS App — Capture 分頁 UI/UX 重構
Date: 2026-07-23
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc
Base commit: fca376970202c4604c6a01fec9cec8e8f7ae2abc

## BLUF
把 `ContentView.swift` 的 detail 容器從「ScrollView 垂直堆疊 6 個卡片」改為「固定頂欄 + 滿版工作區」，套用到全部 5 個 SidebarSection；Capture 分頁的錄音控制收進固定頂欄、逐字稿與 AI 摘要改用分段控制切換，讓操作更像 macOS 原生 App（不用來回滾動）。已有使用者提供的實際 mockup 截圖與核准的規格。

## 任務邊界

### 可改動
- `macos/WhisperApp/Sources/WhisperApp/ContentView.swift`
  - body 從「ScrollView 包住 header+switch+messages」改為「固定頂欄（Capture 分頁顯示新的 compactControlBar／其餘 4 分頁顯示現有 header）+ Divider + 滿版內容區」
  - 新增 `@State var isSettingsPopoverPresented`、`@State var selectedWorkspaceTab`（.transcript / .summary，或等義的 enum）
- `macos/WhisperApp/Sources/WhisperApp/ContentView+Capture.swift`
  - 移除 `captureCard`／`quickSettings` 的 `.cardStyle()` 卡片包裝
  - 拆成 `compactControlBar`：錄音/停止按鈕 + 計時器 + `AudioWaveformView` + 觸發 Popover 的 Settings 按鈕
  - 拆成 `settingsPopoverContent`：原 `quickSettings` 全部欄位（音訊模式、模型/語言、領域/專有詞、螢幕錄製權限提示）+ `fileTranscription` + `batchTranscription` 全部搬進 Popover 內容
  - `fileTranscription`／`batchTranscription`／`startBatch`／`batchSymbol` 現有邏輯不變，只搬動容器位置
- `macos/WhisperApp/Sources/WhisperApp/ContentView+Results.swift`
  - `resultsWorkspace` 與 `summaryWorkspace` 的外層容器改用 `DaylightTheme.swift` 既有的 `PillSegmentedControl` 元件切換（Transcript / AI Summary），內部欄位邏輯（TextEditor、講者辨識、播放跳轉、匯出選單、摘要生成）保留不變，只搬動容器
  - 新增浮動 Copy/Export 按鈕（右下角，複用既有 `copyDraft()`／`export()` 函式）
  - 注意保留原本掛在 `resultsWorkspace` 上的 `.onChange(of: worker.diarizedSegments)` 與 `.onDisappear { stopPlaybackPolling() }` 副作用，拆分容器時不能遺漏
- 新增 `macos/WhisperApp/Sources/WhisperApp/AudioWaveformView.swift`
  - 純視覺元件，依錄音時的 audio level（`recording.microphone.audioLevel` 或對應 controller 的等效欄位）驅動動態波形動畫
  - 無外部依賴，不讀寫任何 controller/store 狀態，只接收 level 與 isRecording 兩個輸入參數

### 禁止改動
- `macos/WhisperApp/Sources/WhisperApp/AudioInputMode.swift`（`SidebarSection` enum）— 5 個分頁項目不變
- `macos/WhisperApp/Sources/WhisperApp/ContentView+CaptureActions.swift` — 純狀態/邏輯計算屬性（`primaryActionEnabled`、`canStartRecording` 等），無版面，直接沿用
- `macos/WhisperApp/Sources/WhisperApp/ContentView+History.swift`、`ContentView+Settings.swift` — 其餘 4 分頁內容不變，只是外殼套用固定頂欄+滿版版型，內部 `historySection`／`vocabularySection`／`advancedSettings` 邏輯不動
- `DaylightTheme.swift` 的 `DaylightPalette`／`CardStyle` 既有定義 — 先沿用，不要預先新增 token；若實作中發現視覺確實對不上 mockup 才新增，且新增時必須透過 `Color(light:dark:)` 方式擴充，不可寫死顏色值
- 所有 `@Environment` controller/store 的實作本體（`WorkerSupervisor`、`StandardRecordingController` 等業務邏輯層）
- Python worker 與後端 route（`system_audio.py`、`routes.py` 等，本任務純 SwiftUI 前端）

### 執行方不能做（留給 Claude Code）
- git push（一律留給接手驗收的 Claude Code，作為獨立驗證後才讓改動進入共用狀態的把關點）
- 可以 git commit（本機留下完整紀錄＋完成報告），但不要 git push
- package.sh / 打包 / 簽名 / Gatekeeper 核准（這台機器上需要手動雙擊 + 系統設定「仍要打開」的步驟，無法由執行方完成）
- 存取 ~/Library/Application Support/WhisperSTT/.env 或任何本機 Keychain 操作
- 修改 `.loop-state-20260723-u3ss.md`（本機狀態檔，不進 repo，由接手的 Claude Code 管理）

## 驗收條件（AC）
□ AC-1. `swift build` 成功，無編譯錯誤/警告
□ AC-2. `swift test` 全過（現況基準 154/154，不得倒退，請在完成報告中附實際數字）
□ AC-3. Capture 分頁 `compactControlBar` 呈現錄音/停止按鈕 + 計時器 + `AudioWaveformView` + Settings 按鈕；點擊 Settings 顯示 Popover，內含原 `quickSettings` 全部欄位 + `fileTranscription` + `batchTranscription`
□ AC-4. Capture 分頁主內容區以 `PillSegmentedControl` 切換 Transcript / AI Summary，兩者原有功能（逐字稿編輯、講者辨識、摘要生成、播放跳轉）全部保留可操作
□ AC-5. 浮動 Copy/Export 按鈕存在且功能正常（複用既有 `copyDraft()`/`export()`）
□ AC-6. history/vocabulary/integrations/settings 4 分頁套用新外殼（固定頂欄+滿版內容）後，`DisclosureGroup` 展開、新增詞彙、匯出 Obsidian/Notion 等既有操作維持可用（此項無法自動驗證，请在完成報告中列為 [需人工驗證]，並附上你認為可疑或高風險的操作點）
□ AC-7. 21 個 `@Environment` binding 全部保留，無編譯錯誤
□ AC-8. `[MM:SS]` 逐字稿時間戳格式（`segmentLabel` 函式）不變

## 驗收指令（完成後自己跑，全部綠才算完成）
```bash
cd macos/WhisperApp
swift build
swift test
```

## 完成後產出
在專案根目錄（本 worktree 根目錄）建立 `HANDOFF_CLAUDE_CAPTURE_UI_REDESIGN_VERIFICATION.md`，內容包含：
1. 每條 AC 的驗收結果（✅ / ❌ + 原因），AC-6 標注 [需人工驗證] 並列出你的走查結果
2. 驗收指令的實際輸出（`swift build`、`swift test` 的完整結果，含測試數量）
3. `git diff --stat` 摘要
4. Known caveats（若有，例如某個 edge case 沒能完全處理、或跟 mockup 有已知落差的地方）
5. 不應該 commit 的內容說明（若有暫存檔、實驗性檔案等）
