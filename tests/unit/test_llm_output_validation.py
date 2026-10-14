"""unit/test_llm_output_validation.py — 語意校對輸出驗證（is_plausible_punctuation）。

LLM 偶爾回覆拒答或說明文字而不是「原文加標點」，這些內容不得進入逐字稿。
三條驗證：後設回覆樣式、長度比 0.7–1.3、行數差 ≤ 20%；不通過的段落退回原文。
所有句子皆為合成資料。
"""
from __future__ import annotations

import logging
from unittest.mock import patch

import pytest

import llm_post
from llm_post import _llm_punctuate_inner, is_plausible_punctuation, llm_punctuate

_REFUSAL = "我無法處理這個輸入，因為它只包含重複的符號。請提供真實的 ASR 語音辨識原始輸出文字，我會按照指示處理。"


class TestMetaReply:
    def test_refusal_is_rejected(self):
        assert is_plausible_punctuation("哈哈哈哈哈哈哈哈哈哈哈哈", _REFUSAL) == (False, "meta_reply")

    @pytest.mark.parametrize("marker", ["I cannot", "i can't", "As an AI", "Please provide", "作為一個"])
    def test_each_marker_is_detected_case_insensitively(self, marker):
        original = "今天我們討論下一季的排程安排"
        assert is_plausible_punctuation(original, f"{marker} 今天我們討論下一季的排程")[1] == "meta_reply"

    def test_marker_present_in_original_is_not_flagged(self):
        original = "這次的 ASR 模型要換掉 下週再測一次"
        output = "這次的 ASR 模型要換掉，下週再測一次。"
        assert is_plausible_punctuation(original, output) == (True, "ok")

    def test_normal_punctuation_passes(self):
        original = "我們先看一下進度 然後再討論預算的部分"
        output = "我們先看一下進度，然後再討論預算的部分。"
        assert is_plausible_punctuation(original, output) == (True, "ok")


class TestLengthRatio:
    def test_too_short_output_rejected(self):
        original = "這一段原本有很多內容需要保留下來不能被刪掉"
        assert is_plausible_punctuation(original, "這一段原本有很多內容。")[1] == "length_ratio"

    def test_too_long_output_rejected(self):
        original = "我們下週開會"
        assert is_plausible_punctuation(original, "我們下週開會，並且會討論很多額外的事項。")[1] == "length_ratio"

    def test_simplified_to_traditional_keeps_ratio(self):
        assert is_plausible_punctuation("这个信息需要打印出来", "這個資訊需要列印出來。")[0]

    def test_ratio_boundaries_are_inclusive(self):
        original = "一二三四五六七八九十"
        assert is_plausible_punctuation(original, "一二三四五六七")[0]              # 0.7
        assert not is_plausible_punctuation(original, "一二三四五六")[0]            # 0.6
        assert is_plausible_punctuation(original, original + "一二三")[0]           # 1.3
        assert not is_plausible_punctuation(original, original + "一二三四")[0]     # 1.4


class TestLineCount:
    _ORIGINAL = "\n".join(f"第{index}段的發言內容" for index in range(10))

    def test_line_count_within_twenty_percent_passes(self):
        output = "\n".join(f"第{index}段的發言內容。" for index in range(10))
        assert is_plausible_punctuation(self._ORIGINAL, output) == (True, "ok")

    def test_merged_lines_rejected(self):
        lines = [f"第{index}段的發言內容" for index in range(10)]
        output = "\n".join(["，".join(lines[:5])] + lines[5:])   # 10 行 → 6 行
        assert is_plausible_punctuation(self._ORIGINAL, output) == (False, "line_count")

    def test_short_original_skips_line_check(self):
        assert is_plausible_punctuation("第一句話說完了\n第二句話也說完", "第一句話說完了，第二句話也說完。")[0]


class TestCustomPrompt:
    def test_custom_prompt_skips_length_and_line_checks_but_not_meta_reply(self, monkeypatch):
        original = "嗯那個我們就是說下週要開會然後那個討論預算"
        condensed = "我們下週開會討論預算。"
        assert is_plausible_punctuation(original, condensed)[1] == "length_ratio"
        assert is_plausible_punctuation(original, condensed, check_structure=False) == (True, "ok")
        assert is_plausible_punctuation(original, _REFUSAL, check_structure=False) == (False, "meta_reply")

        monkeypatch.setenv("LLM_CUSTOM_PROMPT", "請刪除贅字")
        with patch.object(llm_post, "_llm_call_chunk", return_value=condensed):
            assert _llm_punctuate_inner(original, "", "claude", "key") == condensed

    def test_empty_original_accepts_only_empty_output(self):
        assert is_plausible_punctuation("  \n ", "") == (True, "ok")
        assert is_plausible_punctuation("。", "多出來的字")[1] == "length_ratio"


class TestPunctuateFallsBackPerChunk:
    def test_only_failing_chunk_reverts_to_original(self, caplog):
        # 每行 25 字 × 60 行 = 1500 字，剛好落在 MAX_CHARS 的分段邊界：甲、乙各成一段
        first = "\n".join(f"甲段落第{index:02d}行的合成內容需要加上標點符號這是填充字" for index in range(60))
        second = "\n".join(f"乙段落第{index:02d}行的合成內容需要加上標點符號這是填充字" for index in range(60))
        assert all(len(line) == 25 for line in first.split("\n"))
        text = f"{first}\n{second}"

        def fake_call(chunk, provider, api_key, extra_terms=""):
            if chunk.startswith("甲"):
                return "\n".join(line + "。" for line in chunk.split("\n"))
            return _REFUSAL

        with patch.object(llm_post, "_llm_call_chunk", side_effect=fake_call), \
                caplog.at_level(logging.WARNING):
            result = _llm_punctuate_inner(text, "", "claude", "key")

        result_lines = result.split("\n")
        assert all(line.endswith("。") for line in result_lines if line.startswith("甲"))
        assert [line for line in result_lines if line.startswith("乙")] == second.split("\n")
        assert _REFUSAL not in result
        assert "meta_reply=1" in caplog.text
        assert "甲段落" not in caplog.text and "乙段落" not in caplog.text
        assert "無法處理" not in caplog.text

    def test_llm_punctuate_returns_original_for_refusal(self, monkeypatch, caplog):
        monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-api03-" + "q" * 40)
        original = "哈哈哈哈哈哈哈哈哈哈哈哈哈哈哈"
        with patch.object(llm_post, "_llm_call_chunk", return_value=_REFUSAL), \
                caplog.at_level(logging.INFO):
            assert llm_punctuate(original) == original
        assert original not in caplog.text
        assert "請提供" not in caplog.text
