# Whisper SwiftUI P0 Daily Transcription Execution Spec v1

## BLUF

P0 的完成條件是 Whisper SwiftUI 能獨立支援日常檔案與錄音轉錄、可編輯結果、播放來源音訊，以及輸出 TXT、Markdown 與具真實時間碼的 SRT。未滿足本文件全部 acceptance criteria 前，不宣稱可取代 legacy Whisper STT.app。

## Scope

### Allowed

- 延伸既有 JSONL protocol v1 payload；不得破壞舊 Worker。
- 延伸 Swift history schema，並維持舊 JSON history 可讀。
- 新增 current result workspace、audio playback、copy/clear/restore 與 export。
- 新增 language preset、domain、one-shot terminology 與 bounded batch queue。
- 新增單元、整合與 release pipeline regression tests。

### Forbidden

- 不修改 legacy Whisper STT.app。
- 不 commit、push、stage 或清理既有 dirty worktree。
- 不在 P0 實作 AI summary、發布語意或 productivity parity。
- 不改變既有錄音與 Worker crash-recovery lifecycle 的行為。

## Data contract

每筆成功結果至少保存：來源 audio path、完成時間、requested model、detected/requested language、editable text、segments（start/end/text）、duration、domain 與 one-shot terms。舊 history 缺少新增欄位時，必須以安全預設值載入。

## Acceptance criteria

1. 完成事件可從 Worker `info` 解析 segments、duration、language、domain 與 extra terms，且 protocol v1 舊 payload 仍可用。
2. 完成結果經 atomic write 保存；重啟後可載入，文字修改也必須 atomic persist，寫入失敗時 rollback。
3. UI 可編輯、copy、clear 並從 history restore；clear 不刪除 history。
4. UI 可播放/暫停目前來源音訊。
5. TXT 與 Markdown export 使用使用者編輯後文字；SRT 使用真實 segments，不得偽造等距時間碼。缺少 segments 時明確停用或報錯。
6. Language 提供 Auto、繁中/中文、English、Japanese presets，並允許 ISO code。
7. Domain 與 one-shot terminology 會送入 Worker，且不改變舊 command 必填欄位。
8. Batch queue 有明確容量上限、保留選檔順序、逐檔 terminal state，單檔失敗不抹除其他結果，並可停止尚未送出的工作。
9. P0 新增測試全數通過，既有 Swift 與 Python 測試無 regression，release build/pipeline 通過。

## Verification gate

- `swift test`（WhisperApp package）
- P0-focused Python unit tests及既有 Worker protocol tests
- release build pipeline regression tests
- independent code review 無 unresolved blocker

## Stop conditions

- 發現必須破壞 JSONL v1 才能完成。
- 發現需要修改 legacy app 或 production data。
- 既有 dirty worktree 與本任務修改發生無法安全分離的衝突。
