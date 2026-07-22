# Whisper UI Implementation Plan v1

- Date: 2026-07-02
- Owner: Alex Liao / VIA AI Learning RD Center
- App Scope: Whisper STT macOS desktop app
- Design Decision Source: `Whisper_UI_Final_Direction_Decision_v1.md`
- Layout Spec Source: `Whisper_macOS_UI_Layout_Spec_v1.md`
- Status: Ready for frontend implementation planning

## 1. BLUF

本文件的目的，是把已選定的 UI 方向拆成可以直接執行的實作清單。後續實作一律以 **版本 3 作為主設計方向**，搭配 **版本 2 的品牌語言**，並受 **版本 1 的 layout discipline** 約束。

本次不建議一口氣重寫整個前端，而是採用三階段做法：

1. 先完成靜態版型與視覺層級重整
2. 再補狀態互動與 disabled reasons
3. 最後再處理 compact 窄視窗與細節 polish

## 2. Implementation Goal

### 2.1 Primary outcomes

1. 將現有單欄畫面收斂成五段式結構：
   - Toolbar
   - Main Capture Panel
   - Context Bar
   - Results Workspace
   - Action Bar
2. 讓主畫面第一眼只突出一件事：錄音狀態與主操作
3. 將 `Notion` / `Obsidian` 從獨立 toggle 轉為輸出狀態導向設計
4. 讓 transcript 工作區與 action buttons 成為同一個操作面
5. 建立後續 compact behavior 與樣式 token 的基礎

### 2.2 Non-goals

1. 這一輪不重做完整 Preferences 架構
2. 這一輪不新增新的後端 API
3. 這一輪不處理完整品牌 rename 決策以外的商業包裝內容

## 3. File Touchpoints

| Area | Files | Expected Change |
|---|---|---|
| Main layout structure | `templates/index.html` | 重組區塊結構與 DOM hierarchy |
| Main styling | `static/app.css` | 新增 layout tokens、toolbar、capture panel、workspace styles |
| Main behavior | `static/app.js` | 狀態文案、toolbar 狀態同步、guidance strip 狀態、action states |
| Preferences entry sync | `templates/preferences.html`, `static/preferences.js`, `static/preferences.css` | 視需要補充與主畫面一致的狀態命名 |
| Branding / title sync | `README.md`, `tests/e2e/test_ui.py`, `tests/manual_checklist.md` | 依最終 UI 顯示名稱補充驗收一致性 |

## 4. Implementation Strategy

### Phase 1: Static layout pass

這一階段先做版面，不急著改大量邏輯。

#### Goal

讓畫面在不大改資料流的前提下，先達到新結構與主次層級。

#### Tasks

1. 重組頁面骨架為五段式結構
2. 把目前過度分散的 header 資訊收斂成 toolbar
3. 讓主錄音區成為唯一 hero
4. 將結果區與 action row 整合成同一 card/workspace
5. 將大型系統音訊說明卡收斂成 slim strip

### Phase 2: Interaction polish

這一階段補上狀態導向的互動。

#### Goal

讓新布局不只是靜態漂亮，而是真的可用。

#### Tasks

1. toolbar 模式與輸出狀態同步
2. guidance strip 依權限與模式切換顯示
3. action buttons 顯示 disabled reason
4. summary / timeline 空狀態改為產品文案
5. 詞庫區塊改為更完整的 `會議上下文` 心智模型

### Phase 3: Compact behavior

這一階段處理窄視窗下的穩定度。

#### Goal

讓 Whisper 在小視窗下仍像 macOS app，而不是被壓扁的桌面網頁。

#### Tasks

1. 定義 toolbar 收斂策略
2. 定義 context bar 換行/收折策略
3. 定義 results workspace 最小高度
4. 微調 action row 在窄寬度下的排列

## 5. HTML Plan

### 5.1 `templates/index.html`

#### Current problem

目前頁面雖有功能分區，但仍較像單頁堆疊內容，缺乏明確的 app-shell 結構。

#### Target structure

建議重組成：

```text
app-shell
  toolbar
  main-content
    capture-panel
    guidance-strip
    context-bar
    results-workspace
      workspace-header
      workspace-tabs
      workspace-content
      workspace-actions
```

#### Required edits

1. 將目前頂部品牌列重構為 `toolbar`
2. 將中央狀態圓環與主按鈕包成 `capture-panel`
3. 將系統音訊提示從大卡片抽成 `guidance-strip`
4. 將模型/語言/來源/領域 chips 包成 `context-bar`
5. 將 transcript 區與底部 actions 收進同一個 `results-workspace`

#### Suggested DOM naming

1. `app-toolbar`
2. `toolbar-mode`
3. `toolbar-output-status`
4. `capture-panel`
5. `capture-status`
6. `capture-primary-action`
7. `guidance-strip`
8. `context-bar`
9. `meeting-context`
10. `results-workspace`
11. `workspace-actions`

## 6. CSS Plan

### 6.1 `static/app.css`

#### Goal

用 CSS 先建立「更成熟的商業版 Whisper」視覺秩序。

#### New style priorities

1. 建立一致的 spacing scale
2. 收斂 card radius 與 border strength
3. 將 accent green 用在 primary action、active tab、ready state
4. 用更輕的陰影和更清楚的 surface 層級建立 premium 感

### 6.2 Recommended token groups

建議整理成以下 token 類型：

