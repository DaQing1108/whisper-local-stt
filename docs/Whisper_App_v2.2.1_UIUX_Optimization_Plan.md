# Whisper App v2.2.1 UI/UX 全面優化規劃

- Date: 2026-06-27
- Owner: Alex Liao / VIA AI Learning RD Center
- App Version: v2.2.1
- Status: Draft for user delivery
- Source Baseline: repo inspection, README current state, templates/static UI files, unit/e2e/manual tests

## 1. BLUF

Whisper App v2.2.1 已完成一輪 UI 重構與深度測試後補強，具備可交付基礎；下一步不應只修單點文案，而要把「首次使用、錄音/系統音訊、轉錄結果處理、設定管理、交付驗證」整理成一致的桌面 App 體驗。建議以 v2.2.1 作為 UX stabilization release，優先完成品牌一致性、主工作流清晰化、系統音訊引導、結果工作台、設定頁分層、手動驗收更新，再進入 v2.3 的功能擴張。

## 2. 現況基線

### 2.1 已完成能力

v2.2.1 目前已具備下列可交付能力：

| Area | Current State |
|---|---|
| 版本狀態 | `version.py`、`Info.plist`、`gui.spec` 已升至 `2.2.1` |
| 核心 UI | 主畫面為單欄工作台，包含錄音核心區、quick settings、詞庫、transcript tabs、歷史面板 |
| v2.2 UI 重構 | 圓形錄音按鈕、三環動畫、收合式 quick-bar、transcript / summary / timeline tabs |
| v2.2.1 UX 補強 | Space 鍵修復、summary/timeline placeholder、詞庫入口、quick-bar chips 中文化、系統音訊首次提示 |
| 設定頁 | Obsidian、Notion、LLM API Key、LLM template preset、diarization beta、Sparkle 更新檢查 |
| 交付驗證 | README 記錄 110/110 tests 通過，manual checklist 存在，但部分文字仍停留在 v1.6.x |

### 2.2 主要 UX 問題

| Priority | Issue | Impact |
|---|---|---|
| P0 | 品牌命名不一致：主 UI 是 `Echo`，bundle/package/checklist/log 多處仍是 `Whisper STT` | 使用者交付時容易困惑，安裝、授權、文件對不上 |
| P0 | README 標題仍為 v2.1.0，manual checklist 仍寫 v1.6.x | Release readiness 與使用者文件可信度下降 |
| P0 | 系統音訊權限流程仍偏文字提示，缺少可檢查狀態與一步一步修復路徑 | 非技術使用者首次錄 Teams/Zoom 容易失敗 |
| P1 | quick-bar 有收合，但錄音模式的差異與後果不夠明確 | 使用者不容易判斷標準、即時、系統音訊該選哪個 |
| P1 | summary / timeline tabs 是 future placeholder，容易被看成不可用或半成品 | 交付版需要明確標示產出條件或隱藏未完成功能 |
| P1 | 詞庫入口已補，但「本次詞彙」與「常用詞庫」的關係仍需更清楚 | 使用者不知道詞彙是否會保存、是否會影響本次轉錄 |
| P1 | Preferences 將基礎設定、進階功能、Beta 功能放在同一層 | 對一般使用者造成設定負擔 |
| P2 | E2E test 仍假設 title 含 Whisper、版本含 v1.6 | 自動化驗證已落後於新 UI/branding |

## 3. 設計目標

1. 降低首次成功門檻：使用者從開啟 App 到完成第一次轉錄，應能在 3 分鐘內理解下一步。
2. 提高會議錄音成功率：系統音訊、麥克風、混音三種情境都要有清楚狀態與失敗修復。
3. 讓結果區成為工作台：轉錄後的 copy、export、Obsidian、Notion、history 要被理解為同一條後處理流程。
4. 保留專業能力但降低干擾：模型、語言、領域、詞庫、LLM template 應可被快速掃描，不壓迫主錄音行為。
5. 建立交付一致性：App name、README、manual checklist、測試、版本顯示、權限提示都要一致。

