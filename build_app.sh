#!/usr/bin/env bash
# build_app.sh — 建立 Whisper STT.app bundle
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Whisper STT"
APP_PATH="$PROJECT_DIR/$APP_NAME.app"
MACOS_DIR="$APP_PATH/Contents/MacOS"
CONTENTS_DIR="$APP_PATH/Contents"
RESOURCES_DIR="$APP_PATH/Contents/Resources"
EXECUTABLE="$MACOS_DIR/whisper-launcher"

echo "🔨 建立 $APP_NAME.app …"
echo "   專案目錄：$PROJECT_DIR"

# ── 清除舊版 ──────────────────────────────────────────────────
if [ -d "$APP_PATH" ]; then
  echo "🗑  移除舊版 $APP_NAME.app …"
  rm -rf "$APP_PATH"
fi

# ── 建立 bundle 目錄結構 ──────────────────────────────────────
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# ── 複製並替換 launcher.sh 的佔位符 ──────────────────────────
sed "s|__PROJECT_DIR__|$PROJECT_DIR|g" \
  "$PROJECT_DIR/launcher.sh" > "$EXECUTABLE"
chmod +x "$EXECUTABLE"

# ── 複製 Info.plist ───────────────────────────────────────────
cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"

# ── 複製圖示 ──────────────────────────────────────────────────
if [ -f "$PROJECT_DIR/AppIcon.icns" ]; then
  cp "$PROJECT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
  echo "🎨 圖示已加入"
fi

# ── 打包 ffmpeg（讓 .app 免 Homebrew 依賴）────────────────────
FFMPEG_BIN_DIR="$RESOURCES_DIR/bin"
mkdir -p "$FFMPEG_BIN_DIR"
# 也在專案目錄建立 bin/，讓 Terminal 模式也能找到
mkdir -p "$PROJECT_DIR/bin"

FFMPEG_SRC=""
for candidate in "/opt/homebrew/bin/ffmpeg" "/usr/local/bin/ffmpeg" "$(which ffmpeg 2>/dev/null)"; do
  if [ -x "$candidate" ]; then
    FFMPEG_SRC="$candidate"
    break
  fi
done

if [ -n "$FFMPEG_SRC" ]; then
  rm -f "$FFMPEG_BIN_DIR/ffmpeg" "$PROJECT_DIR/bin/ffmpeg"
  cp "$FFMPEG_SRC" "$FFMPEG_BIN_DIR/ffmpeg"
  cp "$FFMPEG_SRC" "$PROJECT_DIR/bin/ffmpeg"
  chmod +x "$FFMPEG_BIN_DIR/ffmpeg" "$PROJECT_DIR/bin/ffmpeg"
  echo "🎬 ffmpeg 已打包：$FFMPEG_SRC → bin/ffmpeg"
else
  echo "⚠️  未找到 ffmpeg，.app 執行時需要系統已安裝 ffmpeg"
  echo "   建議執行：brew install ffmpeg"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 完成！"
echo ""
echo "   $APP_PATH"
echo ""
echo "使用方式："
echo "  • 雙擊 app 直接啟動"
echo "  • 或拖入 /Applications 後從 Launchpad 開啟"
echo ""
echo "⚠️  首次開啟若出現「無法驗證開發者」："
echo "   右鍵 → 打開 → 打開（bypass Gatekeeper）"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
