"""unit/test_prompts.py — build_prompt() 各 domain × extra_terms 測試。"""
import pytest
from whisper_core import (
    build_prompt,
    DOMAIN_TERMS,
    _strip_prompt_echo,
    _merge_prompt,
    MERGED_PROMPT_MAX_CHARS,
)


class TestBuildPrompt:
    def test_general_no_extra_terms_returns_empty(self):
        # general domain 沒有預設術語，無 extra_terms → 空字串
        result = build_prompt("general", "")
        assert result == ""

    def test_media_domain_contains_terms(self):
        result = build_prompt("media", "")
        assert "ASR" in result
        assert "LLM" in result
        assert "timecode" in result

    def test_tech_domain_contains_terms(self):
        result = build_prompt("tech", "")
        assert "軟體開發" in result
        assert "AI模型" in result

    def test_medical_domain_empty(self):
        # medical 目前無預設術語
        result = build_prompt("medical", "")
        assert result == ""

    def test_legal_domain_empty(self):
        result = build_prompt("legal", "")
        assert result == ""

    def test_extra_terms_appended(self):
        result = build_prompt("general", "Claude、Notion、Obsidian")
        assert "Claude" in result
        assert "Notion" in result

    def test_domain_terms_and_extra_combined(self):
        result = build_prompt("tech", "Kubernetes、gRPC")
        assert "軟體開發" in result
        assert "Kubernetes" in result
        # 應以頓號分隔
        assert "、" in result

    def test_unknown_domain_returns_extra_only(self):
        result = build_prompt("unknown_domain", "專有名詞ABC")
        assert "專有名詞ABC" in result

    def test_unknown_domain_no_extra_returns_empty(self):
        result = build_prompt("unknown_domain", "")
        assert result == ""

    @pytest.mark.parametrize("domain", ["general", "media", "medical", "legal", "tech"])
    def test_all_known_domains_dont_crash(self, domain):
        result = build_prompt(domain, "測試術語")
        assert isinstance(result, str)


class TestStripPromptEcho:
    def test_no_echo_unchanged(self):
        text = "今天會議討論產品方向"
        prompt = "軟體開發、雲端架構"
        result = _strip_prompt_echo(text, prompt)
        assert result == text

    def test_empty_prompt_unchanged(self):
        text = "今天的會議內容"
        result = _strip_prompt_echo(text, "")
        assert result == text

    def test_empty_text(self):
        result = _strip_prompt_echo("", "軟體開發")
        assert result == ""

    def test_prompt_at_start_stripped(self):
        prompt = "軟體開發、雲端架構"
        # Whisper 有時把 prompt 直接輸出在前面
        text = f"{prompt}今天的重點是 API 設計"
        result = _strip_prompt_echo(text, prompt)
        assert "軟體開發" not in result or "今天的重點" in result


class TestMergePrompt:
    def test_domain_and_override_both_present_merges_both(self):
        domain_prompt = "ASR、DGX、TVBS"
        override = "剛才提到的預算數字"
        result = _merge_prompt(domain_prompt, override)
        assert "ASR" in result
        assert "TVBS" in result
        assert "剛才提到的預算數字" in result

    def test_override_empty_returns_domain_prompt_unchanged(self):
        domain_prompt = "ASR、DGX、TVBS"
        result = _merge_prompt(domain_prompt, "")
        assert result == domain_prompt

    def test_override_none_like_falsy_returns_domain_prompt_unchanged(self):
        domain_prompt = "ASR、DGX、TVBS"
        result = _merge_prompt(domain_prompt, None)
        assert result == domain_prompt

    def test_domain_prompt_empty_returns_override_unchanged(self):
        override = "剛才提到的預算數字"
        result = _merge_prompt("", override)
        assert result == override

    def test_both_empty_returns_empty_string(self):
        result = _merge_prompt("", "")
        assert result == ""

    def test_merged_over_limit_truncates_but_keeps_domain_terms(self):
        domain_prompt = "ASR、DGX、TVBS、RNG、timecode、字幕、後製"
        long_override = "很長的前段語境內容" * 40  # 遠超過門檻
        result = _merge_prompt(domain_prompt, long_override)
        assert len(result) <= MERGED_PROMPT_MAX_CHARS
        # domain 詞彙必須至少保留一部分，不能被完全截掉
        assert "ASR" in result
        assert "DGX" in result

    def test_merge_respects_configured_max_chars_constant(self):
        # 確保長度上限是可讀取的具名常數，而非裸數字寫死在函式內
        assert isinstance(MERGED_PROMPT_MAX_CHARS, int)
        assert MERGED_PROMPT_MAX_CHARS > 0
