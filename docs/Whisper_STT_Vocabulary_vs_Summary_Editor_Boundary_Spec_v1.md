# Whisper STT Vocabulary vs Summary Editor Boundary Spec v1

## 1. BLUF

Whisper 的 `加入本次專有名詞` 不應與 `summary` 編輯功能合併思考。兩者有上下游關係，但屬於不同層級：

- `本次專有名詞 / 常用詞庫` 屬於 **STT 前置輔助與校正資產**
- `summary` 編輯屬於 **STT 後處理與會議輸出編修**

產品上應明確拆成兩個模組：

1. `STT Vocabulary / Correction Dictionary`
2. `Meeting Summary Editor`

未來演進方向是：`加入本次專有名詞` 先維持為本次 hotwords / context 提示，再逐步升級為可持久化的 `STT 校正字典庫`；而 `summary` editor 保持專注於 AI 摘要結果的人工作業與輸出品質。

## 2. 背景

目前 repo 中與詞彙相關的能力包含：

- 前端 `加入本次專有名詞，按 Enter 套用`
- `extra_terms` 傳入後端
- `build_prompt()` / domain prompt 將 `extra_terms` 注入 STT / LLM 相關提示
- localStorage 型常用詞庫 UI

同時，新的 `summary` 路線已在：

- `Whisper_Summary_Unification_Implementation_Spec_v2.md`

中定義為 transcript 完成後生成 canonical summary，並允許使用者編輯後再輸出到 Obsidian / Notion。

因此需要一份邊界 spec，避免後續把「STT 辨識校正」與「摘要人工修稿」混成一條功能線。

## 3. 問題定義

### 3.1 容易被誤解為同一功能

使用者很容易把「專有名詞輸入」、「詞庫」、「摘要修正」都理解成「修正 AI 內容」，但實際上三者作用點不同。

### 3.2 若不拆邊界，會導致錯誤投資方向

若把 summary editor 當成 STT 字典的替代品，團隊會把大量時間花在事後修稿，而不是提升 transcript 準確率。

### 3.3 會造成資料模型混亂

若同一套資料同時承擔：

- 本次提示詞
- 長期校正字典
- 摘要編輯內容

則很容易出現用途不清、同步規則混亂與 UI 心智模型不一致。

## 4. 核心原則

### 4.1 先打準 transcript，再優化 summary

STT 的第一責任是把原始逐字稿辨識正確。摘要編輯不能拿來補救所有辨識錯誤。

### 4.2 會議詞彙是上游資產，摘要編輯是下游工作台

- 詞彙 / 字典影響的是 transcript 的原始品質
- summary editor 影響的是產出可用性與對外可讀性

### 4.3 本次詞彙與長期字典要分層

`本次專有名詞` 是會議當次上下文。  
`常用詞庫 / 校正字典` 是可重複使用的長期資產。  
這兩者可以相連，但不能完全等同。

## 5. 模組邊界

## 5.1 模組 A：STT Vocabulary / Correction Dictionary

### 定義

負責提升 transcript 在 STT 階段的辨識正確率，特別是：

- 專有名詞
- 公司名稱
- 產品名
- 人名
- 固定術語
- 中英夾雜縮寫

### 子層

1. `Session Vocabulary`
   - 本次會議有效
   - 來源：使用者本次輸入的專有名詞
   - 生命周期：本次 transcript / session

2. `Saved Vocabulary Library`
   - 使用者儲存的常用詞彙
   - 可跨 session 重用
   - 仍偏「提示詞資產」

3. `Correction Dictionary`
   - 更進一步的 STT 校正層
   - 不只提示模型，還能做 transcript 後處理校正
   - 例如：`DGS -> DGX`、`tempore -> timecode`

### 主要責任

1. 提供本次 transcript 的詞彙上下文
2. 提升 STT 專有名詞準確率
3. 累積可重複使用的詞彙資產
4. 在未來支援規則式校正或 post-STT normalization

### 非責任

1. 不負責決策摘要
2. 不負責 action item 編修
3. 不負責最終會議輸出編輯

## 5.2 模組 B：Meeting Summary Editor

### 定義

負責 transcript 完成後的 AI 摘要生成、人工修改與輸出控制。

### 主要責任

1. 顯示 `generated_summary`
2. 允許使用者編輯為 `edited_summary`
3. 控制輸出到 Obsidian / Notion 的最終版本
4. 改善會議成果的可讀性、可交付性、可追蹤性

### 非責任

1. 不負責修正整份 transcript 的 STT 準確率
2. 不應被當成專有名詞字典替代品
3. 不應承擔熱詞注入或 STT prompt management

## 6. 關聯關係

### 6.1 上下游關係

流程應為：

