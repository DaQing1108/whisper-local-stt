# 🎙️ Whisper STT 本地語音轉文字系統 v2.4.1

## Current State
Last checkpoint: 2026-07-23（錄音回放校對 segment-level seek：跨帳號 handoff → 真實 App 點擊驗證 → push）
Phase: Whisper Swift 兩個 PRD 待辦項目皆已落地（Diarization、錄音回放校對），codex-handoff/codex-receive 分工流程正式沉澱為全域指令
Working: `whisper-swift` 分支（HEAD `ad1e18b`，與 origin 同步）新增 segment-level playback seek——逐字稿編輯框下方新增唯讀可點擊段落列表，點擊跳轉播放時間點＋播放中同步高亮目前段落，純 SwiftUI 改動，不碰 Worker/protocol。Python 293/293、Swift 153/154（唯一失敗是既有、跟本次無關的 WorkerSupervisorTests 環境依賴問題，已登記待修）。已在真實打包安裝的 App 上點擊驗證（用有效音檔的 system-audio 紀錄確認跳轉+高亮正常）。過程中發現並登記混音模式音檔存暫存目錄會消失的既有 bug（`task_d83de434`）。`codex-handoff`/`codex-receive` 兩個全域指令已更新，正式支援「另一個 Claude Code 帳號」（非僅 Codex）的協作分工與 checkpoint 步驟
Next action: 混音音檔暫存目錄問題（`task_d83de434`）與 WorkerSupervisorTests 環境隔離問題待排；HANDOFF v2 剩餘的 Diarization 邊緣案例（編輯保護、切換紀錄保護）與長錄音效能待補測；Whisper Classic PRD 的過時內容尚未修正
Blockers: none

## Checkpoint History
### 2026-07-23｜錄音回放校對 segment-level seek + codex-handoff/receive 流程沉澱
- Completed:
  (1) 確認 Whisper Swift PRD 剩餘兩項待辦（錄音回放校對、Timeline UI），錄音回放校對範圍收斂為「segment-level seek」（基礎播放/audioPath 已存在，只缺點擊跳轉+高亮），評為 L1、純 SwiftUI；
  (2) 跑 spec-writer 產出可直接交付規格，寫成自成一體的 handoff 文件（`docs/Whisper_Recording_Playback_Seek_HANDOFF_v1.md`），確認「commit 但不 push，由接手 session 獨立驗證後才 push」的分工方式；
  (3) 把這個分工方式與 checkpoint 步驟正式沉澱進全域指令 `codex-handoff`/`codex-receive`（iCloud 同步的 `~/Library/Mobile Documents/.../claude-config/commands/`）——新增「執行者類型」判斷（Codex 無 git 權限 vs 另一個 Claude Code 帳號可 commit 不 push）、`codex-receive` 新增 Checkpoint（README+Notion）步驟；
  (4) 另一個 Claude Code 帳號完成實作並 commit（`ad1e18b`），本 session 執行 `/codex-receive`：獨立重跑 `swift build`/`swift test`，發現 153/154（1 個既有、跟本次無關的環境依賴測試失敗，深入查證後確認根因是 `WorkerSupervisor()` 未注入假 model manager、讀到本機真實已下載的 Diarization 模型狀態，非本次回歸，決定登記為已知問題不修）；
  (5) 打包時撞到一個既有的 `com.apple.FinderInfo`（Sparkle nested Updater.app）codesign 卡點，清除後重新打包安裝；
  (6) 電腦操作工具點擊驗證卡在混音錄音的音檔問題——查證後發現 4 筆 mixed-audio 紀錄的 `audioPath` 全部指向系統暫存目錄且檔案已消失（既有 bug，跟本次功能無關），改用有效的 system-audio 紀錄測試後確認 segment-seek 的跳轉與高亮都正常運作；
  (7) 登記混音音檔遺失問題為背景任務（`task_d83de434`），供之後獨立處理；
  (8) 驗證通過後 push `ad1e18b` 到 origin/whisper-swift
- State: `whisper-swift` HEAD `ad1e18b`，與 origin 同步；`codex-handoff`/`codex-receive` 全域指令已更新且已用這次任務實際驗證過整套流程可行
- Next: `task_d83de434`（混音音檔暫存目錄問題）與 WorkerSupervisorTests 環境隔離問題待排優先序
- 可複用教訓：(a) 電腦操作點擊「沒反應」時，先查資料層根因（本次是音檔真的不存在），不要假設是 UI 邏輯壞了；(b) codex-receive 的「本機重跑驗收指令」這一步真的攔到了東西——差點就照對方回報的「跟本次無關」直接相信，深入查證後才確認真的無關，這個獨立驗證的把關價值在這次體現得很具體

