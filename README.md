# 🎙️ Whisper 本地語音轉文字系統 v1.3.0

利用 OpenAI Whisper 開源模型在本地端**免費**進行語音轉文字，支援長達 120 分鐘的會議錄音，並可一鍵上傳至 Notion 或 Obsidian。

> **Apple Silicon Mac 用戶**：自動使用 Apple Neural Engine（mlx-whisper），速度比 CPU 快 8–10x。

---

## 系統需求

- macOS 12+ / Linux（Windows 未測試）
- Python 3.9+
- ffmpeg（`brew install ffmpeg`）
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

### 方式二：原生 macOS App

```bash
pip install pywebview pyinstaller
pyinstaller gui.spec
```

產生的 `dist/Whisper AI 會議記錄.app` 可拖到 Applications，雙擊即開，無需 Terminal。

> 首次開啟 macOS 可能跳「無法驗證開發者」，至**系統設定 → 隱私權與安全性**點「仍要開啟」一次即可。

---

## 功能說明

| 功能 | 說明 |
|------|------|
| 🎤 即時錄音 | 瀏覽器直接錄音，附即時波形視覺化（Web Audio API） |
| 📂 上傳音檔 | 支援 .m4a / .mp3 / .mp4 / .webm / .wav / .ogg / .flac 等格式，Drag & Drop |
| 🤖 模型選擇 | tiny / base / small / medium（越大越準確，速度越慢）|
| 🌍 語言設定 | 自動偵測，或手動指定 zh / en / ja 等 |
| 🏷️ 領域提示詞 | 媒體 / 科技 / 醫療 / 法律四種領域，自動注入專有名詞提示 |
| ✏️ 自訂專有名詞 | 輸入本次會議術語（如 DGX、健康2.0），提升辨識準確率 |
| ⏱️ 長音檔支援 | 自動切成 30 分鐘段落，分段即時顯示進度 |
| 📝 Inline 編輯 | 轉錄結果可直接點擊修改，如同文字編輯器 |
| 🔊 錄音回放 | 轉錄完成後可播放原始錄音，方便聽打校對 |
| ☁️ Notion 上傳 | 轉錄完成後一鍵上傳至指定 Notion 頁面，右上角顯示頁面真實標題 |
| 📓 Obsidian 存檔 | 自動產生含 Dataview YAML frontmatter 的 .md 檔 |
| 🤖 LLM 會議記錄 | 存入 Obsidian 後自動以 Claude 整理摘要、決策、行動事項 |
| 🛡️ 意外防護 | 錄音誤按確認 modal、SSE 斷線自動重連、頁面關閉警告、跨分頁互斥鎖 |
| 🖥️ 原生 App | pywebview 包裝，可打包為 macOS .app 無需 Terminal |

---

## LLM 標點後處理（可選）

轉錄完成後，可選擇呼叫 LLM 精修標點符號並糾正同音錯字（如「拜登套斯」→「Bag & Pulse」）。

在 `.env` 設定任一 API Key 即可自動啟用（依優先順序）：

```env
ANTHROPIC_API_KEY=sk-ant-xxxx    # Claude Haiku 4.5 ≈ NT$0.03/場
GEMINI_API_KEY=AIzaSy...         # Gemini 2.5 Flash ≈ NT$0.01/場
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
| `YYYY-MM-DD HH:MM 逐字稿前20字.md` | 原始逐字稿，含完整 YAML frontmatter（date / time / lang / model / domain） |
| `YYYY-MM-DD HH:MM 逐字稿前20字_會議記錄.md` | LLM 自動整理的結構化會議記錄（摘要、決策、行動事項） |

LLM 整理在背景非同步執行，完成後透過 SSE 推送狀態至 UI。

---

## 系統架構

```
瀏覽器 → waitress (WSGI, thread-based, 16 threads)
    ├── GET /events     ← SSE 長連線，即時推送轉錄進度
    └── POST /transcribe → 立即回 202，排隊後背景執行
              ├── ffmpeg：任意格式 → 16kHz mono WAV
              ├── 若 > 30 分鐘：自動分段轉錄
              ├── subprocess → mlx-whisper (Apple Neural Engine)
              │               或 faster-whisper + VAD (CPU fallback)
              └── LLM 後處理 → 標點精修 + 同音詞糾錯（需 API Key）
```

**並發保護**：`threading.Semaphore(1)` 確保同時只有一個轉錄任務，避免多個 mlx-whisper subprocess 競爭 Apple Neural Engine。第二個請求進來時自動排隊並通知使用者。

**為何用 subprocess 跑 mlx-whisper？**  
Apple Metal GPU compiler service 無法在 web server 的背景執行緒中初始化，須在獨立 process 的主執行緒中執行。每次轉錄 spawn 一個新 process，Metal 正常運作，overhead 約 1 秒。

---

## 專案結構

```
Whisper/
├── app.py           # 入口點：Flask app、Broken pipe patch、__main__
├── gui.py           # 原生 macOS App 入口（pywebview + Waitress）
├── gui.spec         # PyInstaller 打包設定（產生 .app）
├── routes.py        # 所有 Flask 路由（/、/events、/transcribe、/upload、/config、/api/*）
├── whisper_core.py  # 轉錄引擎（mlx-whisper subprocess + faster-whisper fallback）
├── llm_post.py      # LLM 標點後處理（Claude / Gemini / OpenAI 自動選擇）
├── integrations.py  # Obsidian 存檔 + LLM 自動整理會議記錄
├── sse.py           # SSE 廣播狀態與轉錄排隊 semaphore
├── ui.py            # 內嵌前端 HTML（Glassmorphism UI，含意外處理機制）
├── version.py       # 版本號集中管理
├── transcribe.py    # CLI 批次轉錄工具（直接用 mlx-whisper，最快）
├── listen.py        # 麥克風即時轉錄工具
├── setup.sh         # 一鍵安裝腳本
├── start.sh         # 一鍵啟動腳本
└── .env.example     # 環境變數範本
```

---

## 環境變數總覽（.env）

| 變數 | 必要 | 說明 |
|------|------|------|
| `NOTION_TOKEN` | 選填 | Notion Integration Token |
| `NOTION_PAGE_ID` | 選填 | Notion 目標頁面 ID |
| `OBSIDIAN_MEETING_PATH` | 選填 | Obsidian Vault 存檔路徑 |
| `ANTHROPIC_API_KEY` | 選填 | Claude LLM 標點後處理 |
| `GEMINI_API_KEY` | 選填 | Gemini LLM 標點後處理 |
| `OPENAI_API_KEY` | 選填 | OpenAI LLM 標點後處理 |
| `PORT` | 選填 | 伺服器 port（預設 5001）|

> **注意**：在 UI 儲存 Notion 設定時，系統會局部更新 `.env`，不會覆蓋其他已設定的 Key。

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
