# Whisper Legacy vs SwiftUI 功能規格比較 v1

> ⚠️ **本文件已過時（2026-07-22 更新）**
>
> 本文件於 2026-07-18 寫成時，SwiftUI candidate（當時 `codex/swiftui-python-poc`，現已改名為 `whisper-swift` 分支）的 P0/P1/P2 功能尚未完成，下方第 3 節「核心功能矩陣」與第 5 節「Replacement Parity 分級」在寫成當下反映了真實現況。
>
> 但截至 2026-07-22，實際查驗 `.worktrees/swiftui-python-poc`（`whisper-swift` 分支）後確認：**P0（日常轉錄/export）、P1（AI 摘要/Notion/Obsidian 發布語意）、P2（詞庫/history/shortcuts）全部已完成並通過獨立 review**（Swift 108 tests + Python 34 tests 全過）。下方矩陣已同步更新以反映此現況，但**請以下列兩份文件為最新權威依據**，不要單獨依本文件重新評估 migration 決策：
>
> - [`docs/Whisper_SwiftUI_Migration_Task_Spec_v1.md`](Whisper_SwiftUI_Migration_Task_Spec_v1.md)（2026-07-22）— 目前的分支/凍結決策記錄
> - `.worktrees/swiftui-python-poc/docs/Whisper_P0_P2_Parity_Completion_Report_v1.md` — P0–P2 完成證據
> - `.worktrees/swiftui-python-poc/docs/Whisper_Phase4_Gate_E_Readiness_Report_v1.md` — 唯一仍未完成的項目（Gate E，外部條件，非程式碼問題，且已決定暫不投入）
>
> 現行決策：`main`（Whisper Classic）進入凍結維護，`whisper-swift` 為主力開發分支，日常使用 `~/Applications/Whisper SwiftUI.app`。

**日期：** 2026-07-18（矩陣內容於 2026-07-22 更新以反映現況，詳見上方過時警語）  
**比較對象 A：** Whisper STT v2.4.0（Python + Flask + pywebview/WKWebView，現行 production，現已凍結維護）  
**比較對象 B：** Whisper SwiftUI + Python Worker（原生候選版，原 `codex/swiftui-python-poc`，現為 `whisper-swift` 分支，現為主力開發分支）  
**文件目的：** 釐清兩個 App 的真實功能差距，作為 SwiftUI parity、驗收與取代決策依據。

## 1. BLUF

**（2026-07-22 更新）** 兩個 App 的功能差距已大幅縮小。SwiftUI 版的 P0（可編輯逐字稿、繁中正規化、LLM 標點後處理開關、AI 摘要、Obsidian/Notion 發布語意對齊、匯出 TXT/MD/SRT）與 P2（專有名詞庫持久化、history 管理、快捷鍵）已完成並通過獨立 review。SwiftUI 版在 macOS 原生權限、錄音復原、Worker 隔離、Keychain、原生 History 與四種音訊模式上的架構優勢維持不變。

僅剩兩類未達 parity：(1) 說話者分離（diarization）已由使用者於 2026-07-20 明確決策降級為 post-GA 功能，非本輪範圍；(2) Gate E（Developer ID 簽章、notarization、clean Mac 驗證）仍是 NOT READY，但這是外部條件（無 Apple Developer Program 身份、無第二台 clean Mac），非程式碼缺口，且使用者已於 2026-07-22 決定暫不投入，因為現階段僅供個人本機使用。

**目前結論（取代原「保留 v2.4.0 為主 App」的結論）：`main`（Whisper Classic v2.4.x）進入凍結維護；`whisper-swift` 分支取代其成為主力開發與日常使用版本，本機簽章已足夠支撐個人使用。Gate E 留待「確定要對外釋出給其他人」時再重新評估。** 詳見 [`Whisper_SwiftUI_Migration_Task_Spec_v1.md`](Whisper_SwiftUI_Migration_Task_Spec_v1.md)。

## 2. 評估狀態定義

| 狀態 | 定義 |
|---|---|
| ✅ 完整 | 已有可操作 UI、核心流程與對應程式碼，符合目前產品用途 |
| 🟡 部分 | 已有底層能力或簡化流程，但操作、輸出語意或驗證尚未對齊 |
| ❌ 缺少 | 目前 App 沒有對應使用者流程 |
| ⛔ 未發布 | 功能程式碼存在，但正式簽章、notarization、更新或 clean-machine 證據不足 |

