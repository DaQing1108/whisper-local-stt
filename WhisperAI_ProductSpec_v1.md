# Whisper STT — Product Requirements Document (PRD)

**版本：** v1.4（PRD 文件版本）  
**建立日期：** 2026-06-12  
**最後更新：** 2026-06-13  
**作者：** DaQing Liao（VIA AI Learning RD Center）  
**涵蓋 App 版本：** Whisper STT v2.3.1  
**狀態：** Draft

| 版本 | 日期 | 變更摘要 |
|------|------|---------|
| v1.0 | 2026-06-12 | 初版，基於 App v1.3.0 源碼分析 |
| v1.1 | 2026-06-12 | 補入競品分析（Notion AI Meeting）、Ollama P1 |
| v1.2 | 2026-06-13 | 補入研究 Roadmap、品質評估計畫、架構演進五階段、v1.2→v1.3 功能更新清單 |
| v1.3 | 2026-06-13 | 更新至 App v1.4.0：分段上傳架構、即時模式、WKWebView 記憶體隔離、WebM EBML 修復、Gemini 移除等 |
| v1.4 | 2026-06-13 | 更新至 App v1.5.0：ffmpeg 打包、模型下載進度、LLM Key UI、結構化錯誤訊息；P0 優先級重評估 |

---

## Executive Summary

Whisper STT 是一款**本地端 AI 會議記錄工具**，使用 OpenAI Whisper 開源 STT 模型在使用者裝置上免費進行語音辨識，結合 LLM（Claude / Gemini / OpenAI，或完全本地的 Ollama）自動整理結構化會議紀錄，並整合 Obsidian 和 Notion 等知識管理工具。核心差異化是**不傳送音訊至雲端**，隱私安全與零邊際成本兼具。

目前 App 已達 **v1.5.0**，完成首輪 MVP 產品化：ffmpeg 已內嵌 .app 包、模型下載有進度顯示、LLM Key 可在 UI 內設定、錯誤訊息已轉為中文說明。底層架構支援長會議分段上傳（最長 120–180 分鐘）與 15 秒即時轉錄模式。本文件定義從內部工具進化為**正式對外產品**所需的完整需求規格。

**競品基準：** 與 Notion AI Meeting 對比測試顯示，在媒體科技場景下，Notion AI Meeting 在繁簡一致、專有名詞識別（DGX、timecode、健康2.0）方面領先本產品；本產品優勢在於完全本地、無音訊外洩風險、對乾淨音檔無廣告/浮水印污染。縮短這個品質差距是 v2.0 的首要技術目標。

---

## 1. Problem Statement

企業會議中大量決策與行動事項在錄音後未能有效追蹤，主要原因是：
- 人工逐字稿耗時（120 分鐘會議需 2–4 小時整理）
- 雲端 STT 服務（如 Otter.ai、Fireflies）存在資料外洩疑慮，在敏感行業（媒體、醫療、法律）難以採用
- 現有工具產出格式零散，難以直接整合進 Obsidian / Notion 等知識庫

若不解決，知識資產持續流失，PM / 工程師重工比例居高不下。

---

## 2. Target Users

| 角色 | 使用場景 | 痛點 |
|------|----------|------|
| **程式開發者 / PM**（內部主力用戶） | 每日技術評審、需求會議 | 不想碰雲端，Apple Silicon 機器多 |
| **媒體 / 新聞工作者** | 訪談記錄、剪輯前置 | 受訪者隱私、專有名詞多（人名、節目名） |
| **顧問 / 業務** | 客戶會議、簡報後紀錄 | 手動整理行動事項浪費時間 |
| **研究人員** | 焦點團體、深度訪談轉錄 | 多語言、長音檔需求 |

---

## 3. Goals

1. **轉錄準確率**：中文專業場景（媒體 / 科技領域）平均字元錯誤率（CER）< 8%（small model）
2. **端對端時間**：120 分鐘會議從錄音結束到取得結構化會議記錄 < 35 分鐘（M-series Mac）
3. **隱私合規**：音訊資料 100% 本地處理，無任何音訊位元組離開使用者裝置
4. **整合採用率**：啟用 Obsidian / Notion 整合的用戶，每週產出會議筆記 ≥ 3 次
5. **安裝成功率**：目標用戶（macOS 非技術背景）從下載到完成首次轉錄的成功率 ≥ 85%

---

## 4. Non-Goals（本版本不涵蓋）

