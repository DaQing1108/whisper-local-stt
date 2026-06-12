#!/usr/bin/env python3
"""
transcribe.py — Whisper 本地轉錄 + Notion 自動匯入
用法：
  python3 transcribe.py <音檔> [--model small] [--upload] [--page-id <id>]
"""

import argparse
import json
import os

# 確保 Homebrew ffmpeg 在 PATH 中（.app 或非互動式 shell 環境）
os.environ["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + os.environ.get("PATH", "")
import sys
from datetime import datetime
from pathlib import Path

from dotenv import load_dotenv

load_dotenv()


# ────────────────────────────────────────────────────────────────
# 1. 轉錄
# ────────────────────────────────────────────────────────────────

def transcribe(audio_path: str, model_name: str = "small", language: str = None) -> dict:
    """使用本地 Whisper 模型進行轉錄。"""
    try:
        import whisper
    except ImportError:
        sys.exit("❌ 找不到 openai-whisper，請先執行：pip install openai-whisper")

    print(f"⏳ 載入 Whisper 模型：{model_name}（首次需下載，約數分鐘）…")
    model = whisper.load_model(model_name)

    print(f"🎙️  開始轉錄：{audio_path}")
    options = {}
    if language:
        options["language"] = language

    result = model.transcribe(audio_path, **options)
    print(f"✅ 轉錄完成，偵測語言：{result.get('language', 'unknown')}")
    return result


# ────────────────────────────────────────────────────────────────
# 2. 格式化輸出
# ────────────────────────────────────────────────────────────────

def format_markdown(result: dict, audio_path: str) -> str:
    """將轉錄結果格式化為 Markdown（含段落時間戳記）。"""
    audio_name = Path(audio_path).name
    now = datetime.now().strftime("%Y-%m-%d %H:%M")
    detected_lang = result.get("language", "unknown")

    lines = [
        f"# 🎙️ 逐字稿｜{audio_name}",
        f"",
        f"**轉錄時間：** {now}  ",
        f"**偵測語言：** {detected_lang}  ",
        f"**音檔來源：** `{audio_name}`",
        f"",
        f"---",
        f"",
    ]

    segments = result.get("segments", [])
    if segments:
        for seg in segments:
            start = _fmt_time(seg["start"])
            end   = _fmt_time(seg["end"])
            text  = seg["text"].strip()
            lines.append(f"**[{start} → {end}]**  ")
            lines.append(f"{text}")
            lines.append("")
    else:
        # 無段落資訊時直接輸出全文
        lines.append(result.get("text", "").strip())

    return "\n".join(lines)


def _fmt_time(seconds: float) -> str:
    """把秒數轉成 MM:SS 格式。"""
    m, s = divmod(int(seconds), 60)
    return f"{m:02d}:{s:02d}"


def save_locally(markdown: str, audio_path: str) -> str:
    """把 Markdown 儲存到 outputs/ 目錄。"""
    out_dir = Path("outputs")
    out_dir.mkdir(exist_ok=True)
    stem = Path(audio_path).stem
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_file = out_dir / f"{stem}_{ts}.md"
    out_file.write_text(markdown, encoding="utf-8")
    print(f"💾 逐字稿已儲存：{out_file}")
    return str(out_file)


# ────────────────────────────────────────────────────────────────
# 3. Notion 上傳
# ────────────────────────────────────────────────────────────────

def upload_to_notion(markdown: str, audio_path: str, page_id: str) -> None:
    """
    將逐字稿以 blocks 方式附加到指定 Notion 頁面。
    使用 Notion Client SDK（比直接呼叫 requests 更穩定）。
    """
    try:
        from notion_client import Client
    except ImportError:
        sys.exit("❌ 找不到 notion-client，請先執行：pip install notion-client")

    token = os.getenv("NOTION_TOKEN")
    if not token:
        sys.exit(
            "❌ 缺少 NOTION_TOKEN。\n"
            "   請在 .env 或環境變數設定：NOTION_TOKEN=secret_xxxxx\n"
            "   在 Notion 建立 integration：https://www.notion.so/my-integrations"
        )

    notion = Client(auth=token)

    # 確認頁面可存取
    try:
        page = notion.pages.retrieve(page_id=page_id)
        title_prop = page.get("properties", {}).get("title", {})
        title_list = title_prop.get("title", [])
        page_title = title_list[0]["plain_text"] if title_list else page_id
        print(f"📓 目標 Notion 頁面：{page_title}")
    except Exception as e:
        sys.exit(f"❌ 無法存取 Notion 頁面 (ID: {page_id})\n   錯誤：{e}\n   請確認 page_id 正確，且 integration 已加入該頁面。")

    # 把 Markdown 轉為 Notion blocks
    blocks = _markdown_to_blocks(markdown, audio_path)

    # 分批上傳（Notion API 單次最多 100 個 block）
    batch_size = 100
    total = len(blocks)
    uploaded = 0
    for i in range(0, total, batch_size):
        batch = blocks[i : i + batch_size]
        notion.blocks.children.append(block_id=page_id, children=batch)
        uploaded += len(batch)
        print(f"   上傳進度：{uploaded}/{total} blocks")

    print(f"✅ 成功上傳至 Notion！共 {total} 個 blocks。")


def _markdown_to_blocks(markdown: str, audio_path: str) -> list:
    """
    將格式化後的 Markdown 字串轉換為 Notion block objects。
    這裡做輕量解析，足夠覆蓋本工具的輸出格式。
    """
    blocks = []
    audio_name = Path(audio_path).name
    now = datetime.now().strftime("%Y-%m-%d %H:%M")

    # 分隔線
    blocks.append({"object": "block", "type": "divider", "divider": {}})

    # 標題
    blocks.append(_heading(f"🎙️ 逐字稿｜{audio_name}", level=2))

    # 元資料（callout block）
    blocks.append({
        "object": "block",
        "type": "callout",
        "callout": {
            "rich_text": [_rich_text(f"轉錄時間：{now}  ｜  音檔：{audio_name}")],
            "icon": {"type": "emoji", "emoji": "🕐"},
            "color": "gray_background",
        },
    })

    # 逐行解析
    lines = markdown.split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]

        # 跳過標題行（已在上面處理）
        if line.startswith("# ") or line.startswith("**轉錄時間") or line.startswith("**偵測語言") or line.startswith("**音檔"):
            i += 1
            continue

        # 分隔線
        if line.strip() == "---":
            blocks.append({"object": "block", "type": "divider", "divider": {}})
            i += 1
            continue

        # 時間戳記行（粗體 [MM:SS → MM:SS]）
        if line.startswith("**[") and "→" in line:
            timestamp = line.replace("**", "").replace("  ", "").strip()
            # 下一行是內文
            content = ""
            if i + 1 < len(lines):
                content = lines[i + 1].strip()
                i += 1

            # 用 toggle block：標題=timestamp，內容=transcript text
            blocks.append({
                "object": "block",
                "type": "paragraph",
                "paragraph": {
                    "rich_text": [
                        _rich_text(f"{timestamp}  ", bold=True),
                        _rich_text(content),
                    ]
                },
            })
            i += 1
            continue

        # 空行 → 跳過
        if not line.strip():
            i += 1
            continue

        # 一般文字段落
        blocks.append({
            "object": "block",
            "type": "paragraph",
            "paragraph": {"rich_text": [_rich_text(line)]},
        })
        i += 1

    return blocks