### 2026-07-22｜Whisper Swift Speaker Diarization 移植：分析→spike→整合→實測
- Completed:
  (1) 分析 Whisper Classic PRD 與 Whisper Swift PRD，發現 PRD 宣稱 Diarization「完成」但 `worker_entrypoint.py` 實際硬編碼 `available: false`；
  (2) 原規格方向（比照 Classic 用 system Python subprocess）被 2026-07-18 既有 spike 明文否決（違反 SwiftUI AC-4「禁止 arbitrary system Python」），改研究 ONNX 路線；
  (3) 實測驗證 sherpa-onnx（ONNX Runtime，無 torch）：PyInstaller 打包乾淨（41M，無 torch/pyannote 洩漏）、模型免授權下載、真人多說話者錄音品質使用者確認正確；
  (4) 實作 `DiarizationModelManager`（模型下載，5 個測試 + 真實下載驗證）並 commit（`b69fe3e`）；
  (5) 寫 handoff 規格文件（`Whisper_Phase3_Diarization_Integration_HANDOFF_v1.md`），交給另一個 Claude Code 帳號在本機同一 worktree 執行；
  (6) 該帳號完成 Worker/protocol/SwiftUI 完整整合（commit `dc4fe04`：新增 `diarization_service.py`、`worker_entrypoint.py` 的 `diarization_warmup`/`diarize` command、SwiftUI「辨識講者」按鈕，兩輪獨立 code review 修復 3 HIGH + 1 MEDIUM），並寫 HANDOFF v2 記錄剩餘驗證項目；
  (7) 補上 HANDOFF v2 點出的缺口——SwiftUI 沒有「下載模型」按鈕入口，新增後 build/test 皆綠；
  (8) 實際跑 `scripts/build_worker_runtime.sh` + `scripts/build_swiftui_app.sh` 打包（修正 HANDOFF v1 誤寫的 `package.sh`——那是 Classic 的腳本），安裝到 `~/Applications/Whisper Swift.app`，使用者手動完成 Gatekeeper 核准；
  (9) 用電腦操作工具在真實運行的 App 裡點擊「辨識講者」，親眼確認逐字稿正確渲染 `[Speaker A]` 標籤；
  (10) 順手修復兩個無關的技術債：`.git/refs/heads/` 裡 iCloud 同步留下的壞 ref 檔案（`main 2`，導致 `git fetch` 整個失敗）、兩筆舊 discipline-loop 任務（`20260703-23aa`、`20260703-9e3c`）缺失的 `step7-verification-log.log` 記錄（造成 commit 前 hook 誤報）
- State: `whisper-swift` HEAD `178449d`，與 origin 同步，`make test` 293/293、`swift test` 154/154 全過。HANDOFF v2 記錄的 Task 1（真實 UI 驗證）核心流程已確認，步驟 6-7（編輯保護、切換紀錄保護）與 Task 3（長錄音效能）刻意留白，非現在必須完成
- Next: 有需求時再補 HANDOFF v2 剩餘驗證項目；Whisper Classic PRD 的過時 P1/P2 需求表尚未修正（本輪只修了 Whisper Swift PRD）
- 可複用教訓：(a) 動工前先查現有程式碼再假設「完全沒做」——最初以為 SwiftUI 端毫無 diarization 痕跡，其實只是還沒查到；(b) computer-use 自動化點擊 SwiftUI 按鈕列時，按鈕數量變化會讓固定座標整排位移，需要每次重新定位；(c) handoff 文件裡的操作指令（如打包腳本路徑）務必先驗證過一次再寫進去，不能憑專案慣例推測

### 2026-07-22（追加）｜Whisper Swift 版本顯示功能 + Gatekeeper/iCloud 排查
- Completed: (1) 新增 `AppIdentity.versionString`（讀取 `CFBundleShortVersionString`/`CFBundleVersion`）並在設定畫面「關於」區塊顯示；(2) `swift build`/`swift test`（152 tests, 29 suites）全過；(3) 打包安裝到 `~/Applications/Whisper Swift.app` 過程中發現 app 反覆消失/被搬進垃圾桶，查證根因：這台 Mac 的 `~/Documents` 有開 iCloud Drive 同步，`dist/` 打包出的 app 被重新蓋上 `com.apple.quarantine`，加上本機自簽章（非 Developer ID）導致 `spctl --assess` 恆為 rejected，每次重 build 都需要使用者手動在系統設定核准一次；(4) 使用者完成核准，畫面確認看到版號；(5) 已將此診斷樹寫入 `whisper-swift` 的 `CLAUDE.md`；(6) 順手查證並補齊了一個無關的舊 hook 警告（task `20260702-230e` 的 step7 verification log 缺記錄，已補上）
- State: 版本顯示功能程式碼已 commit + push（`12c5a0d`、CLAUDE.md 診斷樹 commit），`whisper-swift` 與 remote 同步；main worktree 除 README 外無其他變更
- Next: 背景任務 `task_edee3d79` 尚未回報；持續觀察 Gatekeeper 重新核准的摩擦是否影響 Gate E 決策


