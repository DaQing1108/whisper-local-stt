# Whisper STT SwiftUI 外殼＋Python AI Core 混合架構評估 v1

- Date: 2026-07-15
- Owner: Alex Liao / VIA AI Learning RD Center
- Scope: Whisper STT macOS desktop app
- Current baseline: v2.3.1, branch `main`
- Document type: Architecture Assessment / Decision Memo
- Status: Draft for decision

## 1. BLUF（結論先講）

Whisper STT 適合進行「SwiftUI 原生外殼＋Python AI Core」的技術驗證，但目前不應直接批准完整遷移，更不應全面重寫成純 Swift App。

建議決策為 **Conditional Go（有條件進入 PoC）**：先用一個獨立 Xcode PoC 驗證 SwiftUI 啟動及管理 Python Worker、音檔轉錄、結構化事件串流、取消、crash recovery、codesign 與 packaged runtime。只有 PoC 通過明確 gate，才進入正式 migration。

推薦的長期邊界如下：

- SwiftUI 負責 macOS App shell、Window、Settings、Menu、權限、麥克風與 ScreenCaptureKit、使用者狀態及 Sparkle。
- Python Worker 負責 Whisper inference、模型快取、文字後處理、Speaker Diarization 與第一階段的 Notion／Obsidian integration。
- Swift 與 Python 以 versioned JSON Lines（JSONL）command/event protocol 溝通；大型音訊只傳 temporary file path，不透過 JSON 傳 binary。
- 第一個正式版本維持單一 Python Worker、單一 active transcription job，不追求 XPC、App Sandbox 或 App Store。

這個方向能解決目前 pywebview／WKWebView、localhost server、權限 patch 與 desktop lifecycle 的主要問題，同時保留已成熟的 Python AI 能力。然而，若 Python runtime 無法被自包含地簽章與發布，或 realtime audio PoC 無法達到現版穩定度，應停止遷移並維持既有架構。

## 2. 文件目的與決策範圍

### 2.1 本文件要回答的問題

1. 哪些責任應搬到 SwiftUI，哪些應留在 Python？
2. Swift／Python 應使用哪一種 inter-process communication（IPC，程序間通訊）？
3. 麥克風、系統音訊、混音、chunking 與 realtime transcript 如何遷移？
4. Python runtime、ML dependencies、Sparkle、codesign 與 notarization 是否可行？
5. 遷移的主要風險、成本、停止條件及驗收標準為何？

### 2.2 讀者應做出的決策

讀完本文件後，決策者應能選擇：

- `Go PoC`：批准最小架構 PoC。
- `Hold`：保留現況，只修正既有 pywebview architecture。
- `No-Go`：目前不投入原生化。

### 2.3 Non-goals

- 本文件不承諾 App Store 上架。
- 本文件不承諾 Universal Binary；現況與初期目標均以 Apple Silicon 為主。
- 本文件不重新設計 Whisper model 或 diarization algorithm。
- 本文件不在本階段修改 production code 或建立正式 Xcode project。
- 本文件不把「UI 看起來原生」當成遷移成功的充分條件。

## 3. 評估方法與證據邊界

本次評估直接檢視目前 Whisper repo 的 source code、packaging script、compiled bundle、test collection 與本機 Xcode／Swift 環境。

已確認事實：

- 主要 app／UI／core 相關程式約 6,584 行；若加上其他 Python module，主要應用程式規模約 7,900 行。
- Pytest 顯示 `237 tests collected`，預設 marker selection 為 `197/237 tests collected (40 deselected)`。
- 現有 `dist/Whisper STT.app` 約 401 MB。
- `bin/system_audio_capture` 與 `bin/ffmpeg` 都是 arm64 Mach-O。
- 本機為 arm64，已安裝 Xcode 26.6、Swift 6.3.3，具備建立 macOS PoC 的條件。
- 現有 strict codesign verification 在 `dist` bundle 上會被 Sparkle nested `Updater.app` 的 `com.apple.FinderInfo` xattr 擋下；這是已知 packaging hygiene 問題，不代表 SwiftUI 方案已通過 release validation。

以下屬於工程估算或建議，而非已驗證成果：

- 時程與人力區間。
- JSONL Worker protocol 的實際 throughput 與 recovery 表現。
- SwiftUI／AVAudioEngine realtime pipeline 的實機穩定度。
- notarization 與正式 distribution 成功率。

上述未知項目必須透過 PoC 或 release experiment 驗證，不能只用 architecture diagram 判定。

## 4. 現況架構

### 4.1 Runtime topology