## 3. 核心功能矩陣

> 下表已於 2026-07-22 更新，反映 `whisper-swift` 分支 P0–P2 完成後的現況（證據來源：`Whisper_P0_P2_Parity_Completion_Report_v1.md`、`Whisper_SwiftUI_P0_Gap_Closing_Specs_v1.md`、`Whisper_Phase2_Gate_D_Readiness_Report_v1.md`、`Whisper_Phase4_Gate_E_Readiness_Report_v1.md` 及目前原始碼）。標記「（2026-07-22 更新）」的列為與 2026-07-18 原版不同之處。

| 功能領域 | Whisper STT v2.4.0 | Whisper SwiftUI candidate | 差距判定 |
|---|---|---|---|
| 標準麥克風錄音 | ✅ 錄完後轉錄 | ✅ 原生 AVAudioEngine，錄完後轉錄 | SwiftUI 原生化較佳 |
| 即時分段轉錄 | ✅ 15 秒 chunk、持續顯示 | ✅ chunk rotation、ordering、drain 與 recovery；Gate D 已通過長時間/裝置切換/睡眠喚醒實測 | SwiftUI 架構較佳，已完成手動驗收 |
| 系統音訊 | ✅ ScreenCaptureKit | ✅ 原生 ScreenCaptureKit | 功能接近；SwiftUI TCC 流程較原生 |
| 麥克風 + 系統混音 | ✅ 系統音訊模式內選配 | ✅ 獨立 Mixed 模式 | SwiftUI 操作更明確 |
| 音訊/影片檔上傳 | ✅ 多格式、multiple input、Drag & Drop | 🟡（2026-07-22 更新）原生 file importer，已支援 bounded batch queue 多檔佇列；未見與 legacy 對齊的 Drag & Drop 證據 | 批次能力已補齊，Drag & Drop 仍是次要差距 |
| 本地 Whisper 模型 | ✅ tiny 至 large-v3，MLX/faster-whisper 路徑 | ✅ bundled Python Worker + faster-whisper | 模型核心可用，但 backend/performance 不完全相同 |
| 模型首次下載 | ✅ 有 UI overlay 與進度提示 | 🟡（2026-07-22 更新）Worker 有進度事件，並已補上模型 cache readiness 檢查；UI 呈現仍非現行版同等 overlay | 次要 UX 差距，非阻塞 |
| 語言選擇 | ✅ auto/zh/en/ja 快速選擇 | ✅（2026-07-22 更新）domain picker 任務已完成，語言/領域選擇已收斂為受控選項 | 已達 parity |
| 強制台灣繁體中文 | ✅ OpenCC + LLM 雙層處理 | ✅（2026-07-22 更新）`whisper_core.py` 的 OpenCC 簡轉繁在 Worker 路徑無條件套用，兩版共用同一套後處理程式碼 | 已達 parity |
| LLM 標點與同音詞精修 | ✅ 可設定 provider/key，自動後處理 | ✅（2026-07-22 更新）P0 任務已補上 LLM provider/API key 設定（Keychain 儲存）與可切換開關，`WorkerSupervisor.swift` 的 `skip_llm` 已從寫死 `true` 改為依 `llmPunctuationEnabled` 開關決定 | 已達 parity |
| 領域提示詞 | ✅ 通用/媒體/科技/醫療/法律 | ✅（2026-07-22 更新）domain picker 任務已完成 | 已達 parity |
| 本次專有名詞 | ✅ 可輸入 tags 套用 | ✅（2026-07-22 更新）P0/P2 範圍已涵蓋 | 已達 parity |
| 專有名詞庫 | ✅ local library、可重複套用 | ✅（2026-07-22 更新）P2 已完成持久化詞庫 | 已達 parity |
| 說話者分離 | ✅ Beta toggle、轉錄後套用 speaker labels | ⛔（2026-07-22 更新）僅 capability probe，2026-07-20 已由使用者明確決策**降級為 post-GA**，非本輪範圍 | 刻意決策的差距，非遺漏；未來要做需沿用 `CLAUDE.md` 的 subprocess 模式 |
| 逐字稿即時顯示 | ✅ | ✅ partial/final result | 核心接近 |
| 逐字稿人工編輯 | ✅ contenteditable | ✅（2026-07-22 更新）P0 已完成可編輯結果 | 已達 parity |
| 錄音回放校對 | ✅ 標準模式可播放 | ✅（2026-07-22 更新）P0 完成報告列有「播放」功能 | 已達 parity |
| Transcript 時間碼 | ✅ segments 可用於 Markdown/SRT/Obsidian | ✅（2026-07-22 更新）`TranscriptTimecodeFormatter` 已將 Worker segments 轉為 `[MM:SS]` 逐行時間碼，供 export 與 Obsidian 共用 | 已達 parity |
| AI 會議摘要 | ✅ 轉錄後自動產生、可編輯、自動儲存 | ✅（2026-07-22 更新）P1 已完成 OpenAI Responses API summary，含 summary editor | 已達 parity |
| Timeline | 🟡 UI placeholder，尚未正式完成 | ❌ | 不列入 replacement blocker（雙方皆未完成） |
| Copy | ✅ 一鍵 copy | 🟡 可選取文字，一鍵 copy 未見獨立證據 | 小型差距，未在完成報告中列出 |
| 匯出 TXT/MD/SRT | ✅ | ✅（2026-07-22 更新）P0 已完成 TXT/Markdown/SRT export，SRT/MD 使用 Worker segments | 已達 parity |
| 清除本次結果 | ✅ | 🟡 未見獨立完成證據 | 次要操作差距 |
| History | ✅ localStorage，可回復與清除 | ✅（2026-07-22 更新）P2 已完成 history search/delete/retention，且有 durable deletion tombstone 機制 | SwiftUI 已達或超越 parity |
| Obsidian 發布 | ✅ 原始逐字稿 + 目的地專用 AI 會議內容、meeting ID、timecodes、更新既有輸出 | ✅（2026-07-22 更新）P1 已完成「unique-note export」：同一筆 history entry 重複發布時更新既有筆記而非新建，內容含 `[MM:SS]` 時間碼逐字稿 | 已達 parity |
| Notion 發布 | ✅ 建立/更新 meeting child page、目的地專用 AI 內容 + transcript、避免重複 | ✅（2026-07-22 更新）P1 已完成「existing-page append + ambiguous-retry lock」：首次發布建立獨立子頁面，重複發布時清空重寫既有子頁面內容，並保留 ambiguous-outcome crash-safety 鎖定 | 已達 parity |
| Notion credential | ✅ Preferences 設定 | ✅ token 存 Keychain | SwiftUI credential 儲存較佳 |
| 設定介面 | ✅ 獨立 Preferences，含整合、LLM、HF 等 | 🟡 主視窗 DisclosureGroup，已新增 LLM provider/API key 等設定項，但仍非獨立 macOS Settings scene | 差距縮小，非阻塞 |
| 鍵盤快捷鍵 | ✅ Space、Cmd+U、Cmd+S 等 | ✅（2026-07-22 更新）P2 已完成 native shortcuts | 已達 parity |
| Dark Mode | ✅ App 內切換 | ✅ 跟隨 macOS system appearance | 方向不同；SwiftUI 較符合平台慣例 |
| 錄音/裝置復原 | 🟡 Web/SSE 防護與互斥 | ✅ device change、sleep/wake、recovery chunks；Gate D 已有真實藍牙裝置切換實測證據 | SwiftUI 明顯較佳，已完成手動驗收 |
| 取消與 Worker crash recovery | 🟡 現行服務流程具防護 | ✅ versioned JSONL、cancel、restart、terminal-state handling | SwiftUI 架構較佳 |
| 無 Homebrew/system Python 依賴 | ✅ packaged app 內建 runtime/ffmpeg | ✅ bundled Worker，isolated HOME/PATH 已測 | 接近 |
| 自動更新 | ✅ 現行 Sparkle release 路徑 | 🟡 UpdateController 已接入，正式 signed feed 未驗證 | 仍卡在 Gate E（見下） |
| 正式簽章與 notarization | ✅ 現行 App 可作 production fallback | ⛔ 僅 local identity 證據，無 Developer ID/notarization | Gate E blocker，**2026-07-22 已決策暫不投入**（僅供個人本機使用，非對外發布） |
| Clean Mac 安裝驗證 | ✅ 現行日常使用基線 | ⛔ 尚無獨立 clean Apple Silicon Mac 證據 | Gate E blocker，**2026-07-22 已決策暫不投入**，留待決定對外釋出時重新評估 |

