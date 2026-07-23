"""unit/test_whisper_core_segments_traditional.py — segment 層級簡轉繁測試。

run_whisper() 過去只轉換合併後的 full_text，沒轉換 info["segments"] 裡每條的
text，導致即時轉錄畫面（用 segments 組出來的）忽簡忽繁。這裡測 _segments_to_traditional()
本身的行為，確保回歸不會再發生。
"""
from whisper_core import _segments_to_traditional, _to_traditional


class TestSegmentsToTraditional:
    def test_converts_simplified_text_in_each_segment(self):
        segments = [
            {"start": 0.0, "end": 2.0, "text": "所以其实我们在讨论的题目叫做"},
            {"start": 2.0, "end": 4.0, "text": "那今天在现场呢"},
        ]
        result = _segments_to_traditional(segments)
        assert result[0]["text"] == _to_traditional("所以其实我们在讨论的题目叫做")
        assert result[1]["text"] == _to_traditional("那今天在现场呢")
        # 繁體轉換確實發生了（不是原封不動的簡體）
        assert result[0]["text"] != segments[0]["text"]

    def test_preserves_start_end_and_other_keys(self):
        segments = [{"start": 1.5, "end": 3.5, "text": "现场"}]
        result = _segments_to_traditional(segments)
        assert result[0]["start"] == 1.5
        assert result[0]["end"] == 3.5

    def test_already_traditional_text_passes_through_unchanged(self):
        segments = [{"start": 0.0, "end": 1.0, "text": "現場"}]
        result = _segments_to_traditional(segments)
        assert result[0]["text"] == "現場"

    def test_empty_segments_list_returns_empty_list(self):
        assert _segments_to_traditional([]) == []

    def test_does_not_mutate_input_segments(self):
        original = [{"start": 0.0, "end": 1.0, "text": "现场"}]
        _segments_to_traditional(original)
        assert original[0]["text"] == "现场"