| 項目 | 排除原因 |
|------|----------|
| Windows / Android / iOS 支援 | Apple Silicon 的 mlx-whisper 是核心效能優勢；跨平台需重新設計引擎層 |
| 說話者分離（Speaker Diarization） | 需額外模型（pyannote），增加複雜度；列入 v2 roadmap |
| 即時逐字（word-by-word）串流 | Whisper 非自回歸架構限制；v1.4.0 已支援每 15 秒顯示一段（Live chunk 模式），但非真正的逐字串流 |
| SaaS / 雲端托管版本 | 與本地隱私定位衝突；需獨立評估商業模式 |
| 多語言混合辨識（中英夾雜同段） | Whisper 單段單語言；需分段偵測方案，列入 v2 |
| 視訊會議工具直接擷取（Zoom / Teams） | 需系統音訊擷取，涉及錄音授權問題 |

---

## 5. User Stories

### 5.1 核心轉錄流程

**As a PM，** I want to upload a meeting recording (m4a/mp4) and receive a punctuated transcript  
**so that** I can review the meeting content without listening back to the full audio.

**Acceptance Criteria：**
- 支援 .m4a / .mp3 / .mp4 / .webm / .wav / .ogg / .flac
- Drag & Drop 上傳後自動開始轉錄，無需額外確認步驟
- 轉錄進度以百分比 + 預估剩餘時間顯示（長音檔每段完成時更新）
- 完成後文字可在 UI 直接 inline 編輯

**As a journalist，** I want to add custom terminology before transcription  
**so that** proper nouns (人名、節目名、專業術語) are correctly recognized.

**Acceptance Criteria：**
- 提供文字輸入框，用逗號分隔專有名詞
- 術語注入 Whisper `initial_prompt`，不影響其他設定
- 若輸入超過 200 字元，顯示警告（可能影響辨識品質）

### 5.2 LLM 會議記錄整理

**As a team lead，** I want the transcript to be automatically structured into a meeting summary with decisions and action items  
**so that** I can immediately share follow-up tasks with the team.

**Acceptance Criteria：**
- 會議記錄包含：📋 摘要（3–5 句）、✅ 決策記錄（帶日期）、📌 行動事項（含負責人與截止日，若有提及）
- LLM 整理在背景非同步執行，不阻塞 UI
- 整理完成後透過 SSE 推送通知，顯示「✅ 會議記錄已產生」
- 未設定 LLM API Key 時，靜默略過，不顯示錯誤（僅顯示提示）

**As a user，** I want to choose which LLM provider to use for meeting notes  
**so that** I can control cost and comply with my organization's approved tools.

**Acceptance Criteria：**
- UI 中顯示已偵測到的可用 provider（Claude / OpenAI；Gemini 於 v1.4.0 移除，因 rate limit 問題不穩）
- 可在設定頁手動切換優先順序
- 每次整理後顯示所使用的 provider 與估計費用

### 5.3 Obsidian 整合

**As a knowledge worker using Obsidian，** I want transcripts to be saved as structured .md files with YAML frontmatter  
**so that** I can query and link them within my vault using Dataview.

**Acceptance Criteria：**
- YAML frontmatter 包含：date / time / language / model / domain / duration / tags
- 產生兩個檔案：逐字稿 (`raw`) + 會議記錄 (`_會議記錄.md`)
- 檔名格式：`YYYY-MM-DD HH:MM 逐字稿前20字.md`（自動清理非法字元）
- 存檔路徑可在 UI 設定並持久化

### 5.4 Notion 整合

**As a team using Notion as a knowledge base，** I want to push the transcript to a Notion page with one click  
**so that** the team can access the notes immediately without switching tools.

**Acceptance Criteria：**
- 支援在 UI 設定 Notion Token 與 Page ID（不需重啟應用）
- 上傳前顯示目標頁面的真實標題確認
- 上傳成功後顯示連結，可直接跳轉
- 上傳失敗時顯示可讀的錯誤訊息（Token 過期、頁面未授權等）

### 5.5 安裝與首次使用

**As a non-technical user on macOS，** I want to install the app by dragging it to Applications  
**so that** I don't need to use Terminal or install Python.

**Acceptance Criteria：**
- `.app` 包含所有依賴（Python runtime、ffmpeg、whisper model）
- 首次啟動時自動下載預設模型（small）並顯示進度
- macOS Gatekeeper 警告有明確的繞過指引（系統設定截圖）
- 首次使用引導：選擇模型 → 測試錄音 → 完成第一次轉錄

