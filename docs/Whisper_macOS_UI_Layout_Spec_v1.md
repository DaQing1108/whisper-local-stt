# Whisper macOS UI Layout Spec v1

- Date: 2026-07-02
- Owner: Alex Liao / VIA AI Learning RD Center
- App Scope: Whisper STT macOS app
- Target App Version: post-v2.2.1 layout refinement baseline
- Status: Draft for design and implementation alignment
- Source Baseline: current v2.2.1 screenshot review, existing `Whisper_App_v2.2.1_UIUX_Optimization_Plan.md`, current macOS desktop usage expectations

## 1. BLUF

Whisper 目前的主畫面已具備乾淨、可信任的基礎，但若要更完整地適用於 macOS，下一步不應只是調整樣式，而要把整體畫面改成更符合桌面 App 的資訊層級與操作節奏。建議將主介面收斂為 `Toolbar + Main Capture Panel + Context Bar + Results Workspace + Action Bar` 的五段式結構，讓使用者在任何時間點都能立即回答三件事：現在是否可開始錄音、目前採用哪種來源/模式、結果會輸出到哪裡。

本 spec 的目標不是重做產品功能，而是用 macOS 原生感的佈局邏輯，重新整理現有功能的主次順序、控制項位置、狀態呈現、視窗縮放行為與操作密度，讓 Whisper 更像一個可長時間使用的本地桌面工具，而不是包在 `.app` 裡的單頁 Web UI。

## 2. Spec Goal

### 2.1 Primary goals

1. 讓使用者在 3 秒內看懂目前狀態與下一步操作。
2. 讓錄音區成為唯一視覺主角，避免設定與輸出資訊分散注意力。
3. 讓主畫面符合 macOS desktop app 的視窗結構與控制項密度。
4. 讓結果區成為穩定的工作台，而不是錄音完成後才臨時可用的附屬區塊。
5. 讓 `Notion`、`Obsidian`、`Export` 這類輸出動作以狀態導向方式整合，而不是零散開關。

### 2.2 Non-goals

1. 本 spec 不新增新的 AI 功能或模型能力。
2. 本 spec 不處理 Windows / mobile 跨平台設計。
3. 本 spec 不重寫 Preferences 全部內容，只定義主畫面與主工作流相關的入口與層級。

## 3. Current Layout Problems

根據 v2.2.1 畫面，現況主要有以下佈局問題：

| Priority | Issue | Impact |
|---|---|---|
| P0 | 頂部列同時承載品牌、版本、整合開關、同步狀態、設定、外觀切換 | 第一眼重點不明，像設定列多於工作列 |
| P0 | 中央主區視覺焦點不夠集中，圓環、說明卡、`STANDBY_` 分散注意力 | 使用者不易快速理解目前是否可錄音 |
| P0 | 權限/模式提示卡長期佔據主畫面大面積空間 | 主畫面容易看起來像 onboarding 或設定頁 |
| P1 | 模型、語言、來源、領域以 chip 方式平鋪，但層級相同 | 進階參數與日常高頻資訊混在一起 |
| P1 | 專有名詞欄位孤立存在，缺乏「會議上下文」整體概念 | 使用者不容易理解其對辨識準確度的價值 |
| P1 | Transcript tabs 與底部操作按鈕距離太遠 | 操作與內容斷裂，桌面工作流不夠順 |
| P1 | `Notion` / `Obsidian` 以 toggle 呈現，但本質是輸出目的地與連線狀態 | 心智模型錯置，容易誤解為即時功能開關 |

## 4. macOS Design Principles

本版型需遵守以下 macOS 導向原則：

1. 主視窗優先反映「狀態」而不是「設定」。
2. 主按鈕數量少，且層級明確，只保留一個 primary action。
3. 平常畫面保持乾淨，只有在權限錯誤、設定缺失、處理中時才升高提示密度。
4. 常用控制項靠近內容，不讓使用者在頁面上下大範圍移動視線。
5. 視窗縮放後仍需維持可理解的布局，不依賴固定寬度長頁。
6. 控制項視覺與互動節奏盡量靠近 macOS 原生邏輯，例如 toolbar、segmented control、popover、status badge、sidebar-like content framing。

