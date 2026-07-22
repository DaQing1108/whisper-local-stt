# 任務規格：Whisper STT ↔ SwiftUI + Python Worker 合併議題（決策記錄）

**建立日期：** 2026-07-22
**狀態：** ⏸️ 擱置 Gate E / 維持雙軌並行（使用者於 2026-07-22 確認）
**風險等級：** L3（涉及共用介面與正式發布判斷，本次結論為「不執行」而非「執行」）

---

## ⚠️ 版本說明

本文件第一版曾依據 `docs/Whisper_Legacy_vs_SwiftUI_Functional_Comparison_Spec_v1.md`（2026-07-18）假設 SwiftUI candidate 仍處於 PoC 前期、P0 功能大量缺失，並據此寫出三階段（PoC → P0 Parity → Gate E）執行規格。

實際查驗 `codex/swiftui-python-poc` worktree（`.worktrees/swiftui-python-poc`）後發現該比較文件已過時，**P0/P1/P2 parity 工作已經完成**。本版取代第一版內容，僅保留一個決策：**Gate E 是否推進**，答案是暫不推進。

---

## 一、已確認現況（截至 2026-07-22 查驗）

### 已完成（不需要再排入執行計畫）

| 項目 | 證據 |
|---|---|
| Phase 0 PoC 穩定性（Worker 生命週期、cancel、crash recovery） | `Whisper_Phase0_Gate_A_Readiness_Report_v1.md`；AC-5 通過 |
| Phase 1 P0 功能 parity（逐字稿編輯、export、language/domain/terminology） | `Whisper_P0_P2_Parity_Completion_Report_v1.md`；Swift 108 tests / Python 34 tests 全過，P0 APPROVE |
| Phase 1 AI 摘要、Notion/Obsidian 發布語意 | 同上，P1 APPROVE（OpenAI Responses API summary、Obsidian unique-note export、Notion existing-page append + ambiguous-retry lock） |
| Phase 2 詞庫/history/shortcuts productivity parity | 同上，P2 APPROVE（持久化詞庫、history search/delete/retention、native shortcuts） |
| 本機簽章與雙 app 共存 | Gate B 通過；`/Applications/Whisper STT.app`（`com.via.whisper-ai`）與 `~/Applications/Whisper SwiftUI.app`（`com.via.whisper-swiftui`）各自獨立 bundle ID，deep strict codesign 驗證皆通過，互不覆蓋 |

### 未完成，且本次決定不投入（Gate E blocker）

`Whisper_Phase4_Gate_E_Readiness_Report_v1.md`（2026-07-18）判定 **NOT READY**，缺口全部是外部條件，非程式碼問題：

1. 無 Apple Developer ID Application 身份與 notarization profile
2. 無 signed Sparkle feed / public key（依賴第 1 項）
3. 無獨立 clean Apple Silicon Mac 可供安裝驗證
4. 尚未執行：真實 private Notion append 憑證遮罩驗證、兩個 notarized 版本的 Sparkle update/rollback 實測

---

## 二、本次決策（2026-07-22，最終版本）

決策經過兩輪修正：

1. 第一輪：暫不投入 Developer ID／clean Mac，SwiftUI 維持內部驗證分支——**已被使用者推翻**
2. 第二輪（最終）：使用者澄清真正目的是「合併後讓 SwiftUI 版存續，legacy 退役，解決現在雙版本維護混亂的問題」。釐清 app 現階段僅供使用者個人在本機使用（未來功能更完善才對外），確認 **Gate E（Developer ID／notarization／clean Mac）暫不需要**——本機簽章已足夠支撐日常個人使用。

**最終決策：**

- **`main`（Whisper Classic，v2.4.x）進入凍結維護** — 不再排入新功能開發，僅在使用者日常 fallback 出問題時才修
- **`codex/swiftui-python-poc` 已改名為 `whisper-swift`**（2026-07-22，local + remote 已執行），成為現階段唯一主力開發分支
- 日常使用直接切到 `~/Applications/Whisper SwiftUI.app`（本機簽章，Gate B 已通過）
- **不投入 Apple Developer ID Program 費用、不取得第二台 clean Mac**——這些留到「確定要對外釋出」時再處理
- 兩版本的 bundle ID 隔離（`com.via.whisper-ai` vs `com.via.whisper-swiftui`）、獨立安裝路徑與資料目錄，提供足夠的 rollback 安全邊界

### 與既有文件的衝突與處理

`docs/Whisper_Dual_Version_Git_Isolation_Plan_v1.md`（2026-07-19，位於 `whisper-swift` worktree 內）明確主張「不以永久 `classic-main`／`swift-main` branches 維護兩套 diverged codebase」，改用 tag 策略（`swift-v0.2.0-preview` → `swift-v3.0.0-rc.1` → 正式取代才用 `whisper-v3.0.0`）。

使用者已於 2026-07-22 明確確認：**該文件想法已過時，改採目前的分支策略**（`whisper-swift` 作為長期主力分支，而非僅用 tag 標記）。後續工作不應再依循該文件的 tag-only 建議。

### 已知殘留風險（未在本次處理）

⚠️ **2026-07-22 更正**：本節原本寫「`whisper-swift` worktree 是 dirty state：3 個 tracked 修改（`routes.py`、`whisper_core.py`、測試檔）+ 33 個 untracked entries，含未驗證的 system-audio 診斷變更」——這段描述直接抄自 `Whisper_Dual_Version_Git_Isolation_Plan_v1.md`（2026-07-19）的舊內容，寫入當下沒有重新核對 `git status`，是錯誤資訊。

實際查證（2026-07-22）：`ContentView.swift` 完全乾淨，近期 commit（`b34c3fd`、`24f5346`、`517a1a9` 等）皆為正常 feature/fix，不是未驗證的診斷改動。目前 `whisper-swift` worktree 的 dirty state 只有 `CLAUDE.md`（本次加的分支策略段落）與 `macos/WhisperApp/Info.plist`（本次版號提升至 0.2.0），加上一個既有無關的 untracked 文件 `docs/Whisper_SwiftUI_P0_Gap_Closing_Specs_v1.md`。不需要複雜的 commit inventory 拆分，可直接 commit 這兩個檔案。

### 何時重新評估 Gate E（觸發條件）

以下任一情況出現時，值得重新回到 task-router 評估是否推進 Gate E：
- 使用者決定加入 Apple Developer Program，或已取得第二台 clean Apple Silicon Mac
- 決定要把 app 交給 VIA 其他同事或外部使用
- 現行 v2.4.x 凍結後仍需要的極少量 fallback 修正，累積到不划算維護兩套的程度

---

## 三、完成回報

1. **修改摘要：** 未修改任何程式碼；更正一份過時的任務規格文件為準確的現況決策記錄
2. **範圍確認：** 本次僅為文件更正與決策記錄，未觸碰 `main` 或 `codex/swiftui-python-poc` 的程式碼
3. **已知風險：** 無新增風險；`Whisper_Legacy_vs_SwiftUI_Functional_Comparison_Spec_v1.md`（2026-07-18）目前仍是過時內容，若之後有人依它評估，會重複本次踩過的坑——建議後續視需要更新該文件或加註過時警告
4. **未完成事項：** 無（Gate E 為明確擱置，非未完成）