### 2026-07-22（更正）｜whisper-swift dirty state 描述有誤
- **錯誤說明：** 先前兩則 checkpoint 記錄（2026-07-22 兩則）都寫「`whisper-swift` worktree 有 3 個 tracked 修改 + 33 個 untracked entries，含未驗證的 system-audio 診斷變更」——這段描述抄自 2026-07-19 的 `Whisper_Dual_Version_Git_Isolation_Plan_v1.md`，早已過時，且從未在寫入當下重新對照 `git status` 核實
- **實際查證結果：** `ContentView.swift` 完全乾淨，近期 commit 都是正常 feature/fix；目前 `whisper-swift` worktree 的 dirty state 只有 `CLAUDE.md`（本次加的分支策略段落）與 `macos/WhisperApp/Info.plist`（本次版號提升），加上一個與本次工作無關的既有 untracked 文件 `docs/Whisper_SwiftUI_P0_Gap_Closing_Specs_v1.md`
- **已處理：** 撤銷了先前基於錯誤描述拋出的背景任務建議（`task_d8e4df9b`，已 dismiss）
- **教訓：** 讀到舊文件描述現況時，必須重新對照當下的 `git status`／`git log` 驗證，不能把文件裡的時間點狀態當成現況直接寫入新的 checkpoint 記錄

### 2026-07-22（追加）｜Whisper Swift 版號提升 + 過時文件更新任務啟動
- Completed: (1) `macos/WhisperApp/Info.plist` 的 `CFBundleShortVersionString` 從 `0.1.0` 提升為 `0.2.0`（build 維持 `1`），反映 P0-P2 已完成的實際進度；(2) 決定 Whisper Swift 版號與 Whisper Classic（`v2.4.x`）脫鉤獨立編號，`1.0.0` 保留給 Gate E 通過、確定對外釋出的時間點；(3) 使用者已在獨立 session 啟動先前拋出的背景任務，開始更新過時的 `Whisper_Legacy_vs_SwiftUI_Functional_Comparison_Spec_v1.md`
- State: 版號修改與先前的 dirty state 一起留在 `whisper-swift` worktree，尚未 commit；背景任務獨立執行中，尚未回報結果
- Next: 待背景任務完成後確認過時文件已更新；`whisper-swift` 的 dirty state 拆分 commit 仍待處理

### 2026-07-22｜Whisper Classic/SwiftUI 合併決策：main 凍結、分支改名 whisper-swift
- Completed: (1) 確認 `codex/swiftui-python-poc` 的 P0/P1/P2 parity 早已完成（此前依據的比較文件已過時）；(2) 確認 Gate E 卡在外部條件（Developer ID、clean Mac），非程式碼問題，且現階段僅個人使用不需要；(3) 依使用者最終確認，將 `main` 列為凍結維護，`codex/swiftui-python-poc` 改名為 `whisper-swift` 作為主力分支（local + remote 已執行，無 PR/CI 相依，安全）；(4) 更新兩邊 `CLAUDE.md` 記錄分支策略，並明確標注舊的 `Whisper_Dual_Version_Git_Isolation_Plan_v1.md`（tag-only 策略）已被使用者否決
- State: 決策已定案並落地於 branch 結構；`whisper-swift` worktree 仍有未拆分的 dirty state（含未驗證的 system-audio 診斷變更），尚未處理
- Next: 使用者驗證 SwiftUI 版日常使用穩定性；後續視需要拆分 `whisper-swift` 的 dirty commit 與更新過時的比較文件

### 2026-07-15｜Checkpoint Publish：v2.4.1 Timecode Patch
- Status: source patch 已完成，尚未封裝或發布；目前 branch 為 `codex/fix-v2-4-1-timecodes`。
- Completed: 修復 footer 發布漏傳 `segments`、chunk 與系統音訊完成 state 未持久化 segments；Obsidian 原始逐字稿可恢復 `[MM:SS]` timecode。
- Verification: full unit suite `216 passed`；CI 同款 integration suite `16 passed`，包含先前失敗的 `/api/save_to_obsidian` test。
- Boundary: 本 checkpoint 不包含 `.claude` 設定、handoff、規劃草稿、音檔、log 或現有 Obsidian 會議檔；既有缺少 segments 的檔案無法安全回填真實 timecode。
- Next: 重新封裝 `v2.4.1`、執行 bundle smoke test、推送 patch 並確認 GitHub CI。

### 2026-07-15｜v2.4.1 Timecode 與 CI Patch
- Fixed: footer 發布會從同一 `meeting_id` 的 backend state 回填 Whisper segments；chunk 與系統音訊完成時也會持久化 segments，因此 Obsidian 原始逐字稿恢復 `[MM:SS]` timecode。
- CI: 在 `WHISPER_TEST=1` 且無 LLM provider 的整合測試中使用 deterministic destination summary；release test 不再讀取未追蹤的本機 ProductSpec。