---

## 6. Requirements

### P0 — Must Have（MVP 產品化必備）

> **v1.5.0 優先級重評估**：經首輪 MVP 產品化評估，P0 項目依「影響所有用戶的安裝/啟動障礙」重新排序；部分原 P0 項目降級，P0-6 移除。

| # | 需求 | 驗收條件 | v1.5.0 狀態 |
|---|------|---------|------------|
| P0-1 | 完整的 macOS .app 安裝包（ffmpeg 內嵌，免 Homebrew） | 拖入 Applications 後雙擊可開啟；ffmpeg binary 已打包進 `.app/Contents/Resources/bin/`；`build_app.sh` 自動完成 | ✅ 已實作 |
| P0-2 | 首次啟動模型下載進度顯示 | 切換未快取模型時顯示 overlay；`GET /api/model-status` 查詢快取狀態；`POST /api/warmup-model` 觸發背景預載；每 3 秒輪詢更新 | ✅ 已實作 |
| P0-4 | LLM API Key UI 設定（免重啟） | UI 內「LLM 設定」卡片；支援 Claude（`sk-ant-`）與 OpenAI（`sk-`）格式驗證；`POST /config` 即時寫入 `.env` + `os.environ` | ✅ 已實作（原 P0-4，重評後仍重要） |
| P0-5 | 錯誤狀態結構化中文說明 | `TranscriptionError(code, message)` 例外類別；SSE `done` 事件含 `error_code`；前端 `ERROR_MESSAGES` 對照表，ffmpeg 缺失、模型載入失敗、API 錯誤均有對應中文解法 | ✅ 已實作 |
| P0-3 | 逐字稿 inline 編輯後可重新觸發 LLM 整理 | 編輯後按「重新整理」，以修改後逐字稿重新呼叫 LLM | ⬇️ 降至 P2（功能本身存在，非安裝障礙） |

### P1 — Should Have（提升體驗）

| # | 需求 | 驗收條件 |
|---|------|---------|
| P1-1 | 說話者分離（Beta） | 利用 pyannote 標記不同說話者，逐字稿以 `[說話者 A]` 區分 |
| P1-1b | 100% 本地 LLM（Ollama 整合） | 整合 Ollama + Llama 3 / Qwen 替代 Claude/Gemini/OpenAI，達成零 API 費用的完全本地化 |
| P1-2 | 會議記錄模板自訂 | 使用者可上傳自訂的 LLM Prompt 模板，替換預設整理格式 |
| P1-3 | 歷史記錄管理 | UI 顯示最近 20 次轉錄記錄（檔名、時間、長度），可重新開啟或刪除 |
| P1-4 | 轉錄結果匯出 | 支援匯出為 .txt / .md / .srt（含時間戳）三種格式 |
| P1-5 | 鍵盤快捷鍵 | 開始/停止錄音（Cmd+R）、上傳（Cmd+U）、儲存至 Obsidian（Cmd+S） |
| P1-6 | 批次轉錄（拖入多個檔案） | 一次拖入多個音檔，依序排隊處理，完成後打包下載 |

### P2 — Future Considerations（v2 以後）

| # | 需求 | 說明 |
|---|------|------|
| P2-0 | 逐字稿 inline 編輯後重觸 LLM 整理 | 原 P0-3，降級；功能本身存在，需補完整流程 |
| P2-1 | Windows 支援 | 替換 mlx-whisper → faster-whisper (CUDA)；需重新測試 UI 層 |
| P2-2 | 即時串流轉錄（word-by-word） | 需評估 Whisper Streaming 或 moonshine 模型 |
| P2-3 | 直接整合 Google Meet / Zoom 音訊 | 系統音訊擷取（BlackHole / ScreenCaptureKit API） |
| P2-4 | 向量搜尋（跨會議查詢） | 將歷史逐字稿建立 embedding，支援語義搜尋 |
| P2-5 | 企業版授權與集中管理 | IT 管理員部署、Token 集中配置 |

### 研究 Roadmap（技術品質提升路徑）

來源：Notion 開發實驗記錄 2026-06-10，依優先順序排列：