## 4. 目標使用者與核心情境

| Persona | Primary Job | Critical UX Need |
|---|---|---|
| Program Manager | 錄製 Teams / Zoom 會議並整理重點 | 系統音訊一次成功、可快速存到 Notion/Obsidian |
| Engineer / Technical Lead | 錄技術討論與 code review | 專有名詞與中英術語保留、支援快捷鍵與批次轉錄 |
| Researcher / Interviewer | 上傳長音檔、訪談逐字稿 | 上傳/批次處理穩定、可匯出 txt/md/srt |
| Non-technical user | 第一次安裝後完成錄音 | 權限、模型下載、設定缺漏要有清楚引導 |

## 5. 資訊架構建議

### 5.1 主畫面

主畫面應保留單欄工作台，但分成五個清楚區塊：

| Zone | Purpose | UX Requirement |
|---|---|---|
| Header | 品牌、版本、連線狀態、偏好設定入口 | 名稱一致；狀態只顯示可行動資訊 |
| Capture | 錄音/系統音訊/上傳入口 | 讓使用者一眼知道目前模式、是否正在錄、下一步是什麼 |
| Setup Strip | 模型、語言、模式、領域 | 預設收合；展開後每項有簡短 helper text |
| Vocabulary | 本次詞彙與常用詞庫 | 明確分出「本次使用」與「已儲存」 |
| Result Workspace | Transcript、Summary、Timeline、History、Actions | 未完成 tab 要有條件說明；actions 依結果狀態啟用 |

### 5.2 偏好設定

Preferences 建議分為三層：

| Layer | Sections | Rule |
|---|---|---|
| Basic | Obsidian、Notion、LLM API Key | 預設顯示，供一般使用者完成必要設定 |
| Workflow | LLM template、export default、history retention | 用於調整產出格式 |
| Advanced / Beta | Speaker diarization、Sparkle、diagnostics | 預設收合，標示 Beta 或 IT/advanced |

## 6. 核心流程設計

### 6.1 首次啟動

Flow:

1. App 開啟後檢查模型、麥克風、螢幕錄製、Notion/Obsidian/LLM 設定。
2. 若缺少可選設定，不阻塞錄音，只顯示「稍後設定」與「前往設定」。
3. 若缺少會阻塞當前模式的權限，例如系統音訊缺少 Screen Recording，進入該模式時顯示專屬修復引導。
4. 模型尚未下載時，保留現有 overlay，但增加預估用途文字：「首次下載，之後可離線使用」。

Acceptance criteria:

- 首次啟動 modal 不應一次列出過多可選設定。
- 使用者未設定 Notion/Obsidian/LLM 時仍能完成本地轉錄。
- 切到系統音訊模式時，若權限 denied，要顯示「開啟系統設定後重啟 App」的明確步驟。

### 6.2 錄音與上傳

Flow:

1. 使用者選擇模式：標準、即時、系統音訊。
2. 按下中央按鈕或 Space 啟動。
3. 錄音中顯示時間、目前模式、保護狀態，例如 WakeLock、系統音訊每 15 秒 chunk。
4. 停止時依模式呈現不同文案：麥克風模式顯示確認，系統音訊模式顯示整合中。
5. 完成後自動切回 transcript，啟用 actions。

Mode helper copy:

| Mode | UI Label | Helper Text |
|---|---|---|
| Standard | 標準 | 錄完後一次整理，適合正式會議與品質優先情境 |
| Live | 即時 | 每 15 秒顯示片段，適合長會議中途確認 |
| System Audio | 系統音訊 | 擷取 Teams / Zoom / YouTube 等電腦播放聲，首次需授權螢幕錄製 |

### 6.3 詞庫

建議將 vocabulary bar 文案改為：

| Element | Current | Recommended |
|---|---|---|
| Input placeholder | `add_term...` | `加入本次專有名詞` |
| Library button title | `已儲存詞庫` | `開啟常用詞庫` |
| Empty library | `詞庫目前沒有儲存詞彙` | 保留，但補上「輸入詞彙按 Enter 會自動加入」 |