### 2026-07-15｜v2.4.0 Summary 與可重複發布
- Scope: transcript 完成後產生可編輯的 Whisper App summary；Obsidian 與 Notion 各自從 transcript 產生目的地專用 AI 會議內容；固定 `meeting_id` 讓相同 session 可安全重複發布更新。
- User flow: 完成轉錄與 App summary 後，使用 footer 的 `Obsidian` 或 `Notion` 主動發布；Obsidian 會寫入一份原始逐字稿與一份連結的會議記錄，Notion 會建立並重寫同一個 meeting child page。
- Verification: focused unit tests `77 passed`、Python/JavaScript syntax checks、bundle smoke test、以及真實設定下的雙次 Obsidian / Notion 端對端發布皆通過；第二次發布確認更新既有檔案與 child page。

### 2026-07-15｜Canonical Summary 統一流程 + 可編輯 Summary
- Completed: (1) 將 AI 會議摘要從 Obsidian 存檔流程抽離，改為 transcript 完成後即自動生成 canonical summary；(2) summary 分頁改為可編輯，新增 `generated_summary` / `edited_summary` / `effective_summary` 狀態模型；(3) `/api/save_to_obsidian` 改為優先寫入使用者編輯後的 summary；(4) 補齊 `GET /api/last_summary`、`POST /api/update_summary` 與 `tests/unit/test_summary_flow.py`；(5) 將 summary prompt 改為 app 內固定結構化摘要模式，不再直接沿用 `meeting-notes.md`，避免資訊不足時回澄清問題
- Verification: `python3 -m py_compile routes.py integrations.py`、`node --check static/app.js`、`python3 -m pytest -q tests/unit/test_summary_flow.py tests/unit/test_meeting_summary_prompt.py` 全數通過（10 passed）；以 source server `PORT=5011 python3 app.py` 做 live smoke test，確認 transcript → summary 自動生成、編輯後可存回 API，且 Obsidian 寫入的是 edited summary；再以 `/Applications/Whisper STT.app` 做 bundle smoke test，確認安裝版 `summary` 會輸出固定結構的 `摘要 / 決策 / 行動事項 / 待確認`，且不再回澄清問題
- Decision: `extra_terms` / 詞庫維持 STT 輔助邊界，不與 summary editor 狀態混用；summary provider 仍是後端直連 LLM provider，目前實際走 Anthropic Claude
- Note: 若 port `5001` 上看到舊行為，優先排查是否仍是舊的 `.app` 在提供服務，而不是最新 source server；若 `summary` 看起來像舊資料，先檢查 `.last_summary.json` 持久化狀態是否仍殘留前一次測試結果

### 2026-07-15｜確認後發布流程
- Completed: (1) 移除 Whisper App header 中 Obsidian / Notion 的本次自動發布開關；(2) 錄音與摘要完成後，footer 的「發布至 Obsidian / Notion」才會成為唯一 App 發布動作；(3) AI 摘要產生中會鎖定發布按鈕，避免發布半成品；(4) Obsidian 改為單一會議檔，依序包含 `AI 會議內容` 與 `逐字稿`；(5) Notion 同一次發布也會以相同順序寫入兩段內容。
- Compatibility: 後端仍保留 `save_obsidian` 給既有外部整合使用；Whisper App 不再傳送自動存檔請求。
- Verification: 相關 unit tests `70 passed`；直接呼叫 `/api/save_to_obsidian` 驗證只寫入單一 `.md`，且不會產生 `_會議記錄.md`。

### 2026-07-15｜發布版本管理：固定 Meeting ID
- Completed: (1) transcript 完成時建立固定 `meeting_id` 與 meeting title，持久化在本次 summary state；(2) 首次發布至 Obsidian 建立會議檔，後續同一 ID 直接覆寫原檔；(3) Notion 首次發布在設定目標頁下建立會議專屬子頁，後續同一 ID 清空並重寫該子頁；(4) stale session ID 會回傳 `409`，避免意外新增發布結果；(5) 舊版無 ID 的 summary state 會在首次發布時自動升級。
- Verification: `pytest` 相關發布流程 `75 passed`、`py_compile`、`node --check`、`git diff --check` 全數通過；重新封裝 `/Applications/Whisper STT.app`，bundle `/api/ping` 正常回應 v2.3.1，空內容發布安全回傳 `400`。
- User verification: Notion 子頁首次建立與第二次覆寫需使用測試會議在真實 Notion 工作區確認；Notion connection 必須具備目標頁存取權，且有建立、讀取與更新內容的能力。

