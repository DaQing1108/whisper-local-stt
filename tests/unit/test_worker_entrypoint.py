"""End-to-end tests for the JSONL Worker runtime with a fake transcriber."""
import io
import json
import threading
import time
from unittest.mock import patch

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


def test_worker_capabilities_reports_unavailable_without_diarization_manager():
    stdout = io.StringIO()
    runtime = WorkerRuntime(lambda *_args, **_kwargs: None, stdout, io.StringIO())

    runtime.handle_line(_command("caps-1", "capabilities"))

    event = _events(stdout)[0]
    assert event["event"] == "capabilities"
    assert event["payload"]["diarization"]["available"] is False
    assert event["payload"]["diarization"]["code"] == "BUNDLED_RUNTIME_UNAVAILABLE"
    assert "/usr/bin/python3" not in json.dumps(event)


class _FakeDiarizationManager:
    def __init__(self, cached=False):
        self._cached = cached
        self.warmup_called = False

    def status(self):
        return {
            "cached": self._cached,
            "segmentation_cached": self._cached,
            "embedding_cached": self._cached,
            "status": "cached" if self._cached else "needs_download",
        }

    def warmup(self):
        self.warmup_called = True
        self._cached = True
        return self.status()


def test_worker_capabilities_reflects_real_diarization_manager_status():
    stdout = io.StringIO()
    runtime = WorkerRuntime(
        lambda *_args, **_kwargs: None, stdout, io.StringIO(),
        diarization_manager=_FakeDiarizationManager(cached=True),
    )

    runtime.handle_line(_command("caps-1", "capabilities"))

    event = _events(stdout)[0]
    assert event["payload"]["diarization"]["available"] is True
    assert event["payload"]["diarization"]["code"] == "READY"


def test_worker_diarization_warmup_rejects_when_busy(tmp_path):
    audio_path = tmp_path / "audio.wav"
    audio_path.write_bytes(b"audio")
    stdout = io.StringIO()

    def wait_forever(*_args, **kwargs):
        cancellation = kwargs["cancellation"]
        while not cancellation.is_cancelled:
            time.sleep(0.01)
        cancellation.raise_if_cancelled()

    runtime = WorkerRuntime(
        wait_forever, stdout, io.StringIO(), diarization_manager=_FakeDiarizationManager(),
    )
    runtime.handle_line(_command("tx-1", "transcribe", {
        "audio_path": str(audio_path), "model_name": "base",
    }))
    time.sleep(0.05)
    runtime.handle_line(_command("diar-warmup-1", "diarization_warmup"))
    runtime.handle_line(_command("cancel-1", "cancel", {"job_id": "tx-1"}))
    runtime.wait_for_idle()

    events = _events(stdout)
    warmup_events = [e for e in events if e["request_id"] == "diar-warmup-1"]
    assert warmup_events[0]["event"] == "failed"
    assert warmup_events[0]["payload"]["code"] == "WORKER_BUSY"


def test_worker_diarization_warmup_uses_injected_manager():
    stdout = io.StringIO()
    manager = _FakeDiarizationManager(cached=False)
    runtime = WorkerRuntime(
        lambda *_args, **_kwargs: None, stdout, io.StringIO(), diarization_manager=manager,
    )

    runtime.handle_line(_command("diar-warmup-1", "diarization_warmup"))
    runtime.wait_for_idle()

    event = _events(stdout)[0]
    assert event["event"] == "diarization_ready"
    assert event["payload"]["cached"] is True
    assert manager.warmup_called is True


def test_worker_diarization_warmup_reports_manager_unavailable():
    stdout = io.StringIO()
    runtime = WorkerRuntime(lambda *_args, **_kwargs: None, stdout, io.StringIO())

    runtime.handle_line(_command("diar-warmup-1", "diarization_warmup"))

    event = _events(stdout)[0]
    assert event["event"] == "failed"
    assert event["payload"]["code"] == "MODEL_MANAGER_UNAVAILABLE"


def test_worker_second_diarize_rejected_while_first_still_running():
    stdout = io.StringIO()
    release = threading.Event()

    def slow_diarize(audio_path, segments, manager=None):
        release.wait(timeout=2)
        return segments

    runtime = WorkerRuntime(
        lambda *_args, **_kwargs: None, stdout, io.StringIO(),
        diarization_manager=_FakeDiarizationManager(cached=True),
    )
    import diarization_service
    with patch.object(diarization_service, "diarize", side_effect=slow_diarize):
        runtime.handle_line(_command("diar-1", "diarize", {"audio_path": "a.wav", "segments": []}))
        time.sleep(0.05)
        runtime.handle_line(_command("diar-2", "diarize", {"audio_path": "a.wav", "segments": []}))
        release.set()
        runtime.wait_for_idle()

    events = _events(stdout)
    second = [e for e in events if e["request_id"] == "diar-2"][0]
    assert second["event"] == "failed"
    assert second["payload"]["code"] == "WORKER_BUSY"


def test_worker_diarize_reports_model_not_ready_when_uncached():
    stdout = io.StringIO()
    runtime = WorkerRuntime(
        lambda *_args, **_kwargs: None, stdout, io.StringIO(),
        diarization_manager=_FakeDiarizationManager(cached=False),
    )

    runtime.handle_line(_command("diar-1", "diarize", {"audio_path": "a.wav", "segments": []}))
    runtime.wait_for_idle()

    event = _events(stdout)[0]
    assert event["event"] == "failed"
    assert event["payload"]["code"] == "MODEL_NOT_READY"


def test_worker_diarize_merges_speakers_when_cached(monkeypatch):
    stdout = io.StringIO()
    runtime = WorkerRuntime(
        lambda *_args, **_kwargs: None, stdout, io.StringIO(),
        diarization_manager=_FakeDiarizationManager(cached=True),
    )

    def fake_diarize(audio_path, segments, manager=None):
        return [{**segment, "speaker": "Speaker A"} for segment in segments]

    import diarization_service
    monkeypatch.setattr(diarization_service, "diarize", fake_diarize)

    runtime.handle_line(_command("diar-1", "diarize", {
        "audio_path": "a.wav", "segments": [{"start": 0.0, "end": 1.0, "text": "hi"}],
    }))
    runtime.wait_for_idle()

    event = _events(stdout)[0]
    assert event["event"] == "diarized"
    assert event["payload"]["segments"] == [{"start": 0.0, "end": 1.0, "text": "hi", "speaker": "Speaker A"}]


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
