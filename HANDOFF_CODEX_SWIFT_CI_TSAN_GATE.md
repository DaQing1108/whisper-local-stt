# Codex Task: Swift CI + 並發測試閘門
Date: 2026-09-19
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc
Base commit: 0e2d7cc
Schema version: 1.1

## BLUF
`whisper-swift` 分支目前完全沒有 Swift 的 CI 覆蓋——`.github/workflows/ci.yml` 只在 `push.branches: [main]` 觸發，三個既有 job（`unit-tests`、`integration-tests`、`bundle-dependency-check`）全是 Python，零 Swift job。本任務要新增 CI 層的 `swift build`/`swift test` 驗證，並解決兩個已知阻礙：(1) 本機 fresh `swift test` 會卡在 test bundle codesign（resource-fork/Finder xattr 污染），(2) `LiveRecordingControllerTests` 有已知的並行執行下 flaky 問題，會拖累新 CI job 的可信度。同時新增一個 advisory 的 Thread Sanitizer job，覆蓋專案內 9 個從未被 TSAN 驗證過的 `@unchecked Sendable` 型別。

## 視覺依據（如有 UI/設計成分）
不適用——本任務純粹是 CI 設定變更，無任何 UI/視覺成分。

## 任務邊界

### 可改動
- `.github/workflows/ci.yml`：新增一個 `swift-tests` job（`runs-on: macos-latest`）
  - Checkout
  - 用獨立 scratch path（例：`SWIFT_SCRATCH_PATH=/tmp/whisper-swift-ci`）執行 `swift build -c debug --scratch-path "$SWIFT_SCRATCH_PATH"`（cwd: `macos/WhisperApp`）
  - 對該 scratch path 執行防禦性 `xattr -cr "$SWIFT_SCRATCH_PATH" || true` 與 `xattr -d com.apple.FinderInfo "$SWIFT_SCRATCH_PATH" 2>/dev/null || true`（比照 `scripts/build_swiftui_app.sh` 對 app bundle 的既有手法，`|| true` 是因為 GitHub Actions 乾淨 runner 可能根本不會遇到這個污染源，不應該因為屬性不存在而讓 job 失敗）
  - 執行 `swift test`，但明確隔離 `LiveRecordingControllerTests`：主要一次跑除了該 suite 以外的全部測試（平行執行），該 suite 另外用序列/非平行方式單獨跑一次。實作方式由你決定（`swift test --filter` 排除+單獨跑、或 Swift Testing 的 suite 層級序列化機制皆可），重點是最終結果不能因為這個已知 flaky 而讓 job 判定不穩定
  - 觸發條件擴大：`push.branches` 加入 `whisper-swift`，`pull_request` 維持現狀（對所有分支的 PR 都跑）
- `.github/workflows/ci.yml`（或新開 `.github/workflows/swift-ci.yml`，你決定哪個更清楚）：新增第二個 **advisory** job `swift-tsan`
  - `continue-on-error: true`（或功能等效的機制，只要失敗不阻擋其他 job 或 PR merge）
  - 執行 `swift test --sanitize=thread`（cwd: `macos/WhisperApp`）
  - 這個 job 的目的是覆蓋以下 9 個 `@unchecked Sendable` 型別的隱含並發路徑：`SystemAudioCallbackGate`、`SystemAudioWAVSession`、`MixedAudioAccumulator`、`MixedAudioErrorBox`、`ChunkRotationDecider`、`ConverterInput`、`CaptureSession`、`AVAudioEngineCaptureBackend`、`RotatingCaptureSession`

### 禁止改動
- `macos/WhisperApp/Sources/` 下任何檔案——本次任務範圍明確排除產品程式碼變更。若 TSAN job 挖出真的 race condition，**不要在本次任務修**，記錄到 Blockers 區塊，我會另開任務處理
- `macos/WhisperApp/Tests/WhisperAppTests/LiveRecordingControllerTests.swift` 本身——用 CI 層的執行方式隔離這個 flaky，不要修改測試原始碼邏輯或斷言，這不是「修 flaky」的任務，是「讓 CI 不被它拖累」
- `Package.swift`——現有結構足以支援本次需求，不需要改動
- 既有三個 Python job（`unit-tests`/`integration-tests`/`bundle-dependency-check`）——不要動，本次只新增 Swift 相關 job

