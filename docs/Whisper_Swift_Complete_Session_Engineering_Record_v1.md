# Whisper Swift 完整 Session 工程紀錄 v1

日期：2026-07-17 至 2026-07-20  
專案：Whisper Swift（SwiftUI shell + bundled Python Worker）  
工作分支：`codex/swiftui-python-poc`  
紀錄性質：完整需求、討論、實作、故障、根因、修正與驗證紀錄；不是摘要  
證據邊界：依本 session 對話、handoff、source code、測試、Gate report、真實裝置操作與安裝版 App 結果整理

## 1. 工作起點與約束

本 session 從 `HANDOFF_CLAUDE_PHASE2_TO_PHASE4_CONTINUATION.md` 的 Phase 2 Checkpoint 2 接手。當時 Phase 0 已完成 transcription core 隔離與 JSONL Worker，Phase 1 已完成 SwiftUI file-transcription PoC，Phase 2 只完成 recording state machine 與 16 kHz mono PCM/WAV writer。後續工作必須依序完成原生 microphone、system audio、mixed audio、settings、history、外部發布、release hardening 與 UI/UX parity。

使用者一開始即鎖定以下操作原則：

- 先檢查 dirty worktree，再重跑既有測試。
- 保留所有既有 tracked／untracked working changes，不 reset、不 clean、不覆寫其他人的工作。
- 開發期間不 commit、不 push、不擴張 scope。
- 每個 checkpoint 要有測試與證據；真實硬體、macOS TCC、外部帳號與公開發布不能用 mock 結果代替。
- Legacy pywebview App 在 Swift 版本通過 replacement gates 前仍是 production fallback。
- Swift 版本繼續使用 Python inference core，並以 bundled Worker 隔離；不把 Whisper inference 全面改寫成 Swift。

## 2. 整體架構決策

### 2.1 為何採用 SwiftUI + Python Worker

現有 Whisper STT v2.4.x 的 Python transcription core 已具有模型選擇、Whisper/faster-whisper/MLX 路由、domain prompt、segments 與既有 regression coverage。全面改寫 inference 會同時增加模型相容性、效能、記憶體與 release 風險。因此決定：

- SwiftUI 負責 macOS 原生 UI、audio capture、狀態管理、history、export、Keychain 與外部整合入口。
- Python Worker 負責 transcription inference。
- 兩者用 versioned JSON Lines（JSONL）protocol 溝通。
- stdout 僅允許 protocol event；diagnostics、Python print 與 traceback 必須送 stderr，避免破壞事件解碼。
- Swift 傳送 audio 的 absolute file path，不透過 stdout 傳 binary audio。

### 2.2 Process 與 failure contract

Worker lifecycle 定義為 startup、`ready`、job `accepted`、progress/status、`completed`／`failed`／`cancelled`。每個 job 有 identity，Swift 端追蹤 request context；Worker crash 時 supervisor 可重啟，但 terminal job 不得被重複完成。Cancellation 以 process ownership 與 cancellable child process 實作，不只取消 UI task。

### 2.3 兩個 App 是否合併

討論中確認 Legacy v2.4.1 與 SwiftUI candidate 功能差異一度很大，不應讓使用者誤以為 SwiftUI 已可直接替代 Legacy。最後決策是維持同一 repository 但兩套獨立產品 identity：

- Legacy／Classic：`Whisper STT`，bundle ID `com.via.whisper-ai`，Python／Web UI。
- Swift candidate：最後簡化名稱為 `Whisper Swift`，bundle ID `com.via.whisper-swiftui`，SwiftUI + bundled Worker。
- 兩者使用不同安裝名稱、Bundle ID 與資料 namespace；Legacy 不被移除。
- 不建立長期 diverged 的 classic-main／swift-main；共用 transcription core 需同時跑相容性測試。
- 正式取代只可發生在 P0/P1 parity、Gate D 與 Gate E 外部證據完整後。

## 3. Phase 0：Transcription core 與 Worker 隔離

### 3.1 原問題

