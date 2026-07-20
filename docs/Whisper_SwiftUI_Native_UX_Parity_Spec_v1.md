# 任務規格：Whisper SwiftUI 操作一致、視覺原生化

**建立日期：** 2026-07-18  
**風險等級：** L2  
**起點：** Execute

## 1. BLUF

以 `/Applications/Whisper STT.app` 的主流程作為操作參考，把 SwiftUI
版本從工程控制台重整為「單一錄音主動作、快速設定、結果工作區、進階設定」的
原生 macOS 介面。保留 Phase 2–4 已完成能力，不複製 Web CSS，也不修改 legacy app。

## 2. 目標與非目標

使用者開啟 App 後，不需要理解 Worker lifecycle，即可選擇音訊模式並開始錄音；
完成後在同一工作區讀取結果、歷史及發布操作。

非本次目標：summary/timeline 新功能、逐像素複製 legacy Web UI、Sparkle release、
新增 dependency、變更 capture/Worker protocol、修改 production legacy app。

## 3. 執行範圍

允許修改 `macos/WhisperApp/Sources/WhisperApp/ContentView.swift`、相關 Swift tests、
SwiftUI build artifact 與本規格。禁止修改 legacy templates/static、Python API、
簽章發布設定、使用者資料與外部服務。

## 4. Locked acceptance criteria

- [ ] App 顯示「Whisper STT / 本地語音 AI」原生 header 與可理解的 runtime 狀態。
- [ ] Worker 在畫面出現後自動準備；手動 Worker 控制收納到進階區。
- [ ] 麥克風、即時、系統音訊、混音四種模式由單一 segmented control 切換。
- [ ] 主 capture card 永遠只有一個主要開始/停止動作，狀態與目前模式一致。
- [ ] 模型、語言與檔案上傳位於主流程，不必展開進階設定。
- [ ] Transcript、進度、diagnostics、history、Obsidian/Notion 操作仍可達。
- [ ] Screen Recording permission、Notion credential、updates、diarization 與
  Worker lifecycle 收納到原生 DisclosureGroup。
- [ ] 既有 Swift tests、production build、packaged Worker smoke 與
  `git diff --check` 通過。

## 5. User verification required

- [ ] 以真實麥克風確認錄音按鈕的開始/停止體驗。
- [ ] 以真實 system/mixed audio 確認 TCC 提示與錄音體驗。
- [ ] Alex 確認視覺層級、密度與 legacy 操作熟悉度。

## 6. 停止條件

需要新增 dependency、修改 capture/Worker protocol、改寫 legacy app、處理正式
credential，或同一 build/runtime 問題連續三次未解時立即停止並回報。

## 7. Rollback

變更限於 SwiftUI view composition；保留 capture controllers 與 legacy production
app。若 UI 驗證失敗，可回復 `ContentView` 而不遷移或刪除任何使用者資料。
