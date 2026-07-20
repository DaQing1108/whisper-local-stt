# Whisper Legacy vs SwiftUI 功能差距與 Parity 規格 v1

**建立日期：** 2026-07-18  
**風險等級：** L2；涉及 LLM credential、Notion production destination 或資料 migration 時升為 L3  
**起點：** Spec  
**比較對象：** `/Applications/Whisper STT.app`（legacy pywebview）與 `Whisper SwiftUI.app`（SwiftUI + bundled Python Worker）

## 1. BLUF

SwiftUI 版已具備原生 microphone、live、system、mixed capture、device recovery、
bundled Worker、基本 history，以及 Obsidian／Notion 的安全寫入入口；但尚未達到 legacy
App 的完整使用流程。主要缺口位於轉錄後工作區：AI summary、可編輯結果、timeline／segments、
詞庫與 domain prompts、batch upload、多格式 export、audio playback，以及與 legacy 相同的
Obsidian／Notion 會議內容語意。

因此目前正確定位是：**SwiftUI = capture/runtime replacement candidate，不是完整 product
replacement**。在 P0、P1 parity 完成前，legacy App 應繼續保留。

## 2. 比較方法與證據邊界

本規格以 source、UI entrypoint、route、資料模型與 tests 比較，不以按鈕名稱推定功能：

- Legacy：`templates/index.html`、`static/app.js`、`static/preferences.js`、`routes.py`、
  `integrations.py`、`gui.py`。
- SwiftUI：`macos/WhisperApp/Sources/WhisperApp/**`、
  `macos/WhisperApp/Tests/WhisperAppTests/**`、Worker JSONL protocol。
- 現有 Gate／Phase 文件用於確認已驗證的 capture、packaging 與 external blockers。

`完整` 表示使用者路徑與資料語意大致等價；`部分` 表示只有入口或較窄的行為；`缺失`
表示 SwiftUI 尚無對應實作；`刻意停用` 表示安全地 fail closed，不應視為 parity。

## 3. 功能矩陣

### 3.1 Capture 與 transcription runtime

| 功能 | Legacy Whisper STT | SwiftUI | 判定 |
|---|---|---|---|
| 標準麥克風錄音 | Browser `MediaRecorder`、chunk upload | `AVAudioEngine`、16 kHz mono PCM/WAV | 完整；SwiftUI lifecycle 較強 |
| Live mode | Chunk session、SSE、session restore | Ordered WAV chunks、Worker queue、drain | 完整；實作架構不同 |
| System audio | Swift helper subprocess | Native ScreenCaptureKit backend | 完整 |
| Mic + system mixed audio | System mode checkbox | 獨立「混音」模式 | 完整 |
| Device／sleep recovery | 主要依賴 Web stream／session recovery | Bluetooth device change、sleep/wake、bounded recovery | SwiftUI 較完整 |
| 單一音訊／影片上傳 | 支援 | 支援 | 完整 |
| Batch upload | 多檔 `batchTranscribe(files)` | 一次單檔 | 缺失 |
| Model 選擇 | tiny～large-v3；預設 large-v3 | tiny～large-v3；目前預設 base | 部分；預設行為不同 |
| Model cache／warmup 狀態 | `/api/model-status`、`/api/warmup-model` | 首次需要時由 Worker 載入 | 缺少預熱與下載狀態 UX |
| Language | auto／zh／en／ja presets | 自由文字 language code | 功能存在，UX 不等價 |
| Domain prompts | general／media／tech／medical／legal | 無 | 缺失 |
| 本次專有名詞 | active tags + saved vocabulary library | Worker UI 無入口／payload | 缺失 |
| Cancellation | Job cancel endpoint | JSONL cancel | 完整 |
| Worker／backend crash recovery | Flask/subprocess recovery | Worker restart、job loss、capture artifact preservation | SwiftUI 較完整 |

### 3.2 轉錄結果與會議工作區

| 功能 | Legacy Whisper STT | SwiftUI | 判定 |
|---|---|---|---|
| Transcript 顯示 | 可編輯 contenteditable | 可選取的唯讀 Text | 部分 |
| Copy | 專用 copy action | 依 macOS text selection 手動複製 | 部分 |
| Clear current result | 有 | 無 | 缺失 |
| Segment timestamps | 後端保留 Whisper segments | Worker completed payload有 segments，但 Swift model 未保存 | 部分／資料遺失 |
| Timeline | UI tab 存在但標示開發中 | 無 | 兩版皆未完成 product capability |
| Audio playback | Local audio player | 無 | 缺失 |
| Export TXT | 有 | 無 | 缺失 |
| Export Markdown | 有 | 僅透過 Obsidian export | 部分；不是一般檔案 export |
| Export SRT | 有，使用 segments | 無 | 缺失 |
| Progress／diagnostics | SSE modal、status log、timer、waveform | Native ProgressView、Worker diagnostics | 部分；SwiftUI 無 timer/waveform |
| Last transcript restore | `.last_result.json` + browser session | history 存在，但 current workspace 不自動 restore | 部分 |

