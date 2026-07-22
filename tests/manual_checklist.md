# Whisper STT v2.4.1 — 手動測試清單

每次 release 前執行。預計 10-15 分鐘。

---

## 環境準備

- [ ] App 已打包：`bash package.sh`
- [ ] 開啟 `/Applications/Whisper STT.app`
- [ ] 確認版本號正確（右上角 v2.4.1）
- [ ] 主畫面、偏好設定、macOS 權限提示使用同一名稱：`Whisper STT`

---

## 1. TCC 權限

- [ ] 首次開啟，系統提示「螢幕錄製」權限 → 點允許
- [ ] 系統設定 → 隱私權與安全性 → 螢幕錄製 → `Whisper STT` 有打勾

---

## 2. 麥克風模式

- [ ] 點「開始錄音」→ 說幾句話 → 點「停止」
- [ ] 轉錄結果顯示在右側（不為空）
- [ ] 狀態列最終顯示「✅ 全部轉錄完成」

---

## 3. 系統音訊模式

- [ ] 開啟 YouTube 或任何音源
- [ ] 切換到「系統音訊」模式 → 點「開始」
- [ ] 系統音訊提示顯示螢幕錄製權限狀態與修復步驟
- [ ] 播放 30 秒 → 點「停止」
- [ ] 轉錄結果顯示（非空）
- [ ] 狀態列顯示「✅ 全部轉錄完成」（不再卡在 LLM 處理中）

---

## 4. 系統音訊

- [ ] 執行系統音訊錄製（30 秒以上）→ 停止
- [ ] 轉錄與 App summary 皆完成，且未自動發布至外部目的地

---

## 5. LLM 後處理

- [ ] 確認 Claude API Key 已設定（sk-ant-api03-...）
- [ ] 錄製一段 10 秒以上的語音
- [ ] 狀態列出現「⏳ 語音辨識完畢，正在啟動 LLM...」
- [ ] **30 秒內**自動結束並顯示結果（不再無限等待）

---

## 6. Summary 自動生成與可編輯

- [ ] 完成一次 transcript 後切到 `summary` 分頁，不需再按額外按鈕就會自動出現摘要
- [ ] summary 載入中會顯示處理狀態，完成後可看到 provider 標記
- [ ] 直接修改 summary 文字，畫面顯示「已編輯」狀態
- [ ] 重新整理頁面後，edited summary 仍會透過 `/api/last_summary` 還原
- [ ] 將 summary 改回與原始 generated summary 完全相同時，「已編輯」狀態會自動消失
- [ ] 未設定 LLM Key 時，summary 區塊顯示略過或提示狀態，不應卡住整體 transcript 流程

---

## 7. Notion 發布與覆寫

- [ ] App summary 完成後，點擊 footer 的 `Notion` 發布按鈕
- [ ] 第一次發布在設定目標下建立一個會議 child page，內含 `Notion AI 會議內容` 與逐字稿
- [ ] 再次點擊 `Notion`，確認更新同一個 child page，而非新增第二頁
- [ ] Notion 內容應由逐字稿產生，不會因為修改 App summary 而被覆寫

---

## 8. Obsidian 發布與覆寫

- [ ] App summary 完成後，點擊 footer 的 `Obsidian` 發布按鈕
- [ ] Vault 內建立一個原始逐字稿檔與一個 `*_Obsidian會議記錄.md` 檔，兩者帶有相同 `meeting_id`
- [ ] 再次點擊 `Obsidian`，確認更新同一對檔案，而非新增重複檔案
- [ ] Obsidian 會議內容應由逐字稿產生，不會因為修改 App summary 而被覆寫

---

## 9. 混音模式（系統音訊 + 麥克風）

- [ ] 切換到「混音」模式
- [ ] 開始後同時有系統音訊和說話
- [ ] 停止後結果包含兩種來源的內容

---

## 10. UI 基本功能

- [ ] 「複製」按鈕：點擊後剪貼簿有內容
- [ ] 「匯出」按鈕：產生 .txt 檔案
- [ ] 「清除」按鈕：清除轉錄內容
- [ ] 「歷史」按鈕：顯示過去記錄
- [ ] 無轉錄結果時，Copy / Export / Obsidian / Notion 按鈕 disabled 且 title 說明原因
- [ ] 未設定 Notion/Obsidian 時，完成轉錄後按鈕仍提示需先到偏好設定完成設定
- [ ] quick-bar 展開後可看到模型、語言、模式、領域的 helper text
- [ ] 詞庫輸入框顯示「加入本次專有名詞，按 Enter 套用」，📌 可開啟常用詞庫
- [ ] 快速設定與常用詞庫使用相同 SVG chevron，展開時皆平順旋轉 180°
- [ ] 將視窗縮至 720×600，toolbar、quick-bar、結果 actions 不重疊且沒有水平捲軸
- [ ] 切換 Light / Dark theme，文字、disabled controls、提示訊息與 focus ring 均可辨識

## 10.1 偏好設定分層

- [ ] 偏好設定標題顯示 Whisper STT v2.4.1
- [ ] Basic 基礎設定預設展開，包含 Obsidian、Notion、LLM API Key
- [ ] Workflow 產出格式預設收合，展開後可設定後處理模板
- [ ] Advanced / Beta 進階功能預設收合，展開後可檢查說話者分離與 App 更新
- [ ] 儲存設定後回主畫面，Notion/Obsidian 按鈕可用狀態正確更新

---

## 11. 跨版本升級

- [ ] 升級後開啟 App，`~/Library/Application Support/WhisperSTT/.env` 中的 API Key 仍存在
- [ ] 不需要重新輸入 API Key

---

## 12. 文件與故障復原

- [ ] 依 `docs/INSTALLATION.md` 可完成安裝與首次轉錄
- [ ] `docs/TROUBLESHOOTING.md` 的麥克風、螢幕錄製、port 5001 與 log 路徑正確
- [ ] README、App 視窗、偏好設定、權限文案均只使用 `Whisper STT`

---

## 通過條件

所有項目打勾 → 可以 release。
若有任何項目失敗 → 修復後重跑該段。
