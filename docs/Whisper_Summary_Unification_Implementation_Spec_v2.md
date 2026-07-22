# Whisper Summary Unification Implementation Spec v2

## 1. BLUF

Whisper 應將 AI 會議摘要從 `save_to_obsidian()` 後置流程中抽離，改為在 transcript 完成後就生成一份 canonical summary draft，並在 app `summary` 分頁中提供可編輯版本。後續 Obsidian 與 Notion 應優先存使用者編輯後的 summary，若尚未編輯才 fallback 到 AI 初稿。這樣可同時解掉目前 `summary` 分頁是 placeholder 的 UX 落差，以及多出口各自重生摘要可能造成的內容不一致問題。

## 2. 背景

目前 repo 的摘要鏈路如下：

1. 前端 `Obsidian` 按鈕呼叫 `/api/save_to_obsidian`
2. `routes.py` 進入 `integrations.save_to_obsidian()`
3. `.md` 檔寫入後，`integrations._trigger_meeting_notes_async()` 背景呼叫 LLM
4. LLM 輸出寫成 `*_會議記錄.md`

同時，主畫面 `summary` 分頁仍是 placeholder，文案為「轉錄完成後，點擊 AI 摘要按鈕生成摘要 / 功能開發中，敬請期待」，但現有 UI 沒有真正的 `AI 摘要` 觸發按鈕，也沒有 render 真實摘要內容。

因此目前的產品落差是：

- 使用者看到 `summary` 分頁，會預期 transcript 完成後可以直接看到摘要
- 實際上摘要卻被綁在 `Obsidian` 存檔之後
- app、Obsidian、Notion 未來若各自補摘要，容易出現重複生成與內容不一致

## 3. 問題定義

目前設計有三個核心問題：

### 3.1 UX 錯位

`summary` 分頁已存在於主工作台，但資料流未接入，造成使用者以為功能壞掉或未完成。

### 3.2 Flow 耦合錯位

摘要生成目前耦合在 Obsidian 輸出行為之後，代表「是否有摘要」取決於是否按了 `Obsidian`，而不是是否完成 transcript。

### 3.3 Multi-output 不一致風險

若後續在 app、Obsidian、Notion 各自觸發摘要生成，將導致：

- 多次消耗 token
- 生成時間拉長
- 同一場會議在不同出口看到不同版本摘要

## 4. 目標

本規格的目標如下：

1. transcript 完成後，自動生成一份 canonical summary
2. `summary` 分頁顯示該 canonical summary
3. Obsidian 與 Notion 輸出重用同一份 canonical summary，而不是再次生成
4. 讓使用者可在 app 內編輯 summary，並以編輯後版本作為輸出優先來源
5. 保持摘要生成為背景非同步，不阻塞 transcript 主流程
6. 保持未設定 LLM API Key 時的 graceful fallback

## 5. 非目標

本輪不處理以下項目：

1. 不重做 summary 的視覺設計語言，只做最小可用 render
2. 不導入新的 provider routing UI
3. 不在本輪處理 timeline 分頁
4. 不在本輪處理摘要歷史版本管理
5. 不在本輪處理多人協作下的摘要衝突合併

## 6. 決策

### 6.1 Canonical summary 應在 transcript 完成後生成

摘要的觸發點應從 `save_to_obsidian()` 抽離，改成：

- 單檔轉錄完成後
- chunked/session 合併完成後
- system audio finalize 完成後

只要主 transcript 完成並可呈現在 UI，就進入背景 summary generation。

### 6.2 Obsidian / Notion / app 共用同一份摘要資料模型

canonical summary 生成後，應作為本次 transcript session 的標準 AI 初稿。前端與輸出邏輯應區分兩層：

- `generated_summary`: AI 生成初稿，不可被覆寫
- `edited_summary`: 使用者在 app 內修改後的版本，可為空

後續：