```text
Whisper STT.app / PyInstaller executable
│
├── gui.py / pywebview
│   ├── WKWebView main window
│   ├── Preferences window
│   ├── microphone permission runtime patch
│   └── spawn same executable --server-mode
│
├── Flask + Waitress on 127.0.0.1:5001
│   ├── HTML / CSS / JavaScript UI
│   ├── REST-like endpoints
│   ├── SSE /events
│   ├── recording session state
│   └── integration endpoints
│
├── Python transcription core
│   ├── ffmpeg conversion
│   ├── mlx-whisper
│   ├── faster-whisper fallback
│   ├── OpenCC / hallucination cleanup
│   ├── LLM post-processing
│   └── pyannote diarization subprocess
│
└── Swift system_audio_capture helper
    └── ScreenCaptureKit -> 16 kHz mono Int16 PCM stdout
```

### 4.2 現況主要資料流

#### 麥克風標準／即時模式

```text
WKWebView getUserMedia
  -> MediaRecorder
  -> WebM / MP4 chunks
  -> multipart upload
  -> Flask routes.py
  -> ffmpeg WAV conversion
  -> Whisper transcription
  -> SSE status/chunk/transcript/done
  -> JavaScript DOM / localStorage
```

標準模式每 10 分鐘 flush；即時模式每 15 秒 flush。JavaScript 負責 `session_id`、`chunk_index`、pending upload、WakeLock、tab lock、錄音 preview 與 UI recovery。

#### 系統音訊／混音模式

```text
JavaScript start request
  -> Flask route
  -> Python SystemAudioCapture
  -> Swift ScreenCaptureKit helper
  -> raw 16 kHz mono PCM stdout
  -> Python 15-second WAV chunk
  -> Whisper workers
  -> SSE event stream
```

混音模式另外以 Python `sounddevice` 擷取 microphone，再由 Python 對 system PCM 與 mic PCM 做混音。

#### 上傳音檔

```text
HTML file input / drag and drop
  -> multipart upload
  -> temp file
  -> ffmpeg
  -> 30-minute inference chunks
  -> transcript / segments / optional diarization
```

### 4.3 現況責任交錯

目前並非乾淨的「Web UI＋獨立 Core」：

- `whisper_core.py` 直接 import 並呼叫 `sse.broadcast`，Core 仍依賴 UI transport。
- `routes.py` 同時負責 transport、session domain state、thread scheduling、LLM finalize 與 integration orchestration。
- `static/app.js` 不只是 view；它持有重要 recording state machine。
- `gui.py` 不只是 shell；它負責 port cleanup、server process、permission patch 與 Preferences bridge。
- frozen App 的 inference 路徑會優先尋找 system Python 中的 `mlx_whisper`／`faster_whisper`，因此目前「bundle 完全自包含」的假設需要重新驗證。

這些交錯是 hybrid migration 的主要工程內容；只重畫 SwiftUI 畫面無法完成遷移。

## 5. 為什麼值得評估 SwiftUI 外殼

### 5.1 可直接改善的問題

SwiftUI／AppKit shell 可以直接改善：

- 不再需要 pywebview 的 WKWebView microphone permission runtime patch。
- 不再需要 main UI 依賴固定 localhost port。
- Window、Settings、Menu、keyboard shortcut、file picker、alerts 與 app termination 回歸 macOS lifecycle。
- ScreenCaptureKit 與 AVAudioEngine 可由同一個 app process 管理 TCC identity。
- Sparkle 可用官方 Swift／Objective-C integration，不再經 PyObjC bridge。
- UI state 可用 Swift concurrency 與 observable state 明確建模。
- recording 與 worker crash 可以在 native process supervisor 中處理。

### 5.2 不會自動改善的問題

SwiftUI 不會自動解決：

- Whisper model 體積與首次下載時間。
- Python runtime／native wheels 的 bundle size。
- MLX、CTranslate2、onnxruntime、pyannote 的簽章與相容性。
- 長音檔 inference latency。
- LLM／Notion 網路錯誤。
- diarization 的 heavyweight dependency。
- 不完整的 cancellation semantics。

因此，不應以 bundle 變小或效能大幅提升作為 SwiftUI migration 的主要商業理由。

## 6. 目標架構

### 6.1 推薦 topology

```text
Whisper STT.app (SwiftUI / AppKit)
│
├── AppShell
│   ├── WindowGroup / Settings
│   ├── MenuCommands / keyboard shortcuts
│   ├── NSOpenPanel / alerts / notifications
│   └── Sparkle updater
│
├── AudioService
│   ├── AVAudioEngine microphone capture
│   ├── ScreenCaptureKit system audio
│   ├── optional mic + system mixer
│   ├── 16 kHz mono PCM normalization
│   └── chunk / temp WAV writer
│
├── AppState + SessionCoordinator
│   ├── recording state machine
│   ├── transcription job state
│   ├── cancellation / retry
│   └── persistence / history
│
└── WorkerSupervisor
    ├── spawn signed Python Worker
    ├── JSONL stdin commands
    ├── JSONL stdout events
    ├── stderr structured logs
    ├── heartbeat / timeout
    └── crash restart policy
          │
          └── Python Worker
              ├── transcription_service.py
              ├── whisper_core.py
              ├── text post-processing
              ├── diarization
              └── integrations
```