Legacy transcription 流程和 Flask/SSE、route 狀態與 GUI lifecycle 耦合。SwiftUI 若直接啟動舊 server，會繼續依賴 web runtime，無法建立清楚的 process ownership、cancel、crash restart 與 packaged-runtime boundary。

### 3.2 實作

建立：

- `transcription_service.py`：transport-independent request/result API。
- `transcription_jobs.py`：job identity 與 terminal state。
- `transcription_events.py`：事件輸出抽象。
- `worker_protocol.py`：versioned JSONL command/event schema。
- `worker_entrypoint.py`：standalone Worker runtime。
- `cancellable_process.py`：hard cancellation 與 child process ownership。
- `model_runtime.py`：模型 runtime/cache status。
- Legacy Flask adapter：舊 route 仍能呼叫新的 transcription service。

### 3.3 遇到的問題與解法

1. Python inference 會在 stdout 印 diagnostic，污染 JSONL。
   - 解法：在 Worker job 執行時 redirect Python stdout 至 stderr；JSONL emitter 獨佔 stdout。
2. UI cancel 不代表模型 child process 已停止。
   - 解法：建立可取消 process abstraction，追蹤 child，cancel 時終止 process group／child，並保證只送一次 terminal event。
3. Worker crash 後 pending job 容易失去狀態。
   - 解法：Swift supervisor 維護 request context，偵測 EOF／termination，將 active job 轉為可解釋失敗，再依 policy restart Worker。
4. packaged App 可能意外使用 system Python/Homebrew。
   - 解法：以 PyInstaller frozen Worker 建置，Swift production discovery 只尋找 bundle Resources 內 Worker；isolated `HOME`、minimal `PATH` smoke 驗證不依賴任意 Python。

### 3.4 Gate A 結果

Core isolation、Legacy adapter 與 protocol tests 通過；Gate A 允許進入 SwiftUI PoC，但 microphone、system audio、Sparkle、notarization 均仍不在此 Gate 內。

## 4. Phase 1：SwiftUI shell 與 file transcription

### 4.1 實作

建立 native macOS Swift package/application、`WorkerSupervisor`、file picker、轉錄進度、取消、Worker diagnostics 與 crash restart。建立 `scripts/build_worker_runtime.sh`、`worker.spec`、bundle verifier 與 Swift app build pipeline。

### 4.2 Packaging 問題

1. 深度重簽 PyInstaller internals 後 Worker 啟動失敗。
   - 根因：對 frozen runtime 內部檔案做不適當 deep re-sign 破壞其執行結構。
   - 解法：保留 Worker artifact 結構，簽外層 App bundle；最終 bundle 仍以 `codesign --verify --deep --strict` 驗證 Resources seal。
2. App 放在 synced Documents/File Provider 路徑時附帶 Finder metadata，可能觸發 App Translocation 或簽章差異。
   - 解法：安裝到穩定的 `~/Applications` 路徑；清除 quarantine/FinderInfo，再在「最終安裝位置」執行 strict verification，而不是只驗 staging artifact。
3. 使用者啟動 App 曾出現「被丟入垃圾桶」或無法啟動。
   - 解法：重新檢查 bundle integrity、xattr、FinderInfo 與簽章；重新封裝並在最終路徑驗證。這是 local signed development build，不等同 Developer ID/notarized public app。

### 4.3 Gate B 結果

Swift shell、bundled Worker、file transcription、event decoding、cancel、crash restart 與 production discovery 通過；外部 notarization 等 release exceptions 保留。

## 5. Phase 2：原生麥克風 Standard／Live Mode

### 5.1 Checkpoint 2 起點

接手時已存在 recording state machine 與 WAV writer，但尚無完整 microphone permission mapping、injectable `AVAudioEngine` service 與真實裝置 recovery。

### 5.2 實作內容