### 3.3 AI summary 與 knowledge workflow

| 功能 | Legacy Whisper STT | SwiftUI | 判定 |
|---|---|---|---|
| AI meeting summary | Anthropic／OpenAI／local fallback routing | 無 | 缺失 |
| Summary tab | 生成、狀態、provider badge | 無 | 缺失 |
| Summary edit + autosave | 有，`/api/update_summary` | 無 | 缺失 |
| Custom prompt／preset | Preferences 可設定 | 無 | 缺失 |
| Destination-specific summary | Obsidian／Notion 使用不同 prompts | 無 | 缺失 |
| Meeting ID／title continuity | 保存 meeting metadata | history entry 僅 UUID、audio/model/lang/text | 缺失 |
| Obsidian | Transcript + destination AI content，可延續既有 meeting note | 每筆 history 輸出原始 transcript Markdown | **部分；語意不同** |
| Notion | 產生／更新 meeting page 與 Notion-oriented AI content | 對指定 page append transcript blocks | **部分；語意不同** |
| Obsidian plugin local API | `/api/transcribe-sync` | 無 local companion API | 缺失；是否移植需產品決策 |

### 3.4 History、設定與桌面 UX

| 功能 | Legacy Whisper STT | SwiftUI | 判定 |
|---|---|---|---|
| History persistence | Browser localStorage，含 text/lang/segments | Atomic JSON，最多 200 筆 | 完整；SwiftUI storage 較可靠 |
| Restore history item | 可回填目前工作區 | 僅列表顯示 | 缺失 |
| Delete／clear history | 單次 restore、clear all | Store 有 remove，但 UI 無刪除 | 部分 |
| Theme | Light／Dark toggle | 跟隨 macOS system appearance | 原生替代，不必照搬 |
| Expanded／regular／compact modes | 有 | Native scrollable window | 部分；需依實際視窗需求決定 |
| Keyboard shortcut | 至少 `⌘U` upload | 無明確 command/menu | 缺失 |
| Preferences window | 獨立頁面，整合各 credentials/settings | Main view DisclosureGroup | 部分 |
| Notion credential | `.env`/config flow | Keychain | SwiftUI 安全性較佳 |
| LLM／HF credentials | Preferences 可保存與 health check | 無 | 缺失；diarization 因 runtime 不可用 |
| Update | Legacy update status/check flow | Sparkle seam，但 feed/key/framework 未完成 | 刻意停用／release blocked |
| Diarization | UI + external Python runtime route | Capability check，bundled runtime 無 torch/pyannote | 刻意停用；非 parity |

## 4. 不應直接照搬的 Legacy 行為

以下是 Web／Flask 架構補償機制，不應當成 SwiftUI 缺陷逐項移植：

- SSE reconnect banner、browser tab lock、wake lock、CORS handling。
- Browser localStorage 作為主要 history store。
- Web theme CSS 與三套逐像素 responsive layout。
- 將 Notion、LLM、HF secrets 寫入一般 `.env` 的 UI 流程；SwiftUI 應使用 Keychain。
- 依賴任意 system Python 的 diarization fallback；packaged App 必須維持 self-contained 或明確停用。

## 5. 建議 Parity Baseline

### P0 — 日常轉錄工作流（replacement blocker）

1. 保存完整 completed result：text、language、segments、duration、model、audio path。
2. Current workspace 支援 edit、copy、clear、restore history item。
3. TXT／Markdown／SRT export；SRT 必須使用真實 segments。
4. Audio playback 與目前結果綁定。
5. Language 改為 auto／中文／英文／日文 presets，保留 advanced ISO code。
6. Domain 與 one-shot terminology 支援，protocol 必須 backward compatible。
7. Batch files 以有界 queue 順序執行，可 individual cancel／failure reporting。

### P1 — Meeting intelligence 與發布語意（replacement blocker）

1. 新增 canonical summary model：generated、edited、provider、status、meeting ID/title。
2. Summary generation 不得阻塞或污染 transcript completion。
3. Summary editor 支援 explicit dirty state、atomic persistence 與 retry。
4. Obsidian export 產生 transcript + destination-specific AI meeting note。
5. Notion flow 明確決定「append existing page」或「create child/page」；不得混稱等價。
6. Credential 只存 Keychain；任何 ambiguous network outcome 保留 retry lock。

