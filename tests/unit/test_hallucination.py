"""unit/test_hallucination.py — is_hallucination() 邊界條件測試。"""
import pytest
from transcribe_common import is_hallucination


class TestNormalText:
    def test_normal_chinese(self):
        text = "今天的會議主要討論產品路線圖，以及第三季的目標與指標。"
        assert not is_hallucination(text)

    def test_normal_mixed(self):
        text = "我們可以看到 AI 技術的快速發展，尤其在語音辨識領域有很大的突破。"
        assert not is_hallucination(text)

    def test_short_text_always_passes(self):
        # 少於 20 字直接放行
        assert not is_hallucination("好")
        assert not is_hallucination("謝謝")
        assert not is_hallucination("")

    def test_empty_string(self):
        assert not is_hallucination("")

    def test_multiline_normal(self):
        text = "第一點：提升產品品質\n第二點：降低成本\n第三點：擴大市場"
        assert not is_hallucination(text)


class TestWordRepetition:
    def test_high_repetition_rejected(self):
        # 單詞重複 20 次，佔比 > 60%
        text = "我們 " * 20
        assert is_hallucination(text)

    def test_borderline_repetition_passes(self):
        # 重複 5 次，低於閾值
        text = "我們可以 我們可以 我們可以 我們可以 我們可以 討論其他議題"
        assert not is_hallucination(text)

    def test_single_char_repeated(self):
        # 需要夠長讓片語偵測觸發（"銀銀銀銀" × 12+ 次）
        text = "銀" * 60
        assert is_hallucination(text)

    def test_exactly_at_threshold(self):
        # 重複 16 次且佔比 > 0.6 → 應該被拒
        word = "你好"
        text = (word + " ") * 16
        assert is_hallucination(text)


class TestPhraseRepetition:
    def test_phrase_repeat_rejected(self):
        # 短片語重複超過 10 次且佔 60% 以上
        phrase = "我們可以看到"
        text = phrase * 15
        assert is_hallucination(text)

    def test_log_output_from_real_case(self):
        # 從真實 log 取得的案例：'銀銀銀銀' repeats 27 times
        text = "銀銀銀銀" * 27
        assert is_hallucination(text)

    def test_slight_variation_passes(self):
        # 有變化的正常重複（如列點）不應被判為幻覺
        text = "\n".join([f"第{i}點：這是一個重要議題，需要深入討論。" for i in range(1, 8)])
        assert not is_hallucination(text)