## 4. 使用流程差異

### 4.1 現行 Whisper STT

`選擇模式/模型/語言/領域/詞彙 → 錄音或上傳 → Whisper 轉錄 → 繁中與 LLM 後處理 → 人工編輯 transcript/summary → TXT/MD/SRT 或 Obsidian/Notion 發布`

這是一條完整的會議內容生產流程，價值不只在 STT（Speech-to-Text，語音轉文字），也在後續校訂與知識沉澱。

### 4.2 Whisper SwiftUI candidate

`選擇四種音訊模式/模型/語言 → 原生錄音或選擇檔案 → Python Worker 轉錄 → 顯示純文字 → 寫入 History → 簡化 Obsidian export 或 Notion append`

這條流程目前強項是原生 capture 與 runtime reliability，但在內容加工、校訂與發布完整度上仍明顯較短。

## 5. Replacement Parity 分級

> ⚠️ **2026-07-22 更新：** 本節 P0/P2 項目已全數完成（見第 3 節矩陣與 [`Whisper_P0_P2_Parity_Completion_Report_v1.md`](../.worktrees/swiftui-python-poc/docs/Whisper_P0_P2_Parity_Completion_Report_v1.md)）。以下保留原始清單並逐項標註現況，供追溯用；不再代表待辦事項。

