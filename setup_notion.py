#!/usr/bin/env python3
"""
setup_notion.py — 互動式引導，幫你完成 Notion integration 設定。
執行：python3 setup_notion.py
"""

import os
import sys
from pathlib import Path


def main():
    print("=" * 60)
    print("  Whisper → Notion 設定精靈")
    print("=" * 60)
    print()
    print("步驟 1：建立 Notion Integration")
    print("-" * 40)
    print("1. 開啟 https://www.notion.so/my-integrations")
    print("2. 點「+ New integration」")
    print("3. 名稱填「Whisper Transcriber」")
    print("4. 選擇你的 workspace")
    print("5. Capabilities：勾選 Read content + Insert content + Update content")
    print("6. 儲存後複製 Internal Integration Secret (secret_xxx...)")
    print()

    token = input("請貼上你的 Notion Token：").strip()
    if not token.startswith("secret_") and not token.startswith("ntn_"):
        print("⚠️  Token 格式看起來不對（應該以 secret_ 或 ntn_ 開頭），請確認後重試。")

    print()
    print("步驟 2：取得目標頁面 ID")
    print("-" * 40)
    print("1. 在 Notion 開啟你要寫入的頁面（例如「2026會議紀錄」）")
    print("2. 頁面 URL 格式：")
    print("   https://www.notion.so/Your-Page-Title-<PAGE_ID>")
    print("   PAGE_ID 是最後那串 32 位英數字（可含 dash）")
    print("3. 重要：在頁面右上角「…」→「Connections」→ 加入「Whisper Transcriber」")
    print()

    page_id = input("請貼上目標頁面 ID：").strip()
    # 移除常見格式問題
    page_id = page_id.split("?")[0].split("#")[0].strip("/").split("/")[-1]
    # 如果包含頁面名稱（用-連結的），取最後32個字元
    if "-" in page_id:
        page_id = page_id.split("-")[-1]

    # 寫入 .env
    env_path = Path(".env")
    env_content = f"NOTION_TOKEN={token}\nNOTION_PAGE_ID={page_id}\n"
    env_path.write_text(env_content)
    print()
    print(f"✅ 設定完成！已寫入 .env")
    print()

    # 驗證連線
    print("正在驗證 Notion 連線…")
    try:
        from notion_client import Client
        notion = Client(auth=token)
        page = notion.pages.retrieve(page_id=page_id)
        props = page.get("properties", {})
        title_prop = props.get("title", props.get("Name", {}))
        title_list = title_prop.get("title", [])
        page_title = title_list[0]["plain_text"] if title_list else page_id
        print(f"✅ 連線成功！目標頁面：{page_title}")
        print()
        print("你現在可以用以下指令轉錄並上傳：")
        print(f"  python3 transcribe.py <音檔.m4a> --upload")
    except Exception as e:
        print(f"❌ 連線失敗：{e}")
        print("   請確認：")
        print("   1. Token 正確")
        print("   2. 頁面 ID 正確")
        print("   3. Integration 已加入該頁面（Connections）")


if __name__ == "__main__":
    main()