```
現在（v1.3.0 已修）
 │
 ├─ 🔴 ① VAD 靜音偵測（Silero，1天）
 │      先偵測靜音段再送 Whisper，減少幻覺 60–80%，同時加速
 │
 ├─ 🔴 ② LLM 後處理擴充（2天）
 │      從標點精修擴展到詞彙糾錯（拜登套斯→Bag & Pulse 等）
 │
 ├─ 🟡 ③ Speaker Diarization（3天）
 │      WhisperX + pyannote.audio，標注「誰說了什麼」
 │
 ├─ 🟡 ④ Benchmark 測試集建立
 │      WER / RTF / 幻覺率，用 jiwer 評估每次改動
 │
 └─ 🟢 ⑤ 領域 Fine-tuning（長期）
        累積校正資料後，用 whisper-medium 繼續訓練
        目標：媒體場景 CER 追上 Notion AI Meeting
```

> **🟢 長期選項：** 即時串流字幕（RealtimeSTT + faster-whisper，延遲 < 2 秒）

---

## 7. Technical Architecture（現況）

```
使用者裝置（本地）
├── Whisper STT.app（pywebview + Waitress WSGI, 16 threads）
│   ├── 前端：內嵌 HTML/JS（Glassmorphism UI）
│   ├── 後端：Flask routes
│   │   ├── GET /events                ← SSE 長連線（進度 + chunk_done 即時文字）
│   │   ├── POST /api/upload-chunk     ← 分段上傳（標準 10min / 即時 15s chunks）
│   │   ├── POST /api/finish-session   ← Session 結束信號（解決 onstop race condition）
│   │   └── POST /transcribe           ← 單檔上傳（舊接口相容）
│   ├── 轉錄引擎：mlx-whisper subprocess → fallback：faster-whisper + VAD
│   │   └── [.app 環境 frozen] 全程透過 system python3 subprocess 隔離記憶體
│   ├── 音訊處理：ffmpeg（任意格式 → 16kHz mono WAV → 30min 分段）
│   └── LLM 後處理：Anthropic / OpenAI API（Gemini 於 v1.4.0 移除）
│       └── 保護機制：輸入 < 10 字元 skip；回傳 > 3× 原長 → 棄用（防 meta-response）
│
└── 本地整合
    ├── Obsidian Vault（本地寫檔）
    └── Notion API（唯一的網路呼叫，僅在用戶主動上傳時觸發）
```

**並發保護：** `threading.Semaphore(1)` — 同時只處理一個轉錄任務，第二個請求自動排隊。

**為何用 subprocess 跑 mlx-whisper：** Apple Metal GPU compiler 無法在背景執行緒初始化，必須在獨立 process 主執行緒執行。每次轉錄 spawn 一個新 process，overhead ≈ 1 秒。在 `.app` 環境（frozen）中更進一步隔離：所有轉錄均透過 system `python3` subprocess 執行，防止 mlx/faster-whisper 記憶體壓力造成 WKWebView renderer crash。

### v1.4.0 錄音模式對照

| 模式 | Chunk 大小 | 行為 | 適用場景 |
|------|-----------|------|---------|
| **高品質模式**（Standard） | 10 分鐘 | 錄音中靜默，結束後整合轉錄並輸出 | 重要會議，品質優先 |
| **即時模式**（Live） | 15 秒 | 每 15 秒轉錄一段，透過 SSE `chunk_done` 即時顯示 | 長會議、需中途確認內容 |

**WebM EBML Header 修復（v1.4.0）：** MediaRecorder 僅在第一個 blob 包含 EBML header，後續 chunk 需補入；前端將第一個 blob 存為 `_webmHeader`，之後每個 chunk 上傳前 prepend header，確保 ffmpeg 可解析（修復 `exit 183` 錯誤）。

### v1.5.0 新增檔案與端點

**新增檔案：**
```
bin/ffmpeg          ← 打包的 ffmpeg binary（隨 .app 分發，免 Homebrew）
build_app.sh        ← .app 打包腳本（自動尋找 + 複製 ffmpeg、PyInstaller 打包）
launcher.sh         ← .app 啟動腳本（將 bundled bin/ 加入 PATH 最高優先位置）
```

**新增 / 擴充 API 端點：**
```
GET  /api/model-status?model={name}  ← 查詢模型快取狀態（cached / downloading / ready）
POST /api/warmup-model               ← 觸發模型背景預載（warmup_model_async）
POST /config（擴充）                 ← 新增接受 anthropic_key / openai_key，即時寫入 .env
```

**新增例外類別：**
```python
class TranscriptionError(Exception):
    def __init__(self, code: str, message: str):
        self.code = code  # FFMPEG_MISSING / MODEL_LOAD_FAILED / LLM_API_ERROR / ...
        super().__init__(message)
```

