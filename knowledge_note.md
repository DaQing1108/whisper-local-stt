# Title: Whisper Swift 系統音訊、AI 摘要與生產力流程 Checkpoint
- Date: 2026-07-20
- Tags: Codex, Whisper Swift, SwiftUI, Python Worker, Anthropic, OpenAI, Obsidian
- Status: Done
- Source: Codex chat
- BLUF: Whisper Swift 已完成系統音訊與混音轉錄、timecode、雙 AI Provider、Obsidian 發布及最後設定保存，並以 126 項 Swift tests、真實音訊與最終路徑簽章完成本機驗證。

## 1. BLUF（結論先講）

Whisper Swift 已安裝至 `/Users/daqingliao/Applications/Whisper Swift.app`。系統音訊可持續錄製並每 15 秒分段轉錄，輸出 timecode；AI 摘要支援 OpenAI 與 Anthropic Claude；Obsidian 可從轉錄歷史建立 Markdown 會議筆記；快速設定會保存最後使用值。Legacy `Whisper STT` 保留為獨立 fallback。

## 2. 問題描述（Problem）

- 系統音訊最初未收錄 headless／CLI 音源，完成後也看不到結果。
- frozen Worker 收到無效 language `08` 時 crash，只顯示 PyInstaller 最後一行。
- AI 摘要缺少可理解 credential 錯誤，也只支援 OpenAI。
- 初版 Anthropic model `claude-sonnet-4-20250514` 已退役而回傳 HTTP 404。
- 音訊模式未保存，重啟後會回到預設值。

## 3. 根因（Root Cause）

- ScreenCaptureKit filter 只包含列出的 GUI applications，漏掉部分系統播放來源。
- language TextField 未驗證，Python inference boundary 也缺少 defensive normalization。
- `MeetingSummaryClientError` 未實作 `LocalizedError`，系統只顯示 enum error number。
- Anthropic 於 2026-06-15 retired Claude Sonnet 4，官方建議改用 `claude-sonnet-4-6`。
- `AudioInputMode` 原本只是 `ContentView` 的 `@State`，未寫入 `UserDefaults`。

## 4. 排查與驗證過程（Investigation）

- 保存並分析真實 system-audio WAV；修正後音量由近乎靜音改善為有效訊號。
- 展開 Worker diagnostics，定位 `lang=08` 與被截斷 traceback。
- 使用保存的真實 chunk 驗證 `08 -> auto -> completed`，得到中文逐字稿與 segment timecode。
- Swift 完整 regression 最終為 `126/126 passed`。
- AI summary focused tests `7/7 passed`，涵蓋 Anthropic Messages API、Provider／credential routing 與 `max_tokens` 截斷保護。
- bundled Worker Gate B、最終 App path `codesign --verify --deep --strict` 均通過。
- 多輪獨立 code review 均 `APPROVE`，無 blocking finding。

## 5. 解法（Resolution / Fix）

- ScreenCaptureKit 改為排除清單模式，收錄完整 display system audio。
- 新增 ordered 15 秒 chunk queue、session WAV、drain／recovery 與 cumulative timecoded result。
- Swift 與 Python 雙層 language normalization；frozen child failure 保留完整 stderr traceback。
- 新增 OpenAI／Anthropic Provider picker，Keychain 使用不同 account 隔離兩組 key。
- Anthropic 使用 `POST /v1/messages`、`anthropic-version: 2023-06-01` 與 `claude-sonnet-4-6`；截斷結果不會標記 completed。
- Obsidian 從轉錄歷史建立唯一 Markdown，包含 YAML、AI summary 與 source transcript。
- `AppSettingsStore` 保存音訊模式、模型、語言、領域及 summary Provider；未知音訊模式安全 fallback 至 `standard`。

## 6. 後續行動（Next Actions）

- 在 App 內完成一次 Claude Sonnet 4.6 真實摘要驗收。
- 選定真實 Obsidian Vault，確認會議 Markdown 建立與內容呈現。
- 若要公開發行，另行完成 Developer ID、notarization、clean Mac Gate E 與 rollback evidence。
- 另案處理 Python release-hardening test 缺少 `WhisperAI_ProductSpec_v1.md`。

## 7. 可複用摘要（Reusable Notes）

- 本地 strict codesign 必須在最終 `.app` 路徑清除 quarantine／FinderInfo 後驗證；staging 成功不足以代表最終 artifact 可執行。
- 系統音訊失敗時先量測 WAV signal，再區分 capture silence、Worker crash 與 UI result visibility。
- frozen subprocess error 不應只保留 stderr 最後一行，否則 PyInstaller wrapper 會遮住真正 traceback。
- LLM model ID 會 retirement；遇到 HTTP 404 應先查官方 deprecation／models overview，而非判斷為 credential 錯誤。
- dirty worktree checkpoint 只 stage 明確 checkpoint 文件，功能 source 與使用者 evidence 維持未提交。

## Checkpoint: Whisper Swift 系統音訊、AI 摘要與生產力流程

- Date: 2026-07-20
- Scope: Whisper Swift SwiftUI + bundled Python Worker local delivery
- Repo / workspace: `/Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc`
- Branch: `codex/swiftui-python-poc`
- Commit: baseline `d8b3e46`; checkpoint commit pending
- Status: Local signed development checkpoint ready
- Completed: system／mixed audio、15-second chunks、timecode、dual AI providers、Obsidian publish、last settings persistence
- Verification: Swift `126/126`; AI focused `7/7`; real Worker chunk completed; Gate B; strict codesign; independent reviews APPROVE
- Files / docs: `README.md`, `knowledge_note.md`; feature files remain dirty and unstaged
- GitHub target: `origin/codex/swiftui-python-poc`, draft PR to `main`
- Notion target: database `361280a95f76806690acdda67775094f`
- Open risks: real Claude／Obsidian user acceptance and external distribution Gate E remain
- Next actions: complete real App summary and Vault publish verification
