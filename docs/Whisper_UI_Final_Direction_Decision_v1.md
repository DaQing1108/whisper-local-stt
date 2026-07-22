# Whisper UI Final Direction Decision v1

- Date: 2026-07-02
- Owner: Alex Liao / VIA AI Learning RD Center
- App Scope: Whisper STT macOS desktop app
- Target Baseline: v2.2.1 UI redesign direction selection
- Status: Approved direction for next-step implementation
- Source Inputs: current v2.2.1 UI screenshot, `Whisper_macOS_UI_Layout_Spec_v1.md`, three visual exploration mockups

## 1. BLUF

Whisper 下一階段的主設計方向，建議採用 **版本 3 作為主視覺與產品化方向**，同時吸收 **版本 2 的品牌延續細節**，並用 **版本 1 的結構紀律** 作為實作時的版面準則。

這代表後續不應把三張圖視為三套平行方案，而應視為一次收斂過程：

1. `版本 1` 提供正確的 macOS 版型骨架
2. `版本 2` 提供與現有 Whisper 一致的品牌語氣
3. `版本 3` 提供正式商業版應有的成熟度與完成度

最後採用策略：

- **主設計基準：版本 3**
- **品牌語言補強：版本 2**
- **版面規範約束：版本 1**

## 2. Decision Summary

| Version | Best Role | Recommendation |
|---|---|---|
| Version 1 | 結構原型 / layout baseline | 保留結構原則，不作最終視覺主稿 |
| Version 2 | 品牌延續 / 過渡升級版 | 擷取品牌元素，不作最終主稿 |
| Version 3 | 正式商業版 / 主設計方向 | 選為最終主設計基準 |

## 3. Version-by-Version Positioning

### 3.1 Version 1

**定位：** `結構原型`

**最適合的用途：**

1. 討論資訊架構
2. 定義主要區塊順序
3. 確認主操作、toolbar、results workspace 的關係
4. 作為窄視窗重排的 layout baseline

**優點：**

1. 版型骨架清楚
2. 主操作位置明確
3. 五段式結構容易進入實作
4. 最符合 macOS 工作區導向的思考方式

**限制：**

1. 品牌感偏弱
2. 視覺完成度不足以代表最終產品
3. 較像高品質 wireframe，而非正式商業版界面

**結論：**

版本 1 很適合做為實作準則，但不適合作為最後要交付給使用者的視覺方向。

### 3.2 Version 2

**定位：** `Whisper 現有品牌語言延伸版`

**最適合的用途：**

1. 將現有產品升級，但保留既有熟悉感
2. 確保老使用者不會覺得像換產品
3. 從當前 UI 漸進式演進，而非大幅翻新

**優點：**

1. 薄荷綠、浮卡、mono tab 等 Whisper 識別度保留得最好
2. 風險低
3. 對現有使用者學習成本最低
4. 可直接回收較多目前畫面語彙

**限制：**

1. 產品升級感有限
2. 商業版成熟度不如版本 3
3. 若目標是對外交付或企業客戶使用，說服力略弱

**結論：**

版本 2 最適合提供品牌細節與過渡感，但不應成為最後主設計，否則會讓升級停留在「更漂亮的現況版」。

### 3.3 Version 3

**定位：** `正式商業版主設計方向`

**最適合的用途：**

1. 作為下一代 Whisper 主界面基準
2. 對外展示、產品交付、企業客戶 demo
3. 建立更成熟的 macOS app 產品印象

**優點：**

1. 整體完成度最高
2. toolbar、hero、results workspace 的層級最成熟
3. 更像真正 shipped 的商業產品，而不是設計草稿
4. 同時具備 Whisper 識別度與產品升級感

**限制：**

1. 若直接照圖實作，需控制不要過度精緻化而脫離現有前端結構
2. 需要刻意保留部分 Whisper DNA，避免變成 generic AI app

**結論：**

版本 3 最適合作為主設計方向，前提是它要吸收版本 2 的品牌特徵，避免過度抽離現有 Whisper 產品語氣。

## 4. Final Direction

### 4.1 Final selection

最終建議：

- **選擇版本 3 作為主設計**

### 4.2 Why Version 3 wins

1. 它最符合「正式產品」而不是「優化中的工具」定位
2. 它更能支撐 macOS 原生桌面 app 的高級感
3. 它讓 Whisper 有升級感，但不必完全放棄既有品牌
4. 它最適合作為之後設計系統、CSS token 與元件整理的上位方向

