#!/usr/bin/env bash
# start.sh — 一鍵啟動 Whisper Web UI
set -e

PORT=${PORT:-5001}

echo "🚀 Whisper STT v$(python3 -c 'from version import __version__; print(__version__)' 2>/dev/null || echo '1.2.0') 啟動中…"
echo "🌐 開啟瀏覽器：http://localhost:$PORT"
echo "🛑 按 Ctrl+C 停止"
echo ""

python3 app.py
