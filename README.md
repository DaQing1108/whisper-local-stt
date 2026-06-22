# 🎙️ Whisper 本地語音轉文字系統 v1.6.4

利用 OpenAI Whisper 開源模型在本地端**免費**進行語音轉文字，支援長達 180 分鐘的會議錄音，並可一鍵上傳至 Notion 或 Obsidian。

> **Apple Silicon Mac 用戶**：自動使用 Apple Neural Engine（mlx-whisper），速度比 CPU 快 8–10x。

---

## 系統需求

- macOS 12+（系統音訊模式需 macOS 12.3+）
- Python 3.9+
- ffmpeg（已內建於 .app bundle；Terminal 模式請執行 `brew install ffmpeg`）
- 麥克風（錄音功能）

---

## 快速開始

### 方式一：瀏覽器模式（Terminal 啟動）

```bash
git clone <this-repo>
cd Whisper
bash setup.sh
bash start.sh
```

然後開啟瀏覽器：**http://localhost:5001**

### 方式二：原生 macOS App（推薦）

```bash
bash build_app.sh
```

產生的 `Whisper STT.app` 可拖到 Applications，雙擊即開，無需 Terminal，**已內建 ffmpeg 無需 Homebrew**。

> 首次開啟 macOS 可能跳「無法驗證開發者」，至**系統設定 → 隱私權與安全性**點「仍要開啟」一次即可。

---

## 功能說明

| 功能 | 說明 |
|------|------|
| 🎤 即時錄音 | 瀏覽器直接錄音，附即時波形視覺化（Web Audio API） |
| ⚡ 即時模式 | 每 15 秒自動切段，邊錄邊看轉錄結果（最低延遲） |
| 🖥️ 系統音訊模式 | 擷取電腦全部聲音（Teams / Zoom 對方聲音、YouTube 等），無需麥克風 |
| 📂 上傳音檔 | 支援 .m4a / .mp3 / .mp4 / .webm / .wav / .ogg / .flac 等格式，Drag & Drop |
| 🤖 模型選擇 | tiny / base / small / medium（越大越準確，速度越慢）|
| 🌍 語言設定 | 自動偵測，或手動指定 zh / en / ja 等 |
| 🏷️ 領域提示詞 | 媒體 / 科技 / 醫療 / 法律四種領域，自動注入專有名詞提示 |
| ✏️ 自訂專有名詞 | 輸入本次會議術語（如 DGX、健康2.0），提升辨識準確率 |
| ⏱️ 長音檔支援 | 分段上傳架構，支援 10–180 分鐘會議，記憶體不隨時間累積 |
| 📝 Inline 編輯 | 轉錄結果可直接點擊修改，如同文字編輯器 |
| 🔊 錄音回放 | 標準模式轉錄完成後可播放原始錄音，方便聽打校對 |
| ☁️ Notion 上傳 | 轉錄完成後一鍵上傳至指定 Notion 頁面，右上角顯示頁面真實標題 |
| 📓 Obsidian 存檔 | 自動產生含 Dataview YAML frontmatter 的 .md 檔 |
| 🤖 LLM 標點精修 | 轉錄後自動以 Claude / OpenAI 精修標點與同音詞糾錯 |
| 🛡️ 意外防護 | 錄音誤按確認 modal、SSE 斷線自動重連、頁面關閉警告、跨分頁互斥鎖 |
| 📦 ffmpeg 內建 | .app bundle 已內建 ffmpeg binary，無需 Homebrew，開箱即用 |
| ⬇️ 模型下載提示 | 首次使用未快取模型時顯示下載進度 overlay，不再無聲等待 |
| 🔑 LLM Key 設定 | UI 內直接設定 Claude / OpenAI API Key，無需手動編輯 .env |
| 🇹🇼 中文錯誤說明 | 所有錯誤狀態附帶繁體中文說明與操作建議 |
| 💤 防休眠 | 錄音中啟用 WakeLock，防止 macOS 螢幕休眠中斷錄音 |
| 🖥️ 原生 App | pywebview 包裝，可打包為 macOS .app 無需 Terminal |