### 6.2 Process ownership

初期建議固定兩個主要 process：

1. Swift App process：所有 UI、TCC、錄音與 lifecycle。
2. Python Worker process：所有 AI 工作與第一階段 integrations。

不要在第一階段增加 XPC service、multiple worker pool 或 distributed queue。現有 `_transcribe_sem = Semaphore(1)` 已表明產品目前只允許一個 inference task 使用 Neural Engine；先保留這個限制可降低 migration 風險。

### 6.3 Source of truth

- Recording state：Swift `SessionCoordinator`。
- Active job state：Swift 與 Worker 以 `job_id` 對齊；Worker 是 inference execution truth，Swift 是 user-visible lifecycle truth。
- User settings：Swift `UserDefaults`／Keychain；Worker 啟動時接收非敏感 config，敏感 token 透過受控 config file 或 Keychain handoff，待 PoC 決定。
- Model cache：保留既有 Python／Hugging Face／MLX cache，路徑需顯式化。
- Transcript files：`~/Library/Application Support/WhisperSTT/`，沿用既有資料目錄並定義 migration schema。

## 7. 模組遷移矩陣

| 現有區域 | 目前責任 | 目標責任 | 決策 | 難度 | 主要原因 |
|---|---|---|---|---:|---|
| `gui.py` | pywebview、server lifecycle、permission patch | Swift AppShell／WorkerSupervisor | Replace | 中 | 原生化核心價值所在 |
| `templates/*` | main UI／Preferences | SwiftUI views | Replace | 中高 | UI 元件多但 domain 可保留 |
| `static/app.css` | responsive／theme | SwiftUI design tokens | Replace | 中 | 視覺可轉譯，不宜逐行搬 |
| `static/app.js` | UI＋錄音＋session state | Swift AppState／AudioService | Redesign | 高 | 不是單純 view logic |
| Flask app | local HTTP transport | JSONL Worker protocol | Phase out | 中高 | 先保留 dev adapter，再移除 production dependency |
| `routes.py` | transport＋domain orchestration | Python service layer＋command handlers | Refactor | 高 | 目前最重的耦合點 |
| `sse.py` | UI event broadcast＋semaphore | EventSink interface＋Worker event emitter | Replace | 中 | Core 不應知道 SSE |
| `whisper_core.py` | conversion／inference／progress | Python Worker Core | Keep + decouple | 中 | 成熟資產，但需移除 transport dependency |
| `transcribe_common.py` | cleanup／hallucination | Python Worker Core | Keep | 低 | 純 domain logic |
| `llm_post.py` | LLM punctuation | Python Worker | Keep | 低 | Python ecosystem 合理 |
| `diarize.py` | pyannote subprocess | Python Worker child process | Keep | 中 | 重依賴，不適合 Swift 重寫 |
| `integrations.py` | Notion／Obsidian | Python Worker first; reassess later | Keep first | 低中 | 與 UI 無強耦合 |
| `system_audio_capture.swift` | ScreenCaptureKit helper | Swift `AudioService` | Merge / rewrite | 中高 | 可消除 helper TCC／signing 邊界 |
| `system_audio.py` | helper wrapper＋mic mix | Swift `AudioService`; keep WAV utility only if needed | Replace | 高 | 音訊 timing 與 mixed capture 高風險 |
| `sparkle_updater.py` | PyObjC Sparkle bridge | Swift Sparkle | Replace | 中 | 官方 integration 更自然 |
| `gui.spec` | PyInstaller whole app | Worker packaging only | Redesign | 高 | distribution 成敗關鍵 |
| `package.sh` | build／sign／install | Xcode archive＋Worker embed＋sign verify | Redesign | 高 | 需建立正式 release pipeline |

## 8. IPC 選型

### 8.1 選項比較

| 選項 | 優點 | 缺點 | 適用階段 | 結論 |
|---|---|---|---|---|
| localhost Flask＋SSE | 可重用現有 routes，PoC 快 | port、HTTP server、lifecycle 問題保留 | 非正式探索 | 不作長期方案 |
| subprocess stdin/stdout JSONL | 無 port、易觀察、跨語言、可測試 | 需自行定義 framing、heartbeat、backpressure | PoC＋v1 | 推薦 |
| Unix domain socket | 支援雙向長連線與多 client | lifecycle、socket cleanup、權限更複雜 | 後期需要時 | 暫不採用 |
| XPC | macOS 安全與 lifecycle 最完整 | Python bridge、code signing、interface complexity 高 | App Store／sandbox 階段 | 暫不採用 |
| Embedded Python | 呼叫延遲低 | GIL、runtime linking、crash isolation、signing 複雜 | 不符合目前隔離需求 | 不建議 |

