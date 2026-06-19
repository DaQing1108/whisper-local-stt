"""unit/test_notion_blocks.py — build_notion_blocks() 格式與結構測試。"""
import pytest
from integrations import build_notion_blocks


def _get_block_types(blocks: list[dict]) -> list[str]:
    return [b["type"] for b in blocks]


class TestBlockStructure:
    def test_always_starts_with_divider(self):
        blocks = build_notion_blocks("測試文字", "zh")
        assert blocks[0]["type"] == "divider"

    def test_always_has_heading(self):
        blocks = build_notion_blocks("測試文字", "zh")
        types = _get_block_types(blocks)
        assert "heading_2" in types

    def test_always_has_callout(self):
        blocks = build_notion_blocks("測試文字", "zh")
        types = _get_block_types(blocks)
        assert "callout" in types

    def test_text_becomes_paragraphs(self):
        text = "第一行內容\n第二行內容\n第三行內容"
        blocks = build_notion_blocks(text, "zh")
        para_blocks = [b for b in blocks if b["type"] == "paragraph"]
        assert len(para_blocks) == 3

    def test_empty_lines_skipped(self):
        text = "第一行\n\n\n第二行"
        blocks = build_notion_blocks(text, "zh")
        para_blocks = [b for b in blocks if b["type"] == "paragraph"]
        assert len(para_blocks) == 2

    def test_single_line_text(self):
        blocks = build_notion_blocks("只有一行文字", "zh")
        para_blocks = [b for b in blocks if b["type"] == "paragraph"]
        assert len(para_blocks) == 1

    def test_empty_text_no_paragraphs(self):
        blocks = build_notion_blocks("", "zh")
        para_blocks = [b for b in blocks if b["type"] == "paragraph"]
        assert len(para_blocks) == 0

    def test_lang_in_callout(self):
        blocks = build_notion_blocks("文字", "en")
        callout = next(b for b in blocks if b["type"] == "callout")
        rich_text = callout["callout"]["rich_text"][0]["text"]["content"]
        assert "en" in rich_text

    def test_paragraph_content_preserved(self):
        text = "這是重要的會議內容，包含 AI 技術討論。"
        blocks = build_notion_blocks(text, "zh")
        para = next(b for b in blocks if b["type"] == "paragraph")
        content = para["paragraph"]["rich_text"][0]["text"]["content"]
        assert content == text

    def test_each_block_has_object_field(self):
        blocks = build_notion_blocks("測試", "zh")
        for b in blocks:
            assert b.get("object") == "block"

    def test_long_text_multiline(self):
        # 20 行文字 → 20 個 paragraph blocks
        lines = [f"這是第 {i} 行的會議記錄內容。" for i in range(1, 21)]
        text = "\n".join(lines)
        blocks = build_notion_blocks(text, "zh")
        para_blocks = [b for b in blocks if b["type"] == "paragraph"]
        assert len(para_blocks) == 20