### 2026-07-15｜目的地獨立 AI 會議內容
- Decision: transcript 是唯一共同原始來源；Whisper App summary 保持 App 專用、可編輯的輸出，Obsidian 與 Notion 不再共用或覆寫它。
- Completed: (1) 新增 Obsidian 知識沉澱 prompt 與 Notion 專案協作 prompt；(2) footer 發布時，各目的地直接以當前 transcript 生成自己的摘要；(3) Obsidian 發布改為兩個檔案：逐字稿與 `*_Obsidian會議記錄.md`，兩者均以 `meeting_id` 關聯；(4) Notion 會議子頁保留 `Notion AI 會議內容` 與逐字稿的獨立區塊；(5) 移除將 App summary 傳入目的地發布的程式入口與誤導文案。
- Verification: 相關 unit tests `77 passed`、`py_compile`、`node --check`、`git diff --check` 通過；重新封裝 bundle，安裝版 ping 正常、空內容發布安全回 `400`。
- User verification: 需要真實 LLM 與 Notion 權限環境驗證首次發布與第二次覆寫；確認 Obsidian 產生兩個檔案且 Notion 不建立重複子頁。

### 2026-07-12｜v2.3.1 release hardening
- Scope: 收合圖示目視驗收、窄視窗與 Light/Dark theme、disabled tooltip、完整測試、品牌一致性、安裝與故障排除文件
- Added: `docs/INSTALLATION.md`、`docs/TROUBLESHOOTING.md`、`tests/unit/test_release_hardening.py`
- Brand: 交付名稱固定為 `Whisper STT`，同步主視窗、偏好設定、bundle、PRD 與 manual checklist
- Verification: 執行中，完成後更新本段結果

### 2026-07-12 01:30｜V2.3.0 收合圖示統一 + App 重新封裝
- Completed: (1) 將快速設定列的文字 `▾` 改為與專有名詞列相同的 14×14 SVG chevron；(2) 補齊 icon flex 對齊樣式並保留展開時 180° 旋轉；(3) 執行 `bash package.sh`，重新封裝並安裝 `/Applications/Whisper STT.app`；(4) 清除 Sparkle 子元件的 Finder extended attribute，重新套用 `WhisperSTT Local` 簽章
- Verification: `python3 -m pytest tests/unit/test_index_html_structure.py -q` 為 16 passed；`git diff --check` 通過；安裝版 `CFBundleShortVersionString=2.3.0`；安裝包內已找到新 SVG；`codesign --verify --deep --strict` 顯示 valid on disk 且 satisfies its Designated Requirement；port 5001 無衝突
- Files: `templates/index.html`、`static/app.css`；checkpoint 更新 `README.md`
- Repo state: branch `main`，基準 commit `e93cd6b`；上述 UI 與 checkpoint 變更尚未 commit，既有其他未追蹤/修改檔案未納入本次操作
- Open risk / Next: `package.sh` 安裝後可能因 Sparkle extended attribute 需要再次清除並重簽；開啟 App 進行最終目視驗收

### 2026-07-11 12:07｜CI 兩輪除錯收尾 + torch 打包優化
- Completed: (1) 排除 torch 打包，app bundle 縮小 304M（704M→400M，commit f3baeb2），以 `sys.meta_path` import-blocking 測試驗證真實推論路徑未受影響；(2) CI 第一輪失敗修復——補上 wheel 建置工具解決 macOS runner 安裝 openai-whisper 失敗（commit bdb76f2）；(3) CI 第二輪失敗修復——gui.spec 假設 `.env` 一定存在於全新 checkout（CI 上不成立）+ 一個既有 integration test 斷言邏輯錯誤（commit e93f8d8）；(4) 確認最新 commit 觸發的 CI run 三個 job（unit-tests / integration-tests / bundle-dependency-check）全數 success
- State: 10 個 commit 全數 push 至 origin/main，working tree 乾淨，CI 全綠，無需第三輪修復
- Root cause/決策背景: `ctranslate2.converters` 因其 `__init__.py` 無條件 import 無法排除，但 torch 本身可以排除（faster_whisper/ctranslate2 內所有 torch 使用皆為 try/except 保護或 function-local lazy import）；gui.spec 的 `.env` datas entry 在任何跑過一次 app 的開發機上都存在，因此本機測試從未暴露此問題，只有全新 CI runner 才會踩到
- 踩過的坑: 連續完整 PyInstaller 重建（~5 次）驗證打包 excludes 清單，耗盡本機記憶體（已存入全域 memory `feedback_pyinstaller_rebuild_cost.md`）；第一次 torch 排除驗證方式（打包後直接呼叫 API）具誤導性，因本機系統 Python 已裝 mlx_whisper/faster_whisper，走的是 external subprocess 路徑而非真正要驗證的 in-process 路徑，改用 `sys.meta_path` 精確阻擋 import 才驗證到位
- 可複用摘要: 驗證打包依賴排除時，優先用 PyInstaller 自己的 xref report（`build/*/xref-*.html`）而非檔案系統 `find`，後者對編入 PYZ 封存檔的純 Python 套件會有 false negative；CI 除錯若瀏覽器工具未登入 GitHub，只能看到 job 通過/失敗圖示，看不到展開的 step log，需請使用者貼上實際錯誤文字才能精確定位