### 8.2 推薦：JSONL subprocess protocol

每行一個 UTF-8 JSON object；stdout 僅允許 protocol event，所有 human log 改走 stderr。Swift 端以 actor 或 dedicated task 序列化寫入，並逐行解析 stdout。

Command envelope：

```json
{"v":1,"type":"command","id":"cmd-001","job_id":"job-001","name":"transcribe_file","payload":{"path":"/tmp/input.wav","model":"large-v3","language":"zh","domain":"general"}}
```

Event envelope：

```json
{"v":1,"type":"event","id":"evt-001","reply_to":"cmd-001","job_id":"job-001","name":"progress","payload":{"completed":1,"total":4,"text":"..."}}
```

Terminal event：

```json
{"v":1,"type":"event","job_id":"job-001","name":"completed","payload":{"text":"...","language":"zh","segments_path":"/tmp/job-001-segments.json"}}
```

Structured error：

```json
{"v":1,"type":"event","job_id":"job-001","name":"failed","payload":{"code":"MODEL_LOAD_FAILED","message":"模型載入失敗","retryable":true}}
```

### 8.3 Protocol 必要能力

- `hello`／capability negotiation。
- protocol version mismatch fail-fast。
- `transcribe_file`、`transcribe_chunk`、`finalize_session`。
- `warmup_model`、`model_status`。
- `cancel_job`。
- `progress`、`partial_transcript`、`completed`、`failed`。
- heartbeat 或 supervisor-side liveness timeout。
- idempotency：重送 command 不得重複產生不可逆 integration write。
- backpressure：Swift 不得無限制送入 chunks。
- graceful shutdown；逾時才 SIGTERM／SIGKILL。
- stdout protocol contamination test。

### 8.4 大型資料傳遞

- Audio：temporary WAV／CAF file path。
- Segment list：小型可 inline；大型寫 JSON file 並傳 path。
- Model：只傳 model identifier，不傳 binary。
- Secrets：不得出現在 command log；PoC 先排除 Notion／LLM write。

## 9. Python Core 解耦設計

### 9.1 必要重構

在連接 SwiftUI 前，先建立 transport-independent service layer：

```python
class EventSink(Protocol):
    def emit(self, name: str, payload: dict) -> None: ...

class CancellationToken(Protocol):
    def is_cancelled(self) -> bool: ...

class TranscriptionService:
    def transcribe_file(self, request, sink, cancellation) -> Result: ...
```

Flask／SSE adapter 與 JSONL Worker adapter 都呼叫同一個 `TranscriptionService`。這讓 migration 期間舊 UI 與新 Swift PoC 可並行驗證，避免 fork 兩套 inference logic。

### 9.2 必須移除的耦合

- `whisper_core.py -> sse.broadcast`。
- `routes.py` 內的 session dict 作為唯一 domain model。
- `routes.py` thread creation 與 domain logic 混合。
- integration write 由 `done` UI event 隱式觸發。

### 9.3 Cancellation 現況缺口

目前大多數 Python inference 透過 blocking `subprocess.run(..., timeout=7200)` 或 in-process model call 執行，沒有完整 cooperative cancellation。Swift UI 即使送出 `cancel_job`，若 Worker 無法終止 child process，就只能等待或殺掉整個 Worker。

PoC 至少需要：

- 將長時間 inference 改為 `Popen` 管理 child PID。
- cancel 時先 terminate，再於 grace period 後 kill。
- 清理 temporary audio／WAV／segment files。
- Worker 被殺後能重新啟動並接受下一個 job。

這是 Go／No-Go 的必要條件，而非後續 polish。

## 10. Audio pipeline 遷移

### 10.1 麥克風

建議使用 `AVAudioEngine` input tap，由 Swift 統一轉為 16 kHz mono PCM，按模式寫入 temporary WAV chunks。

需要驗證：

- 實際 hardware sample rate 44.1／48 kHz 的 resampling。
- input route change、Bluetooth headset、USB microphone、sleep／wake。
- permission denied／revoked。
- interruption 與 device disconnect recovery。
- 10-minute standard chunk 與 15-second live chunk 的邊界。
- 長時間錄音 memory 是否常數成長。
- preview audio 是否要另外保留原始品質檔。

