# 任務規格：Whisper 雙版本與 Git 隔離計畫 v1

**建立日期：** 2026-07-19  
**風險等級：** L0（本文件）；後續 rename／資料路徑調整為 L2  
**起點：** Spec  
**負責人：** Alex Liao  
**技術負責人：** 待確認

## 1. BLUF

Whisper Classic v2.4.1 與 Whisper Swift Preview 應在同一 repository 內維持兩套可辨識、可獨立建置與發布的 App；不建立永久分叉的產品 branches。第一階段先隔離 product identity、安裝路徑、Application Support、測試與 release tag，再處理 Swift system-audio bug。任何 commit／push 前必須先拆分目前 3 個 tracked modifications 與 33 個 untracked entries，並排除本機產物、credential、錄音和逐字稿。

## 2. 問題背景與目標

### 問題背景

目前兩個 App 的 `CFBundleName` 都是 `Whisper STT`。雖然 Bundle ID 不同，UI automation 與使用者仍可能依顯示名稱開錯版本，macOS Screen Recording／Microphone 權限也容易授予錯誤目標。SwiftUI PoC worktree 同時包含 Classic tracked source、Swift untracked source與共用 Python Worker，尚未形成可安全 review 的 commit 邊界。

### 任務目標

- Classic 顯示為 `Whisper Classic`，Swift 顯示為 `Whisper Swift`（Preview 階段可顯示版本後綴）。
- 兩個 App 使用不同 Bundle ID、安裝路徑、資料目錄、測試命令與 release tag。
- 兩個 UI 只透過明確 adapter 使用共用 transcription core；JSONL Worker contract 維持 versioned／backward-compatible。
- commit 可依 Classic、Swift、Worker、release、docs 五類獨立 review。

### 非本次目標

- 不立即 rename、搬移 source 或修改 Application Support。
- 不 stage、commit、push、建立 tag 或發布 release。
- 不移除 Classic、不遷移使用者資料、不覆蓋既有安裝。
- 不在本規格階段修正 system-audio。

## 3. 現況盤點

### Product identity

| 項目 | Classic | Swift |
|---|---|---|
| 現行 App | `/Applications/Whisper STT.app` | `/Users/daqingliao/Applications/Whisper SwiftUI.app` |
| 建議顯示名稱 | Whisper Classic | Whisper Swift |
| Bundle ID | `com.via.whisper-ai` | `com.via.whisper-swiftui` |
| Executable | `WhisperAI` | `WhisperApp` |
| 目前版本 | 2.4.1 | 0.1.0 |
| 最低 macOS | 12.0 | 14.0 |
| Source boundary | repository root Python／Web UI | `macos/WhisperApp/` |

Swift `Info.plist` 目前缺少 Classic 已具備的 `NSScreenCaptureUsageDescription`；這是後續 system-audio L2 修正必須驗證的 release metadata，不在本 L0 文件中直接修改。

### Git dirty state

- Branch：`codex/swiftui-python-poc`
- Tracked modifications：3 個（`routes.py`、`whisper_core.py`、`tests/unit/test_transcribe_sync_and_upload.py`）
- Untracked entries：33 個，其中 `macos/` 為整個 Swift App tree。
- Swift tree：34 source files、27 test files，另含 `Info.plist`、`Package.swift`、README 與 entitlements。
- 目前 system-audio 診斷在 `ContentView.swift`／`CaptureUIRulesTests.swift` 有未完成、未驗證的 working changes；不得混入 identity 或 Git isolation commit。

### 邊界分類

| 類別 | 目前檔案／目錄 | Commit prefix |
|---|---|---|
| Classic | repository root Python／Web UI、`templates/`、`static/`、既有 Classic tests | `classic:` |
| Swift | `macos/WhisperApp/` | `swift:` |
| 共用 Worker | `worker_entrypoint.py`、`worker_protocol.py`、`transcription_service.py`、`transcription_jobs.py`、`transcription_events.py`、`cancellable_process.py`、`model_runtime.py` | `worker:` |
| Build／release | `scripts/`、`worker.spec` | `release:` |
| 規格／證據 | `docs/`、handoff 文件 | `docs:` |

`whisper_core.py` 目前同時被 Classic 與 Worker 使用，應視為共用 transcription core；修改它時必須同時跑 Classic 與 Worker／Swift compatibility tests。

## 4. 執行範圍

### 允許修改範圍（後續需另行核准執行）

- Classic 與 Swift 的 `Info.plist` product identity。
- Swift build／release scripts 中的 bundle 名稱與安裝輸出。
- 明確的 Classic／Swift Application Support subdirectory。
- `.gitignore`、兩套測試入口與 release documentation。
- Worker protocol 的 optional、backward-compatible additions。

### 禁止修改範圍

