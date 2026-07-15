# Whisper STT v2.4.0 故障排除

## 執行摘要

先確認 App 版本與權限，再重新啟動 Whisper STT。若仍失敗，檢查 port 5001 與最新 log；舊 log 不能代表目前執行中的 App 狀態。

## App 無法開啟

1. 確認 App 位於 `/Applications/Whisper STT.app`。
2. 前往「系統設定 → 隱私權與安全性」，選擇「仍要開啟」。
3. 完全結束 Whisper STT 後重新啟動。

## 麥克風沒有聲音

1. 前往「系統設定 → 隱私權與安全性 → 麥克風」，開啟 Whisper STT。
2. 確認 App 內選擇的是麥克風模式。
3. 重新啟動 App，錄製至少 10 秒的清楚語音。

## 系統音訊未偵測到內容

1. 前往「系統設定 → 隱私權與安全性 → 螢幕錄製」，開啟 Whisper STT。
2. 權限剛變更時必須完全結束並重新啟動 App。
3. 確認 Teams、Zoom、YouTube 或其他音源正在播放，錄製至少 30 秒再停止。

## App 顯示連線失敗或空白

Whisper STT 使用本機 port 5001。若該 port 被其他程序占用，可在 Terminal 執行：

```bash
lsof -i :5001
```

不要直接強制結束不明程序。先關閉舊的 Whisper STT，再重新啟動；仍無法恢復時，記錄 PID 與程序名稱。

## 檢查 log

開發版 log 通常位於專案根目錄的 `whisper_server.log`；安裝版啟動 log 位於 `~/Library/Logs/WhisperSTT/`。只採用本次操作時間附近的新紀錄，並保留完整 traceback。

## Disabled 按鈕無法使用

- Copy / Export：需要先完成轉錄。
- Obsidian：需要先在偏好設定驗證 Vault 路徑。
- Notion：需要先驗證 Integration Token 與目標 Page ID。
- Speaker Diarization：需要有效 Hugging Face Token 與相依模型。

完成設定後返回主畫面；若狀態沒有更新，重新開啟偏好設定或重新啟動 App。