- `MicrophoneCaptureService` 封裝 `AVAudioEngine`，將硬體輸入轉為 16 kHz、mono、signed PCM Int16。
- `StandardRecordingController`：開始、停止、先 finalize WAV，再把 absolute path 交給 Worker。
- `LiveRecordingController`：預設每 15 秒 rotation，建立 ordered finalized chunk queue。
- submission queue 嚴格串行送 Worker，前一 chunk terminal 後才送下一個。
- stop 時進入 drain 狀態，全部剩餘 chunk 完成後才顯示 idle/completed。
- device change 與 sleep/wake 觸發 recovery：先 finalize active chunk，再建立新 capture generation。
- 空的 header-only WAV 可清理；含 audio payload、非 terminal 或 recovery artifact 一律保留。

### 5.3 真實 Bluetooth device-change 長時間除錯

使用者多次依指示在 `MacBook Pro Microphone` 與 `soundcore AeroFit Pro` 間切換。早期現象包括：

- device change 後錄音卡住或沒有 recovery evidence。
- 舊 AVAudioEngine callback 在新 session 開始後仍回來，污染新的 generation。
- teardown 與 MainActor lifecycle 交錯，engine 尚未完全停止就建立新 engine。
- 使用 iPhone microphone 時 macOS 拒絕切換，不能算成功的 device-change evidence。

最終修正：

- 統一 teardown 路徑，不讓 stop、device change、sleep recovery 各自做一套不一致清理。
- callback gate 追蹤 generation，stale callback 直接丟棄。
- recovery 前 drain callback，避免舊 tap 繼續寫入。
- 每次 recovery 建立全新的 `AVAudioEngine`，不重用狀態不明的 engine。
- 舊 engine 延後在 MainActor 之外 retire，避免 teardown 阻塞新 capture。

真實驗證結果：由內建麥克風切到 `soundcore AeroFit Pro` 時，controller finalize recovery chunks、恢復 `Live recording`，Worker 完成轉錄；chunk 為非空 WAV（約 424–472 KB），沒有新 crash report。sleep/wake 也可持續增加 finalized chunk，停止後能 drain 至 Completed。

### 5.4 長錄音與比較

- 自動模擬 120 chunks，確認沒有遺失或重新排序。
- 以固定 5.4735 秒 macOS TTS WAV 比較 Legacy 與 packaged Worker：兩者文字幾乎相同，差異只有 `fixed`／`Fixed` 大小寫。
- Legacy 約 4.980 秒、peak RSS 470,482,944 bytes；Worker 約 3.923 秒、597,000,192 bytes。
- 此結果顯示 Worker 在該 cold synthetic run 約快 21%，但 peak memory 約高 27%；它不是完整真人語音品質評測。

### 5.5 Gate D 結果

Standard、Live、chunk ordering、長錄音、sleep/wake 與真實 Bluetooth recovery 皆取得證據，Phase 2 判定 READY FOR GATE D SIGN-OFF；但 Legacy 仍保留至 Phase 3/4 完成。

## 6. Phase 3：System Audio 與 Mixed Audio

### 6.1 使用者回報的核心問題

在 Whisper Swift 選擇「系統音訊」後：

1. 看不到每 15 秒逐字稿。
2. 點擊完成後也看不到結果。
3. 某些測試錄音產生 WAV，但幾乎是靜音。

這三個現象必須分開判斷：capture 是否有 signal、Worker 是否完成、UI 是否把 cumulative result 顯示出來。

### 6.2 ScreenCaptureKit capture 修正

原 filter 依 `SCShareableContent.applications` 建立包含清單。這對一般 GUI App 有效，但 headless／CLI 播放來源可能不在清單中，因此 ScreenCaptureKit session 看似正常、WAV 也存在，實際音訊能量接近零。

修正方式：

- 使用 display content filter 的 exclusion 模式，不只 include 已列出的 GUI applications。
- 保留 current-process audio 設定的明確行為。
- 以實際保存 WAV 的 signal level／payload 大小驗證，不以「startCapture 沒丟錯」判定成功。
- 將 Screen Recording TCC permission 狀態和 capture error 映射到 UI。

### 6.3 每 15 秒與完成結果不可見

system audio controller 最初只把 chunk 送 Worker，沒有正確累積顯示所有 chunks 的 result，或完成時沒有把最後 session result寫回 history/UI。

