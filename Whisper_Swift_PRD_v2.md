# Whisper Swift — Product Requirements Document

**文件版本：** v2.0  
**產品版本基線：** Whisper STT v1.5.0  
**狀態：** Draft／待產品決策確認  
**作者：** DaQing Liao（VIA AI Learning RD Center）  
**建立日期：** 2026-07-23

## 0. 文件摘要（BLUF）

Whisper Swift 是一款以 macOS 為主的 local-first AI meeting recorder。產品在使用者裝置上完成 Speech-to-Text（STT），再由使用者選擇的 LLM 產生結構化會議紀錄，並輸出至 Obsidian 或 Notion。產品的核心價值是「音訊不離開裝置、可直接形成知識資產」；下一階段優先補強安裝成功率、轉錄品質、設定體驗與可驗證的產品化流程。

本文件是產品需求基準，不是技術變更日誌。已完成項目標示為現況證據；尚未決策或尚未實作的項目不得視為承諾功能。

## 1. 文件治理

| 版本 | 日期 | 變更摘要 |
|---|---|---|
| v2.0 | 2026-07-23 | 重新整理 PRD 結構；區分產品需求、現況、Roadmap 與技術附錄 |
| v1.4 | 2026-06-13 | 原始 PRD；基於 App v1.5.0 |

**需求優先級：** P0 = Must Have、P1 = Should Have、P2 = Future consideration。  
**需求狀態：** Planned（規劃中）、In Progress（開發中）、Shipped（已完成）、Deferred（延後）。

## 2. 產品背景與問題

企業會議中的決策與行動事項常在錄音後流失。人工整理 120 分鐘會議需約 2–4 小時；雲端 STT 服務又可能不符合媒體、醫療、法律或企業內部的資料保護要求。現有輸出若無法直接進入 Obsidian／Notion，使用者仍須重工整理。

## 3. 產品定位

### 3.1 Value Proposition

在 Apple Silicon Mac 上，讓使用者以低摩擦方式完成「錄音／上傳 → 本地轉錄 → LLM 整理 → 知識庫輸出」，同時維持音訊 local-only。

### 3.2 目標使用者

| Persona | 主要情境 | 核心需求 |
|---|---|---|
| PM／Developer | 技術評審、需求會議 | 快速取得可追蹤的決策與 action items |
| Journalist／Media worker | 訪談、節目製作 | 保護受訪者隱私，正確辨識專有名詞 |
| Consultant／Sales | 客戶會議 | 減少會後整理時間 |
| Researcher | 焦點團體、深度訪談 | 長音檔與多語言支援 |

## 4. 目標與非目標

### 4.1 產品目標（Goals）

1. 中文科技／媒體場景 CER（Character Error Rate）< 8%（small model）。
2. Apple Silicon Mac 上，120 分鐘會議從結束到取得結構化紀錄 < 35 分鐘。
3. 轉錄音訊 100% 在本地處理；僅在使用者主動執行時呼叫外部 LLM／Notion API。
4. 首次使用者從下載到完成首次轉錄的成功率 ≥ 85%。
5. 啟用知識庫整合的活躍使用者，每週產出會議筆記 ≥ 3 次。

### 4.2 非目標（Non-goals）

本版本不承諾 Windows／Android／iOS、SaaS 託管、真正 word-by-word streaming、Zoom／Teams 直接擷取、多語言混合辨識及完整 speaker diarization。這些項目另列於 Roadmap。

## 5. 核心使用流程

1. 使用者啟動 App，選擇模型與語言，必要時設定領域術語。
2. 使用者錄音或拖放音檔；App 顯示進度與錯誤恢復提示。
3. App 產生可編輯逐字稿；使用者可校正內容。
4. 使用者選擇 LLM 整理會議紀錄，取得摘要、決策與行動事項。
5. 使用者將 raw transcript 與 structured notes 儲存至 Obsidian，或一鍵上傳至 Notion。

## 6. 功能需求與驗收條件

### P0 — MVP 產品化必備

| ID | 需求 | 驗收條件 | 狀態 |
|---|---|---|---|
| P0-1 | macOS 可安裝 App | 拖入 Applications 後可啟動；ffmpeg 位於 App bundle；不依賴 Homebrew | Shipped |
| P0-2 | 模型下載可見 | 未快取模型顯示狀態、進度與完成結果；切換模型不需重啟 | Shipped |
| P0-3 | 音檔轉錄 | 支援 m4a、mp3、mp4、webm、wav、ogg、flac；顯示百分比／剩餘時間；完成後可編輯 | Shipped |
| P0-4 | LLM 設定 | UI 可設定 Claude／OpenAI key，不需重啟；未設定時可單獨使用 STT | Shipped |
| P0-5 | 結構化會議紀錄 | 至少包含摘要、決策、行動事項；LLM 整理不阻塞轉錄 UI | Shipped／需持續驗證 |
| P0-6 | 可理解的錯誤處理 | ffmpeg、模型、LLM、授權等錯誤提供 code、中文說明與下一步 | Shipped |
| P0-7 | 隱私邊界 | 音訊不上傳；外部 API 呼叫只在使用者主動執行時發生，並可被文件清楚說明 | In Progress |

### P1 — 體驗提升

