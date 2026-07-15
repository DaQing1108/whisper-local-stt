"""integrations.py — Obsidian 存檔與會議記錄自動整理。"""
from __future__ import annotations

import logging
import os
import re
import threading
from datetime import datetime
from pathlib import Path

_OBSIDIAN_PATH = os.environ.get("OBSIDIAN_MEETING_PATH", "")

_MEETING_NOTES_CMD = Path.home() / ".claude" / "commands" / "meeting-notes.md"

_APP_SUMMARY_SYSTEM_PROMPT = """你是 Whisper STT 內建的會議摘要助手。

你的唯一任務是根據既有逐字稿，直接產出可讀、可編輯、可存檔的會議摘要。

硬性規則：
- 不要反問使用者，不要提出澄清問題，不要要求補資料
- 不要寫「請提供」「請確認」「我需要更多資訊」這類句子
- 資訊不足時，直接用「未知」、「未提及」或「[待補]」標示
- 不要虛構與會者、日期、決策者、期限或數字
- 以逐字稿原文語言輸出；若逐字稿是中文，使用繁體中文
- 輸出內容要能直接顯示在 app 的 summary 分頁，也能直接存入 Obsidian

請用以下結構輸出：
## 摘要
用 2-4 句整理本次會議主題、結論與目前狀態。

## 決策
- 若有明確決策，列成 bullet
- 若沒有，寫「- 未提及明確決策」

## 行動事項
- 格式：`- [Owner 或 未知] 行動內容（Due: 日期或未提及）`
- 若沒有，寫「- 未提及明確行動事項」

## 待確認
- 只列逐字稿中明顯尚未定案、資訊不足或後續待補的點
- 若沒有，寫「- 無」
"""

_DESTINATION_SUMMARY_PROMPTS = {
    "obsidian": """你是 Obsidian 知識庫的會議整理助手。請只根據逐字稿產生適合長期知識沉澱的繁體中文筆記。
不要提問、不要虛構資訊；不確定處請標記「未提及」或「[待補]」。
請依序使用：## 核心摘要、## 決策與脈絡、## 可連結概念、## 待追蹤。""",
    "notion": """你是 Notion 專案協作的會議整理助手。請只根據逐字稿產生適合追蹤執行的繁體中文會議內容。
不要提問、不要虛構資訊；不確定處請標記「未提及」或「[待補]」。
請依序使用：## 執行摘要、## 決策、## 行動事項、## 風險與待確認；行動事項格式為 `- [Owner 或 未知] 事項（Due: 日期或未提及）`。""",
}


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


def build_summary_prompts(transcript: str) -> tuple[str, str]:
    """建立 app 內 canonical summary 專用 prompts。"""
    system_prompt = _APP_SUMMARY_SYSTEM_PROMPT
    user_message = (
        "請直接整理以下逐字稿為可發布的會議摘要。\n"
        "不要提問、不要要求補件、不要回覆成 assistant 對話。\n\n"
        f"逐字稿如下：\n{transcript}"
    )
    return system_prompt, user_message


_LLM_TIMEOUT = 60  # 每次 API 呼叫最長等待秒數

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
        with urllib.request.urlopen(req, timeout=_LLM_TIMEOUT) as resp:
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
                with urllib.request.urlopen(req, timeout=_LLM_TIMEOUT) as resp:
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


def _configured_llm_provider() -> str:
    anthropic_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
    gemini_key = os.environ.get("GEMINI_API_KEY", "").strip()
    openai_key = os.environ.get("OPENAI_API_KEY", "").strip()
    provider = "anthropic" if anthropic_key else "gemini" if gemini_key else "openai" if openai_key else ""
    if not provider:
        raise RuntimeError("未設定任何 LLM API Key（ANTHROPIC / GEMINI / OPENAI）")
    return provider


def build_meeting_summary(transcript: str) -> tuple[str, str]:
    """產生會議摘要，回傳 (provider, summary_text)。"""
    system_prompt, user_message = build_summary_prompts(transcript)
    provider = _configured_llm_provider()
    return provider, _call_llm(system_prompt, user_message)


def build_destination_summary(transcript: str, destination: str) -> tuple[str, str]:
    """以目的地專屬 prompt 從 transcript 生成衍生會議內容。"""
    system_prompt = _DESTINATION_SUMMARY_PROMPTS.get(destination)
    if not system_prompt:
        raise ValueError(f"不支援的摘要目的地：{destination}")
    if os.environ.get("WHISPER_TEST") == "1" and not any((
        os.environ.get("ANTHROPIC_API_KEY"),
        os.environ.get("GEMINI_API_KEY"),
        os.environ.get("OPENAI_API_KEY"),
    )):
        return "test", f"## {destination.title()} 測試摘要\n\n{transcript}"
    provider = _configured_llm_provider()
    user_message = f"請直接整理以下逐字稿，不要提問或要求補充。\n\n逐字稿如下：\n{transcript}"
    return provider, _call_llm(system_prompt, user_message)