修正方式：

- `SystemAudioRecordingController` 使用 15 秒 rotation 與 ordered submission queue。
- 每個 completed chunk 的 text 與 segments 累積到 session transcript。
- segment start/end 加上 cumulative offset，避免每個 chunk 都從 00:00 開始。
- UI 在 chunk terminal 時即刷新 timecoded transcript，stop 時等待 queue drain。
- session 同時保存完整 `system-audio-session-*.wav`，可播放及後續重跑。
- completion 會建立／更新 history entry，不讓結果只存在 controller 暫態狀態。

### 6.4 Worker PyInstaller crash 與 diagnostics 不足

使用者截圖只看到：

`[PYI-37401:ERROR] Failed to execute script 'worker_entrypoint' due to unhandled exception!`

這只是 PyInstaller wrapper 最後一行，無法指出真正 root cause。Swift 端原本顯示的錯誤亦只保留最後一行 stderr。

修正方式：

- frozen inference child 失敗時保留完整 `proc.stderr.strip()`，不再 `splitlines()[-1]`。
- Worker catch exception 後把完整 `traceback.format_exc()` 寫 stderr。
- `WorkerSupervisor` 持續讀 stderr，diagnostics 上限保留最新 20,000 characters，UI 用 disclosure 顯示。
- stdout 仍維持 protocol-only，不把 traceback 混進 JSONL。

### 6.5 `language=08` crash

展開 diagnostics 後確認 Swift UI 的 language field 出現 `08`，Worker 原樣傳給 faster-whisper，造成 inference child exception。這不是音訊 capture 失敗，而是輸入 validation 缺失。

修正採雙層防線：

- Swift `AppSettingsStore` 對 language 做 normalization，只接受支援的 language code；空值代表 auto，無效值回復安全值。
- Python `whisper_core._normalize_language_code()` 再做 defensive normalization，避免其他 caller 繞過 Swift UI。
- frozen Worker 用保存的真實 system-audio chunk 驗證 `08 -> auto -> completed`，成功輸出中文 transcript 與 segments。

### 6.6 Timecode

使用者要求輸出逐字稿帶 timecode。實作保留 Worker 的 segment `start`、`end`、`text`，history entry 也保存 segments。Export 支援：

- plain TXT。
- Timecoded TXT，格式如 `[00:00:32] 文字`。
- Markdown。
- SRT，使用 `HH:MM:SS,mmm --> HH:MM:SS,mmm`。

若 entry 沒有 segments，SRT 會 fail closed，而不是製造假的時間碼。

### 6.7 Mixed Audio 的定義與實作

討論中釐清：

- 系統音訊：只錄 macOS 播放的聲音，例如會議對方、影片或瀏覽器；不含本機麥克風。
- 混音：同時錄系統音訊與本機麥克風，適合保留會議雙方；兩路 PCM 對齊後混合輸出。

Mixed 模式以 microphone + ScreenCaptureKit 兩路 capture、`PCM16Mixer`、15 秒 flush、ordered Worker handoff 實作。任何一路 lifecycle error 都不能被顯示為成功錄音；stale callback 同樣受 generation gate 保護。

## 7. P0：日常轉錄與 Export Parity

功能比較顯示初期 SwiftUI 和 Legacy v2.4.1 差距過大，因此將 replacement blockers 分為 P0、P1、P2 依序完成。

P0 完成：

- 檔案選擇與 transcription。
- Standard microphone、Live microphone、system audio、mixed audio。
- 15 秒 progressive transcription。
- 可編輯轉錄結果與保存修改。
- history persistence。
- audio playback。
- TXT、Timecoded TXT、Markdown、SRT export。
- language、domain、extra terminology 傳入 Worker。
- 最多 20 個檔案的 bounded batch queue；逐一處理、可取消、錯誤不拖垮整批。

重要設計：source transcript 與使用者編輯結果／generated summary 分開保存；export 必須從明確的 effective content 產生，不暗中覆寫 source evidence。

## 8. P1：AI Summary 與發布語意

### 8.1 OpenAI summary

