#!/usr/bin/env bash
# sign_and_install.sh — 已整合至 package.sh，此腳本僅作重導
# TCC 簽名、安裝、版本驗證請改用 package.sh
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "⚠️  sign_and_install.sh 已棄用，自動轉導至 package.sh…"
exec bash "$SCRIPT_DIR/package.sh" "$@"