現況 Web MediaRecorder 使用 WebM／Opus 或 MP4，之後再用 ffmpeg 轉 WAV。原生 capture 可直接產生 PCM/WAV，理論上能降低格式不確定性，但會增加本地檔案 I/O，需要實測。

### 10.2 系統音訊

將 `system_audio_capture.swift` 合併進主 App 的 `AudioService`，由相同 bundle identity 管理 ScreenCaptureKit。保留現有 16 kHz mono output contract，可降低 Python Core 變更。

需要修正或明確決策：

- 現有 helper 同時加入 `.audio` 與 `.screen` output，只實際處理 audio；新實作應確認是否仍需 screen output 才能維持 capture lifecycle。
- `excludesCurrentProcessAudio = false` 代表 App 自身音訊也會被擷取；需確認產品是否需要避免回授。
- display selection 現在固定第一個 display；新 UI 是否需要選擇 display／application audio。
- ScreenCaptureKit API 的 macOS minimum version 與 fallback。

### 10.3 混音

目前混音由 Python `sounddevice` 擷取 mic，再做 PCM sample addition。原生方案應由 Swift 同時管理 microphone 與 system audio，對齊 timestamps／sample rate 後混音。

這是 audio migration 最高風險區：

- 兩路 clock drift。
- 不同 buffer size。
- sample alignment。
- clipping／gain control。
- Bluetooth latency。
- mute／device change。

建議 Phase 1 只做 microphone-only 與 system-audio-only；mixed capture 必須獨立 PoC，不可與第一個 shell migration 綁在一起。

### 10.4 Recording state machine

Swift 端應明確定義：

```text
idle
  -> requestingPermission
  -> preparing
  -> recording
  -> stopping
  -> flushing
  -> transcribing
  -> postProcessing
  -> completed

任何階段 -> failed
recording/transcribing -> cancelling -> idle
```

每個 transition 都應有唯一 owner、timeout、cleanup 與 UI mapping。不要把布林值 `isRecording`、pending chunks 與 modal state 分散在多個 View。

## 11. Settings、資料與整合遷移

### 11.1 Settings

- 非敏感偏好：Swift `UserDefaults`。
- API keys：建議搬到 Keychain；在完成安全設計前，不應從 `.env` 直接複製進 command payload。
- Python Worker 所需設定：啟動時使用最小環境變數或 permissions-restricted config file。
- 舊 `.env`：提供一次性 migration 或持續 read-only fallback，避免使用者設定消失。

### 11.2 History 與 session recovery

現況部分資料放在 WKWebView `localStorage`。SwiftUI migration 必須定義資料遷移：

- 最近設定。
- 詞庫。
- transcript history。
- onboarding flags。
- interrupted session metadata。

建議 v1 使用 Codable JSON file；若 history 需求擴大，再評估 SwiftData。不要為少量設定過早導入 database migration。

### 11.3 Notion／Obsidian／LLM

第一階段保留 Python implementation，降低 scope。正式切換前需把 integration action 改為明確 command，並加入 idempotency key，避免 UI retry 重複寫入 Notion／Obsidian。

Keychain handoff、token exposure、network retry 與 integration audit log 應另立 security review；這些功能不得阻擋純 transcription PoC。

## 12. Packaging、Signing 與 Distribution

### 12.1 最關鍵的 packaging 問題

目前 frozen code 會先搜尋 `/opt/homebrew/bin/python3`、`/usr/local/bin/python3`、`/usr/bin/python3` 是否可 import `mlx_whisper`／`faster_whisper`，再 fallback 到 bundled in-process dependency。這代表目前 runtime 行為可能依賴使用者電腦上的 Python environment。

Hybrid App 不應延續這種不確定性。正式發佈必須選擇並驗證：

1. 自包含的 Worker executable（PyInstaller／Nuitka 等）。
2. App bundle 內固定 Python runtime＋site-packages。
3. 首次啟動下載受版本鎖定的 runtime（不建議作第一版）。

推薦先比較 1 與 2，禁止 production Worker fallback 到任意 system Python。

### 12.2 Bundle layout 建議

```text
Whisper STT.app/
  Contents/
    MacOS/Whisper STT
    Frameworks/
      Sparkle.framework
      Python.framework or worker native libs
    Resources/
      Worker/whisper-worker
      bin/ffmpeg
      Models/optional manifests
```

Worker 與所有 nested native libraries 必須 individually sign，再簽 outer app。Build script 需在簽章前清除 xattr，並在最後執行 `codesign --verify --deep --strict`。

### 12.3 Hardened Runtime 與 notarization

PoC release track 必須實驗：

