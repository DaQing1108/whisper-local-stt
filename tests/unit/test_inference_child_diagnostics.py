import io
import json
import os
import stat
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


class _SeqClock:
    """Fake `time` module returning a fixed sequence of monotonic() values."""

    def __init__(self, values):
        self.values = iter(values)

    def monotonic(self):
        return next(self.values)


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


def _finish(diag_dir):
    (record,) = [r for r in _lines(diag_dir) if r["event"] == "finish"]
    return record


def test_normal_inference_appends_one_record(tmp_path, diag_dir, monkeypatch):
    monkeypatch.setattr(worker_entrypoint, "time", _Clock(step=1.0))
    wav = _make_wav(tmp_path / "a.wav", seconds=10)
    code, _ = _run(wav)
    assert code == 0
    record = _finish(diag_dir)
    assert record["audio_seconds"] == 10
    assert record["model"] == "large-v3"
    assert record["load_seconds"] == 1.0
    assert record["infer_seconds"] == 1.0
    assert record["elapsed_seconds"] == 2.0
    assert record["segments"] == 2
    assert isinstance(record["cpu_seconds"], float)
    assert "T" in record["timestamp"]
    assert not list(diag_dir.glob("*.wav"))


def test_unreadable_wav_records_null_audio_seconds(tmp_path, diag_dir):
    bad = tmp_path / "bad.wav"
    bad.write_bytes(b"not a wav")
    code, _ = _run(bad)
    assert code == 0
    assert _finish(diag_dir)["audio_seconds"] is None


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
    assert _finish(diag_dir)["wav_saved"] == copies[0].name


def test_exactly_three_times_is_not_slow(tmp_path, diag_dir, monkeypatch):
    monkeypatch.setattr(worker_entrypoint, "time", _Clock(step=30.0))
    _run(_make_wav(tmp_path / "a.wav", seconds=10))
    assert not list(diag_dir.glob("*.wav"))


def test_oversize_wav_not_copied_but_logged(tmp_path, diag_dir, monkeypatch):
    monkeypatch.setattr(worker_entrypoint, "time", _Clock(step=100.0))
    monkeypatch.setattr(worker_entrypoint, "SLOW_WAV_MAX_BYTES", 10)
    _run(_make_wav(tmp_path / "a.wav", seconds=10))
    assert not list(diag_dir.glob("*.wav"))
    record = _finish(diag_dir)
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
    saved = [r["wav_saved"] for r in _lines(diag_dir) if r["event"] == "finish"]
    assert names == sorted(saved)[-10:]


def test_result_printed_before_diagnostics_and_survives_failure(tmp_path, diag_dir, monkeypatch):
    seen = {}

    def boom(*args, **kwargs):
        seen["stdout_at_call"] = sys.stdout.getvalue()
        raise RuntimeError("disk on fire")

    monkeypatch.setattr(worker_entrypoint, "_record_inference_finish", boom)
    code, out = _run(_make_wav(tmp_path / "a.wav"))
    assert code == 0
    assert json.loads(seen["stdout_at_call"])["text"] == "你好 世界"
    assert json.loads(out)["text"] == "你好 世界"


def test_start_and_finish_share_pid(tmp_path, diag_dir):
    _run(_make_wav(tmp_path / "a.wav", seconds=10))
    start, finish = _lines(diag_dir)
    assert start["event"] == "start" and finish["event"] == "finish"
    assert start["pid"] == finish["pid"] == os.getpid()
    assert start["audio_seconds"] == 10
    assert start["model"] == "large-v3"
    assert start["prompt_chars"] == 0
    assert "timestamp" in start


def test_start_line_failure_is_swallowed(tmp_path, diag_dir, monkeypatch):
    real = worker_entrypoint._append_diagnostics_record

    def fail_on_start(record):
        if record["event"] == "start":
            raise OSError("nope")
        real(record)

    monkeypatch.setattr(worker_entrypoint, "_append_diagnostics_record", fail_on_start)
    code, out = _run(_make_wav(tmp_path / "a.wav"))
    assert code == 0
    assert json.loads(out)["language"] == "zh"
    assert [r["event"] for r in _lines(diag_dir)] == ["finish"]