### 執行方不能做（留給 Claude Code）
- git push（一律留給接手驗收的 Claude Code）
- 你可以 git commit（本機留下完整紀錄＋完成報告），但不要 git push
- 打包 / 簽名 / `package.sh` / `build_swiftui_app.sh` 相關操作
- 存取 `~/Library/Application Support/WhisperSTT/.env` 或任何 Keychain 憑證
- 實際觸發 GitHub Actions 遠端執行（因為不 push，你的環境很可能也沒有對這個 repo 的 push 權限）——AC-5 標注為需要我在驗收階段 push 後才能驗證，你只需要確保本機能合理推斷 YAML 邏輯正確（例如用 `act` 本機模擬，如果你的環境有裝；沒有的話，仔細檢查 YAML 語法與邏輯即可，不要求你自己觸發遠端 CI）

## 驗收條件（AC）
AC Source: 未經 spec-writer，人工列出（源自 2026-09-19 Whisper Swift 優化評估對話，經 harness-rules pre-flight 確認 L1 可執行）

□ AC-1. `.github/workflows/ci.yml` 對 `whisper-swift` 分支的 push 與所有 PR 觸發一個執行 `swift build` 與 `swift test` 的 job
□ AC-2. 新 CI job 的 `swift test` 執行方式不會因為 `LiveRecordingControllerTests` 的已知 flaky 而產生不穩定的紅燈（該 suite 以序列/隔離方式執行）
□ AC-3. 存在一個獨立、advisory（`continue-on-error: true` 或等效機制）的 `swift test --sanitize=thread` job，其失敗不阻擋其他 job 或 PR merge
□ AC-4. `git diff --stat` 顯示零改動於 `macos/WhisperApp/Sources/` 與 `macos/WhisperApp/Tests/` 底下任何檔案，本次改動僅限 `.github/workflows/` 下的 CI 設定檔
□ AC-5. [需 Claude Code 驗證，你不需要自己完成這條] 對這個 CI 設定實際觸發一次，連續兩次執行都得到與新 job 定義一致的結果——你只需確保 YAML 邏輯正確，實際遠端觸發由我在驗收階段 push 後執行

## 驗收指令（完成後自己跑，全部綠才算完成）
```bash
cd /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc

# AC-4：確認改動範圍
git diff --stat
git diff --stat -- macos/WhisperApp/Sources/ macos/WhisperApp/Tests/  # 這行必須無輸出

# AC-1/2/3：本機驗證 YAML 語法與邏輯（若無 act 工具，至少確認 YAML 可被 parse）
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo "YAML 語法正確"

# 本機重現一次 swift build + swift test（驗證你新增的隔離手法在本機也走得通，
# 即使不透過 CI 執行器）：
cd macos/WhisperApp
SWIFT_SCRATCH_PATH=/tmp/whisper-swift-ci-verify
rm -rf "$SWIFT_SCRATCH_PATH"
swift build -c debug --scratch-path "$SWIFT_SCRATCH_PATH"
xattr -cr "$SWIFT_SCRATCH_PATH" || true
xattr -d com.apple.FinderInfo "$SWIFT_SCRATCH_PATH" 2>/dev/null || true
swift test --scratch-path "$SWIFT_SCRATCH_PATH"   # 確認你的隔離手法讓這行穩定通過或至少不因 flaky 隨機紅燈
```

## Blockers（執行中卡住時使用）
若執行中發現規格不清楚或需要澄清，**不要重新發起一輪交接**，直接在本檔案這個區塊 append 具體問題、commit，並告知 PLAN 端：

```
### [日期] Blocker
Q: [具體問題]
影響：[卡住的是哪個 AC 或哪個改動]
```

PLAN 端下次上線只需讀這個區塊回覆，不必重新對齊整份規格。

## 完成後產出
在專案根目錄建立 `HANDOFF_CLAUDE_SWIFT_CI_TSAN_GATE_VERIFICATION.md`，內容包含：
1. Acceptance Criteria Source（沿用本文件：未經 spec-writer，人工列出）
2. 每條 AC 的驗收結果（✅ / ❌ + 原因；AC-5 標注「留待 Claude Code 驗證」）
3. 驗收指令的實際輸出（貼上完整 test result，包含本機重現的 `swift build`/`swift test` 輸出）
4. `git diff --stat` 摘要
5. Known caveats（若有，例如：本機環境沒有 `act` 無法完全模擬 GitHub Actions runner）
6. 不應該 commit 的內容說明（本任務不涉及 .env 等敏感檔案，若你發現任何不該進版控的檔案請在此說明）
