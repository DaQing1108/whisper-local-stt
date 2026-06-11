#!/usr/bin/env bash
# setup.sh — Whisper 本地語音轉文字系統一鍵安裝
set -e

echo "🔍 檢查系統需求..."
echo ""

# ── Python ────────────────────────────────────────────────────
PYTHON=$(command -v python3 || true)
if [ -z "$PYTHON" ]; then
  echo "❌ 找不到 python3，請先安裝 Python 3.9+"
  echo "   macOS: brew install python3"
  exit 1
fi
PY_VER=$($PYTHON -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
echo "✅ Python $PY_VER"

# ── ffmpeg ────────────────────────────────────────────────────
if ! command -v ffmpeg &>/dev/null; then
  echo "⚠️  找不到 ffmpeg，嘗試用 Homebrew 安裝..."
  if command -v brew &>/dev/null; then
    brew install ffmpeg
  else
    echo "❌ 請先安裝 ffmpeg"
    echo "   macOS: brew install ffmpeg"
    echo "   或至 https://ffmpeg.org/download.html 下載"
    exit 1
  fi
fi
echo "✅ ffmpeg $(ffmpeg -version 2>&1 | head -1 | awk '{print $3}')"

# ── Apple Silicon 提示 ────────────────────────────────────────
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  echo "✅ Apple Silicon 偵測到，將使用 Neural Engine 加速（mlx-whisper）"
else
  echo "ℹ️  非 Apple Silicon，使用 CPU 模式（faster-whisper）"
fi

echo ""
echo "📦 安裝 Python 套件..."
$PYTHON -m pip install --user -r requirements.txt

echo ""
echo "⚙️  設定環境變數..."
if [ ! -f .env ]; then
  cp .env.example .env
  echo "📝 已建立 .env"
  echo "   如需 Notion 上傳功能，請編輯 .env 填入 NOTION_TOKEN 和 NOTION_PAGE_ID"
else
  echo "✅ .env 已存在，略過"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 安裝完成！"
echo ""
echo "🚀 啟動方式："
echo "   bash start.sh"
echo ""
echo "   或手動執行："
echo "   python3 -m waitress --port=5001 --threads=8 app:app"
echo ""
echo "🌐 然後開啟：http://localhost:5001"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
