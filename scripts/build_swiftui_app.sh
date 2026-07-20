#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$PROJECT_DIR/macos/WhisperApp"
RUNTIME_DIR="$PROJECT_DIR/dist/WhisperWorker"
APP="$PROJECT_DIR/dist/Whisper Swift.app"
STAGING="$PROJECT_DIR/dist/Whisper Swift.signing"
SCRATCH="${SWIFT_SCRATCH_PATH:-/tmp/whisper-swift-release}"
SIGNING_IDENTITY="${WHISPER_SIGNING_IDENTITY:-WhisperSTT Local}"

test -x "$RUNTIME_DIR/WhisperWorker"
python3 "$PROJECT_DIR/scripts/verify_worker_bundle.py" "$RUNTIME_DIR"

cd "$PACKAGE_DIR"
CLANG_MODULE_CACHE_PATH=/tmp/whisper-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/whisper-clang-cache \
swift build -c release --scratch-path "$SCRATCH"

rm -rf "$APP" "$STAGING"
mkdir -p "$STAGING/Contents/MacOS" "$STAGING/Contents/Resources"
cp "$SCRATCH/release/WhisperApp" "$STAGING/Contents/MacOS/WhisperApp"
cp "$PACKAGE_DIR/Info.plist" "$STAGING/Contents/Info.plist"
cp -R "$RUNTIME_DIR" "$STAGING/Contents/Resources/WhisperWorker"

xattr -cr "$STAGING"
xattr -d com.apple.FinderInfo "$STAGING" 2>/dev/null || true
codesign --force --sign "$SIGNING_IDENTITY" "$STAGING"
codesign --verify --deep --strict --verbose=2 "$STAGING"
mv "$STAGING" "$APP"
xattr -cr "$APP"
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
codesign --verify --deep --strict --verbose=2 "$APP"

ISOLATED_HOME="/tmp/whisper-gate-b-home"
rm -rf "$ISOLATED_HOME"
mkdir -p "$ISOLATED_HOME"
env -i HOME="$ISOLATED_HOME" PATH="/usr/bin:/bin" \
    "$APP/Contents/Resources/WhisperWorker/WhisperWorker" \
    </dev/null > /tmp/whisper-gate-b-ready.jsonl
python3 -c 'import json; event=json.loads(open("/tmp/whisper-gate-b-ready.jsonl").readline()); assert event["event"] == "ready"'

echo "Gate B local artifact ready: $APP"