初版 P1 使用 OpenAI Responses API：

- API key 只存 macOS Keychain。
- transcript 完成後可產生 summary。
- summary editor 可修改並保存。
- request／HTTP／decoding／empty response 有明確 failure state。
- 付費 external call 不在 automated tests 自動觸發，以 mock transport 驗證 request contract。

### 8.2 使用者看到 `WhisperApp.MeetingSummaryClientError 錯誤 1`

原 enum 沒實作 `LocalizedError`，SwiftUI 只能顯示不具意義的系統 error number。修正後每個錯誤有可理解訊息，例如 missing credential、HTTP status、invalid response、empty result、truncated response，UI 顯示 provider 與 failed state。

### 8.3 擴充 Anthropic Claude

使用者詢問是否支援 Claude API key，決定同時支援 OpenAI 與 Anthropic：

- UI 增加 summary Provider picker。
- OpenAI key 與 Anthropic key 使用不同 Keychain account，不能互相覆寫。
- Anthropic 使用 `POST /v1/messages`。
- Header：`anthropic-version: 2023-06-01`。
- request 包含 model、max_tokens、messages。
- 解析 content blocks，沒有文字或 response truncated 時 fail closed。

### 8.4 Claude model 404

Claude API key 設定完成後仍無法摘要，實際錯誤不是 Keychain，而是初版使用 `claude-sonnet-4-20250514`。該 model 已 retirement，API 回傳 404。

修正：預設 Anthropic model 改為 `claude-sonnet-4-6`，focused tests 驗證 URL、headers、body、credential routing 與 truncated output。自動環境未代替使用者傳送真實 transcript；最後真實 Claude 成功仍需在 App 內按「產生摘要」驗收。

### 8.5 Summary 狀態與安全

- source transcript 永遠保留。
- generated summary、edited summary、effective summary 分離。
- provider failure 不清空舊 summary，也不把空白標為 completed。
- API key 不進 UserDefaults、history JSON、Markdown、diagnostics 或 Notion/Obsidian metadata。

## 9. Obsidian 整合

### 9.1 討論釐清

使用者詢問「逐字稿是用複製方式，不會存入 Obsidian？」釐清兩種不同操作：

- 複製：只進 clipboard，不會建立 Vault file。
- 發布至 Obsidian：選擇並驗證 Vault 後，App 實際建立 Markdown file。

### 9.2 實作

- 使用者用 file importer 選擇真實 Vault。
- 驗證 canonical root 存在且 writable。
- 拒絕 symlink／path traversal，確保輸出沒有逃出 Vault。
- 使用 atomic write，失敗時不留下半份 note。
- 唯一檔名避免覆寫其他筆記。
- Markdown 包含 YAML metadata、會議 title、AI summary 與 source transcript/timecode。
- history entry 是發布來源，clipboard copy 不是發布 prerequisite。

### 9.3 證據邊界

Automated tests 用 temporary Vault 驗證 path、symlink、unique name、atomic write 與內容；沒有在未授權情況修改使用者真實 Vault。真實 Vault UI 發布仍列為 user acceptance item。

## 10. Notion 整合

Swift App 的產品功能採「append 至使用者指定既有 Page」語意，不把 Notion 和 Obsidian 描述成相同同步：

- token 存 Keychain。
- destination page ID 由使用者設定。
- API request preflight 檢查 token、page ID 與 block count。
- 使用 Notion API version `2026-03-11`。
- timeout／network interruption 在 server 可能已接受 request 時標記 `ambiguousOutcome`。
- ambiguous entry 持久化鎖定 retry；使用者確認 Notion 後才能解除，避免重複 append。
- history deletion 同時清除關聯 ambiguous lock/tombstone。

這個 session 的工程 checkpoint 另透過 Codex Notion connector 寫入工作總結資料庫；這和 App 本身的 Notion append 功能是兩條不同操作路徑，不應混為同一驗證。

## 11. P2：Productivity Parity

完成項目：