## 5. What To Keep

### 5.1 Keep from Version 1

以下元素應保留為實作硬約束：

1. 五段式結構：
   - Toolbar
   - Main Capture Panel
   - Context Bar
   - Results Workspace
   - Action Bar
2. 主操作集中化
3. 結果區與操作列靠近
4. 對 `Regular` 與 `Compact` 視窗的雙模式思考
5. 不把 Notion / Obsidian 當作分散 toggle

### 5.2 Keep from Version 2

以下元素應保留為品牌延續細節：

1. 薄荷綠 accent
2. Whisper 既有的圓角浮卡語氣
3. mono-style tab 味道
4. 輕科技感、非過度商務化的留白
5. 與目前 screenshot 相近的柔和產品氣質

### 5.3 Keep from Version 3

以下元素應作為最終主視覺主體：

1. 更克制的 toolbar
2. 更成熟的中央 hero 區
3. 更像工作台的 transcript workspace
4. 更精準的間距、邊界、陰影與層級
5. 更像正式商業 app 的整體節奏

## 6. What Not To Keep

### 6.1 Do not keep from current UI

1. 頂部過多並列的整合 toggle
2. 大面積常駐說明卡
3. 上下分離太遠的 transcript 與 action buttons
4. 主畫面大留白但狀態資訊不足的 hero 區
5. 把所有參數都當成同層 chip 排列

### 6.2 Do not keep from Version 1

1. 過於 wireframe 感的簡化視覺
2. 太中性的品牌個性

### 6.3 Do not keep from Version 2

1. 過度接近現況而造成升級感不足
2. 仍偏工具型而非正式產品型的節奏

### 6.4 Do not keep from Version 3

1. 過度 generic 的 premium AI app 視覺
2. 為了質感而犧牲 Whisper 現有辨識度

## 7. Layout Strategy Decision

### 7.1 Supported layout modes

這次不建議做成兩套平行 UI，而是採用：

1. `Regular desktop workspace`
2. `Compact narrow-window behavior`

### 7.2 Explicit decision

- **有主版型**
- **有縮窗重排規則**
- **沒有完全獨立的直式版本**

理由：

1. macOS 使用情境仍以桌面橫向工作區為主
2. 獨立直式版會增加設計與前端維護成本
3. 以同一套設計語言做 `Regular -> Compact` 過渡，比雙版本更穩定

## 8. Implementation Priority

### P0

1. 收斂 toolbar 結構
2. 重做中央 Main Capture Panel 層級
3. 將系統音訊說明卡改成 slim guidance strip
4. 讓 results workspace 與 action bar 視覺整合

### P1

1. 將 chips 重組為 Context Bar
2. 將專有名詞輸入改成 `會議上下文` 區塊
3. 重新整理結果區 metadata 與 tab header
4. 收斂按鈕主次層級

### P2

1. 定義 compact 窄視窗布局
2. 補齊快捷鍵顯示與 hover/disabled states
3. 微調高級感細節，例如陰影、透明層次、細邊框

## 9. Recommended Build Plan

### Phase 1: Static layout pass

先不改動太多資料流，優先處理：

1. HTML 結構
2. CSS layout
3. 視覺層級

### Phase 2: Interaction polish

再補：

1. toolbar 狀態互動
2. guidance strip 開合
3. output status capsule 行為
4. action disabled reasons

### Phase 3: Compact behavior

最後處理：

1. 窄視窗重排
2. 小尺寸間距調整
3. 最小高度與結果區可讀性

## 10. Final Instruction for Design and Frontend

後續所有設計與實作，如未特別例外，統一遵守以下原則：

1. 以 **版本 3** 為主視覺方向
2. 以 **版本 2** 補強 Whisper 品牌語言
3. 以 **版本 1** 約束資訊架構與 layout discipline
4. 不再回到三案平行發展
5. 先完成主版型，再處理 compact behavior

## 11. Next Step

建議下一步直接建立一份實作文件：

- `Whisper_UI_Implementation_Plan_v1.md`

內容應至少包含：

1. `templates/index.html` 結構調整清單
2. `static/app.css` 視覺層級與 token 調整清單
3. `static/app.js` 狀態與互動調整清單
4. 驗收用 screenshot checklist