1. `--bg-app`
2. `--bg-surface`
3. `--bg-muted`
4. `--border-soft`
5. `--border-strong`
6. `--text-primary`
7. `--text-secondary`
8. `--accent-mint`
9. `--accent-mint-soft`
10. `--shadow-card`
11. `--radius-card`
12. `--radius-pill`

### 6.3 Component styling tasks

#### Toolbar

1. 降低 header 視覺噪音
2. 讓右上控制變成一組節奏一致的工具列按鈕
3. 讓 output status 顯示成 capsule，而非平鋪文字

#### Capture panel

1. 保留 Whisper 圓形視覺語言，但縮到更克制
2. 強化主狀態與主按鈕層級
3. 減少空白只是為了大，而是要讓留白服務聚焦

#### Guidance strip

1. 改成 slim inline strip
2. 成功/警告/錯誤三種狀態需有對應樣式
3. 不再像大面積 onboarding 提示卡

#### Context bar

1. 保留 chip 語感，但層級要更像 control row
2. 音訊來源可視情況改為 segmented style
3. 詞庫區塊需與一般 chip 群明顯區隔

#### Results workspace

1. 加強 workspace card 一體感
2. transcript tabs、內容區、actions 形成連續層級
3. 空狀態的留白要乾淨，但不能顯得未完成

#### Action bar

1. 主要按鈕與次要按鈕的層級需清楚
2. `trash` 需要更輕、更遠離主操作
3. disabled state 要更可理解，不只是變灰

### 6.4 Responsive rules

#### Regular

- 完整展示 toolbar、capture panel、context bar、workspace

#### Compact

1. toolbar 右側控制收斂
2. context bar 可換為兩列
3. actions 可自動換行或收斂成較緊湊排列
4. workspace 保持優先高度

## 7. JavaScript Plan

### 7.1 `static/app.js`

#### Goal

讓新版 UI 的狀態呈現與互動節奏成立。

#### Required behavior changes

1. toolbar 中的 mode label 要與當前模式同步
2. toolbar output status 要能反映 Obsidian / Notion readiness
3. guidance strip 要依據權限狀態與 mode 顯示不同文案
4. 結果 action buttons 要能顯示 disabled reason
5. transcript / summary / timeline 的空狀態文案改為產品級文案

### 7.2 UI state mapping

| State Area | Needed Behavior |
|---|---|
| Capture status | `待命中` / `錄音中` / `轉寫中` / `已完成` |
| Source subtitle | 根據麥克風 / 系統音訊 / 混音切換 |
| Guidance strip | hidden / ready / first-time tip / denied / warning |
| Output status | Obsidian ready, Notion ready, partial ready, not configured |
| Action buttons | enabled / disabled + reason |

### 7.3 Suggested JS tasks

1. 抽一個更新 toolbar 狀態的 render function
2. 抽一個更新 capture panel 文案的 render function
3. 抽一個 guidance strip state mapper
4. 抽一個 action button state/tooltip updater
5. 抽一個 results empty-state copy updater

## 8. Copy Plan

### 8.1 Status copy

建議統一使用中文主文案：

| Area | Recommended Copy |
|---|---|
| Idle | `待命中` |
| Recording | `錄音中` |
| Processing | `轉寫中` |
| Done | `已完成` |
| Empty transcript | `轉錄結果會出現在這裡` |
| Empty summary | `完成轉錄並設定 LLM 後可產生摘要` |
| Empty timeline | `偵測到時間碼後會在此整理段落` |

### 8.2 Guidance copy

| State | Recommended Copy |
|---|---|
| Ready | `系統音訊已就緒` |
| First-time | `首次使用系統音訊時，請確認已允許螢幕錄製權限` |
| Denied | `尚未取得系統音訊權限，請前往系統設定完成授權後重新開啟 App` |
| Mixed warning | `若要同時收錄自己聲音，請切換混音模式並確認麥克風權限` |

## 9. Acceptance Checklist

### 9.1 Phase 1 acceptance

- [ ] DOM 結構已重整為五段式
- [ ] toolbar 不再是分散式 header
- [ ] 主錄音區成為第一視覺焦點
- [ ] transcript 區與 action row 已整合
- [ ] 大型系統音訊卡已收斂

### 9.2 Phase 2 acceptance

- [ ] mode label 會隨目前模式更新
- [ ] output status 會反映 Notion / Obsidian readiness
- [ ] guidance strip 會依權限/模式變化
- [ ] disabled actions 有原因提示
- [ ] 空狀態文字像產品文案而非 placeholder

### 9.3 Phase 3 acceptance

- [ ] 窄視窗下 toolbar 不擠爆
- [ ] context bar 可閱讀
- [ ] results workspace 保持可用高度
- [ ] actions 在小視窗下不重疊

## 10. Suggested Commit Slices

1. `ux/app-shell-layout`
2. `ux/toolbar-and-capture-panel`
3. `ux/guidance-strip-and-context-bar`
4. `ux/results-workspace-and-actions`
5. `ux/state-copy-and-disabled-reasons`
6. `ux/compact-window-behavior`

## 11. Next Recommended Action

如果下一步要直接進入實作，建議順序是：

1. 先讀 `templates/index.html`
2. 對照本文件改 DOM 結構
3. 再改 `static/app.css`
4. 最後補 `static/app.js` 的狀態 render 與 disabled reason 行為