- app `summary` 預設 render `generated_summary`，一旦使用者修改後，改 render `edited_summary`
- Obsidian 若需要摘要檔或附錄摘要，優先取 `edited_summary`，否則 fallback `generated_summary`
- Notion 若要上傳摘要，也遵循同一優先順序

### 6.3 若 LLM 不可用，summary 保持空但狀態可理解

未設定可用 API Key 時，不顯示 hard error。UI 應呈現：

- transcript 已完成
- summary 未生成
- 原因是未設定 LLM，而不是功能壞掉

### 6.4 Summary 應可編輯，輸出以編輯後版本為準

摘要不是只讀報表，而是本次會議工作台的一部分。使用者應能在 app 的 `summary` 分頁中直接調整：

- 專有名詞
- 決策內容
- 行動事項 owner / due date
- 刪除 AI 誤判內容

輸出規則：

- 若 `edited_summary` 非空，Obsidian / Notion 優先使用 `edited_summary`
- 若 `edited_summary` 為空，則使用 `generated_summary`

## 7. 使用者行為定義

### 7.1 成功路徑

1. 使用者錄音或上傳音檔
2. transcript 完成並顯示於 `transcript`
3. app 狀態列顯示摘要生成中
4. `summary` 分頁從 placeholder 轉為 loading 狀態
5. 摘要完成後，`summary` 分頁顯示 AI 初稿
6. 使用者可直接在 `summary` 分頁編輯內容
7. 使用者之後按 `Obsidian` 或 `Notion`，共用同一份摘要結果，且優先輸出編輯後版本

### 7.2 無 LLM Key 路徑

1. 使用者完成 transcript
2. app 不進行摘要生成
3. `summary` 分頁顯示「尚未設定 LLM，無法產生摘要」類型說明
4. `Obsidian` / `Notion` 仍可依現有規則處理 transcript 本體

### 7.3 摘要失敗路徑

1. transcript 已完成
2. summary 進入 loading
3. 若 provider timeout / 429 / API failure，summary 狀態轉為 failed
4. UI 提示摘要生成失敗，但 transcript 不受影響
5. 後續出口不可默默再次生成不同摘要；若需要 retry，應明確使用同一條 summary service

### 7.4 編輯後輸出路徑

1. transcript 已完成
2. AI 初稿生成成功
3. 使用者修改 `summary`
4. app 將本次 summary 標記為 dirty / edited
5. 使用者按 `Obsidian` 或 `Notion`
6. 輸出使用 `edited_summary`

## 8. 後端設計

### 8.1 新增 summary service 邏輯層

建議新增一層明確抽象，例如：

- `generate_meeting_summary_async(...)`
- `build_meeting_summary(...)`
- `MeetingSummaryState`

目的：

- 不再讓 `save_to_obsidian()` 同時承擔「存檔」與「生成摘要」
- 讓 transcript 完成與 output export 都能呼叫同一服務

### 8.2 輸入

summary service 的輸入應至少包含：

- `text`
- `lang`
- `segments`（若可用）
- `meta`（model / domain / extra_terms / duration 等）
- `session_id` 或可識別本次結果的 key

### 8.3 輸出

summary service 的輸出建議標準化為：

- `status`: `idle | loading | ready | skipped | error`
- `provider`
- `generated_summary`
- `edited_summary`
- `is_summary_edited`
- `generated_at`
- `error`（若失敗）

其中：

- `generated_summary` 為 immutable AI 初稿
- `edited_summary` 初始為空，僅在使用者修改後寫入
- 實際輸出時使用 `effective_summary = edited_summary or generated_summary`

### 8.4 狀態保存

建議與現有 `_last_transcript` 對齊，新增本次 summary 快取，例如：

- in-memory `last_summary`
- 視需要落地 `.last_summary.json`

最小版本可先只做 in-memory + SSE；若要支援 reload restore，再補磁碟快取。

若要支援 reload 後不丟失人工編輯，`.last_summary.json` 應保存：