### P0：取代現行 App 前必須完成

1. ✅ 可編輯 transcript，並定義 edited text 如何成為後續 export/publish 的唯一來源。（P0 已完成）
2. ✅ 補回台灣繁中正規化及可設定的 LLM 後處理；無 API key 時需有明確 fallback。（P0 已完成，`skip_llm` 已改為依開關決定）
3. ✅ 補回 AI summary 的生成、編輯、保存狀態與錯誤復原。（P1 已完成，OpenAI Responses API）
4. ✅ 對齊 Obsidian 發布：meeting ID、timecodes、原始逐字稿、目的地專用 AI 內容、重複發布更新語意。（P1 已完成，unique-note export）
5. ✅ 對齊 Notion 發布：meeting child page、目的地專用內容、重複發布更新與 idempotency。（P1 已完成，existing-page append + ambiguous-retry lock）
6. ✅ 補回領域提示、本次專有名詞與可重用詞庫，或取得明確產品決策同意移除。（P0/P2 已完成）
7. ✅ 完成 TXT/MD/SRT 匯出，SRT/MD 必須使用 Worker segments。（P0 已完成）
8. ✅ 將說話者分離從 capability probe 接到可操作、可失敗復原的完整流程，或明確降級為 post-GA 功能。（2026-07-20 已決策：明確降級為 post-GA，非可操作完整流程）
9. ⛔ 完成 Developer ID、Hardened Runtime、notarization/stapling、Gatekeeper、signed Sparkle update/rollback 與 clean-machine 驗證。（Gate E 仍 NOT READY；2026-07-22 已決策暫不投入，見第 1 節）

### P1：建議在正式切換時完成

1. ✅ 錄音回放與依時間碼校對。（P0 完成報告列有播放功能）
2. 🟡 Drag & Drop、多檔/批次上傳與明確格式驗證。（bounded batch queue 已完成，Drag & Drop 未見獨立證據）
3. 🟡 一鍵 Copy、清除結果、History 刪除/搜尋/重新開啟。（History 搜尋/刪除已完成；一鍵 Copy、清除結果未見獨立完成證據）
4. ✅ macOS Commands/Menu Bar 與快捷鍵，包括開始/停止、選檔、copy、export。（P2 native shortcuts 已完成）
5. 🟡 將 Preferences 從主流程抽離為標準 macOS Settings scene。（設定項目已擴充，仍非獨立 Settings scene）
6. 🟡 將模型下載、權限拒絕、Worker restart 與 recovery 狀態轉成使用者可理解的繁中訊息。（未見獨立完成證據）

### P2：可在正式切換後迭代

