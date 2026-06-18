#!/usr/bin/env bash
# build_app.sh — 導向正確的打包腳本
# Whisper STT 使用 PyInstaller 打包，請執行 package.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "ℹ️  build_app.sh 已整合至 package.sh，自動轉導…"
exec bash "$SCRIPT_DIR/package.sh" "$@"
