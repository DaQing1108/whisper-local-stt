# Whisper STT v2.4.1 安裝指南

## 執行摘要

Whisper STT 是 Apple Silicon macOS 本地語音轉文字 App。正式安裝包已包含 Python runtime 與 ffmpeg，不需要 Homebrew；完成安裝、權限設定與模型準備後即可進行首次轉錄。

## 系統需求

- Apple Silicon Mac（M1 或更新機型）
- macOS 12 Monterey 或更新版本
- 建議至少 8 GB RAM、首次模型下載所需的穩定網路，以及 2 GB 可用磁碟空間
- 麥克風錄音需要「麥克風」權限；系統音訊需要「螢幕錄製」權限

## 安裝

1. 將 `Whisper STT.app` 拖入 `/Applications`。
2. 從 Applications 開啟 Whisper STT。
3. 若 macOS 顯示無法驗證開發者，前往「系統設定 → 隱私權與安全性」，確認來源後選擇「仍要開啟」。
4. App 顯示權限提示時允許麥克風。需要轉錄 Teams、Zoom 或瀏覽器聲音時，再允許螢幕錄製。

## 完成首次轉錄

1. 保持預設語言與模型，選擇「麥克風」。
2. 按下開始錄音並清楚說話至少 10 秒。
3. 停止錄音，等待狀態顯示全部轉錄完成。
4. 確認 Transcript 出現文字，再測試 Copy 或 Export。

Notion、Obsidian、LLM API Key 與 Speaker Diarization 都是選填設定；未設定時不影響本地轉錄。

遇到權限、啟動或轉錄問題，請依 [故障排除指南](TROUBLESHOOTING.md) 處理。
