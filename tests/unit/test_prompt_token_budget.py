"""unit/test_prompt_token_budget.py — 詞彙 prompt token 上限（fit_prompt_to_budget / prompt_budget）。

faster-whisper 只保留 initial_prompt 最後 223 個 token，超過的部分從開頭默默丟掉，
會把開頭的詞整個丟掉或切成殘字。這裡驗證：
- 未超過時與 build_prompt 逐字相同（AC-1）。
- 超過時以「整個詞」為單位從開頭捨棄，不留殘字（AC-2、AC-3）。
- 轉錄路徑使用 fit 後的 prompt，tokenizer 取不到時退回原行為（AC-4）。
- Worker prompt_budget 指令（AC-5）。

所有詞彙皆為合成資料，不含真實人名或使用者詞庫。
"""
from __future__ import annotations

import io
import json
from types import SimpleNamespace
from unittest.mock import patch

import pytest

import whisper_core
import worker_entrypoint
from tests.conftest import make_tone_wav
from whisper_core import (
    PROMPT_TOKEN_LIMIT,
    build_prompt,
    count_prompt_tokens,
    fit_prompt_to_budget,
    run_whisper,
)
from worker_entrypoint import WorkerRuntime
from worker_protocol import PROTOCOL_NAME, PROTOCOL_VERSION, ProtocolError, decode_command


class _CharTokenizer:
    """每個字元 = 1 token 的假 tokenizer，讓 token 數可預測。"""

    def encode(self, text, add_special_tokens=True):
        assert add_special_tokens is False, "必須與 faster-whisper 相同，不加 special tokens"
        return SimpleNamespace(ids=list(text))


def _synthetic_terms(count: int) -> list[str]:
    return [f"Zyntrix{index:02d}" for index in range(count)]


def _real_tokenizer_or_skip():
    tokenizer = whisper_core.load_prompt_tokenizer("large-v3-turbo")
    if tokenizer is None:
        pytest.skip("large-v3-turbo tokenizer.json 不在本機 HuggingFace 快取（模型未下載）")
    return tokenizer


@pytest.fixture(autouse=True)
def _clear_tokenizer_cache():
    whisper_core._prompt_tokenizers.clear()
    yield
    whisper_core._prompt_tokenizers.clear()


