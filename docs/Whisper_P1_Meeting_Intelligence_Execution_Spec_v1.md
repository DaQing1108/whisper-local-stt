# Whisper SwiftUI P1 Meeting Intelligence Execution Spec v1

## BLUF

P1 完成後，每筆 transcript 有獨立且可恢復的 meeting summary；生成、編輯、保存及發布失敗不得修改或遮蔽 source transcript。Notion 維持明確的「append existing page」語意，Obsidian 產生獨立 meeting note；兩者不得被 UI 泛稱為等價同步。

## Acceptance criteria

1. Canonical summary 保存 meeting ID/title、transcription ID、generated/edited text、provider、status、error 與 timestamps。
2. Summary generation 為 async task；失敗只更新 summary state，不改 transcript completion/history。
3. Summary edit 有 dirty state、explicit save、atomic persistence 與 write rollback。
4. App restart 可恢復 summary；舊 history 沒 summary 時安全顯示 empty state。
5. LLM credential 只存 Keychain，不進 UserDefaults、history、summary JSON、log 或 export metadata。
6. Obsidian 產生 transcript + destination-specific summary 的獨立 meeting note，atomic write 且不覆寫既有檔案。
7. Notion 明確標示並實作 append existing page；單一 request，ambiguous outcome 保留 retry lock。
8. Generated summary、edited summary 與 source transcript 分開保存；發布使用 effective summary，但保留 transcript section。
9. Swift/Python regression、destination mock tests、temp Vault read-back 與 independent review 全部通過。

## Boundaries

- 不建立或寫入正式 Notion page，不讀取正式 LLM credential。
- 不把 legacy `.env` 或 `.last_summary.json` 當作 migration source。
- 不破壞 JSONL protocol v1；如新增 command，舊 transcribe/cancel clients 必須保持相容。
- 不 commit、push、stage 或修改 legacy production app。
