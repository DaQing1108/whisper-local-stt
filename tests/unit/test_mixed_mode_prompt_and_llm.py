"""unit/test_mixed_mode_prompt_and_llm.py — build_prompt / llm_punctuate 生效驗證（共用進入點）。

混音模式（MixedAudioRecordingController → WorkerSupervisor → worker_entrypoint.py
的 JSONL transcribe 命令）與純麥克風/純系統音模式共用同一個 Python 呼叫鏈：
worker_entrypoint._start_transcription() 組出 domain/extra_terms options，
交給 TranscriptionService.transcribe()，最終呼叫 whisper_core.run_whisper()。

這裡直接呼叫 run_whisper()（該呼叫鏈裡真正的共用進入點），只 mock 掉最底層的
_transcribe_file（實際 Whisper 推論）與 llm_punctuate（LLM API 呼叫），驗證：
- AC-C1：非空 domain/extra_terms 時，_transcribe_file 收到的 initial_prompt
  等於 build_prompt(domain, extra_terms) 的輸出。
- AC-C2：輸出逐字稿不含 prompt echo。
- AC-D1：有 LLM key 時 llm_punctuate 被呼叫，且其回傳值出現在最終文字。
- AC-D2：無 LLM key 時 llm_punctuate 不被呼叫，轉錄仍正常完成、不拋例外。

範圍限制：本檔只驗證 run_whisper() 內部邏輯（Python 側 domain/extra_terms → prompt
→ llm_punctuate 的處理鏈），不驗證 Swift 端 MixedAudioRecordingController.domain/
extraTerms 是否經 WorkerSupervisor → JSONL payload 正確傳遞到這裡的 kwargs——那段
Swift→Python 參數傳遞由 WorkerSupervisorTests（Swift 測試）涵蓋。
"""
from __future__ import annotations

from unittest.mock import patch

from tests.conftest import make_tone_wav
from whisper_core import build_prompt, run_whisper


def _mock_transcribe_result(text: str) -> dict:
    return {
        "text": text,
        "language": "zh",
        "segments": [{"text": text, "start": 0.0, "end": 1.0}],
    }


class TestMixedModePromptEffective:
    def test_non_empty_domain_reaches_initial_prompt(self, monkeypatch):
        """AC-C1: domain='media' 的 initial_prompt 必須等於 build_prompt() 輸出，非空。"""
        monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
        monkeypatch.delenv("GEMINI_API_KEY", raising=False)
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)

        captured_opts = {}

        def fake_transcribe_file(wav_path, model_name, opts, cancellation=None):
            captured_opts.update(opts)
            return _mock_transcribe_result("這是一段混音測試逐字稿")

        with patch("whisper_core._transcribe_file", side_effect=fake_transcribe_file):
            text, lang, info = run_whisper(
                make_tone_wav(440.0, 1.0), ".wav", "base", "zh",
                domain="media", extra_terms="",
            )

        expected_prompt = build_prompt("media", "")
        assert expected_prompt != ""
        assert captured_opts.get("initial_prompt") == expected_prompt
        assert info["domain"] == "media"

    def test_non_empty_extra_terms_reaches_initial_prompt(self, monkeypatch):
        """AC-C1: extra_terms 非空時同樣要出現在 initial_prompt。"""
        monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
        monkeypatch.delenv("GEMINI_API_KEY", raising=False)
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)

        captured_opts = {}

        def fake_transcribe_file(wav_path, model_name, opts, cancellation=None):
            captured_opts.update(opts)
            return _mock_transcribe_result("混音逐字稿內容")

        with patch("whisper_core._transcribe_file", side_effect=fake_transcribe_file):
            run_whisper(
                make_tone_wav(440.0, 1.0), ".wav", "base", "zh",
                domain="general", extra_terms="Claude、Notion",
            )

        expected_prompt = build_prompt("general", "Claude、Notion")
        assert "Claude" in expected_prompt
        assert captured_opts.get("initial_prompt") == expected_prompt

    def test_output_does_not_contain_prompt_echo(self, monkeypatch):
        """AC-C2: Whisper 若把 prompt 誤當內容輸出，_strip_prompt_echo 必須在混音路徑生效。"""
        monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
        monkeypatch.delenv("GEMINI_API_KEY", raising=False)
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)

        prompt = build_prompt("media", "")

        def fake_transcribe_file(wav_path, model_name, opts, cancellation=None):
            # 模擬 Whisper 把 initial_prompt 原樣輸出在轉錄結果最前面。
            echoed_text = prompt + "今天討論的重點是字幕流程"
            return _mock_transcribe_result(echoed_text)

        with patch("whisper_core._transcribe_file", side_effect=fake_transcribe_file):
            text, _, _ = run_whisper(
                make_tone_wav(440.0, 1.0), ".wav", "base", "zh",
                domain="media", extra_terms="",
            )

        assert "ASR" not in text
        assert "DGX" not in text
        assert "今天討論的重點是字幕流程" in text


class TestMixedModeLlmPunctuateEffective:
    def test_llm_punctuate_called_and_result_used_when_key_present(self, monkeypatch):
        """AC-D1: mock LLM key 存在 + mock llm_punctuate，斷言被呼叫且回傳值出現在最終 text。"""
        monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-api03-" + "a" * 40)

        def fake_transcribe_file(wav_path, model_name, opts, cancellation=None):
            return _mock_transcribe_result("原始逐字稿沒有標點")

        punctuated_text = "已修稿：原始逐字稿，沒有標點。"

        with patch("whisper_core._transcribe_file", side_effect=fake_transcribe_file), \
             patch("whisper_core.llm_punctuate", return_value=punctuated_text) as mock_punctuate:
            text, _, _ = run_whisper(
                make_tone_wav(440.0, 1.0), ".wav", "base", "zh",
                domain="general", extra_terms="",
            )

        mock_punctuate.assert_called_once()
        assert punctuated_text in text or punctuated_text == text

    def test_llm_punctuate_not_called_without_key_and_no_exception(self, monkeypatch):
        """AC-D2: 無 LLM key 時混音轉錄正常完成、不呼叫 llm_punctuate、不拋例外。"""
        monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
        monkeypatch.delenv("GEMINI_API_KEY", raising=False)
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)

        def fake_transcribe_file(wav_path, model_name, opts, cancellation=None):
            return _mock_transcribe_result("沒有 LLM key 的逐字稿")

        with patch("whisper_core._transcribe_file", side_effect=fake_transcribe_file), \
             patch("whisper_core.llm_punctuate") as mock_punctuate:
            text, lang, info = run_whisper(
                make_tone_wav(440.0, 1.0), ".wav", "base", "zh",
                domain="general", extra_terms="",
            )

        mock_punctuate.assert_not_called()
        assert "沒有 LLM key 的逐字稿" in text
        assert lang == "zh"