### 2026-07-11｜Whisper STT 完整架構審查與修復
- Completed: (1) 4 個並行唯讀 subagent 完成核心架構/打包邊界/整合功能/測試覆蓋四大範圍審查，發現 gui.spec 打包設定回歸重新引入 torch/pyannote 打包風險，以及兩個核心端點零測試覆蓋 (2) 依優先序修復並各自 push：gui.spec 清理（9af0494）、補 /api/transcribe-sync 與 Notion /upload 測試（9ddcb28）、修正混音擷取併發 guard 缺口（bb16d65）、清理 system_audio_sc.py 等技術債（53eaa4b）、CLAUDE.md 補架構決策記錄（25ada68）、CI 新增 macOS integration-test 與 bundle 依賴檢查 job（46f9721）
- State: 189 個 unit test + 16 個 integration test 全數通過，6 個 commit 皆已 push 至 origin/main，完整 review 報告與過程記錄已存入 Notion「工作總結倉庫」
- Root cause/決策背景: gui.spec 的 hiddenimports 從未同步 diarize.py 的 subprocess 隔離重構，是這次最關鍵的回歸來源；CI 擴大過程中意外發現 WHISPER_TEST 環境變數從未真正被讀取、3 個既有 integration test 有邏輯錯誤，皆已修復並經使用者同意才擴大範圍，獨立 review 又抓到 3 個 HIGH（含一個自己漏改的同類 bug）也一併修復
- Next: 使用者至 GitHub Actions 確認新 CI job 雲端執行結果；ctranslate2.converters 拉入 torch 的問題已建 task chip，待後續處理

### 2026-07-08 10:10｜Hallucination 漏檢修復
- Completed: (1) is_hallucination() 新增 character-level CJK 重複偵測（Counter 對每字元計頻，佔 60%+ 且 10+ 次即判定）；(2) 新增 foreign script 污染偵測（Cyrillic/Arabic/Thai 等佔比 > 30%）；(3) 新增 clean_segments() segment 層級後處理（空白 segment 移除、hallucination segment 過濾、重複 timestamp 去重）；(4) whisper_core.py 4 個引擎出口插入 clean_segments()；(5) integrations.py save_to_obsidian() + routes.py _finish_session() 加防線
- State: unit tests 28/28 通過（新增 12 cases：4 char-level + 3 foreign script + 5 clean_segments），已重新打包 v2.3.0 並安裝
- Root cause: 中文字元重複（如「好」×200）因 split() 空格分詞無法偵測；空白 phantom segments 因 len<20 直接放行
- Next: 日常使用觀察過濾效果

### 2026-07-03 10:40｜macOS UI 響應式改版 + Preferences 驗收 + v2.3.0
- Completed: (1) Phase 1 五段式結構重排（commit c46fbfc）；(2) 展開/一般/直式三種視窗模式 + phone 風格底部導覽 Record/History/Dictionaries/Settings（commit e4ef4e1），核心決策為單一 DOM + data-view-mode 屬性驅動 CSS 重排，避免模式切換中斷錄音狀態；(3) 修正既有 e2e 測試 3 類 test/實作不匹配問題（commit 4f6c949）；(4) 版本升級 2.2.1→2.3.0（commit 7f17070）；(5) 驗收既有未 commit 的 Preferences 分層重構並補齊版本號（commit f9174c0）
- State: unit tests 158/158、e2e tests 全數通過（含 3 個核心行為測試驗證錄音狀態跨模式不中斷）；獨立 code review 兩輪，皆確認 CRITICAL/HIGH 問題已解決；已打包 v2.3.0 並用真實 App 截圖驗證三模式切換、compact 4-tab 導覽、深淺主題渲染；5 個 commit 皆已 push 至 remote main
- Next: Phase 2/3 尚未排入，待使用者指示

### 2026-07-01 09:30｜PortAudio 裝置失效自動恢復修復
- Completed: 診斷出錄音按鈕無回應根因為 sounddevice.PortAudioError -9986（AUHAL Invalid Property Value）；在 MixedAudioCapture.start() 加入 PortAudio reinit + retry；routes.py exception handler 補強
- State: bundle v2.2.1 smoke test 通過，自動恢復機制已打包
- Next: 使用者插拔耳機後實機驗證

### 2026-06-28 17:45｜說話者分離 Bundle Smoke Test 確認 + discipline-loop 規則補充
- Completed: bundle 環境 /api/diarize 驗證通過（ok:true，2 位說話者，labeled_transcript 有說話者標記）；CLAUDE.md 加入 discipline-loop Step 8 bundle smoke test 補充規則（Whisper 專案 Step 8 不能只跑 unit test）
- State: 說話者分離 Beta 在 bundle 環境完整確認，engineering discipline loop 規則已更新
- Next: 決定 v2.3 下一功能