def save_summary_to_obsidian(
    transcript_path: str,
    summary_text: str,
    suffix: str = "_會議記錄",
    meeting_id: str = "",
) -> str:
    """依既有 transcript 檔名規則寫出摘要檔。"""
    if not transcript_path or not summary_text.strip():
        return ""
    try:
        src = Path(transcript_path)
        out_path = src.parent / src.name.replace(".md", f"{suffix}.md")
        source_name = src.name
        md = summary_text
        if meeting_id:
            md = f"""---
meeting_id: \"{meeting_id}\"
source: whisper-destination-summary
derived_from: \"{source_name}\"
---

{summary_text}
"""
        out_path.write_text(md, encoding="utf-8")
        logging.info("[Obsidian] 已存摘要：%s", out_path)
        return str(out_path)
    except Exception as e:
        logging.warning("[Obsidian] 摘要存檔失敗：%s", e)
        return ""


def build_notion_blocks(text: str, lang: str, summary: str = "") -> list[dict]:
    """組裝確認後的會議記錄：AI 會議內容在前，逐字稿在後。"""
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    blocks: list[dict] = [
        {"object": "block", "type": "divider", "divider": {}},
        {"object": "block", "type": "heading_2",
         "heading_2": {"rich_text": [{"type": "text",
                                      "text": {"content": f"🎙️ 會議記錄｜{now}"}}]}},
        {"object": "block", "type": "callout",
         "callout": {
             "rich_text": [{"type": "text",
                            "text": {"content": f"偵測語言：{lang}  ｜  {now}"}}],
             "icon": {"type": "emoji", "emoji": "🎤"},
             "color": "purple_background",
         }},
    ]
    if summary.strip():
        blocks.append({"object": "block", "type": "heading_2",
                       "heading_2": {"rich_text": [{"type": "text", "text": {"content": "Notion AI 會議內容"}}]}})
        for line in summary.split("\n"):
            line = line.strip()
            if line:
                blocks.append({"object": "block", "type": "paragraph",
                               "paragraph": {"rich_text": [{"type": "text", "text": {"content": line}}]}})
        blocks.append({"object": "block", "type": "heading_2",
                       "heading_2": {"rich_text": [{"type": "text", "text": {"content": "逐字稿"}}]}})

    for line in text.split("\n"):
        line = line.strip()
        if line:
            blocks.append({"object": "block", "type": "paragraph",
                           "paragraph": {"rich_text": [{"type": "text",
                                                        "text": {"content": line}}]}})
    return blocks


def _existing_meeting_path(vault_dir: Path, existing_path: str) -> Path | None:
    if not existing_path:
        return None
    try:
        candidate = Path(existing_path).resolve()
        candidate.relative_to(vault_dir.resolve())
        return candidate
    except (OSError, ValueError):
        return None


def save_to_obsidian(
    text: str,
    lang: str,
    meta: dict | None = None,
    meeting_id: str = "",
    existing_path: str = "",
) -> str:
    """把確認後的逐字稿與 AI 會議內容存成單一 Obsidian .md 檔。"""
    obsidian_path = os.environ.get("OBSIDIAN_MEETING_PATH", "")
    if not obsidian_path or not text.strip():
        return ""
    try:
        vault_dir = Path(obsidian_path)
        vault_dir.mkdir(parents=True, exist_ok=True)

        now      = datetime.now()
        date_str = now.strftime("%Y-%m-%d")
        time_str = now.strftime("%H:%M")
        snippet  = re.sub(r'[\\/:*?"<>|\n]', '', text.strip()[:20]).strip()
        fname    = f"{date_str} {time_str} {snippet}.md" if snippet else f"{date_str} {time_str} 會議記錄.md"
        fpath = _existing_meeting_path(vault_dir, existing_path) or vault_dir / fname

        meta = meta or {}
        duration_sec = meta.get("duration_seconds", 0)
        duration_formatted = ""
        if duration_sec:
            m = int(duration_sec // 60)
            s = int(duration_sec % 60)
            duration_formatted = f"{m:02d}:{s:02d}"

        segments = meta.get("segments") or []
        if segments:
            from transcribe_common import clean_segments
            segments = clean_segments(segments)
            lines = []
            for seg in segments:
                t = int(seg.get("start", 0))
                ts = f"[{t // 60:02d}:{t % 60:02d}]"
                lines.append(f"{ts} {seg['text'].strip()}")
            transcript_body = "\n".join(lines)
        else:
            transcript_body = text

        md = f"""---
date: {date_str}
time: "{time_str}"
language: {lang}
source: whisper-local-stt
model: {meta.get("model", "unknown")}
domain: {meta.get("domain", "general")}
status: raw
meeting_id: "{meeting_id}"
extra_terms: "{meta.get("extra_terms", "")}"
duration: "{duration_formatted}"
tags:
  - meeting
  - transcript
---

# 會議逐字稿 {date_str} {time_str}

## 逐字稿

{transcript_body}
"""
        fpath.write_text(md, encoding="utf-8")
        logging.info("[Obsidian] 已存檔：%s", fpath)
        return str(fpath)
    except Exception as e:
        logging.warning("[Obsidian] 存檔失敗：%s", e)
        return ""
