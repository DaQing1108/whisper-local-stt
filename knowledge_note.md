# 2026-07-02｜Whisper macOS UI 改版討論與 Claude 執行交接

## BLUF

本次已完成 Whisper 主畫面改版方向的完整收斂：先從現況截圖提出 macOS 化佈局建議，再整理成正式的 layout spec、最終設計決策與 implementation plan，最後產出可直接交給 Claude Code 執行的 `Phase 1 靜態改版` handoff。最終決策是以版本 3 作為主設計方向，版本 2 補強品牌語言，版本 1 約束版面結構。

## 討論起點

- 使用者提供 Whisper App v2.2.1 畫面截圖，要求提出更適合 macOS 的佈局優化建議。
- 重點不是只調美術，而是讓介面更像原生 macOS 工作型 App。

## 第一階段：macOS 版型優化建議

### 核心判斷

- 現有畫面基礎乾淨，但資訊重心分散
- 頂部列承載太多元素：品牌、版本、Notion、Obsidian、同步狀態、設定、Dark
- 中央主區焦點不夠集中，圓環、提示卡、`STANDBY_` 同時搶注意力
- transcript 區與底部 actions 距離過遠，工作流被切斷

### 建議的 macOS 結構

- `Toolbar`
- `Main Capture Panel`
- `Context Bar`
- `Results Workspace`
- `Action Bar`

### 關鍵建議

- 把 `Notion / Obsidian` 從分散 toggle 改成輸出狀態導向設計
- 把中央區收斂成單一主角：錄音狀態與主按鈕
- 把大型系統音訊說明卡改成 slim guidance strip
- 把 transcript / summary / timeline 與底部操作列整合成同一個 workspace
- 為 macOS 視窗定義 `Regular` 與 `Compact` 兩種 behavior，而不是做兩套平行橫直版

## 第二階段：產出正式規格文件

### 已建立文件

- `docs/Whisper_macOS_UI_Layout_Spec_v1.md`
- `docs/Whisper_UI_Final_Direction_Decision_v1.md`
- `docs/Whisper_UI_Implementation_Plan_v1.md`

### `Whisper_macOS_UI_Layout_Spec_v1.md`

內容重點：

- 明確定義五段式主畫面結構
- 說明目前 v2.2.1 畫面的核心問題
- 定義 toolbar、capture panel、guidance strip、context bar、results workspace、action bar 的責任與規則
- 加入 `Regular / Compact / Expanded` 視窗行為
- 加入 acceptance criteria 與文字 wireframe

### `Whisper_UI_Final_Direction_Decision_v1.md`

內容重點：

- 收斂三張示意稿，不再視為三套平行方案
- 版本 1 定位為結構原型
- 版本 2 定位為現有 Whisper 品牌延伸版
- 版本 3 定位為正式商業版主設計方向
- 最終決策：
  - 主設計採版本 3
  - 品牌細節參考版本 2
  - Layout discipline 遵守版本 1

### `Whisper_UI_Implementation_Plan_v1.md`

內容重點：

- 拆成 `HTML / CSS / JS / Acceptance`
- 明確指出這一輪只做 `Phase 1 靜態改版`
- 主要改動檔案：
  - `templates/index.html`
  - `static/app.css`
  - `static/app.js`
- 先不要深動：
  - `preferences` 頁面
  - 後端 API
  - 錄音與轉寫核心邏輯

## 第三階段：三版示意圖探索與收斂

### 版本 1

- 定位：`結構原型`
- 長處：版型骨架清楚，適合討論資訊架構
- 限制：品牌感弱，較像高品質 wireframe

### 版本 2

- 定位：`Whisper 現有品牌語言延伸版`
- 長處：保留薄荷綠、浮卡、mono tab、輕科技感
- 限制：升級感有限，較像「更漂亮的現況版」

### 版本 3

- 定位：`正式商業版主設計方向`
- 長處：層級最成熟、質感最高、最像可對外交付的 macOS app
- 限制：若執行時太抽離現有產品語氣，會變成 generic premium AI app

### 最終採用策略

- 主設計：版本 3
- 品牌語言：版本 2
- 結構規範：版本 1

## 第四階段：釐清「靜態改版」定義

### 算靜態改版的內容

- 重排 `templates/index.html` 的主畫面區塊結構
- 調整 `static/app.css` 的版面、卡片、字級、按鈕層級、工作區整合
- 小幅修改 `static/app.js` 以配合新 DOM 與狀態文案
- 重寫空狀態畫面與提示文案
- 補 `Compact` 窄視窗規則

### 不算靜態改版的內容

- 重寫錄音流程
- 重寫轉寫狀態機
- 改後端 API
- 重做 Notion / Obsidian 真實同步流程
- 深改 Preferences 架構

## 第五階段：交給 Claude Code 的執行 handoff

### 已建立 handoff 文件

- `HANDOFF_CLAUDE_WHISPER_UI_STATIC_REDESIGN_PHASE1.md`

### handoff 內容重點

- scope 鎖定 `Phase 1 靜態改版`
- 允許修改：
  - `templates/index.html`
  - `static/app.css`
  - `static/app.js`
- 不允許擴大到：
  - Preferences 重構
  - 後端流程
  - 錄音 / 轉寫核心
  - 打包 / Sparkle / release
- 包含：
  - BLUF
  - Locked AC
  - 可改與不可改檔案
  - 現有 git 狀態與 dirty worktree 提醒
  - 建議驗證命令
  - Claude Code 回報格式

## 重要決策摘要

### 版型決策

- 不做橫直兩套平行 UI
- 只做：
  - `Regular desktop workspace`
  - `Compact narrow-window behavior`

### 產品定位決策

- 這次不是只是畫面美化
- 目標是把 Whisper 往更完整的 macOS 商業產品體驗推進

### 實作策略決策

- 先做 `Phase 1 靜態改版`
- 再做互動 polish
- 最後再補 compact behavior 與進一步精修

## 建議後續順序

1. Claude Code 依 `HANDOFF_CLAUDE_WHISPER_UI_STATIC_REDESIGN_PHASE1.md` 實作第一輪靜態改版
2. 完成後回報：
   - 是否達成五段式結構
   - 是否保留 Whisper 品牌語言
   - 是否仍維持既有功能接線
3. 再由 Codex 或 Claude 接著進行：
   - interaction polish
   - compact layout behavior
   - 視覺細修與驗收

## 相關檔案索引

- `docs/Whisper_macOS_UI_Layout_Spec_v1.md`
- `docs/Whisper_UI_Final_Direction_Decision_v1.md`
- `docs/Whisper_UI_Implementation_Plan_v1.md`
- `HANDOFF_CLAUDE_WHISPER_UI_STATIC_REDESIGN_PHASE1.md`
