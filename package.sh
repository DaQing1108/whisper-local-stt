#!/usr/bin/env bash
# package.sh — Whisper AI 打包 + 驗證腳本
# 用法：bash package.sh
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Whisper STT"
DIST_APP="$PROJECT_DIR/dist/$APP_NAME.app"
INSTALL_APP="/Applications/$APP_NAME.app"
PORT=5001

cd "$PROJECT_DIR"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📦 Whisper AI 打包流程"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 步驟 1：檢查舊 server ────────────────────────────────────
echo ""
echo "🔍 [1/5] 檢查是否有舊 server 佔用 port $PORT…"
OLD_PIDS=$(lsof -ti :$PORT 2>/dev/null || true)
if [ -n "$OLD_PIDS" ]; then
  echo "   ⚠️  發現舊 server（PID: $OLD_PIDS），強制終止中…"
  echo "$OLD_PIDS" | xargs kill -9 2>/dev/null || true
  sleep 1
  echo "   ✅ 舊 server 已清除"
else
  echo "   ✅ port $PORT 無衝突"
fi

# ── 步驟 2：PyInstaller 打包 ─────────────────────────────────
echo ""
echo "🔨 [2/5] PyInstaller 打包中（約 2–3 分鐘）…"
python3 -m PyInstaller -y gui.spec 2>&1 | grep -E "^(INFO|WARNING|ERROR).*BUNDLE|completed|failed|error" || true
if [ ! -d "$DIST_APP" ]; then
  echo "   ❌ 打包失敗：找不到 $DIST_APP"
  exit 1
fi
echo "   ✅ 打包完成"

# ── 步驟 3：簽章 ────────────────────────────────────────────
echo ""
echo "✍️  [3/5] 清除 metadata 並簽章…"
xattr -cr "$DIST_APP" 2>/dev/null || true
codesign -s - --deep --force --no-strict "$DIST_APP" 2>&1 | grep -v "^$" || true
echo "   ✅ 簽章完成"

# ── 步驟 4：部署到 /Applications ────────────────────────────
echo ""
echo "🚀 [4/5] 部署到 /Applications…"
rm -rf "$INSTALL_APP"
cp -R "$DIST_APP" "/Applications/"
echo "   ✅ 已安裝到 $INSTALL_APP"

# ── 步驟 5：驗證 ────────────────────────────────────────────
echo ""
echo "🧪 [5/5] 驗證安裝結果…"

# 確認沒有巢狀結構
NESTED=$(find "$INSTALL_APP" -name "*.app" -mindepth 2 2>/dev/null | head -1)
if [ -n "$NESTED" ]; then
  echo "   ❌ 發現巢狀 .app：$NESTED"
  exit 1
fi
echo "   ✅ app 結構正常（無巢狀）"

# 確認 ffmpeg 路徑寫入
FFMPEG_CHECK=$(grep -r "opt/homebrew/bin/ffmpeg" "$INSTALL_APP/Contents/Resources/whisper_core.py" 2>/dev/null | wc -l)
if [ "$FFMPEG_CHECK" -eq 0 ]; then
  echo "   ❌ whisper_core.py 缺少 ffmpeg 路徑修正"
  exit 1
fi
echo "   ✅ ffmpeg 路徑已寫入"

# 確認 gui.py 有 PATH 設定
PATH_CHECK=$(grep -c "opt/homebrew/bin" "$INSTALL_APP/Contents/Resources/gui.py" 2>/dev/null || echo 0)
if [ "$PATH_CHECK" -eq 0 ]; then
  echo "   ❌ gui.py 缺少 PATH 設定"
  exit 1
fi
echo "   ✅ PATH 設定已寫入"

# 確認版本號
VERSION=$(python3 -c "import sys; sys.path.insert(0,'$INSTALL_APP/Contents/Resources'); from version import __version__; print(__version__)" 2>/dev/null || echo "unknown")
echo "   ✅ 版本：v$VERSION"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ 打包完成！v$VERSION"
echo ""
echo "   $INSTALL_APP"
echo ""
echo "⚠️  首次開啟若出現「無法驗證開發者」："
echo "   系統設定 → 隱私權與安全性 → 仍要開啟"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
