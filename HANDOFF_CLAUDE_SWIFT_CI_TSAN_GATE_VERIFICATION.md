# Verification: Swift CI + 並發測試閘門
Date: 2026-09-19
Project: /Users/daqingliao/Documents/AI-Workspace/1P_Projects/Whisper/.worktrees/swiftui-python-poc
Base commit: 0e2d7cc
Verified by: Claude Code (whisper-swift worktree session)

## 1. Acceptance Criteria Source
沿用 `HANDOFF_CODEX_SWIFT_CI_TSAN_GATE.md`：未經 spec-writer，人工列出（源自 2026-09-19 Whisper Swift 優化評估對話，經 harness-rules pre-flight 確認 L1 可執行）。

## 2. AC 驗收結果

- **AC-1** ✅ — `.github/workflows/ci.yml` 的 `on.push.branches` 新增 `whisper-swift`；`pull_request` 維持對所有分支觸發。新增 `swift-tests` job（`runs-on: macos-latest`）依序執行 `swift build -c debug` 與兩段 `swift test`（cwd: `macos/WhisperApp`）。
- **AC-2** ✅ — `swift-tests` job 內以 `swift test --skip LiveRecordingControllerTests` 執行主測試（本機驗證：198 tests / 32 suites 全綠），再以 `swift test --filter LiveRecordingControllerTests` 單獨序列執行該 suite（本機驗證：20 tests 全綠）。`swift test` 預設 `--no-parallel`（已用 `swift test --help` 確認），未顯式加 `--parallel`，故隔離執行時不會有 intra-run 並行；避免與其餘 31 個 suite 混跑時的資源競爭觸發已知 flaky。
- **AC-3** ✅ — 新增獨立的 `swift-tsan` job，`continue-on-error: true`，執行 `swift test --sanitize=thread`（cwd: `macos/WhisperApp`）。本機驗證：218 tests / 33 suites 全綠，指令本身可正確執行（無語法或環境錯誤），失敗時因 `continue-on-error: true` 不會阻擋其他 job 或 PR merge。
- **AC-4** ✅ — `git diff --stat -- macos/WhisperApp/Sources/ macos/WhisperApp/Tests/` 無任何輸出，確認零改動於這兩個目錄。
- **AC-5** — 留待 Claude Code（本次即為驗收方）／PLAN 端 push 後於 GitHub Actions 遠端驗證兩次連續執行結果一致。本次僅完成本機 YAML 邏輯正確性檢查與本機重現（見下方輸出），未觸發遠端 CI（無 push 權限範圍內動作，且任務邊界要求 push 留給 PLAN 端）。

## 3. 驗收指令實際輸出

### AC-4：改動範圍確認
```
$ git diff --stat
.github/workflows/ci.yml | 40 +++++++++++++++++++++++++++++++++++++++-
 1 file changed, 39 insertions(+), 1 deletion(-)

$ git diff --stat -- macos/WhisperApp/Sources/ macos/WhisperApp/Tests/
(無輸出)
```

### YAML 語法驗證
```
$ python3 -c "import yaml; yaml.safe_load(open('.github/workflows/ci.yml'))" && echo "YAML 語法正確"
YAML 語法正確
```

### 本機重現 swift build
```
$ cd macos/WhisperApp
$ swift build -c debug --scratch-path /tmp/whisper-swift-ci-verify
Building for debugging...
[Planning deferred tasks]
...
Build complete! (12.93 sec)
```

### xattr 防禦性清理
```
$ xattr -cr /tmp/whisper-swift-ci-verify || true
$ xattr -d com.apple.FinderInfo /tmp/whisper-swift-ci-verify 2>/dev/null || true
(本機為乾淨環境，未實際存在該屬性，指令依 || true 正常通過不報錯)
```

### 主測試（排除 LiveRecordingControllerTests）
```
$ swift test --scratch-path /tmp/whisper-swift-ci-verify --skip LiveRecordingControllerTests
... (198 tests)
✔ Test run with 198 tests in 32 suites passed after 1.241 seconds.
```

### 隔離執行 LiveRecordingControllerTests
```
$ swift test --scratch-path /tmp/whisper-swift-ci-verify --filter LiveRecordingControllerTests
... (20 tests)
✔ Suite LiveRecordingControllerTests passed after 0.863 seconds.
✔ Test run with 20 tests in 1 suite passed after 0.864 seconds.
```

### TSAN advisory job 本機重現
```
$ swift test --sanitize=thread --scratch-path /tmp/whisper-swift-tsan-verify
... (218 tests, 涵蓋全部 suite 包含 LiveRecordingControllerTests，因未用 --skip)
✔ Test run with 218 tests in 33 suites passed after 1.504 seconds.
[exited with code 0]
```
無資料競爭被 TSAN 偵測到，指令本身可正確執行；9 個目標型別（`SystemAudioCallbackGate`、
`SystemAudioWAVSession`、`MixedAudioAccumulator`、`MixedAudioErrorBox`、`ChunkRotationDecider`、
`ConverterInput`、`CaptureSession`、`AVAudioEngineCaptureBackend`、`RotatingCaptureSession`）
所在的測試路徑皆包含在本次 218 個測試內，已隨常規測試套件間接覆蓋。

## 4. git diff --stat 摘要

```
.github/workflows/ci.yml | 40 +++++++++++++++++++++++++++++++++++++++-
 1 file changed, 39 insertions(+), 1 deletion(-)
```

僅一個檔案改動，`.github/workflows/` 之外無任何改動。

## 5. Known caveats

- 本機環境沒有 `act`，無法完全模擬 GitHub Actions runner 的網路/沙箱條件；已改用「本機重現每個 CI step 的實際指令」取代，邏輯與指令序列與 YAML 中定義完全一致。
- 本機為開發機，未必存在 `com.apple.FinderInfo` xattr 污染（該問題原發生於本地打包情境，見 CLAUDE.md 症狀描述），因此本機驗證無法重現「清理成功」的正向案例，只能驗證「屬性不存在時 `|| true` 不會導致失敗」。GitHub Actions 乾淨 runner 預期同樣不會有此污染源，`xattr` 步驟屬防禦性，不影響核心邏輯。
- AC-5 的「連續兩次執行結果一致」需要實際 push 觸發 GitHub Actions 才能驗證，本次僅完成本機可驗證的部分。
- TSAN 本機執行涵蓋了全部 33 個 suite（含 `LiveRecordingControllerTests`），而不是分別針對 9 個 `@unchecked Sendable` 型別做隔離測試——這符合 handoff 原意（用完整測試套件間接驗證這些型別的並發路徑），非缺失。

## 6. 不應該 commit 的內容說明

本任務未涉及 `.env`、Keychain 憑證或任何敏感檔案。改動範圍僅 `.github/workflows/ci.yml`。
本次驗收過程中產生的本機 scratch path（`/tmp/whisper-swift-ci-verify`、`/tmp/whisper-swift-tsan-verify`）
已在驗證完成後清除，未進入版控。

工作目錄中另存在兩個 untracked 文件（`HANDOFF_CODEX_SWIFT_CI_TSAN_GATE.md` 本身、
`HANDOFF_CLAUDE_WHISPER_SWIFT_OPTIMIZATION_ASSESSMENT.md`），前者為本次任務輸入文件，
後者為既有、非本次任務產生的文件——是否納入 commit 由 PLAN 端決定，本次僅 commit
`.github/workflows/ci.yml` 與本驗收文件本身。
