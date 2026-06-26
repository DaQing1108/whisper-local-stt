#!/usr/bin/env bash
# package.sh — Whisper STT 完整打包腳本（唯一需要執行的指令）
# 用法：bash package.sh
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Whisper STT"
DIST_APP="$PROJECT_DIR/dist/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"
PORT=5001
CERT="WhisperSTT Local"
SPARKLE_FRAMEWORK="$PROJECT_DIR/Sparkle.framework"
DIST_FRAMEWORKS="$DIST_APP/Contents/Frameworks"

cd "$PROJECT_DIR"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Whisper STT 打包流程"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 步驟 0：確認 gui.spec 版本與 version.py 一致 ────────────
echo ""
echo "🔍 [0/6] 確認版本號一致…"
SPEC_VER=$(grep "CFBundleShortVersionString" gui.spec | grep -o "'[0-9.]*'" | tr -d "'")
CODE_VER=$(python3 -c "import sys; sys.path.insert(0,'$PROJECT_DIR'); from version import __version__; print(__version__)")
if [ "$SPEC_VER" != "$CODE_VER" ]; then
  echo "   ❌ 版本不一致：gui.spec=$SPEC_VER  version.py=$CODE_VER"
  echo "   請先同步版本號再打包"
  exit 1
fi
echo "   ✅ 版本一致：v$CODE_VER"

if [ -d "$SPARKLE_FRAMEWORK" ]; then
  echo "   ✅ Sparkle.framework 已找到，將納入 .app/Contents/Frameworks"
else
  echo "   ⚠️  找不到 Sparkle.framework；自動更新 UI/檢查邏輯待 framework 放入專案根目錄後才會生效"
  echo "      預期位置：$SPARKLE_FRAMEWORK"
fi

# ── 步驟 1：關閉舊 App + 清除 port ──────────────────────────
echo ""
echo "🔍 [1/6] 關閉舊 App 並清除 port $PORT…"
pkill -f "WhisperAI\|whisper-launcher" 2>/dev/null || true
OLD_PIDS=$(lsof -ti :$PORT 2>/dev/null || true)
if [ -n "$OLD_PIDS" ]; then
  echo "$OLD_PIDS" | xargs kill -9 2>/dev/null || true
  sleep 1
  echo "   ✅ 舊 server 已清除"
else
  echo "   ✅ port $PORT 無衝突"
fi

# ── 步驟 2：PyInstaller 打包 ─────────────────────────────────
echo ""
echo "🔨 [2/6] PyInstaller 打包中（約 2–3 分鐘）…"
python3 -m PyInstaller -y gui.spec 2>&1 | grep -E "BUNDLE|completed|failed|error" || true
if [ ! -d "$DIST_APP" ]; then
  echo "   ❌ 打包失敗：找不到 $DIST_APP"
  exit 1
fi
echo "   ✅ 打包完成"

if [ -d "$SPARKLE_FRAMEWORK" ]; then
  mkdir -p "$DIST_FRAMEWORKS"
  rm -rf "$DIST_FRAMEWORKS/Sparkle.framework"
  cp -R "$SPARKLE_FRAMEWORK" "$DIST_FRAMEWORKS/"
  echo "   ✅ Sparkle.framework 已複製到 Contents/Frameworks"
fi

# ── 步驟 3：穩定簽章（TCC 身份跨 rebuild 不變）────────────────
echo ""
echo "✍️  [3/6] 穩定簽章（WhisperSTT Local）…"
xattr -cr "$DIST_APP" 2>/dev/null || true
if ! codesign --sign "$CERT" --deep --force --no-strict "$DIST_APP" 2>&1 | grep -v "^$"; then
  echo "   ❌ 簽章失敗：憑證 '$CERT' 可能不存在或已過期"
  exit 1
fi
echo "   ✅ 穩定簽章完成"

# ── 步驟 4：安裝到 /Applications ─────────────────────────────
echo ""
echo "🚀 [4/6] 安裝到 /Applications…"
rm -rf "$INSTALL_APP"
cp -R "$DIST_APP" "/Applications/"
echo "   ✅ 已安裝"

# ── 步驟 5：重新簽名 system_audio_capture（穩定 TCC 身份）──
echo ""
echo "🔏 [5/6] 重新簽名 system_audio_capture（TCC 穩定身份）…"
TCC_SIGNED=0
for HELPER in "Contents/Resources/bin/system_audio_capture" \
              "Contents/Frameworks/bin/system_audio_capture"; do
  HP="$INSTALL_APP/$HELPER"
  if [ -f "$HP" ]; then
    if ! codesign --force --sign "$CERT" \
      --identifier "com.via.whisper-ai.audio-helper" \
      "$HP" 2>&1 | grep -v "^$"; then
      echo "   ❌ Helper 簽章失敗：$HP"
      exit 1
    fi
    echo "   ✅ $HELPER"
    TCC_SIGNED=$((TCC_SIGNED + 1))
  fi
done
if [ "$TCC_SIGNED" -eq 0 ]; then
  echo "   ⚠️  找不到 system_audio_capture，系統音訊功能可能異常"
fi

# ── 步驟 6：驗證 ────────────────────────────────────────────
echo ""
echo "🧪 [6/6] 驗證安裝結果…"

INSTALLED_VER=$(python3 -c "
import sys
sys.path.insert(0,'$INSTALL_APP/Contents/Resources')
from version import __version__
print(__version__)
" 2>/dev/null || echo "unknown")

if [ "$INSTALLED_VER" != "$CODE_VER" ]; then
  echo "   ❌ 版本驗證失敗：安裝版本=$INSTALLED_VER 預期=$CODE_VER"
  exit 1
fi
echo "   ✅ 版本確認：v$INSTALLED_VER"

NESTED=$(find "$INSTALL_APP" -name "*.app" -mindepth 2 ! -path "*/Sparkle.framework/*" 2>/dev/null | head -1)
if [ -n "$NESTED" ]; then
  echo "   ❌ 發現巢狀 .app：$NESTED"
  exit 1
fi
echo "   ✅ app 結構正常"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 打包完成！v$INSTALLED_VER"
echo "   $INSTALL_APP"
echo ""
echo "⚠️  首次開啟若出現「無法驗證開發者」："
echo "   系統設定 → 隱私權與安全性 → 仍要開啟"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