### 2026-06-28 14:30｜Obsidian Plugin 完整實作 + Notion Spec
- Completed: Flask 改獨立子程序（--server-mode）防止 GUI crash 帶死 server；語言別名轉換（中文→zh）修復轉錄失敗；_free_port() 加 ping 保護；Obsidian plugin 全流程驗證可用；CLAUDE.md 加入跨系統整合評估清單與測試紀律；engineering-discipline-loop v1.7.0（Step 1 跨系統評估五項）；Notion Obsidian Spec 文件完整
- State: Obsidian plugin 全流程可用（已手動驗證）；Whisper app subprocess 架構穩定
- Next: npm build + e2e 驗證 Obsidian plugin，或繼續 Whisper 下一功能

### 2026-06-27 22:00｜說話者分離 Beta 實機驗證通過
- Completed: pyannote subprocess 架構（繞開 PyInstaller bundle 依賴衝突）、huggingface_hub 降版 0.23.4、speechbrain/lightning_fabric/torch 三個 patch 整合、實機測試莊敬高職音檔識別出 2 位說話者、工程教訓寫入 CLAUDE.md 與全域記憶
- State: 說話者分離 Beta 完整可用，上傳音檔後逐字稿出現說話者 A/B 標記
- Next: checkpoint 後繼續下一功能

### 2026-06-27｜說話者分離 Beta 主流程接入
- Completed: Quick-bar diarize toggle、/transcribe keep_wav、/api/diarize path traversal 防護（tmpdir 限制）、SSE done handler → labeled 逐字稿顯示、9 個 unit test
- State: 124/124 tests，commit ae08c83，說話者分離 Beta 完整可用（需 HF Token）
- Next: 取得 HF Token → 偏好設定填入 → 實機驗證說話者標記

### 2026-06-27｜v2.2.1 UX 深度測試後四項優化
- Completed: Space 鍵 bug 修復（toggleRecord）、dead code 清除、summary/timeline tab placeholder 引導說明、詞庫 📌 入口按鈕、QB chips 中文化、系統音訊首次引導 toast、升版 v2.2.1 重新打包
- State: 110/110 tests，commit 8b6e39f，/Applications/Whisper STT.app v2.2.1
- Next: 實機驗證四項 UX 改善

### 2026-06-27｜v2.2.1 UI/UX 交付一致性優化
- Completed: 主 UI 品牌收斂回 Whisper STT、quick-bar helper text、系統音訊權限狀態提示、詞庫文案、結果 action disabled reason、Preferences Basic / Workflow / Advanced 分層、release checklist 更新
- State: 待實機驗證
- Next: 手動驗證系統音訊權限、Notion/Obsidian disabled reason、Preferences 分層與窄視窗排版

### 2026-06-27｜v2.1.0 三功能實作
- Completed: 批次轉錄（batchTranscribe + 失敗計數）、鍵盤快捷鍵（Space/Cmd+U/Cmd+S + isInput guard）、自訂 LLM 模板（LLM_CUSTOM_PROMPT env var + 偏好設定 textarea），修復 2 個 HIGH issues
- State: 105/105 tests，版號 v2.1.0（version.py + Info.plist + gui.spec），commit b417ef7
- Next: ./package.sh → 手動 UI 驗證 → 規劃 v2.2

### 2026-06-26｜v1.6.8 全專案風險稽核修補
- Completed: 統一 .env 路徑到 Application Support（根治 Obsidian 消失問題）、page_id 遮蔽、啟動健檢 endpoint、移除 WHISPER_TEST bypass、race condition 修復、LLM timeout、codesign 強化、靜默失敗改 logging
- State: 77/77 unit tests 全通過，Obsidian 存檔驗證成功，.app 正常
- Next: 日常使用觀察

### 2026-06-25｜v1.6.7 VAD 優化 + Hallucination 偵測
- Completed: VAD silence threshold 調為 500、新增 timestamp-only phantom 偵測、版號升至 v1.6.7
- State: unit tests 16/16 全綠，.app 系統音訊轉錄正常
- Next: 日常使用觀察 hallucination 過濾效果

### 2026-06-24 10:30｜v1.6.6 模型升級
- Completed: 新增 large-v3 選項並設為預設、加入 condition_on_previous_text=False 防止時間戳循環、版號升至 v1.6.6、重新打包 .app
- State: large-v3 預設模型正常，系統音訊模式 TCC 授權正常
- Next: 日常使用觀察轉錄品質

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
| 🤖 LLM 標點精修 | 轉錄後自動以 Claude / OpenAI 精修標點、同音詞糾錯，並將簡體轉為台灣繁體用語 |
| 🇹🇼 強制繁體中文 | OpenCC s2twp 確定性轉換 + LLM 雙層保障，輸出保證為繁體中文（台灣慣用詞） |
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

