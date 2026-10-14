"""unit/test_corrections.py — 誤聽修正表（apply_corrections / transcribe 選填 corrections）。

規則：精確字串、區分大小寫；純 ASCII 的 wrong 要求左右不是英數字；長規則優先、單趟替換；
未帶 corrections 時 Worker 輸出與既有行為逐字相同。所有內容皆為合成資料。
"""
from __future__ import annotations

import io
import json

import pytest

from whisper_core import apply_corrections, apply_corrections_to_text
from worker_entrypoint import WorkerRuntime
from worker_protocol import PROTOCOL_NAME, PROTOCOL_VERSION, ProtocolError, decode_command


def _rules(*pairs):
    return [{"wrong": wrong, "right": right} for wrong, right in pairs]


class TestApplyCorrections:
    def test_cjk_substring_replacement(self):
        assert apply_corrections_to_text("把朋友放入到KM裡", _rules(("朋友放入", "文件放入"))) == "把文件放入到KM裡"

    def test_ascii_requires_non_alphanumeric_neighbours(self):
        rules = _rules(("Free", "FTP"))
        assert apply_corrections_to_text("用 Free 上傳", rules) == "用 FTP 上傳"
        assert apply_corrections_to_text("Free上傳", rules) == "FTP上傳"
        assert apply_corrections_to_text("Freedom 很重要", rules) == "Freedom 很重要"
        assert apply_corrections_to_text("XFree", rules) == "XFree"

    def test_case_sensitive(self):
        assert apply_corrections_to_text("free 上傳", _rules(("Free", "FTP"))) == "free 上傳"

    def test_longer_rule_wins_and_no_chained_replacement(self):
        rules = _rules(("Zyn", "Q1"), ("Zyn trix", "Zyntrix"), ("Zyntrix", "Zyn"))
        assert apply_corrections_to_text("Zyn trix 與 Zyn", rules) == "Zyntrix 與 Q1"

    def test_empty_or_invalid_rules_leave_text_unchanged(self):
        text = "原始逐字稿 Free 上傳"
        assert apply_corrections_to_text(text, []) == text
        assert apply_corrections_to_text(text, None) == text
        assert apply_corrections_to_text(text, _rules(("F", "X"), ("Free", "Free"), (" ", "X"))) == text

    def test_segments_are_corrected_and_other_fields_kept(self):
        segments = [
            {"start": 0.0, "end": 1.5, "text": "Articature 要更新", "speaker": "Speaker A"},
            {"start": 1.5, "end": 3.0, "text": "沒有需要修正"},
        ]
        corrected = apply_corrections(segments, _rules(("Articature", "Architecture")))

        assert corrected == [
            {"start": 0.0, "end": 1.5, "text": "Architecture 要更新", "speaker": "Speaker A"},
            {"start": 1.5, "end": 3.0, "text": "沒有需要修正"},
        ]
        assert segments[0]["text"] == "Articature 要更新"  # 不改動輸入
        assert apply_corrections(segments, []) is segments


def _command(request_id, command, payload):
    return json.dumps({
        "protocol": PROTOCOL_NAME, "version": PROTOCOL_VERSION, "type": "command",
        "request_id": request_id, "command": command, "payload": payload,
    }) + "\n"


def _transcribe(tmp_path, extra_payload):
    audio_path = tmp_path / "audio.wav"
    audio_path.write_bytes(b"audio")
    stdout = io.StringIO()

    def fake_transcriber(*_args, **_kwargs):
        return "用 Free 上傳到 Freedom", "zh", {
            "segments": [{"start": 0.0, "end": 1.0, "text": "用 Free 上傳到 Freedom"}],
            "domain": "general", "extra_terms": "",
        }

    runtime = WorkerRuntime(fake_transcriber, stdout, io.StringIO())
    runtime.handle_line(_command("tx-1", "transcribe", {
        "audio_path": str(audio_path), "model_name": "base", "language": "zh", **extra_payload,
    }))
    assert runtime.wait_for_idle()
    events = [json.loads(line) for line in stdout.getvalue().splitlines()]
    return next(event for event in events if event["event"] == "completed")["payload"]


class TestWorkerCorrections:
    def test_corrections_apply_to_text_and_segments(self, tmp_path):
        payload = _transcribe(tmp_path, {"corrections": _rules(("Free", "FTP"))})

        assert payload["text"] == "用 FTP 上傳到 Freedom"
        assert payload["info"]["segments"][0]["text"] == "用 FTP 上傳到 Freedom"
        assert payload["info"]["domain"] == "general"

    def test_without_corrections_output_is_identical_to_baseline(self, tmp_path):
        baseline = _transcribe(tmp_path, {})
        assert baseline == {
            "job_id": baseline["job_id"],
            "text": "用 Free 上傳到 Freedom",
            "language": "zh",
            "info": {
                "segments": [{"start": 0.0, "end": 1.0, "text": "用 Free 上傳到 Freedom"}],
                "domain": "general", "extra_terms": "",
            },
        }
        empty = _transcribe(tmp_path, {"corrections": []})
        assert {**empty, "job_id": None} == {**baseline, "job_id": None}

    @pytest.mark.parametrize("corrections", [
        "Free=FTP",
        [{"wrong": "Free"}],
        [{"wrong": "Free", "right": 1}],
        ["Free"],
    ])
    def test_invalid_corrections_are_protocol_errors(self, tmp_path, corrections):
        with pytest.raises(ProtocolError):
            decode_command(_command("tx-2", "transcribe", {
                "audio_path": str(tmp_path / "a.wav"), "model_name": "base", "corrections": corrections,
            }))

    def test_null_corrections_treated_as_empty(self, tmp_path):
        command = decode_command(_command("tx-3", "transcribe", {
            "audio_path": str(tmp_path / "a.wav"), "model_name": "base", "corrections": None,
        }))
        assert command.payload["corrections"] is None