## 5. Target Information Architecture

### 5.1 Top-level layout

主視窗改為五段式結構：

1. `Toolbar`
2. `Main Capture Panel`
3. `Context Bar`
4. `Results Workspace`
5. `Action Bar`

### 5.2 Layout responsibilities

| Zone | Purpose | Must Answer |
|---|---|---|
| Toolbar | 顯示 App 身分、目前模式、輸出狀態、設定入口 | 這是哪個 App、現在用什麼模式、輸出目的地是否正常 |
| Main Capture Panel | 顯示錄音狀態與主操作 | 現在能不能開始錄、目前在做什麼 |
| Context Bar | 管理本次會議上下文與必要參數 | 這次轉錄要用什麼語言、來源、詞彙與領域 |
| Results Workspace | 顯示逐字稿、摘要、timeline | 結果在哪裡、目前是否有可處理內容 |
| Action Bar | 放置 copy/export/integrations | 完成後下一步能做什麼 |

## 6. Layout Spec

### 6.1 Toolbar

Toolbar 應模仿 macOS 視窗上方工作列，而非網站 header。

#### Required items

| Position | Element | Behavior |
|---|---|---|
| Left | App icon + `Whisper STT` | 固定顯示，不再在主畫面重複放大品牌 |
| Center | Current mode label | 顯示 `系統音訊`、`麥克風`、`混音模式` 其中之一 |
| Right | Output status capsule | 顯示 `Obsidian 已啟用`、`Notion 未連線` 等摘要 |
| Right | Settings button | 開啟 Preferences |
| Right | Appearance button | Light / Dark 或跟隨系統 |

#### Layout rules

1. 移除目前將 `Notion`、`Obsidian` 分散為獨立 switch 的作法。
2. `v2.2.1` 版本號不應常駐在主視覺第一層，可移至 About、tooltip 或次要 metadata。
3. Output status capsule 可點擊展開 popover，顯示：
   - Obsidian path 是否有效
   - Notion token / page 是否已設定
   - 最近一次同步結果

### 6.2 Main Capture Panel

這是整個主畫面的唯一視覺主角。

#### Required content

1. 一個主狀態文字：
   - `待命中`
   - `錄音中`
   - `轉寫中`
   - `已完成`
2. 一個主操作按鈕：
   - `開始錄音`
   - `停止錄音`
   - `處理中...`
3. 一行次要說明：
   - `來源：系統音訊（Teams / Zoom / 播放聲音）`
   - `來源：麥克風`
   - `來源：系統音訊 + 麥克風`
4. 一行輔助狀態：
   - `螢幕錄製權限已授權`
   - `尚未取得系統音訊權限`
   - `正在整理第 3 / 8 段音訊`

#### Layout rules

1. 保留現有圓形或圓環語言可以，但必須服務於狀態辨識，不可大於主操作本身的重要性。
2. `STANDBY_` 這類偏 terminal 風格字樣可保留為品牌細節，但不應取代真正的人類可讀狀態。
3. 權限或模式說明不應長駐為大卡片；只有異常或首次模式切換時才展開。

### 6.3 Permission and Guidance Strip

原本的大型淡綠色說明卡，應改成 inline guidance strip。

#### Default state

- 顯示為單行，例如：`系統音訊已就緒`
- 顏色低干擾，不搶主操作

#### Expanded state triggers

1. 第一次切換到 `系統音訊`
2. 權限 denied
3. 偵測到使用者選擇混音模式但尚未允許麥克風

#### Expanded content

- 問題摘要
- 最多 3 步修復說明
- `前往系統設定`
- `稍後再說`

### 6.4 Context Bar

Context Bar 是本次轉錄的工作上下文，不應只是零散的 chips。

#### Required groups