- `VocabularyStore`：持久化專有詞庫，domain 與 extra terms 送入 transcription prompt。
- history search、編輯、刪除、retention 數量設定。
- atomic JSON history write。
- durable deletion tombstone，防止 App crash/restart 後已刪資料復活。
- 刪除時協調 transcript、summary、publish locks 與相關 artifact cleanup。
- native keyboard shortcuts、menu commands。
- 錄音 elapsed time、RMS meter 與明確 recording state。
- model cache readiness/status，避免只顯示不明的「下載模型 Cache」。
- batch transcription 上限 20 files。

## 12. 最後設定保存

使用者要求音訊模式、模型、語言、領域在重啟後保存最後值，後續也把 summary Provider 納入。

原問題：audio mode 是 `ContentView` 的 `@State`，App restart 必定回預設；model/language/domain 的保存邊界也不一致。

修正：建立 `AppSettingsStore`，以 Swift Observation 注入 environment，使用 `UserDefaults` 保存：

- audio input mode：standard、live、system audio、mixed。
- default model。
- language；空值代表 auto，輸入會 normalization。
- domain。
- history retention。
- summary Provider。
- Obsidian Vault path、Notion destination page ID 與 ambiguous outcome IDs 等非 secret settings。

未知／舊版 audio mode raw value 會安全 fallback 至 `standard`。API keys/token 絕不放入 UserDefaults，仍由 Keychain 管理。

## 13. UI/UX 原生化與 Legacy 操作一致

使用者要求參考 `Whisper STT.app` 調整 `Whisper SwiftUI.app`，目標是操作一致但視覺原生化。實作方向：

- 使用 macOS native picker、segmented control、Form/Section、DisclosureGroup、Toolbar/Commands。
- 核心流程依序呈現快速設定、錄音／檔案轉錄、結果、summary、history、advanced integrations。
- diagnostics 預設收合，但 failure 時可展開查看完整 traceback。
- 不能因原生化而藏掉 transcript、progress、cancel、history、Obsidian/Notion 或 error status。
- 功能比較後不再只追求視覺相似，而以 daily workflow parity 為 replacement gate。

命名由 `Whisper SwiftUI` 簡化為 `Whisper Swift`，避免使用者開錯 Legacy v2.4.1。仍保留不同 Bundle ID、安裝位置與 data namespace。

## 14. History、播放與結果可見性

早期 system audio 問題暴露出「Worker completed 不等於使用者看得到結果」。因此建立以下 invariants：

- Worker terminal event 必須映射到 controller state。
- controller completed payload 必須包含 text、language、segments 與 audio URL。
- view 必須把 active session cumulative transcript 和 saved history 分開但都可見。
- stop/drain 完成後建立 history entry。
- history text 可編輯，保存後不破壞 segments/audio metadata。
- audio file 存在時可播放；不存在時明確 disabled。
- error status 和 previous transcript 可以同時存在，錯誤不能把結果區整個清空。

## 15. Diarization、Sparkle 與 Release Hardening

### 15.1 Diarization

packaged Worker runtime 不含 `torch`／`pyannote.audio`。為避免偷偷依賴 `/usr/bin/python3` 或 Homebrew，Phase 3 spike 做出 FAIL／disabled 決策：UI 可顯示 capability unavailable，但不能宣稱 bundled diarization 已完成。這是 fail-closed，而不是功能成功。

### 15.2 Sparkle

建立 update UI seam，但只有 HTTPS `SUFeedURL`、EdDSA `SUPublicEDKey` 與 Sparkle framework 齊全時才啟用。下載 Sparkle 2.9.2 artifact 曾停在 0 B，因此沒有保留不完整 dependency，也沒有填假 feed/key。真實 signed appcast update/rollback 留在 Gate E。

### 15.3 Developer ID／notarization

release pipeline 已具備 fail-closed preflight、Hardened Runtime、notarytool、staple、validate 與 Gatekeeper 檢查步驟，但本機沒有：

- Apple Developer ID Application identity／Team ID。
- notarization Keychain profile。
- 兩個 notarized releases 與 signed HTTPS appcast。
- 獨立 clean Apple Silicon Mac。

