"""constants.py — 跨模組共用常數。"""
from pathlib import Path

# 使用者設定檔目錄（.app 與 Terminal 模式統一讀寫此路徑）
USER_DATA_DIR = Path.home() / "Library" / "Application Support" / "WhisperSTT"
ENV_PATH = USER_DATA_DIR / ".env"