1. ❌ Timeline 正式功能。（雙方皆未完成，非阻塞）
2. ✅ 更完整的 History 管理與跨版本 migration。（P2 已完成 search/delete/retention + durable deletion tombstone）
3. 🟡 進階 diagnostics 與效能面板。（未見獨立完成證據）
4. 🟡 UI 視覺精修、動畫與更完整的 accessibility polish。（未見獨立完成證據）

## 6. 建議驗收矩陣

| 驗收面向 | 同一測試素材/條件 | 通過標準 |
|---|---|---|
| 轉錄品質 | 同一批中文、英文、混合語言與媒體術語音檔 | CER/WER 不顯著退化，繁簡與術語結果可接受 |
| 四種錄音模式 | 標準、即時、系統、混音各至少 30 分鐘 | 無漏段、亂序、無法停止或遺失 recovery file |
| 後處理 | 同一 transcript 與同一 LLM provider | 繁中、標點、summary 結構與錯誤 fallback 符合 spec |
| Export | 同一 segments | TXT/MD/SRT 內容、時間碼與 encoding 一致 |
| Obsidian | 同一 meeting 發布兩次 | 不重複建立錯誤檔案，第二次更新正確，timecodes 保留 |
| Notion | 同一 meeting 發布兩次 | child page 不重複，內容可更新，timeout 不造成重複 append |
| Recovery | Worker crash、device switch、sleep/wake、permission denied | App 可恢復或提供可行動錯誤，音訊不靜默遺失 |
| Release | clean Apple Silicon Mac | 安裝、TCC、模型下載、notarization、更新與 rollback 全部通過 |

## 7. 產品決策建議

> ⚠️ **2026-07-22 更新：已執行決策，取代下方原始建議。** 原建議是「先完成 P0 parity + Gate E 才切換」；P0 已完成，但使用者澄清 app 現階段僅供個人本機使用（非對外發布），因此決定 Gate E 暫不投入，直接以本機簽章切換為主力：
>
> - **`main`（Whisper STT v2.4.x）：** 進入凍結維護，不再排入新功能開發，僅在日常 fallback 出問題時修。
> - **`whisper-swift`（原 `codex/swiftui-python-poc`）：** 取代 `main` 成為主力開發分支，日常使用 `~/Applications/Whisper SwiftUI.app`（本機簽章，Gate B 已通過）。
> - **Gate E（Developer ID/notarization/clean Mac）重新評估觸發條件：** 使用者決定加入 Apple Developer Program、取得第二台 clean Mac，或決定將 app 交給其他人/對外釋出時。
>
> 詳見 [`Whisper_SwiftUI_Migration_Task_Spec_v1.md`](Whisper_SwiftUI_Migration_Task_Spec_v1.md)（2026-07-22，最終決策記錄）。以下為原始（已過時）建議，僅供追溯：

目前不應以「哪一個 UI 比較漂亮」決定主 App，而應採雙軌：

- **Whisper STT v2.4.0：** production baseline，持續供日常工作使用，只做必要維護。
- **Whisper SwiftUI：** replacement candidate，先完成 P0 parity，再做正式 release gate。
- **切換條件：** P0 全數完成、雙 App 使用同一 acceptance corpus 通過比較、Gate E 通過，才改變預設安裝與更新路徑。

## 8. 本版證據邊界

本文件第 3、5、7 節已於 2026-07-22 依 `.worktrees/swiftui-python-poc`（`whisper-swift` 分支）的 `Whisper_P0_P2_Parity_Completion_Report_v1.md`、`Whisper_SwiftUI_P0_Gap_Closing_Specs_v1.md`、`Whisper_Phase2_Gate_D_Readiness_Report_v1.md`、`Whisper_Phase4_Gate_E_Readiness_Report_v1.md` 及當前原始碼（`WorkerSupervisor.swift` 的 `skip_llm` 邏輯等）重新核對更新。

以下為 2026-07-18 原始版本的證據邊界說明，僅供追溯：本文件依 2026-07-18 兩個 worktree 的實際程式碼、UI entrypoint、route、測試與 Gate D/E 報告整理。SwiftUI worktree 目前有大量未 commit 檔案，因此「已實作」代表本機候選工作樹存在，**不代表已合併至 main、已發布或可安全取代 production App**。

**最新權威文件：** [`Whisper_SwiftUI_Migration_Task_Spec_v1.md`](Whisper_SwiftUI_Migration_Task_Spec_v1.md)（2026-07-22）。