1. `Session Vocabulary / Dictionary`
2. STT transcript 生成
3. canonical summary 生成
4. summary editor 人工修正
5. Obsidian / Notion 輸出

也就是說，Vocabulary 模組在上游，Summary Editor 在下游。

### 6.2 影響方式

- 詞彙做得好，summary 需要人工修的量會下降
- 但即使 transcript 完全正確，summary 還是可能需要 PM / Program Manager（專案經理）判斷與人工整理

因此兩者互相影響，但不可互相取代。

## 7. 產品設計建議

### 7.1 `加入本次專有名詞` 的正確定位

目前應定義為：

**本次 STT context / hotwords 輸入**

UI 心智模型應清楚表達：

- 這些詞會影響本次 transcript
- 不等於一定永久保存
- 不等於 summary 編輯內容

### 7.2 `常用詞庫` 的正確定位

目前應定義為：

**Saved Vocabulary Library**

它是常用詞彙集合，而不是完整 `Correction Dictionary`。  
未來可以演進為更正式的 STT 校正字典，但第一階段不必一次做到太重。

### 7.3 `STT 校正字典庫` 的演進方向

未來可在 `Saved Vocabulary Library` 之上加一層更強的 dictionary schema，例如：

- canonical term
- possible misheard variants
- domain / client / project tags
- language / abbreviation metadata

例如：

```text
canonical: DGX
variants: DGS, dgx, DG-X
domain: tech
project: Whisper
```

此時它就不只是提示詞，而是 **STT normalization asset**。

### 7.4 `summary` editor 的正確定位

summary editor 不應承擔：

- 修復所有 STT 人名錯誤
- 補救所有 transcript 錯字
- 儲存詞彙資產

它應聚焦在：

- 摘要整理
- 決策整理
- 行動事項整理
- 對外輸出版面

## 8. 資料模型建議

## 8.1 Session Vocabulary

最小模型：

- `terms: string[]`
- `source: manual | library`
- `session_id`

## 8.2 Saved Vocabulary Library

最小模型：

- `term`
- `created_at`
- `last_used_at`
- `usage_count`

## 8.3 Correction Dictionary

未來模型建議：

- `canonical_term`
- `variants[]`
- `domain`
- `project`
- `language`
- `notes`

## 8.4 Summary Editor

沿用 v2 spec：

- `generated_summary`
- `edited_summary`
- `is_summary_edited`
- `effective_summary`

## 9. UX 規格建議

### 9.1 主畫面詞彙區

建議文案保持明確：

- 輸入框：`加入本次專有名詞，按 Enter 套用`
- 按鈕：`開啟常用詞庫`

並補一句 helper：

- `影響本次轉錄辨識，不會直接修改摘要內容`

### 9.2 常用詞庫

建議明確區分：

- `本次已套用`
- `已儲存詞庫`

避免使用者誤以為「輸入一次就永久生效」或「刪詞庫等於刪本次 tag」。

### 9.3 Summary 分頁

建議補一句邊界說明：

- `摘要來自 transcript，自動生成後可人工編輯`

避免使用者以為在 summary 裡修詞就等於修正了原始 transcript。

## 10. 路線圖建議

### Phase 1

維持現有 `extra_terms` + localStorage 常用詞庫，明確 UI 心智模型。

### Phase 2

把常用詞庫從單純 string list 升級為結構化 vocabulary library。

### Phase 3

加入 correction dictionary / transcript normalization 能力。

### Phase 4

讓 dictionary 可依 domain / project / client profile 自動套用。

Summary Editor 則維持獨立演進，不與字典系統混成同一模組。

## 11. Acceptance Criteria

### AC-1 Boundary clarity

產品文件與實作規格明確區分：

- STT Vocabulary / Dictionary
- Meeting Summary Editor

### AC-2 Session vocabulary scope

`加入本次專有名詞` 被定義為本次 transcript 的 STT context，不被誤定義為 summary 編輯器的一部分。

### AC-3 Library evolution path

`常用詞庫` 被定義為 vocabulary library，可演進為 correction dictionary，但目前不等同於 summary 存檔內容。

### AC-4 Output responsibility

Obsidian / Notion 的 summary 輸出優先來自 `effective_summary`，而不是詞庫內容本身。

### AC-5 Upstream/downstream model

團隊共識明確：Vocabulary 是上游 transcript quality 模組；Summary Editor 是下游 output quality 模組。

## 12. 建議下一步

1. 在 UI / spec 層明確把 `本次專有名詞` 定位成 STT context
2. 在後續 Summary Editor 實作中，不把詞庫與 summary 狀態混存
3. 未來若要提升 transcript 準確率，再另開 `Correction Dictionary` spec，而不是把需求塞進 summary editor

