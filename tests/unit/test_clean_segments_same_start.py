"""unit/test_clean_segments_same_start.py — 同起始時間群組內的近似重複句過濾。

群組：起始時間（0.01 秒）相同且 ≥4 段；只丟與群組內前面保留段「近似」的段
（去標點空白後 SequenceMatcher ratio ≥ 0.6，或較短者 ≥2 字被較長者包含），其他全保留。
所有句子皆為合成資料。
"""
from __future__ import annotations

import logging

from transcribe_common import _is_near_duplicate, clean_segments


def _same_start(start, *texts):
    return [{"start": start, "end": start, "text": t} for t in texts]


def _texts(segments):
    return [s["text"] for s in segments]


class TestNearDuplicate:
    def test_variant_endings_are_near(self):
        assert _is_near_duplicate("我會買這台", "我會買的")

    def test_containment_is_near(self):
        assert _is_near_duplicate("我會買這台", "沒事,我會買這台")
        assert _is_near_duplicate("沒事，我會買這台。", "我會買這台")

    def test_unrelated_short_phrases_are_not_near(self):
        assert not _is_near_duplicate("比如說", "弄一份")
        assert not _is_near_duplicate("在那個階段", "請大家準備")

    def test_single_character_is_not_judged_by_containment(self):
        assert not _is_near_duplicate("買", "我會買這台")
        assert not _is_near_duplicate("", "我會買這台")


class TestSameStartGroups:
    def test_hallucinated_variant_burst_keeps_only_distinct_content(self):   # AC-2：19 段
        variants = [
            "我會買的", "我會買您的", "我會買人", "我不會買的", "沒事,我會買這台", "我會買這台嗎", "我會買",
            "我會買的啦", "嗯我會買的", "我會買那台", "我會買這個", "我會買你的", "我會買台", "你會買這台",
            "我會買給你", "我會買這台的",
        ]
        group = _same_start(3846.0, "我會買這台", *variants[:8], "下午三點開會", *variants[8:], "記得帶筆電")
        assert len(group) == 19

        result = clean_segments(group + [{"start": 3850.0, "end": 3852.0, "text": "我會買的"}])

        assert _texts(result) == ["我會買這台", "下午三點開會", "記得帶筆電", "我會買的"]  # 群組外不受影響

    def test_real_speech_squeezed_on_one_timecode_is_kept(self):            # AC-3：7 段
        group = _same_start(2304.0, "我們可以先看的", "比如說", "弄一份", "在那個階段", "拆封", "比如說吧", "請大家準備")

        assert _texts(clean_segments(group)) == ["我們可以先看的", "比如說", "弄一份", "在那個階段", "拆封", "請大家準備"]

    def test_start_times_match_to_one_hundredth(self):
        group = [
            {"start": 100.001, "end": 100.001, "text": "我會買這台"},
            {"start": 100.004, "end": 100.004, "text": "我會買的"},
            {"start": 99.996, "end": 99.996, "text": "我會買您的"},
            {"start": 100.0, "end": 100.0, "text": "下午三點開會"},
        ]
        assert _texts(clean_segments(group)) == ["我會買這台", "下午三點開會"]

    def test_small_groups_and_different_starts_are_untouched(self):           # AC-4
        three = _same_start(10.0, "我會買這台", "我會買的", "我會買您的")
        assert _texts(clean_segments(three)) == ["我會買這台", "我會買的", "我會買您的"]
        consecutive = [{"start": 20.0 + i, "end": 21.0 + i, "text": t}
                       for i, t in enumerate(["我會買這台", "我會買的", "我會買您的", "我會買人", "我會買那台"])]
        assert _texts(clean_segments(consecutive)) == ["我會買這台", "我會買的", "我會買您的", "我會買人", "我會買那台"]

    def test_log_counts_without_content(self, caplog):
        with caplog.at_level(logging.WARNING):
            clean_segments(_same_start(5.0, "我會買這台", "我會買的", "我會買您的", "下午三點開會"))
        assert "same-start near-duplicate rule dropped 2 segment(s)" in caplog.text
        assert "我會買" not in caplog.text