| Group | Control Type | Notes |
|---|---|---|
| 語言 | Pop-up button | 預設顯示 `zh` 或 `自動偵測` |
| 音訊來源 | Segmented control | `麥克風` / `系統音訊` / `混音` |
| 模型 | Pop-up button or secondary menu | 平常只顯示目前值，例如 `large-v3` |
| 領域/模板 | Pop-up button | 例如 `通用`、`會議`、`技術討論` |
| 會議上下文 | Expandable field group | 包含專有名詞與本次提示 |

#### Vocabulary behavior

將目前的 `加入本次專有名詞，按 Enter 套用` 改為 `會議上下文` 區塊。

區塊內至少包含：

1. `本次專有名詞`
2. `已套用詞彙 tags`
3. `開啟常用詞庫`

此變更的目的，是讓使用者理解這不是單一輸入框，而是提升轉錄品質的上下文配置。

### 6.5 Results Workspace

Results Workspace 應是整個 App 的第二主區塊，負責承接錄音後的所有處理工作。

#### Structure

1. Header row
2. Tab row
3. Content pane

#### Header row content

| Position | Element |
|---|---|
| Left | Current result title 或 `本次轉錄結果` |
| Right | duration / timestamp / word count / processing status |

#### Tab row

- `Transcript`
- `Summary`
- `Timeline`
- `History` 可考慮收進右側按鈕或次層，不一定與前三者同級

#### Content rules

| Tab | Empty State | Ready State |
|---|---|---|
| Transcript | `轉錄結果會出現在這裡` | 支援瀏覽、選取、編輯 |
| Summary | `完成轉錄並設定 LLM 後可產生摘要` | 顯示摘要、決策、行動項 |
| Timeline | `偵測到時間碼後會在此整理段落` | 顯示 time segments |

#### Layout rules

1. 結果區需與操作列在視覺上相連，不應分隔過遠。
2. 若畫面高度不足，優先保留結果區高度，而不是讓上方說明與空白區佔據空間。
3. 空狀態文案要像產品文案，不應像開發 placeholder。

### 6.6 Action Bar

Action Bar 應固定貼近 Results Workspace 底部，承接結果後處理。

#### Recommended button order

1. `匯出`
2. `Copy`
3. `存到 Obsidian`
4. `送到 Notion`
5. `清除`

#### State rules

| Action | Disabled Condition | Required Feedback |
|---|---|---|
| 匯出 | 無 transcript | 顯示 `尚無可匯出的內容` |
| Copy | 無 transcript | 顯示 `完成轉錄後可複製` |
| 存到 Obsidian | vault path 未設定 | 顯示 `請先在設定中指定 Obsidian 路徑` |
| 送到 Notion | token/page 未設定 | 顯示 `請先完成 Notion 設定` |
| 清除 | 無內容時可保留可點或 disabled | 若有內容需二次確認或 undo |

#### Hierarchy rules

1. 不要讓五個按鈕看起來權重完全一致。
2. 一次只應有一個 primary action。
3. destructive action 必須與主要操作保持距離。

## 7. Window Behavior Spec

### 7.1 Default window size

建議以 `regular desktop` 為主要設計基準，避免以單一長頁思維處理。

### 7.2 Responsive window modes

| Mode | Approx Behavior | Layout Change |
|---|---|---|
| Compact | 窄視窗 | Toolbar 右側狀態收斂，Context Bar 可換成兩列 |
| Regular | 預設桌面使用 | 完整五段式布局 |
| Expanded | 寬視窗 | 可增加右側 metadata pane 或 history pane |

### 7.3 Resize rules

1. 視窗變矮時，優先壓縮 hero 空白，不壓縮結果區可讀性。
2. 視窗變窄時，將次要設定收進 popover，不讓 toolbar 擁擠換行。
3. `Results Workspace` 應至少維持一個穩定最小高度，避免只剩空白殼。

## 8. macOS Native-Fit Requirements

### 8.1 Native-feel controls

建議主畫面逐步向下列互動語言靠攏：

1. Toolbar buttons
2. Segmented control
3. Pop-up menu
4. Status capsule / badge
5. Popover for secondary settings

### 8.2 Keyboard shortcuts

主畫面至少應明示或支援：

