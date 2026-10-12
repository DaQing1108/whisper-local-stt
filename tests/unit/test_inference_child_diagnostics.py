import io
import json
import sys
import types
import wave
from contextlib import redirect_stdout

import pytest

import worker_entrypoint


class _FakeSegment:
    def __init__(self, text, start, end):
        self.text, self.start, self.end = text, start, end


class _FakeModel:
    def __init__(self, *args, **kwargs):
        pass

    def transcribe(self, *args, **kwargs):
        info = types.SimpleNamespace(language="zh")
        return iter([_FakeSegment("你好", 0.0, 1.0), _FakeSegment("世界", 1.0, 2.0)]), info


class _Clock:
    """Fake `time` module: monotonic() advances by `step` per call."""

    def __init__(self, step):
        self.now, self.step = 0.0, step

    def monotonic(self):
        value = self.now
        self.now += self.step
        return value


@pytest.fixture
def diag_dir(tmp_path, monkeypatch):
    directory = tmp_path / "diag"
    monkeypatch.setenv("WHISPER_DIAGNOSTICS_DIR", str(directory))
    fake = types.ModuleType("faster_whisper")
    fake.WhisperModel = _FakeModel
    monkeypatch.setitem(sys.modules, "faster_whisper", fake)
    return directory


def _make_wav(path, seconds=10, rate=1000):
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(b"\x00\x00" * rate * seconds)
    return path


def _run(wav):
    buf = io.StringIO()
    with redirect_stdout(buf):
        code = worker_entrypoint.run_inference_child([str(wav), "large-v3", "zh", ""])
    return code, buf.getvalue()


def _lines(diag_dir):
    return [json.loads(l) for l in (diag_dir / "inference.jsonl").read_text().splitlines()]


def test_normal_inference_appends_one_record(tmp_path, diag_dir, monkeypatch):
    monkeypatch.setattr(worker_entrypoint, "time", _Clock(step=1.0))
    wav = _make_wav(tmp_path / "a.wav", seconds=10)
    code, _ = _run(wav)
    assert code == 0
    (record,) = _lines(diag_dir)
    assert record["audio_seconds"] == 10
    assert record["model"] == "large-v3"
    assert record["elapsed_seconds"] == 1.0
    assert record["segments"] == 2
    assert isinstance(record["cpu_seconds"], float)
    assert "T" in record["timestamp"]
    assert not list(diag_dir.glob("*.wav"))


def test_unreadable_wav_records_null_audio_seconds(tmp_path, diag_dir):
    bad = tmp_path / "bad.wav"
    bad.write_bytes(b"not a wav")
    code, _ = _run(bad)
    assert code == 0
    assert _lines(diag_dir)[0]["audio_seconds"] is None


def test_stdout_is_only_original_json(tmp_path, diag_dir):
    code, out = _run(_make_wav(tmp_path / "a.wav"))
    assert code == 0
    assert out.count("\n") == 1
    assert json.loads(out) == {
        "text": "你好 世界",
        "language": "zh",
        "segments": [
            {"text": "你好", "start": 0.0, "end": 1.0},
            {"text": "世界", "start": 1.0, "end": 2.0},
        ],
    }


def test_slow_inference_copies_wav(tmp_path, diag_dir, monkeypatch):
    monkeypatch.setattr(worker_entrypoint, "time", _Clock(step=100.0))
    code, _ = _run(_make_wav(tmp_path / "a.wav", seconds=10))
    assert code == 0
    copies = list(diag_dir.glob("slow-*.wav"))
    assert len(copies) == 1
    assert _lines(diag_dir)[0]["wav_saved"] == copies[0].name


def test_exactly_three_times_is_not_slow(tmp_path, diag_dir, monkeypatch):
    monkeypatch.setattr(worker_entrypoint, "time", _Clock(step=30.0))
    _run(_make_wav(tmp_path / "a.wav", seconds=10))
    assert not list(diag_dir.glob("*.wav"))


def test_oversize_wav_not_copied_but_logged(tmp_path, diag_dir, monkeypatch):
    monkeypatch.setattr(worker_entrypoint, "time", _Clock(step=100.0))
    monkeypatch.setattr(worker_entrypoint, "SLOW_WAV_MAX_BYTES", 10)
    _run(_make_wav(tmp_path / "a.wav", seconds=10))
    assert not list(diag_dir.glob("*.wav"))
    record = _lines(diag_dir)[0]
    assert record["wav_saved"] is False
    assert record["wav_skipped"] == "too_large"


def test_unwritable_diagnostics_dir_does_not_affect_result(tmp_path, monkeypatch, capsys):
    blocker = tmp_path / "file"
    blocker.write_text("x")
    monkeypatch.setenv("WHISPER_DIAGNOSTICS_DIR", str(blocker / "sub"))
    fake = types.ModuleType("faster_whisper")
    fake.WhisperModel = _FakeModel
    monkeypatch.setitem(sys.modules, "faster_whisper", fake)
    code = worker_entrypoint.run_inference_child(
        [str(_make_wav(tmp_path / "a.wav")), "large-v3", "zh", ""]
    )
    captured = capsys.readouterr()
    assert code == 0
    assert json.loads(captured.out)["text"] == "你好 世界"
    assert "diagnostics failed" in captured.err


def test_keeps_only_latest_ten_slow_wavs(tmp_path, diag_dir, monkeypatch):
    monkeypatch.setattr(worker_entrypoint, "time", _Clock(step=100.0))
    wav = _make_wav(tmp_path / "a.wav", seconds=1)
    for _ in range(13):
        _run(wav)
    names = sorted(p.name for p in diag_dir.glob("slow-*.wav"))
    assert len(names) == 10
    saved = [r["wav_saved"] for r in _lines(diag_dir)]
    assert names == sorted(saved)[-10:]
