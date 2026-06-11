"""integrations.py — Obsidian 存檔與 Claudian 自動整理。"""
from __future__ import annotations

import logging
import os
import re
import subprocess
import threading
import time
from datetime import datetime
from pathlib import Path

from sse import broadcast

_OBSIDIAN_PATH = os.environ.get("OBSIDIAN_MEETING_PATH", "")


def _trigger_claudian_async(fpath: Path) -> None:
    """背景執行 Claudian 整理會議記錄。"""
    def run() -> None:
        try:
            time.sleep(1)  # 等檔案寫入穩定
            logging.info("[Claudian] 開始背景整理檔案：%s", fpath.name)
            broadcast("status", {"msg": f"🤖 Claudian 自動整理中：{fpath.name}…"})
            cmd = [
                "/opt/homebrew/bin/claude", "-p",
                f"執行 meeting-notes 整理 {fpath.name}",
                "--permission-mode", "bypassPermissions",
            ]
            res = subprocess.run(
                cmd, cwd=str(fpath.parent),
                capture_output=True, text=True, timeout=300,
            )
            if res.returncode == 0:
                logging.info("[Claudian] 整理成功！")
                broadcast("status", {"msg": f"✅ Claudian 整理完成：{fpath.name}"})
            else:
                last_err = res.stderr.strip().splitlines()[-1] if res.stderr else "未知錯誤"
                logging.warning("[Claudian] 整理失敗。Code: %d, Error: %s", res.returncode, res.stderr)
                broadcast("status", {"msg": f"⚠️ Claudian 整理失敗：{last_err}"})
        except Exception as e:
            logging.warning("[Claudian] 呼叫異常：%s", e)
            broadcast("status", {"msg": f"❌ Claudian 執行異常：{e}"})

    threading.Thread(target=run, daemon=True).start()


def save_to_obsidian(text: str, lang: str, meta: dict | None = None) -> str:
    """把轉錄文字存成 Obsidian .md 檔，回傳檔案路徑；失敗回傳空字串。"""
    if not _OBSIDIAN_PATH or not text.strip():
        return ""
    try:
        vault_dir = Path(_OBSIDIAN_PATH)
        vault_dir.mkdir(parents=True, exist_ok=True)

        now      = datetime.now()
        date_str = now.strftime("%Y-%m-%d")
        time_str = now.strftime("%H:%M")
        snippet  = re.sub(r'[\\/:*?"<>|\n]', '', text.strip()[:20]).strip()
        fname    = f"{date_str} {time_str} {snippet}.md" if snippet else f"{date_str} {time_str} 會議記錄.md"
        fpath    = vault_dir / fname

        meta = meta or {}
        duration_sec = meta.get("duration_seconds", 0)
        duration_formatted = ""
        if duration_sec:
            m = int(duration_sec // 60)
            s = int(duration_sec % 60)
            duration_formatted = f"{m:02d}:{s:02d}"

        md = f"""---
date: {date_str}
time: "{time_str}"
language: {lang}
source: whisper-local-stt
model: {meta.get("model", "unknown")}
domain: {meta.get("domain", "general")}
status: raw
extra_terms: "{meta.get("extra_terms", "")}"
duration: "{duration_formatted}"
tags:
  - meeting
  - transcript
---

# 會議逐字稿 {date_str} {time_str}

> 由 Whisper 本地轉錄，可用 Claudian 整理為會議記錄
> 指令範例：`$meeting-notes` 整理此頁面

## 逐字稿

{text}
"""
        fpath.write_text(md, encoding="utf-8")
        logging.info("[Obsidian] 已存檔：%s", fpath)
        _trigger_claudian_async(fpath)
        return str(fpath)
    except Exception as e:
        logging.warning("[Obsidian] 存檔失敗：%s", e)
        return ""