| Shortcut | Action |
|---|---|
| `⌘R` | 開始 / 停止錄音 |
| `⌘U` | 上傳音檔 |
| `⌘C` | 複製 transcript |
| `⌘,` | 開啟設定 |

### 8.3 Accessibility and readability

1. 中文主文案優先，不要讓英文小字成為狀態主體。
2. Mono font 可用於技術狀態與 chips，但不應主導整個介面。
3. 狀態顏色必須有文字對應，不可只靠顏色表意。

## 9. Suggested Wireframe

```text
+----------------------------------------------------------------------------------+
| Whisper STT                    系統音訊                    輸出：Obsidian 已啟用  ⚙ |
+----------------------------------------------------------------------------------+
|                                                                                  |
|                                  待命中                                          |
|                              [ 開始錄音 ]                                        |
|                    來源：系統音訊（Teams / Zoom / 播放聲音）                      |
|                         系統音訊已就緒                                           |
|                                                                                  |
+----------------------------------------------------------------------------------+
| 語言: zh   來源: 系統音訊   模型: large-v3   領域: 通用   會議上下文 ▾           |
| 本次專有名詞: [Notion] [Whisper] [Zoom]                    開啟常用詞庫           |
+----------------------------------------------------------------------------------+
| 本次轉錄結果                                            52 min · 3,482 chars     |
| Transcript | Summary | Timeline                                                |
|----------------------------------------------------------------------------------|
|                                                                                  |
| 轉錄結果內容                                                                      |
|                                                                                  |
|                                                                                  |
+----------------------------------------------------------------------------------+
| 匯出            Copy            存到 Obsidian            送到 Notion       清除   |
+----------------------------------------------------------------------------------+
```

## 10. Implementation Mapping

### 10.1 Likely file touchpoints

| Area | Candidate Files |
|---|---|
| Main layout structure | `templates/index.html` |
| Main UI behavior | `static/app.js` |
| Main UI styling | `static/app.css` |
| Preferences entry / output status interaction | `templates/preferences.html`, `static/preferences.js` |
| Keyboard shortcut labeling | `static/app.js` |

### 10.2 Recommended implementation slices

1. `layout/toolbar-refactor`
2. `layout/capture-panel-rebalance`
3. `layout/context-bar-restructure`
4. `layout/results-action-unification`
5. `ux/permission-guidance-inline`

## 11. Acceptance Criteria

### 11.1 Product-level acceptance

- [ ] 使用者第一次看主畫面時，可在 3 秒內辨識主操作與目前狀態。
- [ ] 上方不再同時存在多個分散的 integration toggles。
- [ ] 主畫面不再由常駐大型說明卡主導。
- [ ] `Transcript` 內容區與底部 actions 在視覺上形成同一工作區。
- [ ] 視窗縮小時，結果區仍維持可讀，不會被大面積空白與說明區擠壓。
- [ ] `Notion` / `Obsidian` 的狀態被理解為輸出目的地，而不是單純 on/off 開關。

### 11.2 macOS-fit acceptance

- [ ] Toolbar、主操作、次要設定之間具備清楚層級。
- [ ] 控制項類型更接近 macOS 桌面 App 習慣，而非單頁網站表單。
- [ ] 畫面在 `Compact`、`Regular`、`Expanded` 三種視窗寬度下都有穩定布局策略。
- [ ] 快捷鍵與設定入口符合 macOS 使用者預期。

## 12. Open Decisions

下列項目在進入實作前需要定版：

1. 對外品牌名稱最終是 `Whisper STT`、`Whisper AI Meeting`，或其他統一名稱。
2. `History` 是否維持與 transcript/summary/timeline 同級 tab。
3. `Summary` / `Timeline` 是否在未滿足條件時保留 tab，或改為延後顯示。
4. Output status capsule 是否只顯示一個整體摘要，或允許展開雙列細節。

## 13. Recommended Next Step

建議下一步直接產出一份實作導向文件 `Whisper_macOS_UI_Implementation_Plan_v1`，把本 spec 拆成：

1. HTML 結構調整
2. CSS layout tokens 與 spacing 規範
3. JS 狀態機調整
4. 窄視窗與快捷鍵驗收清單
