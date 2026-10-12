import json
import subprocess
import sys
import types
import wave

import pytest

import whisper_core
import worker_entrypoint
from cancellable_process import ProcessResult
from transcription_jobs import TranscriptionCancelled

OK = ProcessResult(0, json.dumps({"text": "ok", "language": "zh", "segments": []}) + "\n", "")


def _wav(path, seconds):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(1000)
        w.writeframes(b"\x00\x00" * 1000 * seconds)
    return str(path)


def _install(monkeypatch, outcomes):
    calls = []

    def fake(command, **kwargs):
        calls.append((list(command), kwargs))
        outcome = outcomes[len(calls) - 1]
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome

    monkeypatch.setattr(whisper_core, "run_cancellable", fake)
    return calls


def _timeout():
    return subprocess.TimeoutExpired(["x"], 1)


def _run(wav):
    return whisper_core._transcribe_frozen_worker_subprocess(wav, "large-v3", "zh", "p")


def test_within_limit_runs_once_with_four_args(tmp_path, monkeypatch):
    calls = _install(monkeypatch, [OK])
    assert _run(_wav(tmp_path / "a.wav", 10))["text"] == "ok"
    assert len(calls) == 1
    assert calls[0][0][-4:] == [str(tmp_path / "a.wav"), "large-v3", "zh", "p"]


def test_timeout_limit_is_60_plus_1_5x_duration(tmp_path, monkeypatch):
    calls = _install(monkeypatch, [OK])
    _run(_wav(tmp_path / "a.wav", 20))
    assert calls[0][1]["timeout_seconds"] == 60 + 1.5 * 20


def test_timeout_retries_once_with_beam_1_and_longer_limit(tmp_path, monkeypatch, capsys):
    calls = _install(monkeypatch, [_timeout(), OK])
    assert _run(_wav(tmp_path / "a.wav", 10))["text"] == "ok"
    assert len(calls) == 2
    assert calls[1][0] == calls[0][0] + ["1"]
    assert calls[1][1]["timeout_seconds"] == 60 + 3.0 * 10
    captured = capsys.readouterr()
    assert "inference watchdog" in captured.err and "beam_size=1" in captured.err
    assert captured.out == ""


def test_retry_timeout_propagates_without_third_attempt(tmp_path, monkeypatch):
    calls = _install(monkeypatch, [_timeout(), _timeout()])
    with pytest.raises(subprocess.TimeoutExpired):
        _run(_wav(tmp_path / "a.wav", 10))
    assert len(calls) == 2


def test_retry_failure_propagates(tmp_path, monkeypatch):
    calls = _install(monkeypatch, [_timeout(), ProcessResult(1, "", "boom")])
    with pytest.raises(RuntimeError, match="boom"):
        _run(_wav(tmp_path / "a.wav", 10))
    assert len(calls) == 2


def test_cancellation_is_not_retried(tmp_path, monkeypatch):
    calls = _install(monkeypatch, [TranscriptionCancelled("job")])
    with pytest.raises(TranscriptionCancelled):
        _run(_wav(tmp_path / "a.wav", 10))
    assert len(calls) == 1


def test_unreadable_duration_has_no_watchdog_and_no_retry(tmp_path, monkeypatch):
    bad = tmp_path / "bad.wav"
    bad.write_bytes(b"nope")
    calls = _install(monkeypatch, [_timeout()])
    with pytest.raises(subprocess.TimeoutExpired):
        _run(str(bad))
    assert len(calls) == 1
    assert "timeout_seconds" not in calls[0][1]


# --- child side -------------------------------------------------------------

class _Model:
    seen = {}

    def __init__(self, *a, **k):
        pass

    def transcribe(self, *a, **kwargs):
        _Model.seen = kwargs
        return iter([]), types.SimpleNamespace(language="zh")


@pytest.fixture
def child(tmp_path, monkeypatch):
    monkeypatch.setenv("WHISPER_DIAGNOSTICS_DIR", str(tmp_path / "diag"))
    fake = types.ModuleType("faster_whisper")
    fake.WhisperModel = _Model
    monkeypatch.setitem(sys.modules, "faster_whisper", fake)
    return tmp_path


def test_child_four_args_defaults_to_beam_5(child, capsys):
    assert worker_entrypoint.run_inference_child([_wav(child / "a.wav", 1), "m", "zh", ""]) == 0
    assert _Model.seen["beam_size"] == 5


def test_child_fifth_arg_sets_beam(child, capsys):
    assert worker_entrypoint.run_inference_child([_wav(child / "a.wav", 1), "m", "zh", "p", "1"]) == 0
    assert _Model.seen["beam_size"] == 1
    assert _Model.seen["initial_prompt"] == "p"
    assert _Model.seen["vad_filter"] is True


@pytest.mark.parametrize("bad", ["abc", "0", "-2", ""])
def test_child_invalid_beam_returns_2(child, capsys, bad):
    assert worker_entrypoint.run_inference_child([_wav(child / "a.wav", 1), "m", "zh", "", bad]) == 2
    assert "usage" in capsys.readouterr().err


def test_child_diagnostics_include_beam_size(child, capsys):
    worker_entrypoint.run_inference_child([_wav(child / "a.wav", 1), "m", "zh", "", "1"])
    records = [json.loads(l) for l in (child / "diag" / "inference.jsonl").read_text().splitlines()]
    assert [r["beam_size"] for r in records] == [1, 1]