- 不刪除、搬移或覆寫既有 Classic／Swift 使用者資料。
- 不重設、清理或還原 dirty worktree。
- 不變更 Classic Bundle ID 或既有 Sparkle update feed。
- 不把模型、`.app`、音訊、逐字稿、token 或本機簽章資料加入 Git。
- 不以永久 `classic-main`／`swift-main` branches 維護兩套 diverged codebase。

### 需要 Alex 核准的變更

- [ ] App 顯示名稱與安裝檔名 rename
- [ ] Application Support 資料目錄或 migration
- [ ] Classic retirement 或預設 App 切換
- [ ] Developer ID notarization／公開 release
- [ ] Git stage／commit／push／tag

## 5. Commit inventory 與建議順序

以下只是候選拆分，不代表授權 stage 或 commit：

1. `docs: add Swift migration and parity evidence`
   - handoff、Phase reports、P0–P2 specs、completion report、本隔離計畫。
2. `worker: add versioned JSONL transcription runtime`
   - Worker protocol／entrypoint／service／jobs／events／runtime與 Python tests。
3. `swift: add native app shell and capture controllers`
   - Swift app foundation、worker supervisor、recording controllers及基礎 tests。
4. `swift: add P0 daily transcription and export parity`
5. `swift: add P1 meeting intelligence and publishing semantics`
6. `swift: add P2 productivity parity`
7. `release: add bundled worker and Swift app pipelines`
8. `classic: adapt shared transcription core`
   - 僅包含 `routes.py`、`whisper_core.py` 與對應 Classic regression test；需證明不破壞 Classic。
9. `swift: fix system audio permission and capture startup`
   - 必須先完成 failing regression、真實 ScreenCaptureKit evidence 與 installed-app驗證。

每一批 stage 前必須執行 `git diff --cached --check`、檢視 `git diff --cached`，並掃描 secret、音訊、逐字稿與 binary。

## 6. `.gitignore` 與敏感資料風險

既有 `.gitignore` 已涵蓋 `.env`、常見音訊格式、`dist/`、`build/`、`*.app/`、zip 與 release artifacts，但仍需補強／確認：

- `.last_summary.json` 目前未被 ignore，可能包含真實摘要內容。
- Application Support、Keychain 與使用者選擇的 Obsidian／Notion 路徑不得進 repository。
- `macos/WhisperApp/.build/` 應明確確認被 ignore。
- 模型 cache、PyInstaller runtime 與測試產生 WAV 不得被 `git add -f`。

## 7. Branch、tag 與 release 策略

- 穩定整合：單一 `main`。
- 工作 branch：`codex/swift-*`、`codex/classic-*`、`codex/worker-*`。
- Classic tags：`classic-v2.4.2`。
- Swift Preview tags：`swift-v0.2.0-preview`。
- Replacement Candidate：`swift-v3.0.0-rc.1`。
- 正式取代後才使用 `whisper-v3.0.0`，Classic 進入限期維護。

## 8. 驗收條件

### 正向驗收條件

- [ ] Finder、Dock、Activity Monitor 與 Accessibility tree 可一眼區分 Classic／Swift。
- [ ] 兩個 App 具有不同顯示名稱、Bundle ID、安裝位置與資料目錄。
- [ ] Classic 與 Swift 可獨立 build、test、install，不互相覆蓋。
- [ ] Worker protocol compatibility tests 同時覆蓋兩個 caller。
- [ ] commit inventory 的每批 diff 可獨立測試與 review。

### 負向驗收條件

- [ ] Classic v2.4.1 的既有設定、history、Sparkle 與使用者資料未被修改。
- [ ] Swift rename 不重設或誤繼承 Classic 的 TCC permissions。
- [ ] Git history 不包含 `.app`、模型、錄音、逐字稿或 credentials。

### 必要驗證

- [ ] `plutil` 驗證兩個 `Info.plist`。
- [ ] `codesign -d` 驗證兩個 installed bundles 的 identifier。
- [ ] Classic full tests。
- [ ] Swift full tests。
- [ ] Worker Python tests與 bundle smoke。
- [ ] 真實 microphone／system-audio／mixed capture manual gate。
- [ ] `git status`、staged diff、secret／large-file scan。

## 9. 停止條件

立即停止並回報 Alex，若：

- 需要刪除、搬移或 migration 使用者資料。
- rename 會改變既有 Classic Bundle ID 或 Sparkle channel。
- 需要 stage、commit、push、tag 或公開發布但尚未獲得明確授權。
- Worker contract 無法保持 backward compatibility。
- system-audio 驗證只能在模糊 App 名稱下執行，無法證明目標是 Swift bundle。
- 發現 credential、真實逐字稿、音訊或不可接受的大型 binary 已進入候選 diff。

## 10. 完成回報格式

完成時回報：product identity diff、Git 邊界、各版本測試證據、安裝路徑、未完成真實驗收、殘留風險，以及明確的未 stage／commit／push 狀態。