| ID | 需求 | 驗收條件 |
|---|---|---|
| P1-1 | Obsidian 輸出 | 產生 raw transcript 與 meeting note；含 YAML frontmatter、日期、模型、語言、duration、tags |
| P1-2 | Notion 輸出 | 上傳前顯示目標頁面真實標題；成功回傳連結；Token／權限錯誤可理解 |
| P1-3 | 歷史記錄 | 顯示最近轉錄紀錄，可重新開啟、匯出或刪除 |
| P1-4 | 匯出 | 支援 `.txt`、`.md`、`.srt` |
| P1-5 | 自訂整理模板 | 使用者可管理 LLM prompt 與輸出欄位 |
| P1-6 | Speaker diarization | 以 speaker label 區分說話者，先以 Beta 形式驗證 |
| P1-7 | 批次轉錄與快捷鍵 | 多檔排隊；提供錄音、上傳、儲存快捷鍵 |

## 7. 會議紀錄輸出規格

LLM 產出的預設 meeting note 必須包含：

- 摘要：3–5 句，忠實描述討論內容。
- 決策記錄：只列出明確形成的決策，附日期或上下文（若有）。
- 行動事項：列出 action、owner、due date；未提及者不得臆測。
- 待確認事項：將不確定、缺少 owner 或 deadline 的內容獨立列出。

LLM 不可將 prompt、系統訊息或無關宣傳文字回寫為會議內容；輸入過短或回應疑似 meta-response 時，應保留原始逐字稿並提示使用者。

## 8. 品質與成功指標

| 指標 | 目標 | 測量方式 |
|---|---|---|
| 安裝完成率 | ≥ 85% | 完成首次轉錄／下載次數 |
| TTFV（Time to First Value） | ≤ 10 分鐘 | 下載至首次成功轉錄 |
| 中文 CER | < 8% | 固定媒體／科技 benchmark |
| RTF（Real-Time Factor） | < 0.3 | 轉錄耗時／音訊長度 |
| 幻覺率 | < 2% | 人工標註 prompt echo／無音訊內容 |
| 第 4 週留存 | ≥ 50% | opt-in telemetry 或使用者回報 |

Benchmark 每次 release 前執行：媒體場景 30 分鐘、科技場景 30 分鐘，記錄 CER、WER、RTF、幻覺率與模型／OS／硬體條件。

## 9. Roadmap 與分階段交付

**Phase 1：Productization（4–6 週）** — 安裝與首次使用、設定頁、錯誤處理、隱私說明、clean-machine 驗證。  
**Phase 2：Workflow（接續 4 週）** — 歷史記錄、匯出、快捷鍵、編輯後重新整理。  
**Phase 3：Differentiation（接續 6 週）** — VAD、speaker diarization、自訂模板、批次轉錄、Ollama。  
**Phase 4：探索項目** — Windows、系統音訊擷取、向量搜尋、企業集中管理與自動更新。

Roadmap 排序以「使用者價值 × 風險降低 × 驗證成本」為準；未完成產品決策前，不將商業模式、遙測政策或跨平台支援視為承諾。

## 10. 依賴、風險與開放決策

| 項目 | 影響 | 下一步 |
|---|---|---|
| Apple Silicon／mlx-whisper | 核心效能依賴平台 | 保留 faster-whisper fallback，持續做 release benchmark |
| LLM provider 與成本 | 影響整理品質、費用與隱私 | 決定支援清單、模型與費用揭露方式 |
| Notion Page vs Database | 影響整合資料模型 | 以目標使用者 workflow 做決策 |
| Telemetry consent | 影響指標可量測性 | 與法務確認 opt-in、資料欄位與保存期限 |
| Sparkle／自動更新 | 影響正式發布與維護 | 完成 Developer ID、notarization、rollback proof 後再排入 |

## Appendix A — v1.5.0 現況基線

目前已具備：瀏覽器錄音、拖放多格式音檔、模型選擇、語言／領域提示詞、長音檔分段、inline transcript editing、SSE 進度、Standard／Live（15 秒 chunk）模式、Obsidian／Notion 輸出、Claude／OpenAI 整理、ffmpeg bundled App、模型下載進度、LLM key UI、結構化中文錯誤。

尚未完成或需補強：歷史記錄、完整設定頁、VAD、speaker diarization、Ollama、批次轉錄、自動更新、clean-machine acceptance 與正式發布證據。

## Appendix B — 技術實作摘要

App 採 pywebview + embedded HTML/JS + Flask/Waitress；SSE 傳遞進度；長會議使用 chunked upload；轉錄透過獨立 subprocess 執行 mlx-whisper，失敗時 fallback faster-whisper；ffmpeg 將輸入轉為 16 kHz mono WAV。Notion API 是唯一在使用者主動上傳時觸發的外部整合；Obsidian 為本地檔案輸出。

## Appendix C — 來源與證據

- `WhisperAI_ProductSpec_v1.md`：原始 PRD 與 v1.5.0 功能基線。
- `docs/`：UI、架構、整合與 migration 規格。
- `tests/`：手動驗證清單與測試說明。

> 本文件整理自 workspace 內的 PRD 與相關規格；Notion 原頁面尚未由本環境成功讀取，因此尚未聲稱與 Notion 頁面逐段一致。
