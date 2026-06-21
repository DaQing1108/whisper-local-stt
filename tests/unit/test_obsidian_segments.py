"""Tests for timestamped segment output in save_to_obsidian."""
import sys
import os
import re
import tempfile
from pathlib import Path

# make integrations importable without full app stack
sys.path.insert(0, str(Path(__file__).parent.parent.parent))


def _setup_obsidian_path(tmp_path: str):
    import integrations
    integrations._OBSIDIAN_PATH = tmp_path


def _call_save(text, lang="zh", meta=None):
    import integrations
    return integrations.save_to_obsidian(text, lang, meta)


def test_segments_format_timestamps(tmp_path):
    """AC-5: segments 時有 [MM:SS] 格式每行輸出。"""
    _setup_obsidian_path(str(tmp_path))
    segments = [
        {"text": "今天的主題是", "start": 12.5, "end": 15.0},
        {"text": "我們來看數據", "start": 75.0, "end": 78.0},
    ]
    fpath = _call_save("今天的主題是\n我們來看數據", "zh", {"segments": segments, "model": "small"})
    assert fpath
    content = Path(fpath).read_text()
    assert "[00:12] 今天的主題是" in content
    assert "[01:15] 我們來看數據" in content


def test_no_segments_falls_back_to_plain_text(tmp_path):
    """AC-6: 無 segments 時輸出純文字，不出現 [MM:SS]。"""
    _setup_obsidian_path(str(tmp_path))
    fpath = _call_save("這是純文字轉錄", "zh", {"model": "small"})
    assert fpath
    content = Path(fpath).read_text()
    assert "這是純文字轉錄" in content
    assert not re.search(r"\[\d{2}:\d{2}\]", content)


def test_empty_segments_list_falls_back(tmp_path):
    """AC-6 variant: segments=[] 也 fallback 純文字。"""
    _setup_obsidian_path(str(tmp_path))
    fpath = _call_save("空 segments 測試", "zh", {"segments": [], "model": "small"})
    assert fpath
    content = Path(fpath).read_text()
    assert "空 segments 測試" in content
    assert not re.search(r"\[\d{2}:\d{2}\]", content)


def test_segment_offset_in_output(tmp_path):
    """AC-2 proxy: start > 60 秒時分鐘正確。"""
    _setup_obsidian_path(str(tmp_path))
    segments = [{"text": "超過一分鐘", "start": 90.0, "end": 93.0}]
    fpath = _call_save("超過一分鐘", "zh", {"segments": segments})
    content = Path(fpath).read_text()
    assert "[01:30] 超過一分鐘" in content