### P2 — Productivity parity

1. Saved vocabulary library。
2. Model download／warmup status 與首次下載 UX。
3. History search、delete、clear-all 與 retention settings。
4. Native menu commands／keyboard shortcuts。
5. Timer 與可存取的 audio-level indicator；不要求複製 legacy waveform 動畫。

### P3 — 需獨立決策，不阻塞核心 parity

- Obsidian plugin companion API 是否由 SwiftUI hosting local HTTP service。
- Diarization：擴大 bundle、獨立 signed helper，或維持停用。
- Compact layout 是否有真實使用需求。
- Sparkle signed release、rollback 與 external clean-Mac evidence。

## 6. 執行範圍

### 允許修改範圍

- `macos/WhisperApp/**`
- backward-compatible Worker protocol／entrypoint 與對應 tests
- 新的 SwiftUI parity docs、fixtures 與 migration adapters

### 禁止修改範圍

- Legacy production App 的使用行為與 UI
- 現有 JSONL v1 contract 的破壞性變更
- App Store、App Sandbox、Universal Binary、純 Swift inference
- 未經批准的 external publish、Notion production write、credential 建立或資料 migration

### 需要 Alex 核准

- [ ] P0／P1 是否都列為 production replacement blocker
- [ ] Notion 目標語意：append existing page 或 create meeting page
- [ ] AI summary provider priority 與離線 fallback policy
- [ ] Obsidian plugin local API 是否納入 SwiftUI
- [ ] Diarization 的 bundle size／helper tradeoff

## 7. 限制與假設

- SwiftUI 必須繼續使用 bundled Worker，不依賴 Homebrew／arbitrary system Python。
- Capture recovery、finalized WAV preservation、JSONL stdout purity 不得退化。
- Summary、Obsidian、Notion 必須分開保存 source transcript 與 generated content。
- Legacy localStorage 與 `.last_result.json` 不直接視為 SwiftUI migration source；如需 migration，
  必須另寫 schema、dry-run、backup 與 rollback 規格。
- 本規格假設「使用者希望 SwiftUI 最終可取代 legacy 全部日常流程」；若只需要 capture tool，
  P1 可降級為 optional，但必須由 Alex 明確決定。

## 8. 驗收條件

### 正向驗收

- [ ] 同一固定音檔在兩版產生可對照 transcript、language、segments 與 exports。
- [ ] 使用者可在 SwiftUI 完成 record/upload → edit → summary → export/publish 全流程。
- [ ] TXT、MD、SRT read-back 與 UI current result 一致。
- [ ] Obsidian／Notion 輸出內容與選定的產品語意一致，且不重複寫入。
- [ ] App restart 後可恢復 current meeting、summary 與 history metadata。
- [ ] Batch job 的順序、單檔錯誤、cancel 與 terminal states 可觀察。

### 負向驗收

- [ ] 不破壞 standard/live/system/mixed capture 與 device recovery。
- [ ] 不把 AI summary 覆蓋成 source transcript。
- [ ] 不在 log、UserDefaults、history JSON 或 Markdown 寫入 tokens／keys。
- [ ] 不把 unavailable diarization／Sparkle 顯示為可用。
- [ ] 不移除 legacy production fallback，直到 parity sign-off 與 Gate E 都完成。

### 必要驗證

- [ ] Swift unit/integration tests + Python Worker tests。
- [ ] Production bundle build、deep strict signature、quarantine-free installed-path smoke。
- [ ] Fixed audio dual-run golden comparison。
- [ ] Real microphone、system、mixed、Bluetooth device-change regression。
- [ ] Export file read-back；Obsidian temp Vault；Notion mock + private-account manual evidence。
- [ ] Independent review，逐項 mapping 回本規格 AC。

## 9. 停止條件

立即停止並回報 Alex，若需要破壞 JSONL compatibility、導入未通過 packaged-runtime spike 的
重量級 dependency、處理正式 secrets／資料、無法區分 Notion append 是否已成功，或同一
implementation gate 連續三次失敗。

## 10. 建議決策

建議把 P0 + P1 定義為 SwiftUI production replacement baseline；P2 分批交付；P3 個別決策。
若 Alex 同意，下一份文件應是 `P0 Execution Spec`，將 P0 拆成 5–7 個小 checkpoint，依
`engineering-discipline-loop` 實作與驗證，而不是再次以 Phase 3–4 的 broad parity 敘述帶過。