class TestFitPromptToBudget:
    def test_under_limit_is_identical_to_build_prompt(self):
        """AC-1：未超過時 prompt 與 build_prompt 逐字相同、dropped_terms 為空。"""
        extra = "Zyntrix、Quorvane, Plexidon，Velmora"
        fitted = fit_prompt_to_budget("media", extra, _CharTokenizer())

        assert fitted["prompt"] == build_prompt("media", extra)
        assert fitted["dropped_terms"] == []
        assert fitted["tokens"] == fitted["total_tokens"] == len(" " + build_prompt("media", extra))
        assert fitted["limit"] == PROMPT_TOKEN_LIMIT == 223

    def test_empty_prompt_has_zero_tokens(self):
        fitted = fit_prompt_to_budget("general", "", _CharTokenizer())

        assert fitted == {
            "prompt": "", "tokens": 0, "total_tokens": 0, "limit": 223,
            "kept_terms": [], "dropped_terms": [],
        }

    def test_over_limit_drops_leading_whole_terms(self):
        """AC-2：超過時捨棄開頭的完整詞，prompt 等於保留詞依原規則重組。"""
        terms = _synthetic_terms(30)  # 每詞 9 字元 + ", " → 約 330 token（假 tokenizer）
        extra = ", ".join(terms)

        fitted = fit_prompt_to_budget("general", extra, _CharTokenizer())

        kept = fitted["kept_terms"]
        dropped = fitted["dropped_terms"]
        assert fitted["total_tokens"] > PROMPT_TOKEN_LIMIT
        assert fitted["tokens"] <= PROMPT_TOKEN_LIMIT
        assert dropped == terms[:len(dropped)]
        assert kept == terms[len(dropped):]
        assert fitted["prompt"] == build_prompt("general", ", ".join(kept))
        # 只多捨棄必要的詞：少丟一個就會超過
        one_more = ", ".join(terms[len(dropped) - 1:])
        assert count_prompt_tokens(one_more, _CharTokenizer()) > PROMPT_TOKEN_LIMIT

    def test_domain_terms_are_dropped_first_and_separators_preserved(self):
        """DOMAIN_TERMS 視為最前面的詞；混用分隔符時保留原分隔符、不產生殘字。"""
        extra = "、".join(_synthetic_terms(10)) + "，" + ", ".join(_synthetic_terms(12))
        full = build_prompt("media", extra)

        fitted = fit_prompt_to_budget("media", extra, _CharTokenizer(), limit=150)

        domain_terms = whisper_core.DOMAIN_TERMS["media"].split("、")
        assert fitted["dropped_terms"][:len(domain_terms)] == domain_terms
        assert full.endswith(fitted["prompt"])
        assert fitted["prompt"].startswith(fitted["kept_terms"][0])
        assert fitted["tokens"] <= 150

    def test_single_term_longer_than_limit_drops_everything(self):
        fitted = fit_prompt_to_budget("general", "X" * 300, _CharTokenizer())

        assert fitted["prompt"] == ""
        assert fitted["tokens"] == 0
        assert fitted["kept_terms"] == []
        assert fitted["dropped_terms"] == ["X" * 300]

    def test_real_turbo_tokenizer_with_synthetic_vocabulary(self):
        """AC-3：真實 large-v3-turbo tokenizer，合成詞彙超過上限後 fit 回 223 以內。"""
        tokenizer = _real_tokenizer_or_skip()
        terms = [f"Quorvane Systems {index:02d}" for index in range(25)] + [
            f"量子雲端平台{index:02d}" for index in range(25)
        ]
        extra = ", ".join(terms)

        fitted = fit_prompt_to_budget("general", extra, tokenizer)

        assert count_prompt_tokens(build_prompt("general", extra), tokenizer) > PROMPT_TOKEN_LIMIT
        assert fitted["total_tokens"] > PROMPT_TOKEN_LIMIT
        assert 0 < fitted["tokens"] <= PROMPT_TOKEN_LIMIT
        assert fitted["dropped_terms"] == terms[:len(fitted["dropped_terms"])]
        assert fitted["prompt"] == ", ".join(terms[len(fitted["dropped_terms"]):])

    def test_real_tokenizer_count_matches_faster_whisper_encoding(self):
        """計數必須與 faster-whisper 的 Tokenizer.encode（不加 special tokens）一致。"""
        tokenizer = _real_tokenizer_or_skip()
        from faster_whisper.tokenizer import Tokenizer as FasterWhisperTokenizer

        prompt = "Quorvane Systems、量子雲端平台, Plexidon"
        expected = FasterWhisperTokenizer(
            tokenizer, multilingual=True, task="transcribe", language="zh"
        ).encode(" " + prompt.strip())

        assert count_prompt_tokens(prompt, tokenizer) == len(expected)


class TestTranscriptionUsesBudget:
    def _run(self, extra_terms):
        captured = {}

        def fake_transcribe_file(wav_path, model_name, opts, cancellation=None):
            captured.update(opts)
            return {"text": "合成測試逐字稿內容", "language": "zh", "segments": []}

        with patch("whisper_core._transcribe_file", side_effect=fake_transcribe_file):
            run_whisper(
                make_tone_wav(440.0, 1.0), ".wav", "base", "zh",
                domain="general", extra_terms=extra_terms, skip_llm=True,
            )
        return captured.get("initial_prompt")

    def test_uses_fitted_prompt_when_tokenizer_available(self, monkeypatch):
        """AC-4：tokenizer 可用時，轉錄收到的是 fit 後的 prompt。"""
        monkeypatch.setattr(whisper_core, "load_prompt_tokenizer", lambda _model: _CharTokenizer())
        extra = ", ".join(_synthetic_terms(30))

        prompt = self._run(extra)

        assert prompt == fit_prompt_to_budget("general", extra, _CharTokenizer())["prompt"]
        assert prompt != build_prompt("general", extra)

    def test_falls_back_to_build_prompt_without_tokenizer(self, monkeypatch):
        """AC-4：tokenizer 取不到時維持 build_prompt 原結果。"""
        monkeypatch.setattr(whisper_core, "load_prompt_tokenizer", lambda _model: None)
        extra = ", ".join(_synthetic_terms(30))

        assert self._run(extra) == build_prompt("general", extra)

    def test_load_prompt_tokenizer_returns_none_for_uncached_model(self, monkeypatch):
        monkeypatch.setattr("huggingface_hub.try_to_load_from_cache", lambda *_args, **_kwargs: None)

        assert whisper_core.load_prompt_tokenizer("not-a-real-model") is None
        assert "not-a-real-model" not in whisper_core._prompt_tokenizers


