"""unit/test_llm_post.py — LLM 後處理邏輯：key 驗證、timeout、meta-response 防護。"""
from __future__ import annotations

import time
from unittest.mock import MagicMock, patch

import pytest
from llm_post import _is_valid_key, has_llm_key, llm_punctuate, _LLM_TOTAL_TIMEOUT


class TestIsValidKey:
    def test_valid_claude_key(self):
        assert _is_valid_key("claude", "sk-ant-api03-" + "a" * 40)

    def test_valid_gemini_key(self):
        assert _is_valid_key("gemini", "AIzaSy" + "a" * 30)

    def test_valid_openai_key(self):
        assert _is_valid_key("openai", "sk-proj-" + "a" * 40)

    def test_empty_key_rejected(self):
        assert not _is_valid_key("claude", "")

    def test_too_short_rejected(self):
        assert not _is_valid_key("claude", "sk-ant-short")

    @pytest.mark.parametrize("placeholder", [
        "test", "fake", "dummy", "example", "your_key", "xxx", "abc"
    ])
    def test_placeholder_rejected(self, placeholder):
        key = f"sk-ant-api03-{placeholder}-" + "a" * 30
        assert not _is_valid_key("claude", key)

    def test_key_with_xxx_in_ui_rejected(self):
        # UI 預設顯示的遮罩值不應被視為有效 key
        assert not _is_valid_key("claude", "secret_xxxxxxxxxxxxxxxx")


class TestHasLlmKey:
    def test_no_keys_in_env(self, monkeypatch):
        monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
        monkeypatch.delenv("GEMINI_API_KEY", raising=False)
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)
        assert not has_llm_key()

    def test_valid_anthropic_key_detected(self, monkeypatch):
        monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-api03-" + "a" * 40)
        assert has_llm_key()


class TestLlmPunctuate:
    def test_short_text_skipped(self):
        # 少於 10 字不呼叫 LLM，直接回傳原文
        result = llm_punctuate("你好")
        assert result == "你好"

    def test_no_key_returns_original(self, monkeypatch):
        monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
        monkeypatch.delenv("GEMINI_API_KEY", raising=False)
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)
        text = "今天的會議討論了產品路線圖以及第三季的目標"
        assert llm_punctuate(text) == text

    def test_timeout_returns_original(self, monkeypatch):
        """API 超過 _LLM_TOTAL_TIMEOUT 秒 → 回傳原文，不 block。"""
        monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-api03-" + "a" * 40)

        def slow_urlopen(*args, **kwargs):
            time.sleep(_LLM_TOTAL_TIMEOUT + 5)

        with patch("urllib.request.urlopen", side_effect=slow_urlopen):
            text = "今天的會議討論了產品路線圖以及第三季的目標與重要指標"
            start = time.time()
            result = llm_punctuate(text)
            elapsed = time.time() - start

        assert result == text
        assert elapsed < _LLM_TOTAL_TIMEOUT + 3  # 允許 3s 誤差

    def test_api_error_returns_original(self, monkeypatch):
        """API 回傳錯誤 → 靜默 fallback 原文。"""
        monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-api03-" + "a" * 40)

        import urllib.error
        with patch("urllib.request.urlopen",
                   side_effect=urllib.error.HTTPError(None, 429, "Too Many Requests", {}, None)):
            text = "今天的會議討論了產品路線圖以及第三季的目標與重要指標"
            result = llm_punctuate(text)

        assert result == text

    def test_meta_response_rejected(self, monkeypatch):
        """LLM 回傳比原文長 3 倍以上 → 視為 meta-response，回傳原文。"""
        monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-api03-" + "a" * 40)

        original = "今天會議討論產品方向"
        bloated = original * 10  # 故意回傳超長內容

        mock_resp = MagicMock()
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_resp.read.return_value = (
            '{"content":[{"text":"' + bloated + '"}]}'
        ).encode()

        with patch("urllib.request.urlopen", return_value=mock_resp):
            result = llm_punctuate(original)

        assert result == original
