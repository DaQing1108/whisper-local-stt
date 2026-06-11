"""integrations.py — Obsidian 存檔與會議記錄自動整理。"""
from __future__ import annotations

import logging
import os
import re
import threading
import time
from datetime import datetime
from pathlib import Path

from sse import broadcast

_OBSIDIAN_PATH = os.environ.get("OBSIDIAN_MEETING_PATH", "")

_MEETING_NOTES_CMD = Path.home() / ".claude" / "commands" / "meeting-notes.md"


def _load_meeting_notes_prompt() -> str:
    """讀取 meeting-notes command 的指令內容（去除 frontmatter）。"""
    if not _MEETING_NOTES_CMD.exists():
        return ""
    text = _MEETING_NOTES_CMD.read_text(encoding="utf-8")
    if text.startswith("---"):
        end = text.find("---", 3)
        if end != -1:
            text = text[end + 3:].lstrip()
    return text.strip()


def _call_llm(system_prompt: str, user_message: str) -> str:
    """依可用的 API key 自動選擇 LLM，回傳整理結果。"""
    import urllib.request, json

    anthropic_key = os.environ.get("ANTHROPIC_API_KEY", "")
    gemini_key    = os.environ.get("GEMINI_API_KEY", "")
    openai_key    = os.environ.get("OPENAI_API_KEY", "")

    if anthropic_key:
        payload = json.dumps({
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 4096,
            "system": system_prompt,
            "messages": [{"role": "user", "content": user_message}],
        }).encode()
        req = urllib.request.Request(
            "https://api.anthropic.com/v1/messages",
            data=payload,
            headers={"x-api-key": anthropic_key, "anthropic-version": "2023-06-01",
                     "content-type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=300) as resp:
            return json.loads(resp.read())["content"][0]["text"]

    if gemini_key:
        body = json.dumps({
            "system_instruction": {"parts": [{"text": system_prompt}]},
            "contents": [{"parts": [{"text": user_message}]}],
        }).encode()
        # 依序嘗試，遇 429/503 換下一個
        for model in ("gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.0-flash", "gemini-flash-lite-latest"):
            try:
                req = urllib.request.Request(
                    f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={gemini_key}",
                    data=body,
                    headers={"content-type": "application/json"},
                )
                with urllib.request.urlopen(req, timeout=300) as resp:
                    data = json.loads(resp.read())
                logging.info("[MeetingNotes] Gemini model=%s", model)
                return data["candidates"][0]["content"]["parts"][0]["text"]
            except Exception as e:
                logging.warning("[MeetingNotes] Gemini %s 失敗：%s，嘗試下一個", model, e)
        raise RuntimeError("所有 Gemini 模型均不可用")

    if openai_key:
        payload = json.dumps({
            "model": "gpt-4o-mini",
            "max_tokens": 4096,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user",   "content": user_message},
            ],
        }).encode()
        req = urllib.request.Request(
            "https://api.openai.com/v1/chat/completions",
            data=payload,
            headers={"Authorization": f"Bearer {openai_key}",
                     "content-type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=300) as resp:
            return json.loads(resp.read())["choices"][0]["message"]["content"]

    raise RuntimeError("未設定任何 LLM API Key（ANTHROPIC / GEMINI / OPENAI）")


def _trigger_meeting_notes_async(fpath: Path) -> None:
    """背景整理會議記錄，優先用 Anthropic API，失敗時 fallback 至 claude CLI。"""
    def run() -> None:
        try:
            time.sleep(1)
            logging.info("[MeetingNotes] 開始整理：%s", fpath.name)
            broadcast("status", {"msg": f"🤖 自動整理會議記錄：{fpath.name}…"})

            transcript = fpath.read_text(encoding="utf-8")
            system_prompt = _load_meeting_notes_prompt() or (
                "請將以下會議逐字稿整理成結構化會議記錄，包含摘要、決策記錄與行動事項。"
            )
            user_message = f"請整理以下會議逐字稿：\n\n{transcript}"

            result = _call_llm(system_prompt, user_message)
            logging.info("[MeetingNotes] 整理成功，輸出長度 %d", len(result))
            out_path = fpath.parent / fpath.name.replace(".md", "_會議記錄.md")
            out_path.write_text(result, encoding="utf-8")
            broadcast("status", {"msg": f"✅ 會議記錄已產生：{out_path.name}"})

        except Exception as e:
            logging.warning("[MeetingNotes] 異常：%s", e)
            broadcast("status", {"msg": f"❌ 會議記錄整理異常：{e}"})

    threading.Thread(target=run, daemon=False).start()


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

## 逐字稿

{text}
"""
        fpath.write_text(md, encoding="utf-8")
        logging.info("[Obsidian] 已存檔：%s", fpath)
        _trigger_meeting_notes_async(fpath)
        return str(fpath)
    except Exception as e:
        logging.warning("[Obsidian] 存檔失敗：%s", e)
        return ""