**ffmpeg 搜尋優先順序（`_get_ffmpeg()`）：** `bin/ffmpeg`（.app 內嵌）→ `/opt/homebrew/bin/ffmpeg` → 系統 PATH → 丟出 `TranscriptionError("FFMPEG_MISSING", ...)`

### 架構演進歷程（五階段試錯記錄）

| Phase | 方案 | 問題 | 結論 |
|-------|------|------|------|
| Phase 1 | Flask dev server + 同步轉錄 | HTTP 連線超時 → Broken pipe [Errno 32] | 同步架構不適合長耗時任務 |
| Phase 2 | 非同步架構（SSE + 背景執行緒） | Werkzeug 印出 Broken pipe 噪音（不影響功能） | 架構正確，噪音可忽略 |
| Phase 3 | gunicorn gthread | SSE 長連線占用 worker → /transcribe 推不出去（已修） | 改用 waitress thread-based |
| Phase 4 | mlx-whisper 直接整合 | Metal MTLCompilerService 在背景執行緒崩潰 | Apple ANE 架構限制 |
| Phase 5 ✅ | mlx-whisper subprocess 包裝 | spawn overhead ≈ 1 秒（可接受） | **最終方案**；失敗自動 fallback faster-whisper |

**Backend 效能對比：**

| Backend | 速度 | Fork-safe | Thread-safe | 使用場景 |
|---------|------|-----------|-------------|---------|
| openai-whisper | 1× | ✅ | ✅ | 備用 fallback |
| faster-whisper | 4× | ✅ | ✅ | CPU fallback（含 VAD） |
| mlx-whisper（直接） | 8–10× | ❌ | ❌（Metal 限制） | CLI 工具專用 |
| **mlx-whisper（subprocess）** ⭐ | **8–10×** | **✅** | **✅** | **Web UI 最終方案** |

---

## 8. Success Metrics

### 8.1 Leading Indicators（上線後 1–4 週）

| 指標 | 目標 | 測量方式 |
|------|------|---------|
| 安裝完成率 | ≥ 85% | 首次轉錄成功 / 下載次數 |
| 首次轉錄成功時間（TTFV） | ≤ 10 分鐘 | 從下載到完成首次轉錄的時間 |
| 轉錄啟動率 | ≥ 60% | 成功轉錄 / 啟動 App 次數 |
| Obsidian / Notion 整合啟用率 | ≥ 40% | 完成整合設定的用戶 / 總用戶 |

### 8.2 Lagging Indicators（上線後 4–12 週）

| 指標 | 目標 | 測量方式 |
|------|------|---------|
| 週活躍用戶留存率（WAU Retention） | ≥ 50%（第 4 週） | 第 4 週仍使用 / 第 1 週用戶 |
| 平均每週轉錄次數（per active user） | ≥ 3 次 | 本地 log 統計 |
| NPS | ≥ 40 | 首月後問卷調查 |
| 中文轉錄 CER（small model） | < 8% | 標竿測試集（媒體 + 科技場景各 30 分鐘） |

> **注意：** 因本地部署無法主動追蹤用量，Leading Indicators 需透過匿名 opt-in 遙測（可關閉）或使用者自回報收集。

### 8.3 STT 品質評估計畫（Benchmark）

為縮短與 Notion AI Meeting 的品質差距，建立標準化測試流程：

| 指標 | 定義 | 工具 | 目標（v2.0） |
|------|------|------|-------------|
| WER（Word Error Rate） | 詞彙層錯誤率 | `jiwer` | < 15%（媒體場景） |
| CER（Character Error Rate） | 字元層錯誤率，中文更適用 | `jiwer` | < 8%（small model） |
| RTF（Real-Time Factor） | 轉錄耗時 / 音訊長度；< 1 = 比即時快 | 計時器 | < 0.3（Apple Silicon M 系列） |
| 幻覺率（Hallucination Rate） | 輸出含 prompt echo 或無音訊對應詞彙的比例 | 人工標注 | < 2% |

**標竿測試集規格：**
- 媒體場景：30 分鐘（多人，背景雜音，含專有名詞 DGX / timecode / 節目名）
- 科技場景：30 分鐘（技術評審，中英夾雜術語）
- 每次版本發布前跑一次，結果記入 changelog

**已知品質里程碑：**
- v1.3.0 前：prompt 指令句造成幻覺（prompt echo），CER 實測偏高
- v1.3.0 修復：改用 `language='zh'` + 純術語 `initial_prompt`，幻覺率大幅下降（35 segments 正確輸出驗證）

