#!/usr/bin/env bash
# start.sh — 一鍵啟動 Whisper Web UI
set -e

PORT=${PORT:-5001}

echo "🚀 Whisper 語音轉文字系統"
echo "🌐 開啟瀏覽器：http://localhost:$PORT"
echo "🛑 按 Ctrl+C 停止"
echo ""

python3 -m waitress --port=$PORT --threads=8 app:app
