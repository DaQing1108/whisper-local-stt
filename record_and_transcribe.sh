#!/usr/bin/env bash
# record_and_transcribe.sh
# 錄音完畢後自動呼叫 transcribe.py 並上傳 Notion
# 需要：sox（brew install sox）
#
# 用法：
#   ./record_and_transcribe.sh [--upload] [--page-id <id>] [--model small]

set -euo pipefail

UPLOAD=""
PAGE_ID=""
MODEL="small"
FILENAME="recording_$(date +%Y%m%d_%H%M%S).wav"

# 解析參數
while [[ $# -gt 0 ]]; do
  case "$1" in
    --upload)   UPLOAD="--upload";        shift ;;
    --page-id)  PAGE_ID="--page-id $2";  shift 2 ;;
    --model)    MODEL="$2";              shift 2 ;;
    *)          echo "未知參數：$1"; exit 1 ;;
  esac
done

# 檢查 sox
if ! command -v rec &>/dev/null; then
  echo "❌ 找不到 rec（sox）。請先執行：brew install sox"
  exit 1
fi

echo "🎙️  開始錄音（按 Ctrl+C 停止）…"
rec -r 16000 -c 1 -e signed -b 16 "$FILENAME"

echo ""
echo "🔁 錄音結束，開始轉錄…"
python3 transcribe.py "$FILENAME" --model "$MODEL" $UPLOAD $PAGE_ID

echo "✅ 完成！"