Acceptance criteria:

- 新增詞彙後，畫面要同時表達「已套用本次轉錄」與「已保存到常用詞庫」。
- 刪除常用詞庫項目時，不應誤刪本次 active tag，除非使用者也移除 active tag。

### 6.4 結果工作台

Result Workspace 建議改成「可用狀態導向」：

| Tab | Empty State | Done State |
|---|---|---|
| Transcript | 轉錄結果會出現在這裡 | 顯示逐字稿，可 inline edit |
| Summary | 完成轉錄並設定 LLM 後可產生摘要 | 顯示摘要、決策、行動事項 |
| Timeline | 有 timecode segments 時自動產生 | 顯示時間碼段落，可匯出 srt |
| History | 尚無轉錄紀錄 | 顯示最近紀錄，可恢復 |

Action buttons 建議順序：

1. Copy
2. Export
3. Save to Obsidian
4. Upload to Notion
5. Clear

Rules:

- 無 transcript 時 Copy / Export / Save / Upload disabled。
- Notion 未 ready 時，Upload 顯示 disabled 並附 tooltip：「請先完成 Notion 設定」。
- Obsidian path 未 ready 時，Save disabled 並附 tooltip。

## 7. 視覺與互動規範

### 7.1 Visual direction

目前深色、低彩度、綠色 accent 的方向適合 productivity desktop tool，可保留。但建議收斂下列規則：

| Token | Recommendation |
|---|---|
| Radius | 主工具區可維持 12-16px；小元件維持 6-8px |
| Accent | 綠色只代表 primary action、ready、success；警告與錯誤分開使用 yellow/red |
| Typography | 主畫面維持 Inter；狀態與 chips 使用 mono，但避免過多全英文小字 |
| Icon usage | 錄音、系統音訊、歷史、清除可保留 icon，但所有非直覺 icon 需有 title/tooltip |
| Mobile/responsive | 雖是 macOS app，仍要支援窄視窗；header actions 需可換行或收合 |

### 7.2 Interaction states

每個核心 action 至少要有這些狀態：

| Component | States |
|---|---|
| Record button | idle, recording, processing, disabled by another tab, permission denied |
| Mode selector | default, hover, active, disabled when recording |
| Export | disabled no transcript, menu open, downloading |
| Notion/Obsidian toggles | off, on, configured, missing config, upload/save in progress |
| System audio hint | hidden, first-time tip, permission denied, ready |

## 8. v2.2.1 優化優先級

### P0: 交付一致性與阻塞修補

| Item | Scope | Acceptance Criteria |
|---|---|---|
| Brand alignment | 決定交付名稱：`Echo` 或 `Whisper STT`，同步 title、header、bundle、README、manual checklist、tests | 使用者看到的名稱不再混用 |
| Release docs update | README title、manual checklist version、e2e assumptions | 文件全部指向 v2.2.1 |
| System audio permission UX | 將權限 denied、unknown、granted 對應到可行動 UI | 使用者知道如何修復 Screen Recording |
| Result action disabled reasons | Notion/Obsidian/export/copy disabled 時有明確原因 | 不再出現按鈕不可點但不知道原因 |

### P1: 工作流清晰化

| Item | Scope | Acceptance Criteria |
|---|---|---|
| Mode helper text | quick-bar 展開時加入短說明 | 三種模式差異可在 5 秒內理解 |
| Vocabulary UX | placeholder、library empty state、active/saved 分層 | 使用者知道詞彙會套用到本次轉錄 |
| Summary/timeline policy | 未完成功能改為「需要 LLM / timecode 才產生」或暫時隱藏 | 不讓使用者誤以為功能壞掉 |
| Preferences grouping | Basic / Workflow / Advanced 分層 | 一般使用者只需看到必要設定 |

### P2: 下一版鋪路

