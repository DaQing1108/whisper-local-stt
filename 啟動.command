#!/usr/bin/env bash
# macOS 一鍵啟動腳本

cd "$(dirname "$0")"

echo "========================================="
echo "   Whisper AI 語音轉文字系統 v1.2.0"
echo "========================================="
echo ""

# 1. 檢查 ffmpeg
if ! command -v ffmpeg &>/dev/null; then
  echo "⚠️ 系統缺少 ffmpeg，正在嘗試透過 Homebrew 安裝..."
  if command -v brew &>/dev/null; then
    brew install ffmpeg
  else
    echo "❌ 錯誤：找不到 Homebrew，請先手動安裝 ffmpeg！"
    echo "   打開終端機輸入：/bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    exit 1
  fi
fi

# 2. 建立並進入 Python 虛擬環境
if [ ! -d "venv" ]; then
  echo "📦 第一次啟動，正在安裝必要的 AI 模型套件（約需 3-5 分鐘）..."
  python3 -m venv venv
  source venv/bin/activate
  pip install --upgrade pip -q
  pip install -r requirements.txt -q
  echo "✅ 安裝完成！"
else
  source venv/bin/activate
fi

# 3. 初始化環境變數檔
if [ ! -f .env ]; then
  cp .env.example .env
  echo "📝 已建立 .env 設定檔，如需整合 Notion/Obsidian/LLM 請編輯此檔案"
fi

# 4. 啟動伺服器
echo ""
echo "🚀 伺服器已啟動！"
echo "👉 請打開瀏覽器並前往：http://localhost:5001"
echo "🛑 若要關閉，請直接關閉此視窗或按 Ctrl+C"
echo "========================================="
echo ""

python3 app.py