---

## 錄音模式

| 模式 | 說明 | 適合場景 |
|------|------|---------|
| 高品質（標準） | 錄完後整合輸出 | 自己說話的會議、備忘錄 |
| 即時（15 秒延遲） | 邊錄邊顯示 | 演講、直播逐字稿 |
| 系統音訊（會議） | 擷取電腦喇叭輸出，可選同時混入麥克風 | Teams / Zoom 雙方聲音、YouTube 影片 |

---

## 系統音訊（會議）模式

透過 macOS **ScreenCaptureKit** 擷取電腦所有音訊輸出，包含 Teams / Zoom 對方聲音、YouTube、任何 App 播放聲音，每 15 秒自動切段轉錄。

**首次使用需授予螢幕錄製權限：**
系統設定 → 隱私與安全性 → 螢幕錄製 → 開啟 Whisper STT

**混音模式（同時錄製麥克風）：**
勾選「同時錄製麥克風（混音模式）」，可在擷取對方聲音的同時混入自己的麥克風輸入，達到雙軌會議轉錄。

> **提示**：僅轉錄自己說的話時，請使用「🎤 標準模式」效果更佳。

---

## LLM 標點後處理（可選）

轉錄完成後，自動呼叫 LLM 精修標點符號並糾正同音錯字。

在 `.env` 設定任一 API Key 即可自動啟用（依優先順序）：

```env
ANTHROPIC_API_KEY=sk-ant-xxxx    # Claude Haiku 4.5 ≈ NT$0.03/場
OPENAI_API_KEY=sk-xxxx           # GPT-4o-mini      ≈ NT$0.05/場
```

未設定任何 Key 時靜默略過，不影響基本轉錄功能。

---

## 模型速度參考（Apple Silicon M 系列）

| 模型 | 120 分鐘音檔 | 適合場景 |
|------|------------|----------|
| tiny | ~5 分鐘 | 快速草稿、測試 |
| small | ~20–30 分鐘 | 日常會議（推薦） |
| medium | ~40–60 分鐘 | 正式會議紀錄 |

---

## Notion 整合設定（可選）

