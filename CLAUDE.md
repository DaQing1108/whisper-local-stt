# Whisper STT — Claude 技術約束

## 絕對不能做（NEVER）

### 1. 不能用 pyobjc 做系統音訊擷取
- **檔案**：`system_audio_sc.py` 存在但只能用來確認 TCC 狀態，不能呼叫 `start_sc_capture()`
- **原因**：libdispatch 內部 assertion 導致 SIGABRT（exit 133），確認於 v1.6.1
- **正確做法**：`routes.py` 的 `system_audio_start` 必須呼叫 `_sa.start_capture(_on_chunk, on_error=_on_tcc_error)`

### 2. 不能用 ad-hoc 簽名主 app bundle
- **原因**：ad-hoc 每次 rebuild hash 都變，macOS TCC 視為新 app，螢幕錄製授權每次失效
- **正確做法**：`package.sh` 步驟 3 必須用 `--sign "WhisperSTT Local"`，不能 `-s -`

### 4. PyInstaller bundle 不能直接 import 重量級 ML 依賴

- **症狀**：`FileNotFoundError`、`ImportError`、`weights_only` 錯誤等，在打包後才出現
- **根因**：pyannote / torch / speechbrain 等套件有複雜的 data files、C extensions、版本耦合，PyInstaller 無法正確打包
- **正確做法**：用 `/usr/bin/python3` subprocess 執行，完全繞開 bundle，結果以 JSON stdout 傳回。參考 `diarize.py` 的 `_DIARIZE_WORKER_SCRIPT` 模式
- **Spike 原則**：引入任何新重量級依賴前，先做最小打包 spike（`pyinstaller --onedir test_import.py`）確認可打包，跑不通就改用 subprocess 模式，不要先實作再除錯

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

### ⚠️ 打包後新功能失敗

```
→ 「source 測試通過」≠「bundle 能跑」，兩者是不同 Python 環境
→ 每次打包後必須在 bundle 環境跑 smoke test 再告知使用者可以測試
→ Smoke test 方式：
     python3 -c "import sys; sys.path.insert(0, '/Applications/Whisper STT.app/Contents/Resources'); <import 新模組>"
   或直接用 flask test client 呼叫新 endpoint
→ 新功能如果引入新依賴，smoke test 必須覆蓋「bundle 裡的那條路徑」
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

## 跨系統整合評估（實作前必做）

任何涉及「讓 Whisper app 與外部系統整合」的任務（Obsidian plugin、Notion、Slack 等），
在寫任何程式碼之前，必須先回答以下五個問題，輸出給使用者確認後才能進入實作：

```
□ 1. 介面約束：兩個系統之間的傳輸格式、安全限制是什麼？
      （CORS origin、Obsidian requestUrl vs fetch、auth header 格式等）

□ 2. 生命週期約束：各元件的存活範圍與依賴關係是什麼？
      （Flask thread 與 GUI 主 thread 的關係、subprocess orphan 行為等）

□ 3. 不可控邊界：哪些東西由 OS / 框架決定，無法改變？
      （macOS TCC 授權、PyInstaller bundle 限制、Whisper ISO 語言代碼等）

□ 4. 最高風險假設：哪個假設一旦錯就要整個重來？
      → 寫 ≤50 行 spike 驗證，通過後才展開完整實作

□ 5. 測試邊界：哪些我能自動驗證，哪些只有使用者能驗證？
      → 現在就標注，不留到交付前才發現
```

**「評估」≠「實作」**：上面五項的輸出是「應不應該做、怎麼做風險最低」，不是程式碼。
Spike 驗證失敗 → 先討論替代方案，不強行繼續。

---

## Claude 測試紀律（每次修改都必須遵守）

### 原則：元件通過 ≠ 功能完成

「每個零件單獨測過」不等於「用戶路徑可以跑通」。必須有 end-to-end 路徑驗證才能說「修好了」。

### discipline-loop Step 8 補充（Whisper 專案專屬）

Step 8 閉環**不能只跑 unit test 就宣告完成**。Whisper 是 PyInstaller bundle 專案，
source 環境測試通過 ≠ bundle 能跑。每次打包後必須在 bundle 環境補做 smoke test：

```
bundle smoke test 最小路徑：
1. 清環境：pkill -f "WhisperAI"; lsof -ti tcp:5001 | xargs kill
2. 啟動 bundle：open -a "Whisper STT" && sleep 10
3. 確認 ping：curl -s http://127.0.0.1:5001/api/ping
4. 呼叫本次改動涉及的 endpoint，確認回傳正常
5. 清環境（收尾）
```

通過後才輸出 `✅ STEP 8 CLOSED LOOP`，才告訴使用者可以測試。

---

### 打包後強制執行清單（缺一不可）

```
1. 先清環境（防止副作用遮蔽問題）：
   pkill -f "WhisperAI" 2>/dev/null
   lsof -ti tcp:5001 | xargs kill 2>/dev/null
   sleep 2

2. 看 log 確認沒有 ERROR（30 秒能省一輪測試）：
   tail -30 ~/Library/Application\ Support/WhisperSTT/whisper_app.log | grep -E "ERROR|WARN|失敗"

3. 送真實 payload 到 transcribe-sync，驗證 endpoint 本身通：
   open -a "Whisper STT" && sleep 10
   curl -s -X POST http://127.0.0.1:5001/api/transcribe-sync \
     -H "Content-Type: application/json" \
     -d '{"audio_b64":"","model":"base","language":"中文"}' | python3 -m json.tool
   # 預期：400 + {"ok":false,"error":"沒有收到音訊"}（語言代碼轉換後不應出現 ValueError）

4. 才告訴使用者可以測試
```

### 我能自動驗證的 vs 必須使用者驗證的

| Claude 能驗（自動化） | 必須使用者驗（人工） |
|----------------------|-------------------|
| server 啟動、存活、API 回應 | 麥克風收音是否正常 |
| 語言代碼轉換邏輯 | 轉錄準確率 |
| base64 編解碼 | 文字插入 note 的位置是否正確 |
| endpoint 回傳格式 | App crash/重啟的實際體驗 |

**每次交付時必須明確說出：「以下 X 項我已驗證，以下 Y 項需要你用真實聲音測試。」**

### 測試後必須清環境

任何用 `kill`、`subprocess`、`Popen` 做的測試，結束後立刻清掉：
```bash
pkill -f "WhisperAI" 2>/dev/null
lsof -ti tcp:5001 | xargs kill 2>/dev/null
```
不清乾淨會留下副作用（orphan server），讓下一輪測試的結果失真。

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
