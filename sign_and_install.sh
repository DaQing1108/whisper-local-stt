#!/bin/bash
# sign_and_install.sh — 打包後簽名並安裝 Whisper STT.app
set -e

CERT="WhisperSTT Local"
DIST="$(dirname "$0")/dist/Whisper STT.app"
INSTALL="/Applications/Whisper STT.app"
BINARY="Contents/MacOS/WhisperAI"
ENTITLEMENTS="$(dirname "$0")/whisper_entitlements.plist"

echo "▶ 簽名主執行檔…"
cp "$DIST/$BINARY" /tmp/WhisperAI_to_sign
codesign --force \
  --sign "$CERT" \
  --identifier "com.via.whisper-ai" \
  /tmp/WhisperAI_to_sign
cp /tmp/WhisperAI_to_sign "$DIST/$BINARY"
rm /tmp/WhisperAI_to_sign

echo "▶ 安裝到 /Applications…"
rm -rf "$INSTALL"
cp -r "$DIST" /Applications/

echo "▶ 重新簽名 system_audio_capture 輔助工具（穩定 TCC 身份）…"
for HELPER in "Contents/Resources/bin/system_audio_capture" "Contents/Frameworks/bin/system_audio_capture"; do
    HELPER_PATH="$INSTALL/$HELPER"
    if [ -f "$HELPER_PATH" ]; then
        codesign --force \
          --sign "$CERT" \
          --identifier "com.via.whisper-ai.audio-helper" \
          "$HELPER_PATH"
        echo "  ✓ $HELPER"
    fi
done

echo "✅ 完成 — Whisper STT.app 已簽名並安裝"
codesign -dv "$INSTALL/$BINARY" 2>&1 | grep -E "Identifier|TeamIdentifier|Signature"