def _command(request_id, command, payload):
    return json.dumps({
        "protocol": PROTOCOL_NAME, "version": PROTOCOL_VERSION, "type": "command",
        "request_id": request_id, "command": command, "payload": payload,
    }) + "\n"


class TestPromptBudgetCommand:
    def _emit(self, payload):
        stdout = io.StringIO()
        runtime = WorkerRuntime(lambda *_args, **_kwargs: None, stdout, io.StringIO())
        runtime.handle_line(_command("budget-1", "prompt_budget", payload))
        return [json.loads(line) for line in stdout.getvalue().splitlines()]

    def test_reports_usage_and_dropped_terms(self, monkeypatch):
        """AC-5：回傳 {tokens, limit, dropped_terms, available}，tokens 為套用前的總用量。"""
        monkeypatch.setattr(whisper_core, "load_prompt_tokenizer", lambda _model: _CharTokenizer())
        extra = ", ".join(_synthetic_terms(30))

        events = self._emit({"model_name": "base", "domain": "general", "extra_terms": extra})

        fitted = fit_prompt_to_budget("general", extra, _CharTokenizer())
        assert [event["event"] for event in events] == ["prompt_budget"]
        assert events[0]["request_id"] == "budget-1"
        assert events[0]["payload"] == {
            "tokens": fitted["total_tokens"], "limit": 223,
            "dropped_terms": fitted["dropped_terms"], "available": True,
        }

    def test_model_not_downloaded_reports_unavailable(self, monkeypatch):
        """AC-5：模型未下載 → available=false，不拋例外。"""
        monkeypatch.setattr(whisper_core, "load_prompt_tokenizer", lambda _model: None)

        events = self._emit({"model_name": "large-v3-turbo", "extra_terms": "Zyntrix"})

        assert events[0]["event"] == "prompt_budget"
        assert events[0]["payload"] == {"tokens": 0, "limit": 223, "dropped_terms": [], "available": False}

    def test_unexpected_failure_reports_unavailable(self, monkeypatch):
        def boom(*_args, **_kwargs):
            raise RuntimeError("tokenizer exploded")

        monkeypatch.setattr(whisper_core, "load_prompt_tokenizer", lambda _model: _CharTokenizer())
        monkeypatch.setattr(whisper_core, "fit_prompt_to_budget", boom)

        assert worker_entrypoint.prompt_budget("base", "general", "Zyntrix")["available"] is False

    def test_does_not_occupy_transcription_job(self, monkeypatch):
        monkeypatch.setattr(whisper_core, "load_prompt_tokenizer", lambda _model: None)
        stdout = io.StringIO()
        runtime = WorkerRuntime(lambda *_args, **_kwargs: None, stdout, io.StringIO())

        runtime.handle_line(_command("budget-2", "prompt_budget", {"model_name": "base"}))

        assert runtime._registry.active_count == 0

    @pytest.mark.parametrize("payload", [
        {},
        {"model_name": ""},
        {"model_name": "base", "extra_terms": 3},
        {"model_name": "base", "domain": None},
    ])
    def test_protocol_rejects_invalid_payload(self, payload):
        with pytest.raises(ProtocolError):
            decode_command(_command("budget-3", "prompt_budget", payload))