因此只能完成 local signing／structural verification，不能宣稱 public distribution ready。

## 16. 安裝版與真實驗證

本 session 最後使用的 candidate 安裝在 `/Users/daqingliao/Applications/Whisper Swift.app`。已完成的本機證據包括：

- final path `codesign --verify --deep --strict`。
- bundled Worker `ready`。
- isolated first model download/cache 與真實 `tiny` inference。
- Standard／Live microphone。
- 多次 chunk rotation 與 drain。
- sleep/wake operational continuity。
- 真實 soundcore AeroFit Pro device-change recovery。
- system-audio WAV signal、chunk transcription 與 cumulative timecode。
- frozen Worker invalid language normalization。

尚未完成或不可自動代替使用者的真實驗收：

- Claude Sonnet 4.6 使用使用者 API key 產生一次正式 summary。
- 發布一筆真實 history 至使用者選定 Obsidian Vault 並檢查 Markdown。
- Swift App 對使用者 private Notion page 的真實 append。
- Developer ID/notarization/Gatekeeper/clean Mac/Sparkle update rollback。

## 17. 測試與 Review 演進

測試數量隨功能增加：handoff 起點 Swift 9/9；Phase 3 settings/history 約 69/69；Obsidian 72/72；Notion 77/77；P0–P2 completion 108 Swift tests；最後 system audio、Anthropic 與 settings regression 為 Swift full suite 126/126，Anthropic focused 7/7。

Python full suite曾為 275/276；唯一失敗是 release-hardening test 找不到 `WhisperAI_ProductSpec_v1.md`，屬既有文件缺檔，不是本次 transcription runtime regression。這個缺口沒有被假報為全綠，也沒有為了數字擴張 scope。

多輪獨立 code review 覆蓋 capture lifecycle、system result visibility、P0/P1/P2、release gate 與最後 patch，均為 APPROVE、無 blocking findings。Review approval只代表被檢視範圍的 code quality，不能代替真實 credential/TCC/public release evidence。

## 18. Dirty Worktree 與 Git 治理

整個開發過程保留大量 tracked modifications 與 untracked Swift/Worker/docs files。為避免把不同風險混成一個 commit：

- 不使用 `git add -A`。
- 不 reset/clean 使用者與前序 agent 的變更。
- 建議未來依 docs、worker、Swift foundation、P0、P1、P2、release、Classic adapter、system-audio fix 分批 review。
- 音訊、逐字稿、model cache、`.app`、Keychain data、`.env` 與本機 Application Support 絕不可進 Git。
- `whisper_core.py` 是 Legacy 與 Worker 共用邊界，修改時同時跑 Classic + Worker/Swift tests。

本 session 後段使用者明確呼叫 checkpoint publish，才授權只 stage/commit `README.md` 與 `knowledge_note.md`。產生 local commit `1ca3922`；其他 feature source 仍 dirty/unstaged。Push 被停止，因 origin repository 是 PUBLIC，而 checkpoint 含本機路徑與內部開發資訊；未取得明確 public disclosure 核准前不外傳。

## 19. 問題—根因—解法總表