1. 至 [notion.so/my-integrations](https://www.notion.so/my-integrations) 建立一個 Integration
2. 將目標頁面分享給該 Integration（頁面右上角 → 連線）
3. 編輯 `.env`：

```env
NOTION_TOKEN=secret_xxxx
NOTION_PAGE_ID=你的頁面ID
```

---

## Obsidian 整合設定（可選）

```env
OBSIDIAN_MEETING_PATH=/Users/yourname/ObsidianVault/Meetings
```

---

## 系統架構

```
瀏覽器 → waitress (WSGI, 16 threads)
    ├── GET /events                    ← SSE 長連線，即時推送轉錄進度
    ├── POST /api/upload-chunk         ← 麥克風分段上傳（標準 10min / 即時 15s）
    ├── POST /api/system-audio/start   ← 啟動系統音訊擷取（ScreenCaptureKit）
    ├── POST /api/system-audio/stop    ← 停止擷取，合併全文推送結果
    └── POST /transcribe               ← 單檔上傳

系統音訊管線：
    ScreenCaptureKit → system_audio_capture (Swift binary)
        → stdout (raw PCM 16kHz mono int16)
        → system_audio.py (15s 分段 + 靜音偵測)
        → Whisper 轉錄 → SSE chunk_done
```

---

## 專案結構

```
Whisper/
├── gui.py                        # 原生 macOS App 入口（pywebview + Waitress）
├── gui.spec                      # PyInstaller 打包設定
├── routes.py                     # 所有 Flask 路由
├── whisper_core.py               # 轉錄引擎（mlx-whisper + faster-whisper fallback）
├── llm_post.py                   # LLM 標點後處理
├── system_audio.py               # 系統音訊擷取管理
├── system_audio_capture.swift    # ScreenCaptureKit 擷取程式
├── integrations.py               # Obsidian / Notion 整合
├── sse.py                        # SSE 廣播
├── ui.py                         # 前端 HTML
├── version.py                    # 版本號
├── build_app.sh                  # .app 打包腳本
├── tools/entitlements.plist      # codesign 授權（screen-capture）
├── bin/ffmpeg                    # 打包的 ffmpeg binary
└── bin/system_audio_capture      # 編譯好的 Swift binary
```

---

## 環境變數（.env）

| 變數 | 說明 |
|------|------|
| `NOTION_TOKEN` | Notion Integration Token |
| `NOTION_PAGE_ID` | Notion 目標頁面 ID |
| `OBSIDIAN_MEETING_PATH` | Obsidian Vault 存檔路徑 |
| `ANTHROPIC_API_KEY` | Claude API Key（可在 UI 設定） |
| `OPENAI_API_KEY` | OpenAI API Key（可在 UI 設定） |
| `PORT` | 伺服器 port（預設 5001）|

> `.env` 儲存於 `~/Library/Application Support/WhisperSTT/`，重新打包不會清除。

---

## 版本記錄

### v1.6.4（目前版本）

**v1.6.4 Patch 2**（2026-06-22）

系統音訊擷取穩定性全面修復。

| # | 修復 | 根因 |
|---|------|------|
| 1 | **系統音訊 YouTube/瀏覽器音訊擷取** | `SCContentFilter` 改用 `including: content.applications`，確保 Chrome Helper（背景 process，無可見視窗）的音訊也被包含 |
| 2 | **TCC 螢幕錄製授權跨 rebuild 失效** | 主 app bundle 改用 "WhisperSTT Local" 穩定證書簽名（原為 ad-hoc，每次 rebuild hash 改變 → macOS 視為新 app → 授權失效） |
| 3 | **CLAUDE.md 技術約束文件** | 記錄三條 NEVER 規則 + 症狀診斷樹，防止跨 session 重蹈覆轍 |

> **TCC 授權說明**：升級此版本後需重新授權一次（系統設定 → 隱私權與安全性 → 螢幕錄製 → Whisper STT 開啟）。往後每次 rebuild 無需再次授權。

**v1.6.4 Patch**（2026-06-19）

升版自 v1.6.3，修復 chunk-based 架構延伸問題，新增完整測試覆蓋與 Claude Code 開發工具整合。

**新增**
- 測試套件 `tests/`（61 unit tests 全部通過）
- `Makefile` 快捷指令（`make test` / `make server` / `make package`）
- Stop Hook：Claude Code session 結束自動執行 unit tests
- `/test` skill：Claude Code 互動式測試執行與分析

### v1.6.3

**v1.6.3 延伸 Bug 修復**（2026-06-19）

v1.6.3 重構導入 chunk-based 架構後，測試中發現三個未被覆蓋的跨路徑問題：

| # | 問題 | 原因 | 修法 |
|---|------|------|------|
| 1 | 系統音訊錄音結束後，Obsidian **未自動存檔** | `system_audio_start()` session 寫死 `save_obsidian: False`；`_finalize()` 從不呼叫 `save_to_obsidian()`；前端啟動時未傳 `save_obsidian` 欄位 | 三處同步修正：前端傳參、session 讀參、`_finalize()` 存檔邏輯 |
| 2 | 轉錄後 **永遠卡在 LLM 處理中** | chunk-based 錄音每段各自呼叫 `llm_punctuate()`，28 段 × 最長 60 秒 = 長達 28 分鐘 | 各 chunk 轉錄加 `skip_llm=True`，LLM 僅在全文合併後呼叫一次 |
| 3 | LLM API 掛起時無 hard timeout | `urlopen(timeout=60)` 只保護 socket，連線建立後若 API 不送資料仍會無限阻塞 | `llm_punctuate()` 整體包進 daemon thread，**30 秒**總 timeout；逾時靜默回傳原始文字 |

**新增測試套件**

新增 `tests/` 目錄，共 61 個 unit tests，全部通過：

```
tests/unit/test_hallucination.py   # is_hallucination() 幻覺偵測邊界條件
tests/unit/test_prompts.py         # build_prompt() × domain / extra_terms
tests/unit/test_llm_post.py        # LLM timeout、key 驗證、meta-response 防護
tests/unit/test_notion_blocks.py   # build_notion_blocks() 格式結構
tests/integration/                 # 需要 WHISPER_TEST=1 server（inject endpoint）
tests/e2e/                         # Playwright UI 自動化
tests/accuracy/                    # CER 字元錯誤率回歸（release 前執行）
tests/manual_checklist.md          # TCC 權限 + 真實語音（5-10 分鐘）
```

執行 unit tests：
```bash
make test              # unit tests（61 個，~30s，不需要 server）
make test-integration  # integration tests（需要 make server）
make test-e2e          # Playwright UI 自動化
make test-accuracy     # CER 回歸（release 前）
make server            # 啟動測試用 server（WHISPER_TEST=1）
```

**Claude Code 整合（Stop Hook + /test Skill）**

新增 `.claude/settings.json` Stop Hook：每次 Claude Code session 結束前自動跑 unit tests，通過顯示 ✅，失敗顯示 ❌。

新增 `.claude/skills/test.md` skill：在 Claude Code session 中輸入 `/test` 手動觸發，Claude 看得到結果並可直接分析失敗並修復。

```
/test                  → unit tests（預設）
/test integration      → integration tests
/test all              → unit + integration
```

---

**程式碼品質健檢與重構**

本版本針對 v1.6 累積的技術債進行全面健檢，修復 3 項高優先問題、完成 6 項中低優先重構。

**Bug 修復**

- 🔒 **Session 競態條件（Critical）**：`_chunk_sessions` dict 的讀-改-寫分散在多處，多執行緒並行可能造成 KeyError 或資料競爭。新增 `_chunk_prev_context()` 與 `_chunk_session_update()` 兩個 lock-guarded helper，所有 worker 一律透過這兩個函式存取 session 狀態
- 💀 **Zombie Process（High）**：`system_audio.stop()` 呼叫 `kill()` 後未 `wait()`，Swift 子行程會殘留為 zombie。修復：`terminate()` 加 3 秒 timeout，失敗才 `kill()`，兩條路都補 `wait()`
- 🔒 **`_finalize()` lock race（High）**：背景等待執行緒讀取 `done_count` 在 lock 外部，若主執行緒同時寫入可能讀到髒資料。修復：`done` 讀取移入 lock 區塊內
- 🗑️ **Session 記憶體洩漏（Medium）**：系統音訊模式每次錄音在 `_chunk_sessions` 新增 session 但從不清除，長期運行記憶體持續增長。新增 TTL 清除背景執行緒（300 秒逾時自動驅逐），兩個 session 建立點均加入 `"last_active"` 時間戳

**重構**

- 📦 **消除重複常數（DRY）**：3 個檔案各自定義相同的 `domain_label` dict，新增 `transcribe_common.py` 集中定義 `DOMAIN_LABELS` 常數，所有管線統一 import
- 📦 **消除重複函式（DRY）**：`_is_hallucination()` 分散在多處，移至 `transcribe_common.py` 共用
- 🏗️ **Notion block 建構邏輯（M3）**：`upload()` 內含 30 行 block 組裝，抽取至 `integrations.build_notion_blocks(text, lang)` 統一管理
- 🪵 **移除 Production print()（H1）**：所有 `print()` 改為 `logging.debug/info/warning`，方便 log level 控制，不污染 stdout
- 🪟 **ui.py 拆分（M1）**：2106 行 Python 字串變成維護噩夢（無 IDE 支援、語法高亮失效）。重構為 `templates/index.html` + `static/app.css` + `static/app.js` 三個獨立檔案，`ui.py` 縮減至 15 行組裝程式碼；`gui.spec` 同步加入 `templates/` 與 `static/` bundle 路徑
- 🔀 **`sign_and_install.sh` 重導向**：舊腳本改為 7 行 wrapper，自動轉導至統一入口 `package.sh`，避免歷史肌肉記憶造成誤用

**異動檔案**

| 檔案 | 說明 |
|------|------|
| `routes.py` | 新增 `_chunk_prev_context()`、`_chunk_session_update()`、TTL 清除執行緒；`_finalize()` lock 修正；`print()` → `logging`；Notion block 邏輯移出 |
| `system_audio.py` | `stop()` zombie fix；`_find_binary()` debug log；`print()` → `logging` |
| `transcribe_common.py` | 新檔案：`DOMAIN_LABELS` 常數 + `is_hallucination()` 共用函式 |
| `integrations.py` | 新增 `build_notion_blocks(text, lang)` |
| `ui.py` | 縮減至 15 行組裝程式碼 |
| `templates/index.html` | 新檔案：HTML 骨架（259 行） |
| `static/app.css` | 新檔案：CSS 樣式（463 行） |
| `static/app.js` | 新檔案：JavaScript 邏輯（1382 行） |
| `sign_and_install.sh` | 改為 7 行重導向 wrapper |
| `gui.spec` | 加入 `templates/`、`static/` bundle 路徑；版本號 `1.6.2` → `1.6.3` |
| `version.py` | 版本號 `1.6.2` → `1.6.3` |

---

### v1.6.2

**修復**
- 📝 **Obsidian 存入內容修正**：`saveToObsidian()` 改用 `.transcript-text` 元素取得純文字，修復先前 `innerText` 連時間標籤（`10:30:45｜zh`）一起存入的問題
- ⏱️ **Stop race condition 修復**：系統音訊停止時改為背景等待所有 chunk worker 完成（最多 30 秒），修復最後幾段逐字稿漏掉的問題
- 🛡️ **Whisper 幻覺過濾**：新增 `_is_hallucination()` 偵測「我們可以看到」× 100 等重複幻覺輸出，自動丟棄避免污染逐字稿與 Obsidian 存檔

### v1.6.1

**修復**
- 🎙️ **混音模式修復**：`MixedAudioCapture` 改為計時器驅動（每 15 秒），修復麥克風聲音積在 buffer 無法送出的問題（原設計須等系統音訊有聲才觸發）
- 🛡️ **移除 App Crash 路徑**：in-process SCKit (pyobjc) 呼叫 `startCaptureWithCompletionHandler_` 會觸發 SIGABRT 導致整個 App 閃退，已移除改回 Swift subprocess
- ⚠️ **TCC 拒絕即時提示**：`-3801` 螢幕錄製權限拒絕時立即顯示操作指引，不再顯示通用「未偵測到語音內容」
- 🔑 **TCC 簽名穩定**：`bin/system_audio_capture` 以穩定 cert 簽名（`com.via.whisper-ai.audio-helper`），`sign_and_install.sh` 安裝後自動重新簽名，每次 rebuild 不再重置 TCC 權限

### v1.6.0

**新功能**
- 🖥️ **系統音訊（會議）模式**：透過 ScreenCaptureKit 擷取電腦全部聲音輸出（Teams / Zoom 對方聲音、YouTube 等），無需麥克風，每 15 秒自動切段轉錄
- 🎤 **麥克風混音模式**：系統音訊 + 麥克風雙軌同錄，轉錄雙方對話
- 靜音自動偵測（RMS threshold），跳過無聲片段防止 Whisper 幻覺

**修復**
- `done` SSE 事件加入 `text` fallback，修復 `transcript` 事件遺漏時 UI 不顯示結果
- 系統音訊 stop 端點補齊 `time`、`segments` 欄位
- `.env` 改存 `~/Library/Application Support/WhisperSTT/`，重新打包不清除 API Key
- LLM key 格式驗證，拒絕 fake key，避免 60 秒 timeout

### v1.5.0

- ffmpeg 內建於 .app bundle
- 首次使用顯示模型下載進度
- UI 直接設定 LLM API Key
- 中文錯誤說明

### v1.4.0

- 即時模式（15 秒分段）、WebM 修正、音訊播放器

---

## License

MIT