| Item | Scope | Acceptance Criteria |
|---|---|---|
| UX telemetry decision | 定義是否要匿名 opt-in events | 不影響 v2.2.1 release，但為 v2.3 做準備 |
| History management polish | history search、delete single item、restore confirmation | 歷史紀錄成為可靠工作流 |
| Diarization beta UX | 將 HF Token、license、model size、latency 風險講清楚 | Beta 功能不會破壞主流程信任 |

## 9. 工程交接建議

### 9.1 Suggested file touchpoints

| Area | Files |
|---|---|
| Main UI structure | `templates/index.html` |
| Main UI behavior | `static/app.js` |
| Main UI styling | `static/app.css` |
| Preferences | `templates/preferences.html`, `static/preferences.js`, `static/preferences.css` |
| Version / branding | `version.py`, `Info.plist`, `gui.spec`, `package.sh`, `README.md` |
| Tests | `tests/unit/test_v21_features.py`, `tests/e2e/test_ui.py`, `tests/manual_checklist.md` |

### 9.2 Implementation slices

建議拆成 5 個 PR 或 commit slices：

1. `docs/release-alignment`: 修 README、manual checklist、e2e version/title assumptions。
2. `ux/brand-alignment`: 統一 App name、header、title、bundle display name。
3. `ux/system-audio-guidance`: 改善系統音訊權限狀態與修復引導。
4. `ux/result-workspace`: 補 disabled reasons、summary/timeline empty state、actions tooltip。
5. `ux/preferences-grouping`: Preferences 分層與 advanced/beta 收合。

## 10. 驗收清單

### 10.1 Product acceptance

- [ ] App 名稱、README、manual checklist、window title、bundle name 一致。
- [ ] 首次啟動時，不設定 Notion/Obsidian/LLM 仍可完成本地轉錄。
- [ ] 系統音訊模式第一次切換時能看到授權提示。
- [ ] Screen Recording denied 時，畫面提供清楚修復步驟。
- [ ] 三種模式的用途在 UI 中可理解。
- [ ] 詞庫輸入與常用詞庫行為清楚。
- [ ] transcript 完成後，copy/export/Obsidian/Notion 的可用狀態正確。
- [ ] summary/timeline 不再像壞掉的空白功能。
- [ ] Preferences 一般設定與 Beta/Advanced 功能分層。

### 10.2 Engineering acceptance

- [ ] Unit tests 仍全數通過。
- [ ] E2E tests 更新為 v2.2.1 與實際 title。
- [ ] Manual checklist 更新為 v2.2.1。
- [ ] 打包後 `/Applications/Whisper STT.app` 或新品牌 App 可開啟。
- [ ] macOS TCC 權限文字與實際 App 名稱一致。
- [ ] 窄視窗下 header、quick-bar、actions 不重疊。
- [ ] Light / dark theme 都可讀。

## 11. 決策點

| Decision | Options | Recommendation |
|---|---|---|
| Product name | `Whisper STT` / `Echo` / `Echo by Whisper` | 若短期交付給內部使用者，建議先維持 `Whisper STT`，避免 TCC、bundle、文件大規模重命名風險；`Echo` 可作為 v2.3 branding spike |
| Summary/timeline | 顯示 placeholder / hidden until ready / implement now | v2.2.1 建議保留 tabs，但 empty state 明確標示觸發條件；不要承諾尚未完成的自動摘要 |
| Diarization beta | 放在主畫面 / 放在 Preferences advanced / hidden | 放在 Preferences advanced，並保留狀態檢查；不要進入主錄音流程 |
| System audio guide | toast only / inline guide / modal wizard | toast + inline guide；權限 denied 時才用 modal 或 blocking alert |

## 12. 建議下一步

1. 先確認交付名稱是否維持 `Whisper STT`。
2. 依 P0 scope 做一輪交付一致性修補。
3. 更新 manual checklist 與 e2e tests。
4. 開啟 App 做 5-10 分鐘實機驗證。
5. 若 P0 全過，再處理 P1 的 mode helper、vocabulary、result workspace、preferences grouping。