---

## 9. Open Questions

| # | 問題 | 負責方 | 阻塞性 |
|---|------|--------|--------|
| Q1 | 是否需要收費模型？若是，定價策略為何（買斷 vs. 訂閱）？ | DaQing + 管理層 | ✅ 阻塞（影響功能範圍） |
| Q2 | 匿名遙測是否可接受？opt-in 還是 opt-out？ | DaQing + 法務 | ⬜ 非阻塞 |
| Q3 | 說話者分離（pyannote）的授權費用是否在 v1 預算內？ | DaQing + 財務 | ⬜ 非阻塞（P1 功能） |
| Q4 | 目標用戶是否涵蓋 Linux？若是，需驗證 mlx-whisper fallback 路徑 | 工程 | ⬜ 非阻塞 |
| Q5 | LLM 整理的「會議記錄格式」是否需要用戶自訂，或統一格式即可？ | DaQing + 潛在用戶訪談 | ⬜ 非阻塞 |
| Q6 | Notion 整合是否需要支援資料庫（Database）而非僅頁面（Page）？ | 工程 + 用戶需求 | ⬜ 非阻塞 |
| Q7 | 自動更新機制如何設計？Sparkle framework？ | 工程 | ⬜ 非阻塞 |

---

## 10. Timeline Considerations

### 現況基線（App v1.5.0）
- ✅ v1.5.0 首輪 MVP 產品化完成（STT + LLM + Obsidian + Notion + 分段上傳 + 即時模式）
- ✅ macOS .app 打包（pywebview + PyInstaller），ffmpeg 已內嵌（免 Homebrew）
- ✅ 首次啟動模型下載進度 overlay（`/api/model-status` + `/api/warmup-model`）
- ✅ LLM API Key 可在 UI 設定（不需重啟，即時寫入 `.env`）
- ✅ 結構化中文錯誤訊息（`TranscriptionError` + `ERROR_MESSAGES` 對照表）
- ✅ 長會議支援（最長 120–180 分鐘），macOS WakeLock
- ❌ 尚無 App Store 或自動更新機制
- ❌ Notion / Obsidian / 模型路徑設定仍需編輯 .env

### 建議 Phasing

**Phase 1（v2.0）— 產品化基礎** 目標：4–6 週
- P0-1 完整安裝包（含 ffmpeg、自動下載模型）
- P0-4 UI 內完整設定頁面（取代 .env）
- P0-5 錯誤狀態改善
- P0-6 雙語文件

**Phase 2（v2.1）— 體驗提升** 目標：Phase 1 後 4 週
- P1-3 歷史記錄
- P1-4 匯出格式
- P1-5 鍵盤快捷鍵
- P0-3 編輯後重新整理

**Phase 3（v2.2）— 差異化功能** 目標：Phase 2 後 6 週
- P1-1 說話者分離（Beta）
- P1-2 自訂 LLM 模板
- P1-6 批次轉錄

---

## 11. Dependencies

| 依賴項目 | 版本 | 風險 |
|---------|------|------|
| mlx-whisper | latest | Apple Silicon 限定；若 Apple 修改 ANE API 可能失效 |
| faster-whisper | latest | CPU fallback；Intel Mac 效能瓶頸 |
| ffmpeg | ≥ 6.0 | 音訊格式轉換核心依賴 |
| pywebview | ≥ 4.x | macOS WebKit 版本限制 |
| Anthropic API | claude-haiku-4-5 | 模型名稱隨版本更新需維護 |

---

## Appendix A：現有功能清單（v1.5.0 現況）

