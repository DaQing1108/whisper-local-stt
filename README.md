# 🎙️ Whisper 本地語音轉文字系統 v1.5.0

利用 OpenAI Whisper 開源模型在本地端**免費**進行語音轉文字，支援長達 180 分鐘的會議錄音，並可一鍵上傳至 Notion 或 Obsidian。

> **Apple Silicon Mac 用戶**：自動使用 Apple Neural Engine（mlx-whisper），速度比 CPU 快 8–10x。

---

## 系統需求

- macOS 12+ / Linux（Windows 未測試）
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

| 模式 | 分段間隔 | 適合場景 |
|------|---------|---------|
| 高品質（標準） | 10 分鐘 | 一般會議，錄完後整合輸出 |
| 即時（15 秒延遲） | 15 秒 | 即時逐字顯示，適合演講、直播逐字稿 |

兩種模式都支援最長 180 分鐘錄音，分段架構確保記憶體不隨錄音時間成長。

---

## LLM 標點後處理（可選）

轉錄完成後，自動呼叫 LLM 精修標點符號並糾正同音錯字（如「拜登套斯」→「Bag & Pulse」）。

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

不設定 Notion 仍可正常使用所有轉錄功能。

1. 至 [notion.so/my-integrations](https://www.notion.so/my-integrations) 建立一個 Integration
2. 將目標頁面分享給該 Integration（頁面右上角 → 連線）
3. 編輯 `.env`：

```env
NOTION_TOKEN=secret_xxxx
NOTION_PAGE_ID=你的頁面ID
```

> 頁面 ID 取得方式：在 Notion 頁面 URL 中，`notion.so/` 後面那串 32 位數字即是。

---

## Obsidian 整合設定（可選）

```env
OBSIDIAN_MEETING_PATH=/Users/yourname/ObsidianVault/Meetings
```

點擊「🟣 存入 Obsidian」後，系統自動在指定資料夾產生**兩個檔案**：

| 檔案 | 說明 |
|------|------|
| `YYYY-MM-DD HH:MM 逐字稿前20字.md` | 原始逐字稿，含完整 YAML frontmatter |
| `YYYY-MM-DD HH:MM 逐字稿前20字_會議記錄.md` | LLM 自動整理的結構化會議記錄（摘要、決策、行動事項） |

---

## 系統架構

```
瀏覽器 → waitress (WSGI, 16 threads)
    ├── GET /events             ← SSE 長連線，即時推送轉錄進度
    ├── POST /api/upload-chunk  ← 分段上傳（標準 10min / 即時 15s）
    │       ├── 每段獨立轉錄 → chunk_done SSE
    │       └── 最後一段完成 → 合併全文 → LLM → transcript SSE
    └── POST /transcribe        ← 單檔上傳（相容舊接口）
              ├── ffmpeg：任意格式 → 16kHz mono WAV
              ├── subprocess → mlx-whisper (Apple Neural Engine)
              │               或 faster-whisper + VAD (CPU fallback)
              └── LLM 後處理 → 標點精修 + 同音詞糾錯
```

**記憶體隔離**：mlx-whisper 在獨立 system python3 subprocess 執行，轉錄完畢自動釋放，WKWebView 不受記憶體壓力影響。

**分段錄音**：JS 端每隔設定時間自動 flush 音訊 blob，確保任意長度會議的記憶體佔用固定。

---

## 專案結構

```
Whisper/
├── app.py           # 入口點：Flask app、Broken pipe patch、__main__
├── gui.py           # 原生 macOS App 入口（pywebview + Waitress）
├── gui.spec         # PyInstaller 打包設定（產生 .app）
├── routes.py        # 所有 Flask 路由（/、/events、/transcribe、/upload、/config、/api/*）
├── whisper_core.py  # 轉錄引擎（mlx-whisper subprocess + faster-whisper fallback）
├── llm_post.py      # LLM 標點後處理（Claude / OpenAI 自動選擇）
├── integrations.py  # Obsidian 存檔 + LLM 自動整理會議記錄
├── sse.py           # SSE 廣播狀態與轉錄排隊 semaphore
├── ui.py            # 內嵌前端 HTML（Glassmorphism UI，含意外處理機制）
├── version.py       # 版本號集中管理
├── transcribe.py    # CLI 批次轉錄工具
├── listen.py        # 麥克風即時轉錄工具
├── setup.sh         # 一鍵安裝腳本
├── start.sh         # 一鍵啟動腳本
├── build_app.sh     # .app bundle 打包腳本（含 ffmpeg bundling）
├── launcher.sh      # .app 內部啟動腳本（由 build_app.sh 嵌入）
├── bin/ffmpeg       # 打包的 ffmpeg binary（build_app.sh 複製）
└── .env.example     # 環境變數範本
```

---

## 環境變數總覽（.env）

| 變數 | 必要 | 說明 |
|------|------|------|
| `NOTION_TOKEN` | 選填 | Notion Integration Token |
| `NOTION_PAGE_ID` | 選填 | Notion 目標頁面 ID |
| `OBSIDIAN_MEETING_PATH` | 選填 | Obsidian Vault 存檔路徑 |
| `ANTHROPIC_API_KEY` | 選填 | Claude LLM 標點後處理（可在 UI「LLM 設定」直接設定） |
| `OPENAI_API_KEY` | 選填 | OpenAI LLM 標點後處理（可在 UI「LLM 設定」直接設定） |
| `PORT` | 選填 | 伺服器 port（預設 5001）|

---

## CLI 使用方式

```bash
# 轉錄音檔
python3 transcribe.py 會議錄音.m4a

# 指定模型與語言
python3 transcribe.py 會議錄音.m4a --model medium --language zh

# 轉錄並上傳 Notion
python3 transcribe.py 會議錄音.m4a --upload

# 即時麥克風轉錄
python3 listen.py
```

---

## License

MIT