- Developer ID Application certificate。
- Hardened Runtime。
- microphone 與 screen capture usage descriptions。
- Python／JIT 相關 entitlement 是否必要。
- nested frameworks 與 Sparkle helper signing order。
- `notarytool submit` 與 stapling。
- Gatekeeper fresh-machine test。

若 packaged Python dependency 需要不可接受的 `disable-library-validation` 或 unsigned executable memory entitlement，必須列為架構阻塞，不能以 local ad-hoc signing 通過代替。

### 12.4 App Sandbox／Mac App Store

目前 `tools/entitlements.plist` 明確為 non-sandbox。Notion、Obsidian 任意資料夾、模型 cache、Python child process 與 Sparkle 都讓 App Store sandbox 成為另一個大型專案。

建議：

- Hybrid v1 以 direct distribution＋Developer ID＋notarization 為目標。
- App Store 可行性另立 Phase 4 study，不納入目前 Go decision。

### 12.5 Architecture support

現有 helper 與 ffmpeg 為 arm64，MLX 也以 Apple Silicon 為主要價值來源。v1 應明確宣告 Apple Silicon only。若要 Universal Binary，Python wheels、ffmpeg、Sparkle、CTranslate2 與所有 native libraries 都必須重新驗證，成本不可忽略。

## 13. Security 與可靠性

### 13.1 Threat boundaries

移除 localhost server 可降低本機 HTTP endpoint 暴露面，但新增 Swift／Worker command boundary。必要控制：

- Worker 只接受 parent process pipe，不開 network listener。
- input path 必須 canonicalize 並限制允許位置／temporary directory policy。
- 不把 token、音訊內容或 transcript 寫入一般 log。
- command schema 嚴格驗證。
- output file permissions 使用 user-only。
- integration write 必須明確 user action 或 policy，而非 Worker restart 自動重送。

### 13.2 Crash model

- Swift crash：Worker 收到 pipe EOF 後自動終止，不能成為 orphan。
- Worker crash：Swift 顯示 structured failure、保留錄音檔、允許重啟 Worker。
- Inference child crash：Worker 回傳 failure，不跟著退出；若 native crash 污染 process，supervisor 重啟。
- Audio capture error：停止 capture、flush 可用資料、保留 recovery file。

### 13.3 Observability

至少分三種 log：

- App lifecycle log。
- Worker protocol／job log（不含 transcript content）。
- inference diagnostic log。

每個 job 使用 `job_id` 串接。提供「匯出診斷資料」時需預設移除 API key、音訊與完整逐字稿。

## 14. 測試策略

### 14.1 保留現有 Python tests

先將 Flask adapter 測試與 domain service 測試分離。現有 transcript cleanup、LLM、integration、system audio concurrency 與 endpoint tests 不應直接丟棄。

### 14.2 新增 Python Worker tests

- command schema parsing。
- protocol version mismatch。
- stdout 每行皆為合法 JSON。
- progress／completed／failed event ordering。
- cancellation terminates child process。
- temp file cleanup。
- worker restart after crash。
- duplicate command id／integration idempotency。

### 14.3 Swift tests

- `SessionCoordinator` state transition unit tests。
- JSONL codec tests。
- WorkerSupervisor process lifecycle tests。
- fake worker integration tests。
- audio format conversion tests。
- permission mapping tests。
- settings migration tests。

### 14.4 End-to-end tests

E2E 應至少包含：

1. 音檔選取 -> transcript completed。
2. model missing -> download／error guidance。
3. transcription cancel -> child terminated -> next job succeeds。
4. Worker crash -> UI recovery -> retry succeeds。
5. microphone standard recording。
6. 30 分鐘以上 chunk ordering。
7. system audio permission denied／granted。
8. mixed capture drift and clipping。
9. Sparkle check path。
10. signed／notarized clean-machine launch。

### 14.5 Dual-run golden comparison

PoC 與 migration 期間，同一組固定音檔同時跑現版與 Worker service，至少比較：

- transcript text／Character Error Rate（CER，字元錯誤率）。
- detected language。
- segment count 與 timestamp tolerance。
- Traditional Chinese conversion。
- hallucination filtering。
- processing time。
- peak memory。

UI 改寫不能造成 transcript quality regression。

## 15. 分階段 Roadmap

### Phase 0：Core seam preparation

目標：在不改變現有 App 行為下，建立 transport-independent `TranscriptionService`。

交付：

- EventSink abstraction。
- cancellation abstraction。
- session model 從 Flask route 抽離。
- 現有 Flask adapter 全測試通過。

停止條件：無法在不大量改寫 inference 的情況下移除 SSE coupling。

估算：1–2 週。

### Phase 1：File transcription PoC

目標：SwiftUI App 啟動 packaged Worker，選取音檔並取得 transcript。

交付：