## LLM 標點後處理 + 繁體中文保證

轉錄完成後，自動呼叫 LLM 精修標點符號、糾正同音錯字，並將簡體中文轉為繁體中文（台灣慣用詞）。

**繁體中文雙層保障：**
1. **LLM 層**：prompt 指示將簡體用語轉為台灣慣用寫法（信息→資訊、程序→程式）
2. **OpenCC 層**：`s2twp` 模式做確定性字詞轉換，即使沒有 LLM Key 也保證輸出為繁體

在 `.env` 設定任一 API Key 即可啟用 LLM 精修（依優先順序）：

```env
ANTHROPIC_API_KEY=sk-ant-xxxx    # Claude Haiku 4.5 ≈ NT$0.03/場
OPENAI_API_KEY=sk-xxxx           # GPT-4o-mini      ≈ NT$0.05/場
```

未設定任何 Key 時 LLM 精修靜默略過，但 OpenCC 繁體轉換仍會執行。

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

## Governance

- Branch: `main`
- Changes should go through pull requests
- Repo validation is defined in [`.github/workflows/ci.yml`](.github/workflows/ci.yml)
- Ownership defaults to [`.github/CODEOWNERS`](.github/CODEOWNERS)
- Contribution workflow is documented in [CONTRIBUTING.md](CONTRIBUTING.md)
- Security reporting guidance is in [SECURITY.md](SECURITY.md)

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

### v2.3.0（目前版本）

**v2.3.0 Patch**（2026-07-06）

強制繁體中文（台灣）輸出，徹底解決 Whisper 輸出夾雜簡體字問題。

| # | 修復／新增 | 說明 |
|---|------|------|
| 1 | **OpenCC 簡轉繁保底** | 新增 `opencc` (`s2twp`) 確定性轉換，所有轉錄輸出在回傳前強制轉為繁體中文（台灣慣用詞），如「内存」→「記憶體」、「鼠标」→「滑鼠」 |
| 2 | **LLM Prompt 簡繁指令** | LLM 後處理 prompt 加入簡體→繁體台灣用語轉換指令，搭配標點修正同步處理 |
| 3 | **新增依賴** | `opencc-python-reimplemented>=0.1.7`、PyInstaller spec 加入 `opencc` hidden import |

---

**v2.3.0**（2026-07-03）

macOS 主畫面響應式改版 + Preferences 分層重構。

---

### v1.6.5

**v1.6.5**（2026-06-22）

系統音訊擷取穩定性全面修復。

| # | 修復／新增 | 說明 |
|---|------|------|
| 1 | **系統音訊 YouTube/瀏覽器音訊擷取** | `SCContentFilter` 改用 `including: content.applications`，確保 Chrome Helper（背景 process，無可見視窗）的音訊也被包含 |
| 2 | **TCC 螢幕錄製授權跨 rebuild 失效** | 主 app bundle 改用 "WhisperSTT Local" 穩定證書簽名（原為 ad-hoc，每次 rebuild hash 改變 → macOS 視為新 app → 授權失效） |
| 3 | **CLAUDE.md 技術約束文件** | 記錄三條 NEVER 規則 + 症狀診斷樹，防止跨 session 重蹈覆轍 |
| 4 | **轉錄模式逐字稿含時間戳** _(補記自 v1.6.4)_ | 上傳音檔、麥克風錄音、系統音訊三條路徑均以 `[MM:SS]` 格式存入 Obsidian 逐字稿 |

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

## Sparkle 自動更新

**v1 決策**

- appcast 託管：GitHub Releases + raw `appcast.xml` URL
- Sparkle framework 來源：手動下載固定版本 `2.9.3`，放在專案根目錄 `Sparkle.framework`

**打包行為**

`package.sh` 只檢查 `Sparkle.framework` 是否存在並提示，不會自動下載或更新 framework。若檔案存在，`gui.spec` 會保留 framework bundle 路徑，打包流程也會確認它位於 `.app/Contents/Frameworks/Sparkle.framework`，並在 app plist 中寫入 Sparkle key：

- `SUFeedURL`
- `SUPublicEDKey`

目前這兩個值仍是佔位符。正式發版前需先完成：

1. 用 Sparkle `generate_keys` 產生 EdDSA key pair，保管 private key。
2. 將 public key 寫入 `Info.plist` 與 `gui.spec` 的 `SUPublicEDKey`。
3. 在 GitHub Releases 上傳 release artifact。
4. 更新並公開 `appcast.xml`，將 raw URL 寫入 `SUFeedURL`。
5. 用 Sparkle signing tool 產生 release artifact signature，確認 appcast 版本、URL、signature 一致。

可從 `release/appcast.template.xml` 複製正式 `appcast.xml`，詳細步驟見 `release/README.md`。

中期若發版流程穩定，再評估用 release script 或 CI 自動產生 appcast 與 signature。

---

## License

MIT
