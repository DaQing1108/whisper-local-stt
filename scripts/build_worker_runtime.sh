#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist/WhisperWorker"

cd "$PROJECT_DIR"
export PYINSTALLER_CONFIG_DIR="${PYINSTALLER_CONFIG_DIR:-/tmp/whisper-pyinstaller}"
python3 -m PyInstaller --clean -y worker.spec
test -x "$DIST_DIR/WhisperWorker"
test -x "$DIST_DIR/_internal/bin/ffmpeg"

"$DIST_DIR/WhisperWorker" </dev/null > /tmp/whisper-worker-ready.jsonl
python3 -c 'import json; event=json.loads(open("/tmp/whisper-worker-ready.jsonl").readline()); assert event["event"] == "ready"'
python3 scripts/verify_worker_bundle.py "$DIST_DIR"
echo "Worker runtime ready: $DIST_DIR"