- `generated_summary`
- `edited_summary`
- `is_summary_edited`
- `provider`
- `status`

### 8.5 與 Obsidian 的關係

`save_to_obsidian()` 應改為：

1. 專心寫 transcript `.md`
2. 若 summary 已 ready，決定是否一併輸出摘要檔或附錄
3. 摘要內容優先使用 `edited_summary`，否則 fallback `generated_summary`
4. 不再自行觸發新的摘要生成

### 8.6 與 Notion 的關係

Notion 上傳若要包含摘要，應直接取用 `effective_summary`。

本輪若 Notion 尚未接摘要，也至少要保留可擴充欄位，不再在 upload path 裡偷偷重算摘要。

## 9. 前端設計

### 9.1 `summary` 分頁狀態

`panel-summary` 至少需支援四種狀態：

1. `empty`
2. `loading`
3. `ready`
4. `error/skipped`

此外需支援兩種內容模式：

1. `generated view`
2. `edited view`

### 9.2 初始文案

建議替換目前 placeholder：

- `empty`: 尚無轉錄結果
- `loading`: AI 摘要產生中
- `skipped`: 未設定 LLM，無法產生摘要
- `error`: 摘要生成失敗，請稍後重試

### 9.3 內容格式

第一版不必做高度視覺化卡片，建議直接 render 結構化純文字或 markdown，至少能穩定呈現：

- 摘要
- 決策記錄
- 行動事項

### 9.4 可編輯行為

`summary` 分頁應提供可編輯區，建議第一版直接使用可編輯文字區或 textarea 類型容器。

需要支援：

- 使用者可修改 AI 初稿
- 有編輯後可標記 dirty state
- 切到其他 tab 再切回不會丟失內容
- 存 Obsidian / Notion 時使用當前編輯後版本

### 9.5 顯示層命名建議

避免 UI 上直接暴露 `canonical` 一詞給一般使用者。UI 文案可用：

- `AI 摘要`
- `已編輯`
- `尚未儲存到 Obsidian`

## 10. SSE / API 設計

### 10.1 建議事件

可新增 summary 專用 SSE event，例如：

- `summary_status`
- `summary_ready`
- `summary_error`
- `summary_edited`

或沿用既有 `status` + 新增 payload 類型，但建議 summary data 本體不要只塞進人類可讀字串訊息。

### 10.2 最小可行 payload

```json
{
  "status": "ready",
  "provider": "anthropic",
  "generated_summary": "...",
  "edited_summary": "",
  "is_summary_edited": false
}
```

### 10.3 重連恢復

若要與 `_onSSEReconnected()` 對齊，後端需提供：

- `/api/last_summary`

用於頁面重連後補回最近一次摘要內容。

若前端允許編輯後自動保存到 server state，則需再補：

- `/api/update_summary`

## 11. 檔案與模組建議變更

### 11.1 後端

- `integrations.py`
  - 抽出 meeting summary generation service
  - 保留 provider 選擇與 prompt 載入
- `routes.py`
  - 在 transcript finalize 路徑觸發 summary generation
  - 提供 `last_summary` restore API
  - 提供 summary edit update API
  - 廣播 summary SSE

### 11.2 前端

- `templates/index.html`
  - `panel-summary` 從 placeholder 改為可 render 容器
- `static/app.js`
  - 新增 summary state
  - 處理 summary SSE
  - 處理 summary 編輯與 dirty state
  - 支援 reload restore
- `static/app.css`
  - 補 summary loading / error / content 的最小樣式

### 11.3 測試

- unit tests：summary state / SSE payload / skipped behavior / edit priority
- integration tests：transcript 完成後 summary 產生
- UI tests：summary tab 不再永遠是 placeholder，且編輯後輸出優先順序正確

## 12. Acceptance Criteria

### AC-1 Transcript-complete trigger

單檔、chunked session、system audio 三條主轉錄完成路徑，皆會在 transcript 完成後觸發同一條 summary generation service。