def _heading(text: str, level: int = 2) -> dict:
    type_map = {1: "heading_1", 2: "heading_2", 3: "heading_3"}
    t = type_map.get(level, "heading_2")
    return {
        "object": "block",
        "type": t,
        t: {"rich_text": [_rich_text(text)]},
    }


def _rich_text(text: str, bold: bool = False) -> dict:
    obj: dict = {"type": "text", "text": {"content": text}}
    if bold:
        obj["annotations"] = {"bold": True}
    return obj


# ────────────────────────────────────────────────────────────────
# 4. CLI 入口
# ────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="本地 Whisper 轉錄，並可選擇上傳至 Notion"
    )
    parser.add_argument("audio", help="音檔路徑（.m4a / .mp3 / .wav / .flac …）")
    parser.add_argument(
        "--model",
        default="small",
        choices=["tiny", "base", "small", "medium", "large"],
        help="Whisper 模型大小（預設：small）",
    )
    parser.add_argument(
        "--language",
        default=None,
        help="強制指定語言代碼，例如 zh / en（不指定則自動偵測）",
    )
    parser.add_argument(
        "--upload",
        action="store_true",
        help="轉錄完成後自動上傳至 Notion",
    )
    parser.add_argument(
        "--page-id",
        default=None,
        help="目標 Notion 頁面 ID（優先於 .env 的 NOTION_PAGE_ID）",
    )
    parser.add_argument(
        "--no-save",
        action="store_true",
        help="不在本地儲存 .md 逐字稿",
    )
    args = parser.parse_args()

    # 確認音檔存在
    if not Path(args.audio).exists():
        sys.exit(f"❌ 找不到音檔：{args.audio}")

    # 轉錄
    result = transcribe(args.audio, model_name=args.model, language=args.language)

    # 格式化
    markdown = format_markdown(result, args.audio)

    # 本地儲存
    if not args.no_save:
        save_locally(markdown, args.audio)

    # Notion 上傳
    if args.upload:
        page_id = args.page_id or os.getenv("NOTION_PAGE_ID")
        if not page_id:
            sys.exit(
                "❌ 請指定 Notion 頁面 ID：\n"
                "   --page-id <id>  或在 .env 設定 NOTION_PAGE_ID=<id>"
            )
        upload_to_notion(markdown, args.audio, page_id)
    else:
        # 若不上傳，直接印出逐字稿
        print("\n" + "─" * 60)
        print(markdown)
        print("─" * 60)
        print("\n💡 提示：加上 --upload 即可自動上傳至 Notion")


if __name__ == "__main__":
    main()