| 功能 | 狀態 |
|------|------|
| 瀏覽器錄音（含波形視覺化） | ✅ 已實作 |
| 音檔上傳（多格式 + Drag & Drop） | ✅ 已實作 |
| 模型選擇（tiny/base/small/medium） | ✅ 已實作 |
| 語言設定（auto/zh/en/ja 等） | ✅ 已實作 |
| 領域提示詞（媒體/科技/醫療/法律） | ✅ 已實作 |
| 自訂專有名詞注入 | ✅ 已實作 |
| 長音檔自動分段（30 分鐘） | ✅ 已實作 |
| Inline 逐字稿編輯 | ✅ 已實作 |
| 錄音回放 | ✅ 已實作 |
| Notion 一鍵上傳 | ✅ 已實作 |
| Obsidian 存檔（含 YAML frontmatter） | ✅ 已實作 |
| LLM 自動整理會議記錄（Claude / OpenAI） | ✅ 已實作 |
| SSE 即時進度推送 + 斷線重連 | ✅ 已實作 |
| 頁面關閉警告 + 跨分頁互斥鎖 | ✅ 已實作 |
| macOS .app 打包（pywebview + PyInstaller） | ✅ 已實作 |
| 分段上傳架構（/api/upload-chunk） | ✅ v1.4.0 新增 |
| 即時模式（Live，15s chunks + SSE 顯示） | ✅ v1.4.0 新增 |
| macOS WakeLock（錄音防熄屏） | ✅ v1.4.0 新增 |
| WKWebView 記憶體隔離（system python3 subprocess） | ✅ v1.4.0 新增 |
| LLM meta-response 防護 | ✅ v1.4.0 新增 |
| ffmpeg 內嵌 .app（免 Homebrew） | ✅ v1.5.0 新增 |
| 模型下載進度 overlay（/api/model-status） | ✅ v1.5.0 新增 |
| LLM API Key UI 設定（即時生效） | ✅ v1.5.0 新增 |
| 結構化中文錯誤訊息（TranscriptionError） | ✅ v1.5.0 新增 |
| 歷史記錄管理 | ❌ 待開發 |
| 說話者分離 | ❌ 待開發 |
| VAD 靜音偵測（Silero） | ❌ 待開發（🔴 高優先） |
| Notion / Obsidian 路徑 UI 設定 | ❌ 待開發（仍需 .env） |
| Ollama 本地 LLM 整合 | ❌ 待開發（P1-1b） |
| 熱詞注入（hotwords） | ❌ 待開發（faster-whisper 原生支援） |

### v1.2.0 → v1.3.0 功能更新清單

| 類別 | 功能 | 說明 |
|------|------|------|
| **穩定性** | Waitress threads 8 → 16 | 修復 SSE 長連線耗盡所有 thread 導致 UI 卡住的問題 |
| **穩定性** | SSE 指數退避重連 | 斷線後 2→3→5→8→13→21→30 秒，最多重試 10 次；紅色橫幅倒數提示 |
| **穩定性** | .last_result.json 磁碟持久化 | 轉錄結果寫入磁碟，頁面重載後自動補回 |
| **穩定性** | Port 衝突自動解除 | gui.py 啟動時呼叫 `_free_port()`，用 lsof + SIGTERM 清除舊程序 |
| **UX** | 錄音誤按防護 | < 3 秒自動取消；≥ 3 秒彈出確認 modal |
| **UX** | 跨分頁錄音互斥鎖 | BroadcastChannel + localStorage TAB_LOCK_KEY |
| **UX** | 頁面關閉警告 | 錄音或轉錄中關閉視窗時彈出 beforeunload 警告 |
| **整合** | Notion badge 顯示頁面真實標題 | 自動抓取頁面名稱；失敗時顯示縮短 ID，不影響連線狀態 |
| **整合** | /api/last_transcript 端點 | 頁面重新載入後可取回最後一次轉錄結果 |
| **整合** | /api/save_to_obsidian 端點 | 新增獨立存檔 API，支援前端直接呼叫 |
| **打包** | 原生 macOS App（pywebview + PyInstaller） | gui.py + gui.spec；產出 `Whisper STT.app` |
| **品質** | initial_prompt 修正 | 移除指令句，改用 `language='zh'` + 純術語語境，解決 prompt echo 幻覺問題 |
| **品質** | `_strip_prompt_echo()` 強化 | 逐行比對邏輯，偵測片段 echo |
| **品質** | LLM provider：Gemini → Anthropic | 移除格式錯誤的 Gemini Key，改用 Claude Haiku |

### v1.4.0 → v1.5.0 功能更新清單（MVP 產品化）

| 類別 | 功能 | 說明 |
|------|------|------|
| **打包** | ffmpeg 內嵌 .app | `build_app.sh` 自動尋找系統 ffmpeg 並複製至 `.app/Contents/Resources/bin/`；`launcher.sh` 優先讀取 bundled bin/；移除 Homebrew 依賴 |
| **打包** | `build_app.sh` 自動化腳本 | 5 步驟：kill 舊 server → PyInstaller → ffmpeg bundling → codesign → 驗證 |
| **UX** | 模型下載進度 overlay | `GET /api/model-status` 查詢快取；`POST /api/warmup-model` 觸發預載；UI 每 3 秒輪詢，切換未快取模型時自動顯示 |
| **UX** | LLM API Key UI 設定 | 「LLM 設定」卡片含格式驗證（`sk-ant-` / `sk-`）；`POST /config` 即時寫入 `.env` + `os.environ`，不需重啟 App |
| **UX** | 結構化中文錯誤訊息 | `TranscriptionError(code, message)` 例外類別；SSE `done` 事件含 `error_code`；前端 `ERROR_MESSAGES` 對照表（7 種錯誤碼） |
| **架構** | 優先級重評估 | P0-3（inline 重觸 LLM）降至 P2；P0-6（多語言文件）移除；P0-4 LLM Key 設定確認為真 P0 |