| 問題 | 根因 | 解法 | 證據狀態 |
|---|---|---|---|
| Swift App 啟動異常／被移除 | bundle metadata、xattr、簽章與不穩定安裝路徑 | 重建、清 xattr/FinderInfo、final path strict codesign | 本機通過 |
| Worker protocol 被 print 污染 | inference stdout 和 JSONL 共用 | redirect diagnostics 至 stderr | tests/smoke 通過 |
| cancel 後 child 還在跑 | UI cancel 沒有 process ownership | cancellable process + terminal invariant | tests 通過 |
| microphone device change crash/stall | stale callback、engine teardown race、重用 engine | generation gate、drain、fresh engine、deferred retirement | 真實 Bluetooth 通過 |
| system audio WAV 近乎靜音 | include-app filter 漏 headless/CLI source | ScreenCaptureKit exclusion filter + WAV signal驗證 | 真實音訊通過 |
| 每 15 秒看不到逐字稿 | chunk result 沒累積映射 UI | ordered queue + cumulative transcript refresh | installed App驗證 |
| 按完成沒有結果 | stop 未完整 drain/history handoff | stop drain + session entry/history update | installed App驗證 |
| PyInstaller 只顯示最後一行 | stderr 被截成 wrapper message | 完整 traceback/diagnostics retention | 截圖問題已定位修復 |
| `lang=08` crash | UI 無 validation、Python 無 defense | Swift/Python 雙層 normalization | 真實 frozen Worker通過 |
| timecode 缺失 | text-only result/history | 保留 segments、offset、Timecoded TXT/SRT | tests + real transcript |
| AI summary 顯示 error 1 | error enum 無 LocalizedError | provider-specific localized errors | tests/UI修正 |
| Claude key 有效但 404 | 使用 retired model ID | 改 `claude-sonnet-4-6` | focused tests；真實 App待驗 |
| OpenAI/Claude key 可能互蓋 | credential account 未隔離 | provider-specific Keychain accounts | tests通過 |
| Obsidian 被誤認為 clipboard | UI/語意不清 | Vault picker + atomic Markdown publish | temp Vault通過；真實 Vault待驗 |
| Notion retry 可能重複 append | timeout 結果不確定 | persistent ambiguous lock + manual confirm | mock tests通過；真實 page待驗 |
| audio mode 重啟遺失 | `@State` 不持久化 | `AppSettingsStore` + UserDefaults fallback | tests通過 |
| diarization 表面可用但 runtime 缺失 | bundle 無 torch/pyannote | capability fail-closed，不依賴 system Python | spike FAIL/disabled |
| public release 誤判 | local signing 被當 Developer ID | Gate E 明確列外部證據 | Gate E NOT READY |

## 20. 最終產品狀態與使用方式

Whisper Swift 已達到本機開發 candidate，可用於：

1. 選擇音訊模式：Standard、Live、System Audio、Mixed。
2. 選模型、language、domain、terminology；設定會保存。
3. 開始錄音或選擇音訊檔；Live/System/Mixed 每 15 秒處理。
4. 查看帶 timecode 的 cumulative transcript。
5. 完成後編輯、保存、播放、copy 或 export TXT/Markdown/SRT。
6. 設定 OpenAI 或 Anthropic key 至 Keychain並產生摘要。
7. 從 history 選擇 Obsidian Vault 發布 Markdown，或設定 Notion page append。

若遇到問題，診斷順序應為：

1. 確認開啟的是 `Whisper Swift`，不是 Legacy `Whisper STT`。
2. 檢查 Microphone／Screen Recording TCC。
3. 展開 Worker diagnostics，不只看結果區最後一行。
4. system audio 先播放可確認的聲源並檢查 WAV 是否有 signal。
5. language 使用 Auto／zh／en／ja，不輸入任意數字。
6. AI summary 確認 provider 與對應 Keychain key；Claude 使用 current model。
7. Obsidian 必須先選有效 Vault；copy 不等同發布。

## 21. Closure 與未完成邊界

本 session 已完成 SwiftUI + bundled Python Worker 的主要本機功能路徑、P0–P2 parity、system/mixed capture、timecode、雙 AI provider、history/export、Obsidian/Notion入口、設定持久化、真實 microphone device recovery 與 local packaging hardening。

但「本機可用」不等於「可公開取代 Legacy」。正式結案仍必須把以下項目視為外部 release work，而不是本 session 的自動完成項：

- 使用者真實 Claude／Obsidian／private Notion acceptance。
- Developer ID + Hardened Runtime final artifact。
- Apple notarization、stapling、offline validation、Gatekeeper acceptance。
- 獨立 clean Apple Silicon Mac 首次安裝與 TCC。
- 兩個 notarized releases 的 Sparkle update、failure recovery 與 rollback。
- 安全拆分 dirty feature work，完成 focused commits、review 與公開資訊清理後才可 push。

在上述條件完成前，Legacy Whisper STT v2.4.1 應繼續保留為 production fallback，Whisper Swift 以獨立 candidate 身分使用。