### AC-2 Non-blocking behavior

summary generation 為背景非同步，不阻塞 transcript 顯示，也不阻塞既有 copy/export 行為。

### AC-3 Canonical summary reuse

對同一份 transcript，app / Obsidian / Notion 共享同一份 summary 結果，不會因不同出口各自重算。

### AC-4 Editable summary

`summary` 分頁顯示 AI 初稿後，使用者可直接編輯內容；切換 tab 或一般 UI 操作不會立刻丟失該編輯內容。

### AC-5 Edited output priority

當 `edited_summary` 存在時，Obsidian / Notion 輸出優先使用 `edited_summary`；只有在未編輯時才 fallback 到 `generated_summary`。

### AC-6 Summary tab real content

`summary` 分頁在成功路徑下顯示真實摘要內容，不再永遠停留在 placeholder。

### AC-7 Graceful no-key behavior

未設定任何可用 LLM API Key 時，`summary` 分頁顯示可理解的 skipped 狀態，不將功能誤呈現為故障。

### AC-8 Failure isolation

summary generation 失敗時，不影響 transcript、Obsidian transcript 存檔、Notion transcript 上傳等主流程。

### AC-9 SSE recovery

若 transcript 已完成且 summary 已生成，前端 reload 或 SSE reconnect 後可補回最近一次 summary。

## 13. 驗證方式

### 13.1 單元驗證

1. provider key 存在時，summary service 會產出 `ready`
2. 無 key 時，summary service 回 `skipped`
3. provider exception 時，summary service 回 `error`
4. `effective_summary` 優先順序為 `edited_summary or generated_summary`

### 13.2 流程驗證

1. 上傳音檔後 transcript 完成，`summary` 分頁進入 loading
2. 摘要生成成功後顯示 AI 初稿
3. 修改摘要後，點 `Obsidian` 使用編輯後版本
4. 點 `Obsidian` 不會再次生成另一份摘要

### 13.3 回歸驗證

1. `/api/save_to_obsidian` 仍能正常寫 transcript 檔
2. `uploadToNotion()` 既有 transcript 上傳不被破壞
3. 無 LLM 時 app 不 crash、不假裝有摘要
4. summary 編輯後不會被單純 tab 切換或 SSE reconnect 覆蓋掉

## 14. 風險

### 14.1 State duplication

若同時保留舊的 `_trigger_meeting_notes_async()` 路徑與新的 summary service，容易重複生成。實作時需先決定唯一 trigger。

### 14.2 Output contract drift

若 app 使用的 summary 格式與 Obsidian `*_會議記錄.md` 格式不同，仍可能出現「同一份摘要不同呈現」。第一版應優先共用同一內容字串。

### 14.3 Provider latency

summary 在 transcript 完成後立即生成，會讓使用者更常看到 loading 狀態，因此狀態文案必須清楚。

### 14.4 Edited state overwrite risk

若 SSE reconnect 或新的 summary event 回來時直接覆蓋前端內容，可能把使用者已編輯的 summary 洗掉。實作時需保護 dirty / edited state。

## 15. 建議實作順序

1. 抽出後端 summary service
2. 在 transcript finalize 路徑接入
3. 加入 summary SSE 與 `last_summary` restore
4. 前端 `summary` 分頁接資料 render
5. 補上 editable summary state 與 update API
6. 調整 Obsidian flow，改為優先輸出 `edited_summary`
7. 視需要再擴充到 Notion summary append

## 16. Stop Conditions

若在實作過程中發現以下任一情況，應暫停並回報，而不是硬接：

1. 現有 transcript finalize 路徑其實有三套不一致狀態機，無法安全插入共用 summary trigger
2. Obsidian / Notion 的既有輸出 contract 已依賴 `*_會議記錄.md` 的副檔流程，抽離後會造成 backward compatibility 問題
3. 需要大幅重寫 `static/app.js` 狀態機才可支援 summary state