**Commit：** `892df3b` — feat: P0~P1 優化 — ffmpeg 打包、模型下載進度、LLM Key 設定、結構化錯誤

---

### v1.3.0 → v1.4.0 功能更新清單

| 類別 | 功能 | 說明 |
|------|------|------|
| **架構** | 分段上傳（Chunked Upload） | 新增 `/api/upload-chunk` + `/api/finish-session`；支援最長 120–180 分鐘錄音 |
| **架構** | 即時模式（Live Mode） | 每 15 秒 flush 一個 chunk 並轉錄，透過 SSE `chunk_done` 事件即時顯示文字 |
| **架構** | WKWebView 記憶體隔離 | `.app` 環境中全程透過 system `python3` subprocess 執行轉錄，防止 renderer crash |
| **UX** | macOS WakeLock | 錄音期間呼叫 WakeLock API 防止螢幕熄滅 |
| **修復** | WebM EBML Header | 儲存第一個 blob 作為 EBML header，後續 chunk 上傳前 prepend；修復 ffmpeg exit 183 |
| **修復** | LLM meta-response 防護 | 輸入 < 10 字元 skip LLM；回傳 > 3× 原長視為 meta-response，改用原始輸出 |
| **修復** | Session race condition | 新增 `/api/finish-session` 端點；`onstop` 改為 `startRecording()` 內定義，解決 session never end 問題 |
| **修復** | 音訊播放器 Error | Live 模式隱藏播放器（time axis 錯誤）；Standard 模式從 MediaRecorder 動態偵測 MIME type |
| **修復** | ffmpeg PATH 繼承 | macOS `.app` 不繼承 PATH；改用 lazy loading `_get_ffmpeg()` + `gui.py` 顯式 PATH 注入 |
| **移除** | Gemini LLM Provider | 因 rate limit 不穩定，v1.4.0 移除 Gemini；LLM 優先順序改為 Claude → OpenAI |

---

## Appendix B：競品分析 — Whisper vs Notion AI Meeting

> 測試場景：台灣媒體科技公司會議，多人背景雜音，約 50 秒片段（2026-06-11 實測）

| 評估項目 | Whisper STT（v1.3） | Notion AI Meeting |
|---------|--------------------------|-----------------|
| 繁簡一致性 | ❌ 段落間混用繁體/簡體 | ✅ 全程繁體 |
| 專有名詞準確度 | ❌ 大量出錯（見下表） | ✅ 明顯較佳 |
| 標點與分段 | ❌ 多依賴規則式補點 | ✅ 自然分段 |
| 音訊隱私 | ✅ 100% 本地，音訊不外傳 | ❌ 上傳至 Notion 雲端 |
| 輸出乾淨度 | ✅ 純語音轉錄 | ❌ 混入浮水印、頻道宣傳語 |
| 費用 | ✅ 零邊際成本（本地模型） | 需 Notion AI 訂閱 |
| 部署方式 | 本地安裝 | 雲端 SaaS |

### 典型辨識錯誤對照

| 正確應為 | Whisper 目前輸出 | Notion AI |
|---------|----------------|-----------|
| DGX | dgs / DGS | ✅ 正確 |
| timecode | tempore | ✅ 正確 |
| 健康2.0 | 健发 / 举例健发 | ✅ 正確 |
| Bag & Pulse | 拜登套斯 😂 | ✅ 正確 |

### 結論

本產品核心差異化（本地隱私 + 零成本）成立，但 **STT 品質是最大短板**。縮短差距的路徑：
1. 正確使用 `language='zh'` 取代 prompt 語言引導（✅ v1.3.0 已修）
2. initial_prompt 改為純術語語境（✅ v1.3.0 已修）
3. 下一步：VAD filter（减少幻覺）→ Speaker Diarization → 領域 Fine-tuning