def test_inference_exception_logs_error_and_reraises(tmp_path, diag_dir, monkeypatch):
    class _Exploding(_FakeModel):
        def transcribe(self, *args, **kwargs):
            raise ValueError("bad audio")

    fake = types.ModuleType("faster_whisper")
    fake.WhisperModel = _Exploding
    monkeypatch.setitem(sys.modules, "faster_whisper", fake)
    with pytest.raises(ValueError, match="bad audio"):
        _run(_make_wav(tmp_path / "a.wav"))
    events = _lines(diag_dir)
    assert [r["event"] for r in events] == ["start", "error"]
    assert events[1]["pid"] == events[0]["pid"]
    assert events[1]["error"].startswith("ValueError: bad audio")


def test_slow_model_load_alone_is_not_slow(tmp_path, diag_dir, monkeypatch):
    # started=0, loaded=1000 (slow load), inferred=1010 (infer 10s on 10s audio)
    monkeypatch.setattr(worker_entrypoint, "time", _SeqClock([0.0, 1000.0, 1010.0]))
    _run(_make_wav(tmp_path / "a.wav", seconds=10))
    record = _finish(diag_dir)
    assert record["load_seconds"] == 1000.0
    assert record["infer_seconds"] == 10.0
    assert record["elapsed_seconds"] == 1010.0
    assert "slow" not in record
    assert not list(diag_dir.glob("*.wav"))


def test_permissions_dir_0700_files_0600(tmp_path, diag_dir, monkeypatch):
    monkeypatch.setattr(worker_entrypoint, "time", _Clock(step=100.0))
    diag_dir.mkdir(mode=0o755)
    _run(_make_wav(tmp_path / "a.wav", seconds=10))
    assert stat.S_IMODE(diag_dir.stat().st_mode) == 0o700
    assert stat.S_IMODE((diag_dir / "inference.jsonl").stat().st_mode) == 0o600
    (wav,) = diag_dir.glob("slow-*.wav")
    assert stat.S_IMODE(wav.stat().st_mode) == 0o600


def test_new_dir_created_0700(tmp_path, diag_dir):
    _run(_make_wav(tmp_path / "a.wav"))
    assert stat.S_IMODE(diag_dir.stat().st_mode) == 0o700


def test_log_rotates_over_limit_keeping_one_generation(tmp_path, diag_dir, monkeypatch):
    monkeypatch.setattr(worker_entrypoint, "DIAG_LOG_MAX_BYTES", 300)
    wav = _make_wav(tmp_path / "a.wav")
    diag_dir.mkdir(mode=0o700)
    (diag_dir / "inference.jsonl.1").write_text("OLDEST\n")
    (diag_dir / "inference.jsonl").write_text("x" * 400 + "\n")
    _run(wav)
    rotated = (diag_dir / "inference.jsonl.1").read_text()
    assert rotated.startswith("x" * 400)
    assert "OLDEST" not in rotated
    assert not (diag_dir / "inference.jsonl.2").exists()
    assert (diag_dir / "inference.jsonl").exists()


def test_partial_wav_removed_when_copy_fails(tmp_path, diag_dir, monkeypatch):
    monkeypatch.setattr(worker_entrypoint, "time", _Clock(step=100.0))

    def partial_copy(src, dst, *a, **k):
        open(dst, "wb").write(b"partial")
        raise OSError("disk full")

    monkeypatch.setattr(worker_entrypoint.shutil, "copy2", partial_copy)
    code, out = _run(_make_wav(tmp_path / "a.wav", seconds=10))
    assert code == 0
    assert not list(diag_dir.glob("slow-*.wav"))
    record = _finish(diag_dir)
    assert record["wav_saved"] is False
    assert record["wav_skipped"].startswith("copy_failed")


def test_relative_env_dir_is_ignored(tmp_path, monkeypatch):
    monkeypatch.setenv("WHISPER_DIAGNOSTICS_DIR", "relative/dir")
    assert worker_entrypoint._diagnostics_dir().is_absolute()
    assert worker_entrypoint._diagnostics_dir().name == "Diagnostics"
