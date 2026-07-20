"""Process ownership tests for the cancellable inference spike."""
import os
import subprocess
import sys
import threading
import time
import wave

import pytest

import whisper_core
from cancellable_process import ProcessResult, run_cancellable
from transcription_jobs import CancellationToken, TranscriptionCancelled


def test_run_cancellable_collects_stdout_and_stderr():
    result = run_cancellable([
        sys.executable, "-c", "import sys; print('out'); print('err', file=sys.stderr)",
    ])

    assert result.returncode == 0
    assert result.stdout.strip() == "out"
    assert result.stderr.strip() == "err"


def test_run_cancellable_reaps_descendant_holding_output_pipe():
    started_at = time.monotonic()
    result = run_cancellable([
        sys.executable, "-c",
        "import subprocess, sys, time; "
        "subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(2)']); "
        "print('out'); print('err', file=sys.stderr)",
    ], poll_seconds=0.02, terminate_grace_seconds=0.2)

    assert result.returncode == 0
    assert result.stdout.strip() == "out"
    assert result.stderr.strip() == "err"
    assert time.monotonic() - started_at < 1


def test_cancel_terminates_owned_process_group(tmp_path):
    pid_file = tmp_path / "child.pid"
    token = CancellationToken("cancel-child")
    timer = threading.Timer(0.2, token.cancel)
    timer.start()
    started_at = time.monotonic()

    with pytest.raises(TranscriptionCancelled):
        run_cancellable([
            sys.executable, "-c",
            "import os, pathlib, sys, time; "
            "pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)",
            str(pid_file),
        ], cancellation=token, poll_seconds=0.05, terminate_grace_seconds=0.5)

    timer.cancel()
    assert time.monotonic() - started_at < 2
    child_pid = int(pid_file.read_text())
    with pytest.raises(ProcessLookupError):
        os.kill(child_pid, 0)


def test_timeout_terminates_owned_process():
    with pytest.raises(subprocess.TimeoutExpired):
        run_cancellable(
            [sys.executable, "-c", "import time; time.sleep(60)"],
            timeout_seconds=0.1,
            poll_seconds=0.02,
            terminate_grace_seconds=0.2,
        )


def test_mlx_cancellation_is_not_swallowed_by_backend_fallback(monkeypatch):
    token = CancellationToken("cancel-mlx")

    def cancelled(*_args, **_kwargs):
        raise TranscriptionCancelled(token.job_id)

    monkeypatch.setattr(whisper_core, "_HAS_MLX", True)
    monkeypatch.setattr(whisper_core, "_transcribe_mlx_subprocess", cancelled)

    with pytest.raises(TranscriptionCancelled):
        whisper_core._transcribe_file("unused.wav", "base", {}, token)


@pytest.mark.parametrize("backend", ["mlx", "fw"])
def test_frozen_subprocess_backends_use_cancellable_runner(monkeypatch, backend):
    token = CancellationToken(f"cancel-{backend}")
    calls = []

    def fake_runner(command, **kwargs):
        calls.append((command, kwargs))
        return ProcessResult(0, '{"text":"ok","language":"zh","segments":[]}', "")

    monkeypatch.setattr(whisper_core, "run_cancellable", fake_runner)
    if backend == "mlx":
        monkeypatch.setattr(whisper_core, "_get_system_python_mlx", lambda: "python3")
        result = whisper_core._transcribe_mlx_system_subprocess(
            "audio.wav", "base", "zh", cancellation=token,
        )
    else:
        monkeypatch.setattr(whisper_core, "_get_system_python", lambda: "python3")
        result = whisper_core._transcribe_fw_subprocess(
            "audio.wav", "base", "zh", cancellation=token,
        )

    assert result["text"] == "ok"
    assert calls[0][1]["cancellation"] is token


def test_frozen_cancellation_is_not_swallowed_by_fallback(monkeypatch):
    token = CancellationToken("cancel-frozen")
    monkeypatch.setattr(whisper_core.sys, "frozen", True, raising=False)
    monkeypatch.setattr(
        whisper_core, "run_cancellable",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(TranscriptionCancelled(token.job_id)),
    )

    with pytest.raises(TranscriptionCancelled):
        whisper_core._transcribe_file("unused.wav", "base", {}, token)


def test_transcribe_file_normalizes_invalid_language_for_frozen_worker(monkeypatch):
    calls = []
    monkeypatch.setattr(whisper_core.sys, "frozen", True, raising=False)
    monkeypatch.setattr(
        whisper_core,
        "_transcribe_frozen_worker_subprocess",
        lambda *args: calls.append(args) or {"text": "ok", "language": "zh", "segments": []},
    )

    whisper_core._transcribe_file("audio.wav", "base", {"language": "08"})

    assert calls[0][2] is None


def test_frozen_worker_failure_preserves_child_traceback(monkeypatch):
    stderr = "Traceback (most recent call last):\nValueError: invalid language code\n[PYI-1:ERROR] wrapper failed"
    monkeypatch.setattr(
        whisper_core,
        "run_cancellable",
        lambda *_args, **_kwargs: ProcessResult(1, "", stderr),
    )

    with pytest.raises(RuntimeError) as error:
        whisper_core._transcribe_frozen_worker_subprocess("audio.wav", "base", None)

    assert "ValueError: invalid language code" in str(error.value)
    assert "[PYI-1:ERROR]" in str(error.value)


def test_ffmpeg_conversion_uses_cancellable_runner(monkeypatch):
    token = CancellationToken("cancel-ffmpeg")
    calls = []

    def fake_runner(command, **kwargs):
        calls.append((command, kwargs))
        with wave.open(command[-1], "wb") as wav_file:
            wav_file.setnchannels(1)
            wav_file.setsampwidth(2)
            wav_file.setframerate(16000)
            wav_file.writeframes(b"\x00\x00" * 160)
        return ProcessResult(0, "", "")

    monkeypatch.setattr(whisper_core, "_get_ffmpeg", lambda: "ffmpeg")
    monkeypatch.setattr(whisper_core, "run_cancellable", fake_runner)
    monkeypatch.setattr(
        whisper_core, "_transcribe_file",
        lambda *_args, **_kwargs: {"text": "ok", "language": "zh", "segments": []},
    )

    text, language, _info = whisper_core.run_whisper(
        b"audio", ".webm", "base", "zh", cancellation=token, skip_llm=True,
    )

    assert (text, language) == ("ok", "zh")
    assert calls[0][1]["cancellation"] is token
