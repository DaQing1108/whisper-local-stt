"""End-to-end tests for the JSONL Worker runtime with a fake transcriber."""
import io
import json
import time

import worker_entrypoint
from worker_entrypoint import WorkerRuntime, run_worker
from worker_protocol import PROTOCOL_NAME, PROTOCOL_VERSION


def _command(request_id, command, payload=None):
    return json.dumps({
        "protocol": PROTOCOL_NAME,
        "version": PROTOCOL_VERSION,
        "type": "command",
        "request_id": request_id,
        "command": command,
        "payload": payload or {},
    }) + "\n"


def _events(stdout):
    return [json.loads(line) for line in stdout.getvalue().splitlines()]


def test_worker_ping_emits_ready_and_pong():
    stdout = io.StringIO()
    result = run_worker(
        io.StringIO(_command("ping-1", "ping")), stdout, io.StringIO(),
        lambda *_args, **_kwargs: None,
    )

    assert result == 0
    assert [event["event"] for event in _events(stdout)] == ["ready", "pong"]


def test_worker_capabilities_reports_bundled_diarization_unavailable():
    stdout = io.StringIO()
    runtime = WorkerRuntime(lambda *_args, **_kwargs: None, stdout, io.StringIO())

    runtime.handle_line(_command("caps-1", "capabilities"))

    event = _events(stdout)[0]
    assert event["event"] == "capabilities"
    assert event["payload"]["diarization"]["available"] is False
    assert event["payload"]["diarization"]["code"] == "BUNDLED_RUNTIME_UNAVAILABLE"
    assert "/usr/bin/python3" not in json.dumps(event)


def test_worker_transcribes_file_and_keeps_stdout_jsonl_only(tmp_path):
    audio_path = tmp_path / "audio.wav"
    audio_path.write_bytes(b"audio")
    stdout, stderr = io.StringIO(), io.StringIO()

    def fake_transcriber(*_args, **kwargs):
        print("diagnostic noise")
        kwargs["event_sink"]("status", {"msg": "working"})
        kwargs["progress_cb"](1, 1, "partial")
        return "final text", "zh", {"segments": []}

    runtime = WorkerRuntime(fake_transcriber, stdout, stderr)
    runtime.handle_line(_command("tx-1", "transcribe", {
        "audio_path": str(audio_path), "model_name": "base", "language": "zh",
    }))
    result = 0 if runtime.wait_for_idle() else 1

    events = _events(stdout)
    assert result == 0
    assert [event["event"] for event in events] == [
        "accepted", "status", "progress", "completed",
    ]
    assert events[-1]["payload"]["text"] == "final text"
    assert "diagnostic noise" not in stdout.getvalue()
    assert "diagnostic noise" in stderr.getvalue()


def test_worker_cancel_reaches_active_job(tmp_path):
    audio_path = tmp_path / "audio.wav"
    audio_path.write_bytes(b"audio")
    stdout, stderr = io.StringIO(), io.StringIO()

    def slow_transcriber(*_args, **kwargs):
        cancellation = kwargs["cancellation"]
        while not cancellation.is_cancelled:
            time.sleep(0.01)
        cancellation.raise_if_cancelled()

    runtime = WorkerRuntime(slow_transcriber, stdout, stderr)
    runtime.handle_line(_command("tx-1", "transcribe", {
        "audio_path": str(audio_path), "model_name": "base",
    }))
    job_id = _events(stdout)[0]["payload"]["job_id"]
    runtime.handle_line(_command("cancel-1", "cancel", {"job_id": job_id}))

    assert runtime.wait_for_idle()
    events = _events(stdout)
    assert any(event["event"] == "cancelled" for event in events)
    assert any(
        event["event"] == "status" and event["payload"].get("status") == "cancelling"
        for event in events
    )


def test_worker_reports_protocol_error_and_missing_audio():
    stdout = io.StringIO()
    runtime = WorkerRuntime(lambda *_args, **_kwargs: None, stdout, io.StringIO())

    runtime.handle_line("not-json\n")
    runtime.handle_line(_command("tx-missing", "transcribe", {
        "audio_path": "/tmp/definitely-missing-whisper-audio.wav", "model_name": "base",
    }))

    events = _events(stdout)
    assert events[0]["event"] == "protocol_error"
    assert events[1]["payload"]["code"] == "AUDIO_NOT_FOUND"


def test_worker_model_status_and_warmup_use_injected_manager():
    class FakeModelManager:
        def status(self, model_name):
            return {"model_name": model_name, "status": "cached", "cached": True, "loaded": False}

        def warmup(self, model_name):
            return {"model_name": model_name, "status": "ready", "cached": True, "loaded": True}

    stdout = io.StringIO()
    runtime = WorkerRuntime(
        lambda *_args, **_kwargs: None, stdout, io.StringIO(), FakeModelManager(),
    )
    runtime.handle_line(_command("model-1", "model_status", {"model_name": "base"}))
    runtime.handle_line(_command("model-2", "warmup_model", {"model_name": "base"}))

    events = _events(stdout)
    assert [event["event"] for event in events] == ["model_status", "model_ready"]
    assert events[1]["payload"]["loaded"] is True


def test_worker_eof_cancels_active_job(tmp_path):
    audio_path = tmp_path / "audio.wav"
    audio_path.write_bytes(b"audio")
    stdout = io.StringIO()

    def wait_for_cancel(*_args, **kwargs):
        cancellation = kwargs["cancellation"]
        while not cancellation.is_cancelled:
            time.sleep(0.01)
        cancellation.raise_if_cancelled()

    result = run_worker(
        io.StringIO(_command("tx-eof", "transcribe", {
            "audio_path": str(audio_path), "model_name": "base",
        })),
        stdout, io.StringIO(), wait_for_cancel,
    )

    assert result == 0
    assert any(event["event"] == "cancelled" for event in _events(stdout))


def test_worker_thread_start_failure_is_structured_and_cleaned(tmp_path, monkeypatch):
    audio_path = tmp_path / "audio.wav"
    audio_path.write_bytes(b"audio")
    stdout = io.StringIO()

    class FailingThread:
        def __init__(self, **_kwargs):
            pass

        def start(self):
            raise RuntimeError("thread start failed")

    monkeypatch.setattr(worker_entrypoint.threading, "Thread", FailingThread)
    runtime = WorkerRuntime(lambda *_args, **_kwargs: None, stdout, io.StringIO())
    runtime.handle_line(_command("tx-thread", "transcribe", {
        "audio_path": str(audio_path), "model_name": "base",
    }))

    events = _events(stdout)
    assert events[-1]["event"] == "failed"
    assert events[-1]["payload"]["code"] == "WORKER_THREAD_FAILED"
    assert runtime.wait_for_idle()