- Xcode PoC target。
- JSONL v1 protocol。
- WorkerSupervisor。
- file transcription／progress／cancel／restart。
- local signed bundle。

停止條件：Worker 無法穩定自包含、取消無法清理、stdout protocol 不可靠。

估算：2–3 週；若先做 Phase 0，部分工作可重疊但不應跳過驗證。

### Phase 2：Native microphone beta

目標：AVAudioEngine 取代 Web MediaRecorder，支援 standard／live mode。

交付：

- microphone permission。
- PCM/WAV chunk writer。
- state machine。
- long recording／device change tests。

停止條件：長時間錄音、chunk ordering 或 device recovery 低於現版。

估算：2–4 週。

### Phase 3：System audio、mixed capture 與 feature parity

目標：整合 ScreenCaptureKit、混音、Settings、history、Notion／Obsidian、diarization、Sparkle。

估算：4–8 週，取決於 mixed capture 與 packaging。

### Phase 4：Release hardening

目標：Developer ID、Hardened Runtime、notarization、Sparkle update、clean-machine validation、migration／rollback。

估算：2–4 週。

總體 realistic estimate：單一熟悉 Swift 與現有 Python codebase 的工程師約 10–18 週；若需邊維護現版、補 App Store sandbox 或重新設計完整 UI，可能擴大至 4–6 個月以上。這是估算，應在 Phase 1 後重新校準。

## 16. Go／No-Go Decision Gates

### Gate A：Core isolation

必須全部成立：

- Python transcription service 不再依賴 Flask／SSE。
- 舊 Flask UI 仍可透過 adapter 正常運作。
- 既有 Python test suite 無品質回歸。

### Gate B：Worker feasibility

必須全部成立：

- Swift 可啟動／關閉／重啟 Worker。
- progress、completed、failed 事件順序穩定。
- cancellation 可在可接受時間終止 inference child。
- Worker crash 後下一個 job 可成功。
- 不依賴任意 system Python。

### Gate C：Distribution feasibility

必須全部成立：

- Worker 與 native dependencies 可簽章。
- `codesign --verify --deep --strict` 通過。
- notarization 與 stapling 通過。
- clean Apple Silicon Mac 無開發環境亦可執行。
- Sparkle update 不破壞 Worker／model cache／settings。

### Gate D：Audio parity

必須全部成立：

- microphone standard／live mode 達到現版穩定度。
- system audio permission 與 capture 穩定。
- 30 分鐘以上錄音順序正確且 memory 受控。
- mixed capture 若未通過，可明確延後而不阻擋其他模式 release。

### Gate E：Product value

至少成立兩項：

- crash／startup／permission support burden 明顯下降。
- packaging／release steps 可重複自動化。
- native feature roadmap 確實需要 menu bar、global shortcut、background capture 或更深系統整合。
- 使用者體驗提升足以支持 10–18 週工程投資。

若只有視覺改善，建議 No-Go。

## 17. 主要風險登錄

| 風險 | 機率 | 影響 | 緩解方式 | Gate |
|---|---|---|---|---|
| Python runtime 無法乾淨 notarize | 中高 | 高 | Phase 1 優先做 packaged worker experiment | C |
| 仍依賴 system Python | 高（現況） | 高 | 禁止 production fallback，固定 runtime | B/C |
| inference 無法取消 | 高（現況） | 高 | Popen child ownership＋kill policy | B |
| Core 與 SSE／routes 耦合 | 高（現況） | 中高 | Phase 0 service seam | A |
| mixed audio clock drift | 中高 | 高 | 獨立 PoC、延後 release | D |
| SwiftUI rewrite 遺漏 JS state behavior | 中 | 高 | state inventory＋dual-run E2E | D |
| bundle size 沒有明顯下降 | 高 | 中 | 不把 size 當主 KPI | E |
| local history／settings 遺失 | 中 | 中高 | migration test＋rollback | D |
| Notion retry 重複寫入 | 中 | 高 | idempotency key＋explicit action | B |
| Sparkle nested signing／xattr 問題 | 中高 | 高 | deterministic signing pipeline | C |
| Swift／Python 雙棧維護成本上升 | 高 | 中高 | 清楚 ownership、generated schema、少量 IPC | E |

## 18. 建議的最小 PoC 規格

### 18.1 Scope

PoC 只做：

- SwiftUI 單一視窗。
- `NSOpenPanel` 選擇一個音檔。
- 啟動 packaged Python Worker。
- 選擇既有 model／language。
- 顯示 progress 與 partial transcript。
- 完成後顯示 final transcript。
- Cancel。
- 模擬 Worker crash 並重新啟動。
- 產生可簽章的 `.app`。

### 18.2 Explicit exclusions

