# Whisper STT — Claude 技術約束

## 絕對不能做（NEVER）

### 1. 不能用 pyobjc 做系統音訊擷取
- **檔案**：`system_audio_sc.py` 存在但只能用來確認 TCC 狀態，不能呼叫 `start_sc_capture()`
- **原因**：libdispatch 內部 assertion 導致 SIGABRT（exit 133），確認於 v1.6.1
- **正確做法**：`routes.py` 的 `system_audio_start` 必須呼叫 `_sa.start_capture(_on_chunk, on_error=_on_tcc_error)`

### 2. 不能用 ad-hoc 簽名主 app bundle
- **原因**：ad-hoc 每次 rebuild hash 都變，macOS TCC 視為新 app，螢幕錄製授權每次失效
- **正確做法**：`package.sh` 步驟 3 必須用 `--sign "WhisperSTT Local"`，不能 `-s -`

### 3. system_audio_capture binary 必須用穩定 identifier 簽名
- **identifier**：`com.via.whisper-ai.audio-helper`
- **cert**：`WhisperSTT Local`（本機 keychain，SHA1: 0D63DB9D7C4A427A0211FE9B237B90E338D7A941）
- **原因**：同上，TCC 跨 rebuild 穩定

---

## 症狀診斷樹（先查這裡，再動 code）

### ⚠️ 未偵測到語音內容

```
log 有 ERROR -3801？
├── YES → TCC 拒絕
│         ├── 系統設定 → 隱私 → 螢幕錄製 → Whisper STT 是否開啟？
│         ├── NO → 開啟後重啟 app
│         └── YES → 簽名問題：確認 package.sh 用 WhisperSTT Local，執行後重新授權一次
│
└── NO（log 無新條目）
    ├── 錄音時間 < 1 秒？ → chunk 不會產生，錄久一點
    └── log 有 RMS 行？
        ├── RMS > 500 + Hallucination rejected → 音訊擷取 OK，內容不是人聲（換清晰語音影片）
        └── RMS < 500 → 音訊靜音或背景噪音太低（確認系統音量、YouTube 是否在播放）
```

### 🔴 App 啟動後 crash / SIGABRT

```
routes.py system_audio_start 是否呼叫了 _sc.start_sc_capture()？
└── YES → 立刻改回 _sa.start_capture(_on_chunk, on_error=_on_tcc_error)
          這是已知 crash 路徑，pyobjc SCKit 不能在 app 主進程跑
```

### 🔄 修了 code 但行為沒變

```
→ 執行 /debug skill，Step 1 先確認 port 5001 只有一個 process
→ 99% 是改了 source 但跑的是舊 .app
```

### 🔇 dev server（Terminal）跑系統音訊沒有回應 / 靜默

```
→ 這是 TCC 設計限制，不是 code bug，不需要 debug
→ macOS TCC 只授權給簽名的 .app bundle，python 直接跑沒有螢幕錄製權限
→ 正確測試流程：./package.sh → 開 .app → 錄音
→ Terminal 模式只能測麥克風錄音和上傳音檔，無法測系統音訊
```

---

## 架構速查

| 模式 | 入口 | 音訊來源 |
|------|------|----------|
| 麥克風錄音 | `POST /api/upload-chunk` | 瀏覽器 MediaRecorder |
| 系統音訊（純） | `POST /api/system-audio/start` | Swift binary `system_audio_capture` |
| 混音（麥克風+系統） | `POST /api/system-audio/start?with_mic=true` | `MixedAudioCapture`（計時器驅動） |
| 上傳音檔 | `POST /transcribe` | ffmpeg 轉換後 Whisper |

## 關鍵檔案

| 檔案 | 職責 |
|------|------|
| `system_audio_capture.swift` | Swift binary，SCKit 擷取，輸出 16kHz mono int16 PCM |
| `system_audio.py` | 管理 Swift subprocess，RMS silence filter（threshold=500） |
| `system_audio_sc.py` | pyobjc 實作，**只用於 TCC guard check，不用於擷取** |
| `routes.py` | Flask routes，三條音訊管線邏輯 |
| `integrations.py` | Obsidian / Notion 存檔，`[MM:SS]` 逐字稿格式 |
| `package.sh` | 唯一打包入口，含穩定簽名 |
