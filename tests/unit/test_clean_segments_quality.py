"""unit/test_clean_segments_quality.py — clean_segments 新增的四條幻聽規則。

1. 短句連續重複（1–3 字、連續 ≥5 次）→ 保留第一個
2. 句內循環（1–8 字片語以分隔符連續重複 ≥4 次）→ 壓成一次
3. 中文數字清單（≥10 個以「、」或逗號分隔的單一數字）→ 丟棄
4. 外文字元污染（僅 zh）：佔比 ≥10% 或短句含外文 → 丟棄；否則只移除外文字元
每條都有觸發與不誤刪的測試。所有句子皆為合成資料。
"""
from __future__ import annotations

import logging

from transcribe_common import clean_segments


def _segments(*texts):
    return [{"start": float(index), "end": float(index) + 1, "text": text} for index, text in enumerate(texts)]


def _texts(segments):
    return [segment["text"] for segment in segments]


class TestShortConsecutiveRepeats:
    def test_five_or_more_short_repeats_keep_first(self):
        result = clean_segments(_segments(*(["謝謝"] * 18 + ["OK"] * 5 + ["好的我們繼續"])))
        assert _texts(result) == ["謝謝", "OK", "好的我們繼續"]

    def test_short_repeats_below_five_are_kept(self):
        texts = ["對啊"] * 4 + ["OK"] * 2 + ["對對"]
        assert _texts(clean_segments(_segments(*texts))) == texts

    def test_existing_long_repeat_rule_unchanged(self):
        result = clean_segments(_segments(*(["這是同一句重複的話"] * 3)))
        assert _texts(result) == ["這是同一句重複的話"]


class TestInSegmentLoop:
    def test_loops_are_compressed_keeping_surrounding_text(self):
        result = clean_segments(_segments(
            "對呀,對呀,對呀,對呀,對呀,我們繼續",
            "那個,那個,那個,那個,那個,那個 就是說",
            "RD,RD,RD,RD",
            "測試流程，測試流程，測試流程，測試流程。",
        ))
        assert _texts(result) == ["對呀,我們繼續", "那個 就是說", "RD", "測試流程。"]

    def test_genuine_short_repetition_is_kept(self):
        texts = [
            "對對", "OK OK", "好的,好的,好的", "這個 這個 我想一下", "是是是是",
            "IP 設成 1.1.1.1 就好", "預設是 0.0.0.0", "版本 10.0.0.0.0", "分數是 1,1,1,1",
        ]
        assert _texts(clean_segments(_segments(*texts))) == texts

    def test_input_segments_are_not_mutated(self):
        segments = _segments("對呀,對呀,對呀,對呀")
        result = clean_segments(segments)
        assert segments[0]["text"] == "對呀,對呀,對呀,對呀"
        assert result[0] == {"start": 0.0, "end": 1.0, "text": "對呀"}


class TestChineseNumeralList:
    def test_long_numeral_list_is_dropped(self):
        result = clean_segments(_segments("一、四、二、五、四、四、五、九、一、三、七", "這句保留"))
        assert _texts(result) == ["這句保留"]

    def test_comma_separated_list_is_dropped(self):
        assert clean_segments(_segments("三,一,四,一,五,九,二,六,五,三")) == []

    def test_short_enumeration_is_kept(self):
        texts = ["第一點、二、三都要做", "一、二、三", "我們有九個選項：一、二、三、四、五、六、七、八、九"]
        assert _texts(clean_segments(_segments(*texts))) == texts


class TestForeignScript:
    def test_heavily_polluted_or_short_segments_are_dropped(self):
        result = clean_segments(_segments(
            "ネタ",
            "Итак,選由 Vocês預見 minds",
            "我們 있으니까",
            "我們要ря",
            "如果可以加速�나呢",
            "這句正常保留",
        ), language="zh")
        assert _texts(result) == ["這句正常保留"]

    def test_single_stray_kana_in_long_sentence_is_removed(self):
        result = clean_segments(_segments(
            "我們今天要討論的是下一季的產品規劃還有預算分配的問題です",
        ), language="zh")
        assert _texts(result) == ["我們今天要討論的是下一季的產品規劃還有預算分配的問題"]

    def test_stray_char_removal_leaves_no_double_spaces(self):
        result = clean_segments(_segments(
            "下一季的產品規劃 ネ 還有預算分配要先確認再說後面的事情好嗎",
        ), language="zh-TW")
        assert _texts(result) == ["下一季的產品規劃 還有預算分配要先確認再說後面的事情好嗎"]

    def test_katakana_middle_dot_and_long_vowel_mark_are_not_foreign(self):
        texts = ["張三・李四的簡報要先看一下", "大家好我們開始吧ー"]
        assert _texts(clean_segments(_segments(*texts), language="zh")) == texts

    def test_ascii_english_terms_untouched(self):
        texts = ["把 Feature 對到 KR 下面", "OK", "這個 API 的 timeout 要調"]
        assert _texts(clean_segments(_segments(*texts), language="zh")) == texts

    def test_rule_only_applies_to_zh(self):
        texts = ["ありがとうございます", "Итак"]
        assert _texts(clean_segments(_segments(*texts))) == texts              # 不帶語言：向下相容
        assert _texts(clean_segments(_segments(*texts), language="ja")) == texts
        assert _texts(clean_segments(_segments(*texts), language=None)) == texts


class TestLogging:
    def test_new_rules_log_counts_without_content(self, caplog):
        with caplog.at_level(logging.WARNING):
            clean_segments(_segments(
                *(["謝謝"] * 6),
                "對呀,對呀,對呀,對呀",
                "一、四、二、五、四、四、五、九、一、三",
                "ネタ",
            ), language="zh")
        assert "[CleanSegments]" in caplog.text
        assert "short-repeat" in caplog.text and "numeral-list" in caplog.text
        assert "foreign-script" in caplog.text and "in-segment-loop" in caplog.text
        for content in ("謝謝", "對呀", "一、四", "ネタ"):
            assert content not in caplog.text


class TestWorkerPathPassesLanguage:
    def test_frozen_worker_path_applies_foreign_rule_for_zh(self, monkeypatch):
        import sys

        import whisper_core

        monkeypatch.setattr(sys, "frozen", True, raising=False)
        monkeypatch.setattr(whisper_core, "_transcribe_frozen_worker_subprocess", lambda *_args: {
            "language": "zh",
            "segments": [
                {"start": 0.0, "end": 1.0, "text": "ネタ"},
                {"start": 1.0, "end": 2.0, "text": "這句保留下來"},
            ],
        })

        result = whisper_core._transcribe_file("/tmp/a.wav", "base", {"language": "zh"})

        assert [segment["text"] for segment in result["segments"]] == ["這句保留下來"]
