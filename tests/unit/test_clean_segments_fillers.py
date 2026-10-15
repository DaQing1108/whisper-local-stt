"""unit/test_clean_segments_fillers.py — zh 逐字稿丟棄「整段只有英文語助詞」的幻聽 segment。

整段去標點與空白後、不分大小寫完全等於 mm／mmm／mmmm／hmm／hm／mhm／uh／um／uhhuh（uh-huh）才丟；
句中含有語助詞的正常句子保留；語言非 zh 時不套用。所有句子皆為合成資料。
"""
from __future__ import annotations

import logging

import pytest

from transcribe_common import clean_segments


def _segments(*texts):
    return [{"start": float(i), "end": float(i) + 1, "text": t} for i, t in enumerate(texts)]


def _texts(segments):
    return [s["text"] for s in segments]


@pytest.mark.parametrize("filler", [
    "mm", "Mmm.", "MMMM", "hmm", "Hmm...", "hm", "mhm", "Uh", "um.", " Um ", "uh-huh", "Uh-huh.", "UH HUH",
])
def test_filler_only_segment_is_dropped_for_zh(filler):
    assert _texts(clean_segments(_segments(filler, "這句保留"), language="zh")) == ["這句保留"]


def test_sentences_containing_fillers_are_kept():
    texts = ["Um, 我們先開始", "OK", "Hmm 這個要再想", "uh 好", "mmm 對"]
    assert _texts(clean_segments(_segments(*texts), language="zh")) == texts


def test_not_applied_outside_zh():
    texts = ["hmm", "uh-huh", "這句"]
    assert _texts(clean_segments(_segments(*texts), language="en")) == texts
    assert _texts(clean_segments(_segments(*texts))) == texts


def test_log_counts_without_content(caplog):
    with caplog.at_level(logging.WARNING):
        clean_segments(_segments("hmm", "uh-huh", "正常"), language="zh")
    assert "english-filler dropped rule: 2 segment(s)" in caplog.text
    assert "hmm" not in caplog.text and "uh-huh" not in caplog.text
