# 🎙️ Whisper 本地語音轉文字系統 v1.6.0

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
| 系統音訊（會議） | 擷取電腦喇叭輸出 | Teams / Zoom 對方聲音、YouTube 影片 |

---

## 系統音訊（會議）模式

透過 macOS **ScreenCaptureKit** 擷取電腦所有音訊輸出，包含 Teams / Zoom 對方聲音、YouTube、任何 App 播放聲音，每 15 秒自動切段轉錄。

**首次使用需授予螢幕錄製權限：**
系統設定 → 隱私與安全性 → 螢幕錄製 → 開啟 Whisper STT

> **注意**：此模式擷取的是電腦喇叭輸出，**不包含麥克風輸入**。
> 若要轉錄自己說的話，請使用「標準模式」。

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

### v1.6.0（目前版本）

**新功能**
- 🖥️ **系統音訊（會議）模式**：透過 ScreenCaptureKit 擷取電腦全部聲音輸出（Teams / Zoom 對方聲音、YouTube 等），無需麥克風，每 15 秒自動切段轉錄
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