- microphone。
- ScreenCaptureKit。
- mixed audio。
- Notion／Obsidian write。
- diarization。
- Sparkle update UI。
- full production visual design。

### 18.3 Acceptance criteria

1. 同一音檔連續執行 10 次，10 次完成且無 orphan Worker。
2. 轉錄中取消 5 次，child process 均在 5 秒內退出，temp file 清理完成。
3. 強制 kill Worker 後，Swift 於 3 秒內顯示錯誤並可重新執行下一個 job。
4. stdout 100% 為合法 JSONL；stderr 不影響 protocol。
5. transcript 與現版 golden result 無非預期品質差異。
6. packaged App 不依賴 Homebrew／system Python。
7. strict codesign 通過；正式 Go 前再要求 notarization。
8. PoC peak memory 與時間相對現版不得惡化超過 20%，或需有可接受原因。

### 18.4 PoC stop conditions

- 必須依賴使用者預先安裝 Python／Homebrew。
- Worker native dependencies 無法以可接受 entitlement 簽章。
- cancel 只能殺整個 Swift App。
- crash recovery 造成 audio／transcript data 無法保留。
- 需要先重寫 Whisper inference 才能建立 IPC。

## 19. Rollback 與並行策略

- 新 Swift App 使用獨立 target／folder，不直接取代現有 `gui.py`。
- Phase 0 Core refactor 必須讓既有 Flask UI 持續可用。
- Swift beta 與 v2.3.x production build 並行，bundle identifier／user data schema 需避免互相破壞。
- settings migration 採 copy-once，不刪除舊 `.env`／localStorage export，直到新版完成驗收。
- 每個 phase 都可回到現有 pywebview release；不得在 Gate C／D 通過前停止維護現版。

## 20. 最終建議

建議批准 Phase 0＋Phase 1，但把它們視為 architecture experiment，而非已承諾的 product rewrite。

優先順序應是：

1. 抽離 Python `TranscriptionService` 與 EventSink。
2. 建立 JSONL Worker 與 contract tests。
3. 建立最小 SwiftUI file transcription PoC。
4. 先解決 cancellation、自包含 runtime、codesign 與 crash recovery。
5. 通過 Gate A／B／C 後，再批准 microphone migration。
6. ScreenCaptureKit 與 mixed audio 分開驗證。
7. App Store、Universal Binary 與純 Swift inference 均不納入目前 roadmap。

目前決策：**Conditional Go for PoC；No-Go for full rewrite。**

## Appendix A：目前主要檔案與建議 ownership

| 檔案 | 現況 owner | Hybrid owner |
|---|---|---|
| `gui.py` | Python desktop shell | deprecated after migration |
| `app.py` | Flask runtime | dev／legacy adapter only |
| `routes.py` | Flask＋orchestration | thin legacy adapter |
| `whisper_core.py` | inference core | Python Worker |
| `transcribe_common.py` | text cleanup | Python Worker |
| `system_audio.py` | system/mic capture wrapper | Swift AudioService replaces capture |
| `system_audio_capture.swift` | Swift helper | merged into Swift App |
| `diarize.py` | Python subprocess | Python Worker child |
| `integrations.py` | integrations | Python Worker first |
| `llm_post.py` | LLM post-processing | Python Worker |
| `sparkle_updater.py` | PyObjC bridge | Swift Sparkle replaces it |
| `static/app.js` | Web state machine | specification source during migration |
| `gui.spec` | full app packaging | Worker packaging reference |
| `package.sh` | current release script | replaced by Xcode archive pipeline |

## Appendix B：待確認事項

1. 正式 distribution 是否只支援 Apple Silicon？本文件建議是。
2. 近期產品 roadmap 是否真的需要 menu bar／global hotkey／background agent？這會影響 Product Value Gate。
3. 正式發佈是否要求 Developer ID＋notarization，或只供內部安裝？
4. 是否必須在第一個 SwiftUI beta 保留 mixed capture？本文件建議否。
5. API keys 是否同意從 `.env` 遷移到 Keychain？
6. transcript history 的保留期限、資料格式與隱私要求為何？
7. PoC performance baseline 要使用哪些固定音檔與 model？

## Appendix C：建議驗證命令

```bash
python3 -m pytest --collect-only -q
python3 -m pytest tests/unit tests/integration -q
codesign --verify --deep --strict --verbose=2 "Whisper STT.app"
spctl --assess --type execute --verbose=4 "Whisper STT.app"
xcrun notarytool submit "Whisper-STT.zip" --keychain-profile "notary-profile" --wait
xcrun stapler validate "Whisper STT.app"
```

`spctl` 與 notarization 必須使用正式 Developer ID release artifact 判讀；local development identity 的結果不可當作 production release 結論。
