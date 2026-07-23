"""unit/test_hallucination.py — is_hallucination() + clean_segments() 測試。"""
import pytest
from transcribe_common import is_hallucination, clean_segments


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


class TestDigitBearingRepeatAnywhere:
    """含數字的短片語重複，不限文字開頭位置（v2.4 新增）。"""

    def test_real_case_numeric_counting_loop_rejected(self):
        """真實案例：Whisper 卡在數字計數迴圈，重複片段不在文字開頭"""
        text = "3個,1個,1個,1個,1個,1個,1個。"
        assert is_hallucination(text)

    def test_repeated_meaningful_phrase_without_digit_passes(self):
        """規則 5 的既有邊界案例：無數字的片語重複 5 次不應被新規則誤傷"""
        text = "我們可以 我們可以 我們可以 我們可以 我們可以 討論其他議題"
        assert not is_hallucination(text)

    def test_phone_number_digit_run_passes(self):
        """電話號碼裡的連續重複數字（如 1111）不應被誤判"""
        text = "他的電話是0912345678，市話是0233221111，記得打給他。"
        assert not is_hallucination(text)

    def test_normal_text_with_incrementing_numbers_passes(self):
        """遞增編號列點（第1點、第2點...）不應被誤判"""
        text = "第1點跟第2點都要處理，第1點是預算，第2點是排程，我們先討論第1點。"
        assert not is_hallucination(text)


class TestTimestampOnlyPhantom:
    """mlx-whisper 在近靜音段落產生的 timestamp-only phantom 偵測。"""

    def test_repeated_timestamps_rejected(self):
        # 真實案例：[00:32] × 33
        text = "[00:32] " * 10
        assert is_hallucination(text)

    def test_single_timestamp_hms_rejected(self):
        # 單一 HH:MM:SS 格式，超過 20 字
        text = "[00:01.234] [00:02.345] [00:03.456]"
        assert is_hallucination(text)

    def test_timestamp_in_normal_sentence_passes(self):
        # 時間戳出現在正常句子中 → 不應判幻覺
        assert not is_hallucination("討論在 [01:23] 時開始，結論如下：需要進一步評估。")

    def test_normal_text_with_numbers_passes(self):
        # 含數字但非純 timestamp 的正常文字
        assert not is_hallucination("第一季 Q1 2026 目標：完成三個核心功能模組的開發。")


class TestCharacterLevelRepetition:
    """中文 character-level 重複偵測（v2.3 新增）。"""

    def test_single_cjk_char_repeated_200_times(self):
        """真實案例：「好」× 200+，is_hallucination 用 split() 完全漏掉"""
        text = "好" * 200
        assert is_hallucination(text)

    def test_cjk_char_with_foreign_prefix(self):
        """真實案例：「цо好好好好好...」Cyrillic 開頭 + CJK 重複"""
        text = "цо" + "好" * 200
        assert is_hallucination(text)

    def test_mixed_cjk_normal_passes(self):
        """正常中文句子不應被誤判"""
        text = "今天早上有跟凱鈞確認說他那個API有沒有辦法直到某個狀態"
        assert not is_hallucination(text)

    def test_repeated_short_cjk_word(self):
        """雙字重複 — e.g. 「美美美美美美...」"""
        text = "美美" * 50
        assert is_hallucination(text)


class TestForeignScriptContamination:
    """非目標語系字元污染偵測（v2.3 新增）。"""

    def test_cyrillic_dominant_rejected(self):
        """Cyrillic 佔 50% 以上"""
        text = "цо" * 30 + "好" * 10
        assert is_hallucination(text)

    def test_normal_chinese_english_mix_passes(self):
        """正常中英混合"""
        text = "我們使用 Whisper large-v3 模型進行語音辨識，效果很好。"
        assert not is_hallucination(text)

    def test_normal_text_with_rare_english_passes(self):
        """含英文術語但非 foreign script"""
        text = "今天要出3.5.2a，我這邊有一個BUG要區域Pick從3.5.3b。"
        assert not is_hallucination(text)


class TestCleanSegments:
    """clean_segments() segment 層級後處理（v2.3 新增）。"""

    def test_empty_segments_removed(self):
        """空白 text 的 segments 被移除"""
        segments = [
            {"text": "", "start": 0.0, "end": 1.0},
            {"text": " ", "start": 1.0, "end": 2.0},
            {"text": "正常內容", "start": 2.0, "end": 5.0},
        ]
        result = clean_segments(segments)
        assert len(result) == 1
        assert result[0]["text"] == "正常內容"

    def test_duplicate_timestamp_deduped(self):
        """相同 start + 相同 text 的 segments 去重"""
        segments = [
            {"text": "", "start": 213.0, "end": 213.0},
            {"text": "", "start": 213.0, "end": 213.0},
            {"text": "", "start": 213.0, "end": 213.0},
            {"text": "正常內容", "start": 215.0, "end": 220.0},
        ]
        result = clean_segments(segments)
        assert len(result) == 1
        assert result[0]["text"] == "正常內容"

    def test_normal_segments_preserved(self):
        """正常 segments 不變"""
        segments = [
            {"text": "大家集我們開心吧", "start": 15.0, "end": 19.0},
            {"text": "我今天在優化使用者看到代審清單的流程", "start": 19.0, "end": 23.0},
            {"text": "然後早上有跟凱鈞確認說", "start": 23.0, "end": 26.0},
        ]
        result = clean_segments(segments)
        assert len(result) == 3

    def test_hallucination_segment_removed(self):
        """含 hallucination 的 segment 被移除"""
        segments = [
            {"text": "正常開頭", "start": 0.0, "end": 5.0},
            {"text": "好" * 200, "start": 30.0, "end": 45.0},
            {"text": "正常結尾", "start": 45.0, "end": 50.0},
        ]
        result = clean_segments(segments)
        assert len(result) == 2
        assert result[0]["text"] == "正常開頭"
        assert result[1]["text"] == "正常結尾"

    def test_real_world_phantom_batch(self):
        """模擬真實案例：[03:33] 空白行 × 50"""
        segments = [
            {"text": "正常內容", "start": 200.0, "end": 210.0},
        ] + [
            {"text": "", "start": 213.0, "end": 213.0}
            for _ in range(50)
        ] + [
            {"text": "如果有段序的話，就跟我講一下。", "start": 225.0, "end": 228.0},
        ]
        result = clean_segments(segments)
        assert len(result) == 2
        assert result[0]["text"] == "正常內容"
        assert result[1]["text"] == "如果有段序的話，就跟我講一下。"
